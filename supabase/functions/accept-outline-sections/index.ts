import { createClient } from "jsr:@supabase/supabase-js@2";

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
  storyArcBeatID?: string | null;
};
type RequestBody = {
  outline_id: string;
  project_id: string;
  idempotency_key: string;
  sections: Section[];
};

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });
}
function errorResponse(code: string, message: string, status: number) {
  return response({ errorCode: code, message }, status);
}
function isUUID(value: unknown): value is string {
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
function validate(body: RequestBody): string | null {
  if (
    !body || !isUUID(body.outline_id) || typeof body.project_id !== "string" ||
    body.project_id.length === 0
  ) return "outline_id and project_id are required";
  if (
    typeof body.idempotency_key !== "string" ||
    body.idempotency_key.length < 1 || body.idempotency_key.length > 1000
  ) return "idempotency_key is required";
  if (
    !Array.isArray(body.sections) || body.sections.length < 1 ||
    body.sections.length > 100
  ) return "sections must contain 1-100 items";
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
  }
  return null;
}
function sectionRow(section: Section, outlineID: string, position: number) {
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
    story_arc_beat_id: section.storyArcBeatID ?? null,
    status: "draft",
  };
}

async function normalizeStoryArcBeatIDs(
  db: ReturnType<typeof admin>,
  sections: Section[],
) {
  const requestedIDs = [
    ...new Set(
      sections
        .map((section) => section.storyArcBeatID)
        .filter((id): id is string => Boolean(id)),
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
  const validIDs = new Set((data ?? []).map((row) => row.id));
  return sections.map((section) => ({
    ...section,
    // Match embed-section's defensive FK behavior: a stale/local-only beat
    // must not prevent the entire Accept All batch from being inserted.
    storyArcBeatID: section.storyArcBeatID &&
        validIDs.has(section.storyArcBeatID)
      ? section.storyArcBeatID
      : null,
  }));
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
  if (snapshotError || !snapshot) return;
  const { data: rows, error: rowsError } = await db.from("outline_sections")
    .select(
      "id,position,title,summary,container,pov,terminal_beat,status,parent_id,story_arc_beat_id",
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
    candidate.id === request.outline_id
  );
  if (!outline) return;
  const existing = Array.isArray(outline.sections)
    ? outline.sections as Record<string, unknown>[]
    : [];
  const byID = new Map(existing.map((section) => [section.id, section]));
  for (const row of rows ?? []) {
    byID.set(row.id, {
      id: row.id,
      position: row.position,
      title: row.title,
      summary: row.summary,
      container: row.container,
      pov: row.pov,
      terminalBeat: row.terminal_beat,
      status: row.status,
      parentID: row.parent_id,
      storyArcBeatID: row.story_arc_beat_id,
    });
  }
  outline.sections = Array.from(byID.values()).sort((a, b) =>
    Number(a.position ?? 0) - Number(b.position ?? 0)
  );
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
    const normalizedSections = await normalizeStoryArcBeatIDs(
      db,
      request.sections,
    );
    const normalizedRequest = { ...request, sections: normalizedSections };
    const sectionIDs = normalizedSections.map((s) => s.id);
    await db.from("outline_accept_runs").update({
      sections_total: normalizedSections.length,
      section_ids: sectionIDs,
    }).eq("id", runID);
    const { data: positions, error: positionError } = await db.from(
      "outline_sections",
    )
      .select("position")
      .eq("outline_id", normalizedRequest.outline_id)
      .order("position", { ascending: false })
      .limit(1);
    if (positionError) {
      throw new Error(
        `Could not read outline position: ${positionError.message}`,
      );
    }
    const basePosition = (positions?.[0]?.position ?? -1) + 1;
    const { error: insertError } = await db.from("outline_sections").upsert(
      normalizedSections.map((s, index) =>
        sectionRow(s, normalizedRequest.outline_id, basePosition + index)
      ),
      { onConflict: "id" },
    );
    if (insertError) {
      throw new Error(`Could not create sections: ${insertError.message}`);
    }
    const embedURL = `${
      Deno.env.get("SUPABASE_URL")
    }/functions/v1/embed-section`;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    let done = 0;
    let failed = 0;
    for (let i = 0; i < normalizedSections.length; i += 4) {
      const batch = normalizedSections.slice(i, i + 4);
      const results = await Promise.all(batch.map(async (section) => {
        try {
          const embedResponse = await fetch(embedURL, {
            method: "POST",
            headers: {
              Authorization: authHeader,
              apikey: anonKey,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              outline_section_id: section.id,
              outline_id: normalizedRequest.outline_id,
              project_id: normalizedRequest.project_id,
              position: section.position,
              title: section.title,
              summary: section.summary,
              container: section.container ?? null,
              pov: section.pov ?? null,
              terminal_beat: section.terminalBeat ?? null,
              story_arc_beat_id: section.storyArcBeatID ?? null,
              raw_text: [
                `Title: ${section.title}`,
                `Summary: ${section.summary}`,
                section.terminalBeat
                  ? `Terminal Beat: ${section.terminalBeat}`
                  : "",
              ].filter(Boolean).join("\\n\\n"),
            }),
          });
          if (!embedResponse.ok) {
            throw new Error(`embed-section returned ${embedResponse.status}`);
          }
          await db.from("outline_sections").update({ status: "accepted" }).eq(
            "id",
            section.id,
          ).eq("outline_id", normalizedRequest.outline_id);
          return true;
        } catch (err) {
          console.error(
            `[accept-outline-sections] section ${section.id} failed`,
            err,
          );
          return false;
        }
      }));
      done += results.filter(Boolean).length;
      failed += results.filter((ok) => !ok).length;
      await db.from("outline_accept_runs").update({
        sections_done: done,
        sections_failed: failed,
      }).eq("id", runID);
    }
    if (!failed) {
      try {
        await mergeSectionsIntoSnapshot(db, normalizedRequest, userID);
      } catch (snapshotError) {
        console.error(
          "[accept-outline-sections] snapshot merge failed",
          snapshotError,
        );
      }
    }
    await db.from("outline_accept_runs").update({
      status: failed ? "failed" : "completed",
      sections_done: done,
      sections_failed: failed,
      error: failed ? `${failed} section(s) failed to embed` : null,
      completed_at: new Date().toISOString(),
    }).eq("id", runID);
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
  const { data: ownedOutline } = await db.from("outlines")
    .select("id")
    .eq("id", body.outline_id)
    .eq("user_id", identity.user.id)
    .maybeSingle();
  if (!ownedOutline) {
    return errorResponse("not_found", "outline not found", 404);
  }
  let { data: run, error } = await db.from("outline_accept_runs").insert({
    user_id: identity.user.id,
    outline_id: body.outline_id,
    project_id: body.project_id,
    idempotency_key: body.idempotency_key,
    request_json: body,
    sections_total: body.sections.length,
  }).select("id,status,created_at,updated_at").single();
  if (error) {
    const existing = await db.from("outline_accept_runs").select(
      "id,status,created_at,updated_at",
    ).eq("user_id", identity.user.id).eq(
      "idempotency_key",
      body.idempotency_key,
    ).single();
    if (!existing.data) return errorResponse("db_error", error.message, 500);
    run = existing.data;
  }
  const resolvedRun = run;
  if (!resolvedRun) {
    return errorResponse("db_error", "Could not resolve accept run", 500);
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
