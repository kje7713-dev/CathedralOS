import { createClient } from "jsr:@supabase/supabase-js@2";
import { acceptRunTerminalOutcome } from "./_outcome.ts";
import { canonicalUUID } from "../_shared/uuid.ts";
export { canonicalUUID };

// Durable Accept All worker. The iOS client submits the complete suggestion
// batch once, then polls this job. Embedding remains the canonical pipeline,
// but the loop now runs on the server rather than inside a view Task.

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
};
const ALLOWED_CONTAINERS = new Set([
  "beat",
  "moment",
  "vignette",
  "microScene",
  "scene",
  "developedScene",
  "setPiece",
  "sceneSequence",
  "shortStory",
  "chapter",
  "episode",
]);
const MAX_ACCEPTED_SECTIONS = 200;
const NOVEL_LENGTH_CONTRACT = {
  planning_format: "novel",
  target_word_count: 80000,
  target_word_count_min: 70000,
  target_word_count_max: 90000,
} as const;
const CONTAINER_WORD_RANGES: Record<string, [number, number]> = {
  beat: [58, 192],
  moment: [154, 385],
  vignette: [231, 692],
  microScene: [308, 692],
  scene: [615, 1385],
  developedScene: [1154, 2308],
  setPiece: [1538, 3846],
  sceneSequence: [2308, 5385],
  shortStory: [1923, 6154],
  chapter: [2308, 6154],
  episode: [3846, 11538],
};

const ALLOWED_POVS = new Set([
  "firstPerson",
  "secondPerson",
  "thirdPersonLimited",
  "thirdPersonOmniscient",
]);

type Section = {
  id: string;
  position: number;
  title: string;
  summary: string;
  container?: string | null;
  pov?: string | null;
  terminalBeat?: string | null;
  entryState?: string | null;
  dramaticEvent?: string | null;
  resultingChange?: string | null;
  terminalState?: string | null;
  storyArcBeatID?: string | null;
  targetWords?: number | null;
  targetWordsMin?: number | null;
  targetWordsMax?: number | null;
  recipeRequirementIDs?: string[] | null;
};
type CanonicalRecipe = Record<string, unknown>;
type RequestBody = {
  outline_id: string;
  project_id: string;
  // PR 13 (recipe-to-acceptance recovery arc): canonical stableLineageID
  // of the project owning this outline. Optional for backward compat with
  // clients that have not yet migrated; when present, the server validates
  // that it matches the Outline's persisted lineage. When absent, the
  // server logs the gap and skips the lineage-match check.
  project_lineage_id?: string | null;
  idempotency_key: string;
  source_recipe_json: CanonicalRecipe;
  sections: Section[];
};

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}
function errorResponse(code: string, message: string, status: number) {
  return response({ errorCode: code, message }, status);
}
export function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}
function admin() {
  return createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );
}

function isCanonicalRecipe(value: unknown): value is CanonicalRecipe {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const recipe = value as CanonicalRecipe;
  const pack = recipe.promptPack;
  return (recipe.schema === "cathedralos.prompt_pack_export" ||
    recipe.schema === "cathedralos.story_packet") &&
    typeof recipe.version === "number" &&
    !!recipe.project && typeof recipe.project === "object" &&
    !!pack && typeof pack === "object" &&
    typeof (pack as Record<string, unknown>).id === "string" &&
    typeof (pack as Record<string, unknown>).name === "string";
}

function canonicalizeJSON(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalizeJSON);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, child]) => [key, canonicalizeJSON(child)]),
    );
  }
  return value;
}

export async function hashCanonicalRecipe(
  recipe: CanonicalRecipe,
): Promise<string> {
  const bytes = new TextEncoder().encode(
    JSON.stringify(canonicalizeJSON(recipe)),
  );
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

/**
 * PR 12 (recipe-to-acceptance recovery arc): canonical server-side request
 * fingerprint for Accept All idempotency. Stable canonical JSON serialization
 * of the immutable request body, with `idempotency_key` excluded so the
 * fingerprint itself does not include the key used to look up its row.
 *
 * Identical inputs → identical fingerprint. Different inputs (any field,
 * key order, or recipe content) → different fingerprint.
 */
export async function computeRequestFingerprint(body: RequestBody): Promise<string> {
  const { idempotency_key: _ignored, ...rest } = body;
  const bytes = new TextEncoder().encode(
    JSON.stringify(canonicalizeJSON(rest)),
  );
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(
    new Uint8Array(digest),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function freezeOutlineRecipe(
  db: ReturnType<typeof admin>,
  outlineID: string,
  recipe: CanonicalRecipe,
): Promise<void> {
  const hash = await hashCanonicalRecipe(recipe);
  const { data: outline, error: readError } = await db.from("outlines")
    .select("source_recipe_hash").eq("id", outlineID).single();
  if (readError || !outline) {
    throw new Error(
      `Could not read outline provenance: ${
        readError?.message ?? "outline not found"
      }`,
    );
  }
  if (outline.source_recipe_hash && outline.source_recipe_hash !== hash) {
    throw new Error(
      "outline already has immutable recipe provenance with a different hash",
    );
  }
  if (outline.source_recipe_hash) return;
  const pack = recipe.promptPack as Record<string, unknown>;
  const { error } = await db.from("outlines").update({
    source_recipe_json: recipe,
    source_recipe_hash: hash,
    source_recipe_version: recipe.version,
    source_prompt_pack_id: pack.id,
    source_prompt_pack_name: pack.name,
  }).eq("id", outlineID).is("source_recipe_hash", null);
  if (error) {
    throw new Error(
      `Could not freeze outline recipe provenance: ${error.message}`,
    );
  }
}
async function authenticate(req: Request) {
  const auth = req.headers.get("Authorization");
  if (!auth) return null;
  const client = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    },
  );
  const { data: { user } } = await client.auth.getUser();
  return user ? { auth, user } : null;
}
export function validate(body: RequestBody): string | null {
  if (
    !body || !isUUID(body.outline_id) || typeof body.project_id !== "string" ||
    body.project_id.length === 0
  ) return "outline_id and project_id are required";
  if (
    body.project_lineage_id != null &&
    typeof body.project_lineage_id !== "string"
  ) return "project_lineage_id must be a string when present";
  if (
    typeof body.idempotency_key !== "string" ||
    body.idempotency_key.length < 1 || body.idempotency_key.length > 1000
  ) return "idempotency_key is required";
  if (!isCanonicalRecipe(body.source_recipe_json)) {
    return "source_recipe_json must be a canonical recipe payload";
  }
  if (
    !Array.isArray(body.sections) || body.sections.length < 1 ||
    body.sections.length > MAX_ACCEPTED_SECTIONS
  ) return `sections must contain 1-${MAX_ACCEPTED_SECTIONS} items`;
  for (const section of body.sections) {
    if (
      !isUUID(section.id) || !Number.isInteger(section.position) ||
      typeof section.title !== "string" || !section.title ||
      typeof section.summary !== "string" || !section.summary
    ) return "invalid section payload";
    if (
      section.container != null && !ALLOWED_CONTAINERS.has(section.container)
    ) return "invalid section container";
    if (section.pov != null && !ALLOWED_POVS.has(section.pov)) {
      return "invalid section pov";
    }
    if (section.storyArcBeatID != null && !isUUID(section.storyArcBeatID)) {
      return "invalid story arc beat ID";
    }
    if (
      section.recipeRequirementIDs != null && (
        !Array.isArray(section.recipeRequirementIDs) ||
        section.recipeRequirementIDs.length > 50 ||
        section.recipeRequirementIDs.some((id) =>
          typeof id !== "string" || id.length < 1 || id.length > 100
        )
      )
    ) return "invalid recipe requirement IDs";
  }
  return null;
}
export function sectionRow(
  section: Section,
  outlineID: string,
  position: number,
) {
  return {
    id: section.id,
    outline_id: outlineID,
    parent_id: null,
    position,
    title: section.title,
    summary: section.summary,
    container: section.container ?? null,
    pov: section.pov ?? null,
    terminal_beat: section.terminalBeat ?? null,
    entry_state: section.entryState ?? null,
    dramatic_event: section.dramaticEvent ?? null,
    resulting_change: section.resultingChange ?? null,
    terminal_state: section.terminalState ?? null,
    story_arc_beat_id: section.storyArcBeatID ?? null,
    target_words: section.targetWords ?? Math.round(((CONTAINER_WORD_RANGES[section.container ?? ""] ?? [615, 1385])[0] + (CONTAINER_WORD_RANGES[section.container ?? ""] ?? [615, 1385])[1]) / 2),
    target_words_min: section.targetWordsMin ?? (CONTAINER_WORD_RANGES[section.container ?? ""] ?? [615, 1385])[0],
    target_words_max: section.targetWordsMax ?? (CONTAINER_WORD_RANGES[section.container ?? ""] ?? [615, 1385])[1],
    recipe_requirement_ids: section.recipeRequirementIDs ?? [],
    status: "draft",
  };
}

export interface LengthContract {
  planning_format: string;
  target_word_count: number;
  target_word_count_min: number;
  target_word_count_max: number;
  projected_word_count: number;
}

/**
 * PR 14 (recipe-to-acceptance recovery arc): recompute the Outline-level
 * projected_word_count from the resulting complete generation-bearing
 * Outline. Counts leaves only (sections that have no children) so grouping
 * parents like chapters are not double-counted against their scenes.
 *
 * Retry safety: re-running this against the same set of section ids does
 * not inflate the total (the leaves are a property of the stored rows,
 * not of the in-flight batch).
 */
export async function fetchLeafSectionTotals(
  db: ReturnType<typeof admin>,
  outlineID: string,
): Promise<{
  projectedWordCount: number;
  targetWordCountMin: number;
  targetWordCountMax: number;
}> {
  // Leaves = sections with no children referencing them as parent_id.
  // We project target_words / target_words_min / target_words_max so the
  // per-leaf container-derived numbers sum into the Outline-level totals.
  const { data, error } = await db.from("outline_sections")
    .select("id,parent_id,target_words,target_words_min,target_words_max,status")
    .eq("outline_id", outlineID)
    .not("status", "eq", "deleted");
  if (error) {
    throw new Error(`Could not read outline sections for length recompute: ${error.message}`);
  }
  const rows = data ?? [];
  const childIDs = new Set<string>();
  for (const row of rows) {
    if (row.parent_id) childIDs.add(row.parent_id);
  }
  let projected = 0;
  let min = 0;
  let max = 0;
  for (const row of rows) {
    if (childIDs.has(row.id)) continue; // skip grouping parents
    projected += Number(row.target_words ?? 0);
    min += Number(row.target_words_min ?? 0);
    max += Number(row.target_words_max ?? 0);
  }
  return { projectedWordCount: projected, targetWordCountMin: min, targetWordCountMax: max };
}

export function buildLengthContract(
  sections: Array<{ container?: string | null }>,
): {
  outline: LengthContract;
  sections: Array<
    { targetWords: number; targetWordsMin: number; targetWordsMax: number }
  >;
} {
  const targets = sections.map((section) => {
    const [min, max] = CONTAINER_WORD_RANGES[section.container ?? ""] ??
      [615, 1385];
    return { min, max, target: (min + max) / 2 };
  });
  const projected = Math.round(
    targets.reduce((sum, value) => sum + value.target, 0),
  );
  return {
    outline: { ...NOVEL_LENGTH_CONTRACT, projected_word_count: projected },
    sections: targets.map(({ min, max, target }) => ({
      targetWords: Math.round(target),
      targetWordsMin: min,
      targetWordsMax: max,
    })),
  };
}

export async function normalizeStoryArcBeatIDs(
  db: ReturnType<typeof admin>,
  sections: Section[],
) {
  const requestedIDs = [
    ...new Set(
      sections
        .map((section) => section.storyArcBeatID)
        .filter((id): id is string => Boolean(id))
        .map(canonicalUUID),
    ),
  ];
  if (!requestedIDs.length) return sections;

  const { data, error } = await db.from("story_arc_beats").select("id").in(
    "id",
    requestedIDs,
  );
  if (error) {
    throw new Error(`Could not validate story arc beats: ${error.message}`);
  }
  const validIDs = new Set(
    (data ?? []).map((row) => canonicalUUID(String(row.id))),
  );
  const missing = requestedIDs.filter((id) => !validIDs.has(id));
  if (missing.length > 0) {
    // Never silently erase the macro-to-section contract. The caller must
    // sync the owning arc first; accepting with NULL would make generation
    // lose Story Arc Context while reporting a successful outline.
    throw new Error(
      `Story arc beat linkage is unavailable: ${missing.join(", ")}`,
    );
  }
  return sections;
}

export function mergeSectionsByCanonicalID(
  existing: Record<string, unknown>[],
  replacements: Record<string, unknown>[],
): Record<string, unknown>[] {
  const byID = new Map(
    existing.map((section) => [canonicalUUID(String(section.id)), section]),
  );
  for (const replacement of replacements) {
    byID.set(canonicalUUID(String(replacement.id)), replacement);
  }
  return Array.from(byID.values());
}

async function mergeSectionsIntoSnapshot(
  db: ReturnType<typeof admin>,
  request: RequestBody,
  userID: string,
) {
  const { data: snapshot, error: snapshotError } = await db.from(
    "project_snapshots",
  )
    .select("id,snapshot_json")
    .eq("user_id", userID)
    .eq("local_project_id", request.project_id)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (snapshotError) {
    throw new Error(
      `Could not read project snapshot: ${snapshotError.message}`,
    );
  }
  if (!snapshot) {
    throw new Error(
      `Could not update project snapshot: no snapshot found for project ${request.project_id}`,
    );
  }
  const { data: rows, error: rowsError } = await db.from("outline_sections")
    .select(
      "id,position,title,summary,container,pov,terminal_beat,entry_state,dramatic_event,resulting_change,terminal_state,status,parent_id,story_arc_beat_id,target_words,target_words_min,target_words_max,recipe_requirement_ids",
    )
    .in("id", request.sections.map((section) => section.id));
  if (rowsError) {
    throw new Error(`Could not read accepted sections: ${rowsError.message}`);
  }
  const payload = structuredClone(snapshot.snapshot_json) as Record<
    string,
    unknown
  >;
  const outlines = Array.isArray(payload.outlines)
    ? payload.outlines as Record<string, unknown>[]
    : [];
  const outline = outlines.find((candidate) =>
    canonicalUUID(String(candidate.id)) === canonicalUUID(request.outline_id)
  );
  if (!outline) {
    throw new Error(
      `Could not update project snapshot: outline ${request.outline_id} not found in snapshot`,
    );
  }
  const existing = Array.isArray(outline.sections)
    ? outline.sections as Record<string, unknown>[]
    : [];
  const replacements = (rows ?? []).map((row) => ({
    id: canonicalUUID(String(row.id)),
    position: row.position,
    title: row.title,
    summary: row.summary,
    container: row.container,
    pov: row.pov,
    terminalBeat: row.terminal_beat,
    entryState: row.entry_state,
    dramaticEvent: row.dramatic_event,
    resultingChange: row.resulting_change,
    terminalState: row.terminal_state,
    status: row.status,
    parentID: row.parent_id == null ? null : canonicalUUID(String(row.parent_id)),
    storyArcBeatID: row.story_arc_beat_id == null
      ? null
      : canonicalUUID(String(row.story_arc_beat_id)),
    targetWords: row.target_words,
    targetWordsMin: row.target_words_min,
    targetWordsMax: row.target_words_max,
    recipeRequirementIDs: Array.isArray(row.recipe_requirement_ids)
      ? row.recipe_requirement_ids
      : [],
  }));
  outline.sections = mergeSectionsByCanonicalID(existing, replacements).sort((
    a,
    b,
  ) => Number(a.position ?? 0) - Number(b.position ?? 0));
  const { error: updateError } = await db.from("project_snapshots").update({
    snapshot_json: payload,
  }).eq("id", snapshot.id);
  if (updateError) {
    throw new Error(
      `Could not update project snapshot: ${updateError.message}`,
    );
  }
}

async function runJob(runID: string, authHeader: string, userID: string) {
  const db = admin();
  const { data: claimed, error: claimError } = await db.rpc(
    "claim_outline_accept_run",
    { p_run_id: runID },
  );
  if (claimError || !claimed?.[0]) return;
  const request = claimed[0].request_json as RequestBody;
  try {
    const normalizedSections = (await normalizeStoryArcBeatIDs(
      db,
      request.sections,
    )).map((section) => ({
      ...section,
      id: canonicalUUID(section.id),
    }));
    const normalizedRequest = { ...request, sections: normalizedSections };

    // PR 15 (recipe-to-acceptance recovery arc): delegate the
    // authoritative writes (recipe provenance freeze + section upsert +
    // outline length recompute + run-completion mark) to one
    // PostgreSQL transaction via commit_outline_accept_run(...). If any
    // step raises inside the RPC, the transaction rolls back and the
    // function returns status="failed". Retries of the same run/request
    // are idempotent because position assignment reads max(existing)+1
    // and the section upsert is ON CONFLICT DO UPDATE.
    // PR 15: compute recipe hash + extract provenance fields inline
    // (this file has hashCanonicalRecipe but no recipeProvenance helper).
    const recipeObj = normalizedRequest.source_recipe_json as unknown as {
      version?: number;
      promptPack?: { id?: string; name?: string };
    };
    const recipeHash = await hashCanonicalRecipe(
      normalizedRequest.source_recipe_json as CanonicalRecipe,
    );
    const sectionsPayload = normalizedSections.map((s) => ({
      id: s.id,
      title: s.title,
      summary: s.summary,
      container: s.container,
      pov: s.pov,
      terminal_beat: s.terminalBeat,
      entry_state: s.entryState,
      dramatic_event: s.dramaticEvent,
      resulting_change: s.resultingChange,
      terminal_state: s.terminalState,
      story_arc_beat_id: s.storyArcBeatID,
      recipe_requirement_ids: s.recipeRequirementIDs ?? [],
    }));
    const { data: commitResult, error: commitError } = await db.rpc(
      "commit_outline_accept_run",
      {
        p_run_id: runID,
        p_user_id: userID,
        p_outline_id: normalizedRequest.outline_id,
        p_recipe_hash: recipeHash,
        p_recipe_version: Number(recipeObj.version ?? 0),
        p_recipe_prompt_pack_id: String(recipeObj.promptPack?.id ?? ""),
        p_recipe_prompt_pack_name: String(recipeObj.promptPack?.name ?? ""),
        p_source_recipe_json: normalizedRequest.source_recipe_json,
        p_sections: sectionsPayload,
      },
    );
    if (commitError) {
      throw new Error(
        `Atomic Accept All commit failed: ${commitError.message}`,
      );
    }
    const commit = (Array.isArray(commitResult) ? commitResult[0] : commitResult) ?? {};
    if (commit.status === "failed") {
      throw new Error(
        `Atomic Accept All commit failed server-side: ${commit.error ?? "unknown"}`,
      );
    }
    // PR 15 (continued): the project snapshot is a derived view of the
    // relational rows. Run the snapshot merge AFTER the atomic commit
    // succeeds — if it fails, the run is marked failed but the
    // authoritative section writes (already committed) remain. A retry of
    // the same run/request will reconcile the snapshot without losing
    // positions (commit_outline_accept_run is idempotent).
    let snapshotError: string | null = null;
    try {
      await mergeSectionsIntoSnapshot(db, normalizedRequest, userID);
    } catch (err) {
      snapshotError = err instanceof Error ? err.message : String(err);
      console.error("[accept-outline-sections] snapshot merge failed", err);
    }
    const committedDone = Number(commit.sections_done ?? normalizedSections.length);
    if (snapshotError) {
      // Relational Accept All is already committed. Keep the durable run
      // retryable rather than reporting a terminal failure for a derived-view
      // repair; the next worker invocation re-runs the idempotent snapshot RPC.
      await db.from("outline_accept_runs").update({
        status: "pending", sections_done: committedDone, sections_failed: 0,
        error: `snapshot_repair_pending: ${snapshotError}`.slice(0, 2000),
        completed_at: null,
      }).eq("id", runID);
      // A pending row is not a retry by itself. Re-enter the worker after the
      // state transition; claim_outline_accept_run will atomically claim it
      // and rerun the idempotent snapshot reconciliation.
      // @ts-ignore EdgeRuntime is globally available in Supabase Edge Runtime.
      EdgeRuntime.waitUntil(runJob(runID, authHeader, userID));
    } else {
      const outcome = acceptRunTerminalOutcome(0, null, null);
      await db.from("outline_accept_runs").update({
        status: outcome.status, sections_done: committedDone, sections_failed: 0,
        error: outcome.error, completed_at: new Date().toISOString(),
      }).eq("id", runID);
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await db.from("outline_accept_runs").update({
      status: "failed",
      error: message.slice(0, 2000),
      completed_at: new Date().toISOString(),
    }).eq("id", runID);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return response({}, 204);
  if (req.method !== "GET" && req.method !== "POST") {
    return errorResponse("method_not_allowed", "GET or POST required", 405);
  }
  const identity = await authenticate(req);
  if (!identity) {
    return errorResponse("not_authenticated", "Invalid token", 401);
  }
  const db = admin();
  if (req.method === "GET") {
    const runID = new URL(req.url).searchParams.get("run_id");
    if (!isUUID(runID)) {
      return errorResponse("missing_param", "run_id query param required", 400);
    }
    const { data: run, error } = await db.from("outline_accept_runs").select(
      "id,status,sections_total,sections_done,sections_failed,error,created_at,updated_at,completed_at",
    ).eq("id", runID).eq("user_id", identity.user.id).single();
    if (error || !run) {
      return errorResponse("not_found", "accept run not found", 404);
    }
    return response({
      run_id: run.id,
      status: run.status,
      sections_total: run.sections_total,
      sections_done: run.sections_done,
      sections_failed: run.sections_failed,
      error: run.error,
      created_at: run.created_at,
      updated_at: run.updated_at,
      completed_at: run.completed_at,
    });
  }
  let body: RequestBody;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }
  const validationError = validate(body);
  if (validationError) {
    return errorResponse("invalid_request", validationError, 400);
  }
  // PR 13: complete ownership-graph validation in a single pass.
  //   - outline.user_id == auth.uid()
  //   - outline exists
  //   - outline.lineage_id (when set) == body.project_lineage_id (when set)
  //   - outline.story_arc_id (when set) owns every non-null section.storyArcBeatID
  //   - source_recipe_json.project.id == body.project_id
  // The pre-existing section UUID collision check (every submitted id may
  // only already belong to THIS same Outline/user) is performed inside
  // runJob() against the live outline_sections table because the user's
  // request body is JSON-only and we cannot trust a pre-checked client.
  const { data: ownedOutline, error: ownedError } = await db.from("outlines")
    .select("id,user_id,lineage_id,story_arc_id")
    .eq("id", body.outline_id)
    .eq("user_id", identity.user.id)
    .maybeSingle();
  if (ownedError) {
    return errorResponse("db_error", ownedError.message, 500);
  }
  if (!ownedOutline) {
    return errorResponse("not_found", "outline not found", 404);
  }
  // PR 13: lineage match (when both sides are present).
  if (
    body.project_lineage_id != null && ownedOutline.lineage_id != null &&
    body.project_lineage_id !== ownedOutline.lineage_id
  ) {
    return errorResponse(
      "lineage_mismatch",
      "project_lineage_id does not match outline.lineage_id",
      409,
    );
  }
  // PR 13: source_recipe_json.project.id must equal body.project_id.
  // CanonicalRecipe is a JSON object typed loosely; treat absent/invalid
  // project.id as a malformed request.
  const recipeProjectId = (body.source_recipe_json as { project?: { id?: unknown } })
    ?.project?.id;
  if (typeof recipeProjectId !== "string" || recipeProjectId.length === 0) {
    return errorResponse(
      "invalid_request",
      "source_recipe_json.project.id is required",
      400,
    );
  }
  if (recipeProjectId !== body.project_id) {
    return errorResponse(
      "recipe_project_mismatch",
      "source_recipe_json.project.id does not match body.project_id",
      409,
    );
  }
  // PR 13: every non-null submitted beat must belong to the outline's
  // linked StoryArc. Outline with no story_arc_id cannot accept beat-tagged
  // sections; outline with story_arc_id must own every submitted beat.
  const submittedBeatIDs = Array.from(new Set(
    body.sections
      .map((s) => s.storyArcBeatID)
      .filter((id): id is string => typeof id === "string" && id.length > 0),
  ));
  if (submittedBeatIDs.length > 0) {
    if (!ownedOutline.story_arc_id) {
      return errorResponse(
        "beat_without_arc",
        "submitted beats reference a Story Arc but the outline has no story_arc_id",
        409,
      );
    }
    const { data: arcBeats, error: arcBeatsError } = await db.from("story_arc_beats")
      .select("id,story_arc_id")
      .in("id", submittedBeatIDs);
    if (arcBeatsError) {
      return errorResponse("db_error", arcBeatsError.message, 500);
    }
    const arcBeatSet = new Set((arcBeats ?? []).map((b) => b.id));
    // Missing beats (already validated upstream as malformed UUIDs by
    // validate()).
    for (const id of submittedBeatIDs) {
      if (!arcBeatSet.has(id)) {
        return errorResponse(
          "beat_not_in_arc",
          `submitted beat ${id} does not belong to the outline's StoryArc`,
          409,
        );
      }
    }
    // Foreign-project beat guard: even if the beat UUID is well-formed and
    // exists in the global story_arc_beats table, it must belong to the
    // outline's story_arc_id. Reject any beat whose story_arc_id differs.
    const arcBeatMap = new Map((arcBeats ?? []).map((b) => [b.id, b.story_arc_id]));
    for (const id of submittedBeatIDs) {
      const beatArcID = arcBeatMap.get(id);
      if (beatArcID && beatArcID !== ownedOutline.story_arc_id) {
        return errorResponse(
          "beat_foreign_arc",
          `submitted beat ${id} belongs to a different StoryArc`,
          409,
        );
      }
    }
  }
  // PR 12: compute the canonical server-side request fingerprint BEFORE
  // insert. Used to detect idempotency-key reuse with a different request
  // body (HTTP 409 idempotency_conflict) and to bind legacy rows on first
  // matching POST after the migration.
  const fingerprint = await computeRequestFingerprint(body);

  let { data: run, error } = await db.from("outline_accept_runs").insert({
    user_id: identity.user.id,
    outline_id: body.outline_id,
    project_id: body.project_id,
    idempotency_key: body.idempotency_key,
    request_fingerprint: fingerprint,
    request_json: body,
    sections_total: body.sections.length,
  }).select(
    "id,status,created_at,updated_at,request_fingerprint,request_json",
  ).single();
  if (error) {
    // Duplicate (user_id, idempotency_key). Fetch the existing row's
    // fingerprint + stored body to compare against the new request.
    const existing = await db.from("outline_accept_runs").select(
      "id,status,created_at,updated_at,request_fingerprint,request_json",
    ).eq("user_id", identity.user.id).eq(
      "idempotency_key",
      body.idempotency_key,
    ).single();
    if (!existing.data) return errorResponse("db_error", error.message, 500);
    const existingRow = existing.data;

    // PR 12: three-way comparison.
    //   1. Same key + same fingerprint → resolve existing run, do not rebind.
    //   2. Same key + null fingerprint (legacy row) → hash stored body, bind
    //      the fingerprint if it matches the new request, else 409 conflict.
    //   3. Same key + different fingerprint → 409 idempotency_conflict.
    if (existingRow.request_fingerprint === fingerprint) {
      run = existingRow;
    } else if (existingRow.request_fingerprint === null) {
      let legacyFingerprint: string;
      try {
        legacyFingerprint = await computeRequestFingerprint(
          existingRow.request_json as RequestBody,
        );
      } catch (_) {
        // Stored body is malformed or missing fields. Treat as conflict
        // rather than silently rebinding.
        return errorResponse(
          "idempotency_conflict",
          "Idempotency key already used with a different request body",
          409,
        );
      }
      if (legacyFingerprint !== fingerprint) {
        return errorResponse(
          "idempotency_conflict",
          "Idempotency key already used with a different request body",
          409,
        );
      }
      // Bind the fingerprint to the legacy row and resolve.
      await db.from("outline_accept_runs").update({
        request_fingerprint: fingerprint,
      }).eq("id", existingRow.id);
      run = { ...existingRow, request_fingerprint: fingerprint };
    } else {
      return errorResponse(
        "idempotency_conflict",
        "Idempotency key already used with a different request body",
        409,
      );
    }
  }
  const resolvedRun = run;
  if (!resolvedRun) {
    return errorResponse("db_error", "Could not resolve accept run", 500);
  }
  if (resolvedRun.status === "failed") {
    const { error: retryError } = await db.from("outline_accept_runs").update({
      status: "pending",
      sections_done: 0,
      sections_failed: 0,
      error: null,
      completed_at: null,
    }).eq("id", resolvedRun.id).eq("status", "failed");
    if (retryError) return errorResponse("db_error", retryError.message, 500);
  }
  // @ts-ignore EdgeRuntime is globally available in Supabase Edge Runtime.
  EdgeRuntime.waitUntil(
    runJob(resolvedRun.id, identity.auth, identity.user.id),
  );
  return response({
    run_id: resolvedRun.id,
    status: resolvedRun.status,
    created_at: resolvedRun.created_at,
    updated_at: resolvedRun.updated_at,
  }, 202);
});
