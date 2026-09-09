// =============================================================================
// run-outline Edge Function (Phase 8 per docs/multi-section-generation.md)
//
// Multi-section generation orchestrator. Kicks off a chapter run that walks
// outline_sections by parent_id (leaf = single; chapter parent = walks
// children in position order). Per-section generation calls generate-story
// with narrow prior-context queries against the 5 structured columns
// (character_deltas, plot_thread_deltas, continuity_facts, open_loops,
// scene_ending_state).
//
// Per Locked Design Rules (PR #306 / #310, Kevin 16:28 EDT):
//   Rule 2: character_deltas merge fields per character_name (not latest-overwrites)
//   Rule 3: stable thread/loop IDs across scenes
//   Rule 4: continuity_facts provenance + active/superseded
//   Rule 5: ALWAYS inject immediately previous section's summary + ending_state
//   Rule 6: retrieve by outline order (position), NOT created_at
//   Rule 7: location must actually filter (not just tie-break)
//   Rule 8: pipeline order generate → persist → extract → next
//   Rule 9: raw_text is stored but not injected by default
//
// Endpoints:
//   POST /functions/v1/run-outline          — kickoff (auth + idempotency + cost-reserve)
//                                             returns immediately; worker runs in background
//   GET  /functions/v1/run-outline?run_id=… — status poll
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createRunOutlineToken } from "../_shared/run-outline-auth.ts";
import {
  getCreditCost,
  type LengthMode,
  type UserEntitlement,
} from "../generate-story/_credits.ts";
import {
  buildGenerateStoryRequest,
  generationOutputId,
  projectSnapshotLookupFilter,
} from "./_generation_request.ts";
import { prepareCreditReservation } from "./_credit_preflight.ts";
import { deriveRecipeObligations } from "../outline-from-recipe/_recipe_obligations.ts";
import {
  CURRENT_MEMORY_PIPELINE_VERSION,
  isCurrentMemoryPipelineVersion,
} from "../_shared/memory-pipeline.ts";
import { formatCanonicalProjectState } from "../_shared/memory-state.ts";
import {
  ensureMemoryPipelineVersion,
  ensureOutputMemory,
} from "../_shared/section-embedding.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import {
  computeMaxChargeCredits,
  getEnabledModelByProviderModel,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, {
    ...init,
    headers: { ...CORS_HEADERS, ...(init.headers ?? {}) },
  });

const errorResponse = (
  code: string,
  message: string,
  status: number,
): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface RunOutlineRequest {
  resume_run_id?: string;
  outline_id: string;
  start_parent_section_id: string;
  model?: string;
  /**
   * Generation scope. Determines which sections the run walks.
   *   "single"    -- just the start section (default, current behavior)
   *   "chapter"   -- the chapter (top-level ancestor) containing start, plus all its descendants
   *   "from_here" -- start + all subsequent sections in outline order (by position)
   */
  scope?: string;
}

export type ReadinessOutline = {
  source_recipe_json?: unknown;
  source_recipe_hash?: unknown;
  target_word_count_min?: unknown;
  projected_word_count?: unknown;
};

export type ReadinessSection = {
  id?: unknown;
  title?: unknown;
  summary?: unknown;
  container?: unknown;
  pov?: unknown;
  terminal_beat?: unknown;
  story_arc_beat_id?: unknown;
  target_words?: unknown;
  target_words_min?: unknown;
  target_words_max?: unknown;
  recipe_requirement_ids?: unknown;
};

export function generationReadinessFailures(
  outline: ReadinessOutline,
  sections: ReadinessSection[],
): string[] {
  const failures: string[] = [];
  if (!outline.source_recipe_json) failures.push("missing_frozen_recipe");
  if (!outline.source_recipe_hash) failures.push("missing_recipe_hash");
  const minimum = Number(outline.target_word_count_min ?? 0);
  const projected = Number(outline.projected_word_count ?? 0);
  if (!minimum || projected < minimum) {
    failures.push("projected_length_below_minimum");
  }
  const budgetTotal = sections.reduce(
    (sum, section) => sum + Number(section.target_words ?? 0),
    0,
  );
  if (!budgetTotal || budgetTotal < minimum) {
    failures.push("section_budgets_below_minimum");
  }
  const missingSections = sections.some((section) =>
    !String(section.id ?? "") || !String(section.title ?? "").trim() ||
    !String(section.summary ?? "").trim() || !String(section.container ?? "") ||
    !String(section.pov ?? "") || !String(section.terminal_beat ?? "").trim()
  );
  if (missingSections) failures.push("section_contract_incomplete");
  if (sections.some((section) => section.story_arc_beat_id == null)) {
    failures.push("section_missing_story_arc_beat");
  }
  const contracts = sections.map((section) =>
    `${String(section.title ?? "").trim().toLowerCase()}\n${
      String(section.summary ?? "").trim().toLowerCase()
    }`
  );
  if (new Set(contracts).size !== contracts.length) {
    failures.push("duplicate_section_contract");
  }
  if (outline.source_recipe_json && sections.length > 0) {
    const obligations = deriveRecipeObligations(
      outline.source_recipe_json as Record<string, unknown>,
    );
    const assigned = new Set(
      sections.flatMap((section) =>
        Array.isArray(section.recipe_requirement_ids)
          ? section.recipe_requirement_ids.map(String)
          : []
      ),
    );
    for (const obligation of obligations.filter((item) => item.required)) {
      if (!assigned.has(obligation.id)) {
        failures.push(`missing_recipe_obligation:${obligation.id}`);
      }
    }
  }
  return failures;
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });

  if (req.method === "GET") return await handleStatus(req, url);
  if (req.method === "POST") return await handleKickoff(req);

  return errorResponse("method_not_allowed", "POST or GET required", 405);
});

// ---- POST /functions/v1/run-outline ---------------------------------------
async function handleKickoff(req: Request): Promise<Response> {
  // 1. Auth
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse("unauthorized", "missing Authorization header", 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse("unauthorized", "invalid JWT", 401);
  }
  const userId = userData.user.id;

  // 2. Parse + validate body
  let body: RunOutlineRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  if (body.resume_run_id) {
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });
    return await handleResume(
      adminClient,
      userId,
      body.resume_run_id,
      authHeader,
    );
  }
  if (!body.outline_id || !body.start_parent_section_id) {
    return errorResponse(
      "invalid_body",
      "outline_id and start_parent_section_id required",
      400,
    );
  }

  // 3. Idempotency: try insert; on 23505 return existing run
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const { data: readinessOutline, error: readinessOutlineError } =
    await adminClient
      .from("outlines")
      .select(
        "source_recipe_json, source_recipe_hash, target_word_count_min, projected_word_count",
      )
      .eq("id", body.outline_id).single();
  if (readinessOutlineError || !readinessOutline) {
    return errorResponse(
      "outline_not_generation_ready",
      "outline not found",
      422,
    );
  }
  const { data: readinessSections, error: readinessSectionError } =
    await adminClient
      .from("outline_sections")
      .select(
        "id, title, summary, container, pov, terminal_beat, story_arc_beat_id, target_words, target_words_min, target_words_max, recipe_requirement_ids",
      )
      .eq("outline_id", body.outline_id);
  if (readinessSectionError) {
    return errorResponse(
      "outline_not_generation_ready",
      "could not inspect outline readiness",
      422,
    );
  }
  const readinessFailures = generationReadinessFailures(
    readinessOutline,
    readinessSections ?? [],
  );
  if (readinessFailures.length > 0) {
    return corsResponse(
      JSON.stringify({
        errorCode: "outline_not_generation_ready",
        message: "Outline is not ready for generation",
        failures: readinessFailures,
      }),
      { status: 422 },
    );
  }
  await adminClient.from("outlines").update({
    planning_status: "generation_ready",
  })
    .eq("id", body.outline_id);
  const idempotencyKey =
    `${userId}:${body.outline_id}:${body.start_parent_section_id}`;

  // Idempotency: check for existing run first.
  // - running → return 409 already_running
  // - terminal (failed/completed) → preserve the historical row and release
  //   the key before inserting a fresh attempt. Never delete a durable run ID:
  //   older clients may still be polling it.
  const { data: existing } = await adminClient
    .from("chapter_runs")
    .select("id, status")
    .eq("idempotency_key", idempotencyKey)
    .maybeSingle();
  if (
    existing && (existing.status === "queued" || existing.status === "running")
  ) {
    // A prior worker may have died before claiming a lease (or while the app
    // was offline). Keep the idempotency response, but also use this retry as
    // a recovery trigger. claim_chapter_run makes this safe if a worker is
    // already active.
    EdgeRuntime.waitUntil(
      queueContinuation(existing.id, authHeader).catch((err) => {
        console.error(
          `[run-outline] resume queue failed for ${existing.id}: ${err}`,
        );
      }),
    );
    return corsResponse(
      JSON.stringify({ errorCode: "already_running", run_id: existing.id }),
      { status: 409 },
    );
  }
  if (existing) {
    const { error: releaseErr } = await adminClient
      .from("chapter_runs")
      .update({ idempotency_key: null })
      .eq("id", existing.id);
    if (releaseErr) {
      console.error(
        `[run-outline] terminal run key release failed: ${releaseErr.message}`,
      );
      return errorResponse(
        "db_error",
        `Previous run cleanup failed: ${releaseErr.message}`,
        500,
      );
    }
  }

  const { data: run, error: insertErr } = await adminClient
    .from("chapter_runs")
    .insert({
      outline_id: body.outline_id,
      start_parent_section_id: body.start_parent_section_id,
      idempotency_key: idempotencyKey,
      status: "queued",
      sections: [],
      credits_reserved: 0,
      memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
    })
    .select()
    .single();
  if (insertErr) {
    console.error(`[run-outline] insert failed: ${insertErr.message}`);
    return errorResponse("db_error", insertErr.message, 500);
  }

  // 4. Walk the outline so we can estimate cost before the loop.
  let sections: Array<{
    id: string;
    title: string;
    position: number;
    summary: string;
    container: string | null;
    pov: string | null;
    terminal_beat: string | null;
    story_arc_beat_id: string | null;
  }>;
  try {
    const scope = body.scope || "single";
    sections = await collectSectionsToGenerate(
      adminClient,
      body.outline_id,
      body.start_parent_section_id,
      scope,
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await adminClient.from("chapter_runs").update({
      status: "failed",
      error: msg,
      completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse("walk_failed", msg, 400);
  }
  if (sections.length === 0) {
    await adminClient.from("chapter_runs").update({
      status: "failed",
      error: "no sections to generate",
      completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse(
      "no_sections",
      "start_parent_section_id has no children and is itself a leaf — but the leaf wasn't found by the walker",
      400,
    );
  }

  // 5. Persist the complete work list before the durable preflight worker.
  // The old implementation estimated every section synchronously here. That
  // made a 45-section kickoff exceed the Edge Function request lifetime and
  // return a generic 502 before a run could be polled.
  const initialSections = sections.map((s) => ({
    id: s.id,
    title: s.title,
    position: s.position,
    summary: s.summary,
    container: s.container,
    pov: s.pov,
    terminal_beat: s.terminal_beat,
    story_arc_beat_id: s.story_arc_beat_id,
    status: "pending",
  }));
  const { error: initError } = await adminClient.from("chapter_runs").update({
    sections: initialSections,
    model: body.model ?? null,
    user_id: userId,
    memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
  }).eq("id", run.id);
  if (initError) {
    await markRunFailed(
      adminClient,
      run.id,
      `could not persist run queue: ${initError.message}`,
    );
    return errorResponse("db_error", initError.message, 500);
  }

  // 6. Return quickly. The queued status is visible to iOS immediately, and
  // the durable worker performs estimates, credit reservation, and generation.
  // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
  EdgeRuntime.waitUntil(
    prepareRun(run.id, adminClient, authHeader).catch(async (err) => {
      const message = err instanceof Error ? err.message : String(err);
      console.error(
        `[run-outline] preparation ${run.id} crashed: ${message}`,
      );
      await markRunFailed(adminClient, run.id, message);
    }),
  );

  return corsResponse(
    JSON.stringify({
      run_id: run.id,
      status: "queued",
      sections: sections.map((section) => ({
        id: section.id,
        title: section.title,
        position: section.position,
        status: "pending",
      })),
      credits_reserved: 0,
      credits_actual: 0,
      error: null,
      created_at: run.created_at,
      updated_at: run.updated_at,
      completed_at: null,
    }),
    { status: 202 },
  );
}

// ---- durable estimate/credit preflight ------------------------------------
async function prepareRun(
  runId: string,
  adminClient: ReturnType<typeof createClient>,
  authHeader: string,
): Promise<void> {
  const { data: claimed, error: claimError } = await adminClient.rpc(
    "claim_chapter_run",
    { p_run_id: runId, p_lease_seconds: 420 },
  );
  if (claimError) {
    throw new Error(`could not claim preparation: ${claimError.message}`);
  }
  const ownsLease = claimed === true ||
    (Array.isArray(claimed) && claimed.length > 0);
  if (!ownsLease) return;

  const { data: run, error: runError } = await adminClient.from("chapter_runs")
    .select("id, outline_id, user_id, model, sections, status")
    .eq("id", runId).single();
  if (runError || !run) throw new Error("run disappeared during preparation");
  if (run.status !== "queued") {
    await releaseRunLease(adminClient, runId);
    return;
  }

  const sections = Array.isArray(run.sections)
    ? run.sections as Array<Record<string, unknown>>
    : [];
  if (sections.length === 0) throw new Error("run queue is empty");

  let estimatedCost: number;
  try {
    estimatedCost = await estimateRunCost(
      adminClient,
      String(run.user_id),
      authHeader,
      String(run.outline_id),
      sections,
      (run.model as string | null) ?? undefined,
    );
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await markRunFailed(adminClient, runId, msg);
    return;
  }

  const { data: entData, error: entErr } = await adminClient
    .from("user_entitlements")
    .select(
      "user_id, plan_name, is_pro, monthly_credit_allowance, purchased_credit_balance, current_period_start, current_period_end, entitlement_source, updated_at",
    )
    .eq("user_id", run.user_id)
    .single();
  if (entErr || !entData) {
    await markRunFailed(adminClient, runId, "could not load user entitlement");
    return;
  }
  const { reservedCredits, check } = prepareCreditReservation(
    estimatedCost,
    entData as UserEntitlement,
  );
  if (!check.allowed) {
    await adminClient.from("chapter_runs").update({
      status: "failed",
      error:
        `insufficient_credits: needed ${reservedCredits}, have ${check.availableCredits}`,
      credits_reserved: 0,
      completed_at: new Date().toISOString(),
      worker_lease_until: null,
    }).eq("id", runId);
    return;
  }

  const { error: startError } = await adminClient.from("chapter_runs").update({
    status: "running",
    credits_reserved: reservedCredits,
    worker_lease_until: null,
  }).eq("id", runId).eq("status", "queued");
  if (startError) {
    throw new Error(`could not start prepared run: ${startError.message}`);
  }

  await queueContinuation(runId, authHeader);
}

// ---- GET /functions/v1/run-outline?run_id=… ------------------------------
async function handleStatus(req: Request, url: URL): Promise<Response> {
  const runId = url.searchParams.get("run_id");
  const outlineID = url.searchParams.get("outline_id");
  const startParentSectionID = url.searchParams.get("start_parent_section_id");
  if (!runId && (!outlineID || !startParentSectionID)) {
    return errorResponse(
      "missing_param",
      "run_id or outline_id + start_parent_section_id required",
      400,
    );
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse("unauthorized", "missing Authorization header", 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse("unauthorized", "invalid JWT", 401);
  }

  // Authenticate with the user client, then read through the service-role
  // client with an explicit user_id filter. The chapter_runs SELECT policy
  // depends on the related outlines row; immediately after kickoff that
  // relationship can briefly lag the run insert, causing a false 404 even
  // though the user's durable run exists and is already progressing.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const runQuery = adminClient
    .from("chapter_runs")
    .select(
      "id, outline_id, start_parent_section_id, status, sections, credits_reserved, credits_actual, error, created_at, updated_at, completed_at",
    )
    .eq("user_id", userData.user.id);
  const { data: run, error: runErr } = runId
    ? await runQuery.eq("id", runId).single()
    : await runQuery
      .eq(
        "idempotency_key",
        `${userData.user.id}:${outlineID}:${startParentSectionID}`,
      )
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
  if (runErr || !run) return errorResponse("not_found", "run not found", 404);

  // A status poll is also a lightweight recovery trigger. If an invocation
  // died after claiming its lease, enqueue one replacement; the DB claim
  // function prevents duplicate workers from processing the same run.
  if (run.status === "queued" || run.status === "running") {
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });
    const { data: durableRun } = await adminClient.from("chapter_runs")
      .select("worker_lease_until, next_retry_at")
      .eq("id", run.id).maybeSingle();
    const retryAt = durableRun?.next_retry_at
      ? new Date(durableRun.next_retry_at).getTime()
      : 0;
    if (
      retryAt <= Date.now() &&
      (!durableRun?.worker_lease_until ||
        new Date(durableRun.worker_lease_until).getTime() < Date.now())
    ) {
      await queueContinuation(runId, authHeader);
    }
  }

  const sections = Array.isArray(run.sections) ? run.sections : [];
  const sections_done =
    sections.filter((s: { status?: string }) => s?.status === "completed")
      .length;
  const sections_failed =
    sections.filter((s: { status?: string }) => s?.status === "failed").length;
  const current_section = sections.find((s: { status?: string }) =>
    s?.status === "running"
  );

  return corsResponse(
    JSON.stringify({
      run_id: run.id,
      status: run.status,
      outline_id: run.outline_id,
      start_parent_section_id: run.start_parent_section_id,
      sections_done,
      sections_total: sections.length,
      sections_failed,
      current_section: current_section
        ? {
          id: (current_section as { id: string }).id,
          title: (current_section as { title: string }).title,
        }
        : null,
      sections,
      error: run.error,
      credits_reserved: run.credits_reserved,
      credits_actual: run.credits_actual,
      created_at: run.created_at,
      updated_at: run.updated_at,
      completed_at: run.completed_at,
    }),
    { status: 200 },
  );
}

// ---- outline-walker + per-section loop (Day 2) -------------------------
async function runOutline(
  runId: string,
  adminClient: ReturnType<typeof createClient>,
  authHeader: string,
): Promise<void> {
  const { data: claimed, error: claimError } = await adminClient.rpc(
    "claim_chapter_run",
    { p_run_id: runId, p_lease_seconds: 420 },
  );
  if (claimError) throw new Error(`could not claim run: ${claimError.message}`);
  const ownsLease = claimed === true ||
    (Array.isArray(claimed) && claimed.length > 0);
  if (!ownsLease) return; // another live invocation owns the lease

  const { data: run, error: runError } = await adminClient.from("chapter_runs")
    .select(
      "id, outline_id, user_id, model, credits_reserved, created_at, sections, next_retry_at, status, memory_pipeline_version, worker_attempt",
    )
    .eq("id", runId).single();
  if (runError || !run) throw new Error("run disappeared after claim");
  if (run.status !== "running") {
    await releaseRunLease(adminClient, runId);
    return;
  }

  const retryAt = run.next_retry_at
    ? new Date(String(run.next_retry_at)).getTime()
    : 0;
  if (retryAt > Date.now()) {
    await releaseRunLease(adminClient, runId);
    return;
  }

  const workerAttempt = Number(
    (run as Record<string, unknown>).worker_attempt ?? 0,
  );
  const sections = Array.isArray(run.sections)
    ? run.sections as Array<Record<string, unknown>>
    : [];
  for (const section of sections) section.worker_attempt = workerAttempt;
  if (run.memory_pipeline_version !== CURRENT_MEMORY_PIPELINE_VERSION) {
    await adminClient.from("chapter_runs").update({
      memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
    }).eq("id", runId);
    console.log(
      `[run-outline] run_id=${runId} upgraded memory pipeline metadata to ${CURRENT_MEMORY_PIPELINE_VERSION}`,
    );
  }
  // Older runs stored only display fields in sections. Hydrate missing inputs
  // from the authoritative outline so those runs are resumable too.
  const sectionIds = sections.map((s) => String(s.id)).filter(Boolean);
  if (sectionIds.length > 0) {
    const { data: outlineSections } = await adminClient.from("outline_sections")
      .select(
        "id, title, position, summary, container, pov, terminal_beat, story_arc_beat_id, target_words, target_words_min, target_words_max, recipe_requirement_ids",
      )
      .in("id", sectionIds);
    const byId = new Map((outlineSections ?? []).map((s) => [s.id, s]));
    for (const section of sections) {
      const source = byId.get(String(section.id));
      if (source) Object.assign(section, source);
    }
  }
  // A killed worker can leave one section marked running. Its output call was
  // not durably acknowledged, so retry that section on the next lease.
  for (const section of sections) {
    if (section.status === "running") section.status = "pending";
  }
  await adminClient.from("chapter_runs").update({ sections }).eq("id", runId);

  const pending = sections.filter((s) => s.status === "pending");
  if (pending.length === 0) {
    await finalizeRun(adminClient, runId, sections);
    return;
  }

  const { data: outlineRow, error: outlineError } = await adminClient.from(
    "outlines",
  )
    .select("local_project_id, source_recipe_json, source_recipe_hash")
    .eq("id", run.outline_id).single();
  if (outlineError || !outlineRow?.local_project_id) {
    throw new Error("outline.local_project_id missing");
  }
  if (!outlineRow.source_recipe_json || !outlineRow.source_recipe_hash) {
    throw new Error(
      "outline recipe provenance missing; re-plan this outline before Run All",
    );
  }
  const projectId = outlineRow.local_project_id;
  const frozenRecipe = outlineRow.source_recipe_json as Record<string, unknown>;
  const recipeObligations = deriveRecipeObligations(frozenRecipe);

  // Keep each invocation bounded. Continuations are independent invocations,
  // so a platform lifetime limit cannot orphan the entire Run All operation.
  const batch = pending.slice(0, 1);
  for (const section of batch) {
    await renewRunLease(adminClient, runId, workerAttempt);
    await updateSectionStatus(adminClient, runId, {
      ...section,
      worker_attempt: workerAttempt,
      status: "running",
      started_at: new Date().toISOString(),
    });
    try {
      // If the platform killed the worker after generate-story persisted its
      // output but before this row was updated, reuse that output. This makes
      // recovery safe and avoids charging the same section twice.
      const normalize = await ensureMemoryPipelineVersion(
        adminClient,
        String(projectId),
        String(section.id),
        Deno.env.get("OPENAI_API_KEY") ?? "",
        {
          userID: String(run.user_id),
          action: "memory-normalization",
          projectID: String(projectId),
          outlineSectionID: String(section.id),
          adminClient,
          creditStore: new SupabaseCreditStore(adminClient),
        },
        1,
      );
      if (normalize.remaining > 0) {
        await updateSectionStatus(adminClient, runId, {
          ...section,
          status: "pending",
        });
        await releaseRunLease(adminClient, runId);
        await queueContinuation(runId, authHeader);
        return;
      }
      const existingOutput = await findRunOutput(
        adminClient,
        String(run.id),
        String(section.id),
        String(run.user_id),
        String(projectId),
      );
      if (existingOutput) {
        await ensureOutputMemory(
          {
            outline_section_id: String(section.id),
            outline_id: String(run.outline_id),
            project_id: String(projectId),
            position: Number(section.position ?? 0),
            title: String(section.title ?? ""),
            summary: String(section.summary ?? ""),
            container: (section.container ?? null) as string | null,
            pov: (section.pov ?? null) as string | null,
            terminal_beat: (section.terminal_beat ?? null) as string | null,
            story_arc_beat_id: (section.story_arc_beat_id ?? null) as
              | string
              | null,
            output_id: existingOutput,
          },
          existingOutput,
          String(run.user_id),
          adminClient,
          Deno.env.get("OPENAI_API_KEY") ?? "",
        );
        await updateSectionStatus(adminClient, runId, {
          ...section,
          status: "completed",
          output_id: existingOutput,
          cost: estimateSectionCost(section.container as string | null),
          completed_at: new Date().toISOString(),
        });
        continue;
      }
      const generationRequest = buildGenerateStoryRequest({
        snapshot: {},
        frozenRecipe,
        frozenRecipeHash: String(outlineRow.source_recipe_hash),
        recipeObligations,
        assignedRecipeRequirementIDs: section.recipe_requirement_ids,
        section,
        projectId,
        runId: run.id,
        selectedModelId: (run.model as string | null) ?? undefined,
        lengthMode: estimateLengthModeFromContainer(
          section.container as string | null,
        ),
      });
      const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
      (generationRequest as Record<string, unknown>).run_outline_token =
        await createRunOutlineToken(
          serviceRoleKey,
          String(run.user_id),
          run.id,
          String(section.id),
        );
      await renewRunLease(adminClient, runId, workerAttempt);
      const result = await callGenerateStory(generationRequest, authHeader);
      await renewRunLease(adminClient, runId, workerAttempt);
      if (result.status !== "complete" || result.wasTruncated) {
        throw new Error(
          `durable generation incomplete for section ${section.id}`,
        );
      }
      // Durable completion is unconditional on the exact persisted output's
      // memory lineage, even when generate-story returned 200.
      await ensureOutputMemory(
        {
          outline_section_id: String(section.id),
          outline_id: String(run.outline_id),
          project_id: String(projectId),
          position: Number(section.position ?? 0),
          title: String(section.title ?? ""),
          summary: String(section.summary ?? ""),
          container: (section.container ?? null) as string | null,
          pov: (section.pov ?? null) as string | null,
          terminal_beat: (section.terminal_beat ?? null) as string | null,
          story_arc_beat_id: (section.story_arc_beat_id ?? null) as
            | string
            | null,
          output_id: result.output_id,
        },
        result.output_id,
        String(run.user_id),
        adminClient,
        Deno.env.get("OPENAI_API_KEY") ?? "",
      );
      await updateSectionStatus(adminClient, runId, {
        ...section,
        status: "completed",
        output_id: result.output_id,
        cost: estimateSectionCost(section.container as string | null),
        completed_at: new Date().toISOString(),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      if (err instanceof RetryableGenerationError) {
        const retryAt = new Date(
          Date.now() + err.retryAfterSeconds * 1000,
        ).toISOString();
        await updateSectionStatus(adminClient, runId, {
          ...section,
          status: "pending",
          error: msg,
          retry_after_seconds: err.retryAfterSeconds,
        });
        await adminClient.from("chapter_runs").update({
          next_retry_at: retryAt,
        }).eq("id", runId).eq("status", "running");
        await releaseRunLease(adminClient, runId);
        // @ts-ignore EdgeRuntime is globally available in Supabase Edge Runtime
        EdgeRuntime.waitUntil(
          queueContinuationAfterDelay(
            runId,
            authHeader,
            err.retryAfterSeconds,
          ).catch((queueError) => {
            console.error(
              `[run-outline] delayed retry queue failed for ${runId}: ${queueError}`,
            );
          }),
        );
        return;
      }
      await updateSectionStatus(adminClient, runId, {
        ...section,
        status: "failed",
        error: msg,
        completed_at: new Date().toISOString(),
      });
      await markRunFailed(
        adminClient,
        runId,
        `section ${section.id} (${section.title}) failed: ${msg}`,
      );
      return;
    }
  }

  const { data: after } = await adminClient.from("chapter_runs")
    .select("sections, status").eq("id", runId).single();
  const afterSections = Array.isArray(after?.sections)
    ? after.sections as Array<Record<string, unknown>>
    : [];
  if (
    after?.status === "running" &&
    afterSections.some((s) => s.status === "pending")
  ) {
    await adminClient.from("chapter_runs").update({ next_retry_at: null })
      .eq("id", runId).eq("status", "running");
    await releaseRunLease(adminClient, runId);
    await queueContinuation(runId, authHeader);
  } else if (after?.status === "running") {
    await finalizeRun(adminClient, runId, afterSections);
  }
}

async function handleResume(
  adminClient: ReturnType<typeof createClient>,
  userId: string,
  runId: string,
  authHeader: string,
): Promise<Response> {
  const { data: run } = await adminClient.from("chapter_runs")
    .select("id, outline_id, status").eq("id", runId).maybeSingle();
  if (!run) return errorResponse("not_found", "run not found", 404);
  const { data: outline } = await adminClient.from("outlines")
    .select("user_id").eq("id", run.outline_id).single();
  if (outline?.user_id !== userId) {
    return errorResponse("not_found", "run not found", 404);
  }
  if (run.status !== "queued" && run.status !== "running") {
    return corsResponse(JSON.stringify({ run_id: runId, status: run.status }), {
      status: 200,
    });
  }
  // @ts-ignore EdgeRuntime is globally available in Supabase Edge Runtime
  EdgeRuntime.waitUntil(
    (run.status === "queued"
      ? prepareRun(runId, adminClient, authHeader)
      : runOutline(runId, adminClient, authHeader)).catch(async (err) => {
        await markRunFailed(
          adminClient,
          runId,
          err instanceof Error ? err.message : String(err),
        );
      }),
  );
  return corsResponse(JSON.stringify({ run_id: runId, status: run.status }), {
    status: 202,
  });
}

async function releaseRunLease(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
): Promise<void> {
  await adminClient.from("chapter_runs").update({ worker_lease_until: null })
    .eq("id", runId).eq("status", "running");
}

async function queueContinuationAfterDelay(
  runId: string,
  authHeader: string,
  retryAfterSeconds: number,
): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, retryAfterSeconds * 1000));
  await queueContinuation(runId, authHeader);
}

async function queueContinuation(
  runId: string,
  authHeader: string,
): Promise<void> {
  const response = await fetch(`${SUPABASE_URL}/functions/v1/run-outline`, {
    method: "POST",
    headers: {
      "Authorization": authHeader,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ resume_run_id: runId }),
  });
  if (!response.ok && response.status !== 409) {
    throw new Error(`continuation queue returned ${response.status}`);
  }
}

async function finalizeRun(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  sections: Array<Record<string, unknown>>,
): Promise<void> {
  const failed = sections.find((s) => s.status === "failed");
  if (failed) {
    await markRunFailed(
      adminClient,
      runId,
      String(failed.error ?? "section failed"),
    );
    return;
  }
  const actual = await loadActualCredits(adminClient, sections);
  await adminClient.from("chapter_runs").update({
    status: "completed",
    credits_actual: actual,
    completed_at: new Date().toISOString(),
    worker_lease_until: null,
    next_retry_at: null,
  }).eq("id", runId);
  console.log(
    `[run-outline] run_id=${runId} completed; actual_credits=${actual}`,
  );
}

// ---- helpers ----------------------------------------------------------

function estimateLengthModeFromContainer(container: string | null): LengthMode {
  // Mapping per docs/multi-section-generation.md: per-section cost is
  // estimated from the section's container. The 13 containers in
  // outline_sections.container are collapsed to the 4 credit LengthModes:
  //   chapter / episode / novella → "chapter" (8 credits)
  //   shortStory → "short" (1 credit)
  //   (else — scene / developedScene / setPiece / sceneSequence /
  //    beat / moment / vignette / microScene / modelDecides) → "long" (4 credits)
  if (
    container === "chapter" || container === "episode" ||
    container === "novella"
  ) return "chapter";
  if (container === "shortStory") return "short";
  return "long";
}

function estimateSectionCost(container: string | null): number {
  return getCreditCost(estimateLengthModeFromContainer(container));
}

/**
 * Estimate the reserve with the exact same generate-story pricing path used by
 * the iOS estimate UI. The old fixed per-length-mode reserve (1/2/4/8) could
 * disagree with model/token pricing and reject an otherwise affordable run.
 */
async function estimateRunCost(
  adminClient: ReturnType<typeof createClient>,
  userId: string,
  authHeader: string,
  outlineId: string,
  sections: Array<Record<string, unknown>>,
  selectedModelId?: string,
): Promise<number> {
  const { data: outline, error: outlineError } = await adminClient
    .from("outlines")
    .select("local_project_id, source_recipe_json, source_recipe_hash")
    .eq("id", outlineId).single();
  if (outlineError || !outline?.local_project_id) {
    throw new Error("outline.local_project_id missing");
  }
  if (!outline.source_recipe_json || !outline.source_recipe_hash) {
    throw new Error(
      "outline recipe provenance missing; re-plan this outline before Run All",
    );
  }
  const frozenRecipe = outline.source_recipe_json as Record<string, unknown>;
  const recipeObligations = deriveRecipeObligations(frozenRecipe);
  if (sections.length === 0) return 0;

  const endpoint = `${SUPABASE_URL}/functions/v1/generate-story`;
  const firstSection = sections[0];
  const request = {
    ...buildGenerateStoryRequest({
      snapshot: {},
      frozenRecipe,
      frozenRecipeHash: String(outline.source_recipe_hash),
      recipeObligations,
      assignedRecipeRequirementIDs: firstSection.recipe_requirement_ids,
      section: firstSection as {
        id: string;
        title: string;
        summary: string;
        container: string | null;
        pov: string | null;
        terminal_beat: string | null;
      },
      projectId: String(outline.local_project_id),
      selectedModelId,
      lengthMode: estimateLengthModeFromContainer(
        firstSection.container as string | null,
      ),
    }),
    // One server-authoritative estimate request avoids a gateway burst for
    // large Run All queues while retaining per-section container pricing.
    generationAction: "estimate_bulk",
    estimateSections: sections.map((section) => ({
      id: String(section.id),
      title: String(section.title ?? ""),
      summary: String(section.summary ?? ""),
      container: section.container == null
        ? undefined
        : String(section.container),
      pov: section.pov == null ? undefined : String(section.pov),
      terminalBeat: section.terminal_beat == null
        ? undefined
        : String(section.terminal_beat),
      recipeRequirementIDs: Array.isArray(section.recipe_requirement_ids)
        ? section.recipe_requirement_ids
        : undefined,
    })),
  };

  let response: Response;
  let result: Record<string, unknown> | null = null;
  for (let attempt = 0;; attempt += 1) {
    response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": authHeader,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request),
    });
    result = await response.json().catch(() => null) as
      | Record<string, unknown>
      | null;

    // The bulk path should not normally hit the gateway burst limiter, but
    // retain one bounded retry for a transient 429 during deployment traffic.
    if (response.status !== 429 || attempt >= 1) break;
    const retryAfter = Number(
      result?.retryAfterSeconds ?? response.headers.get("Retry-After"),
    );
    const retryAfterSeconds = Number.isFinite(retryAfter) && retryAfter > 0
      ? Math.min(Math.ceil(retryAfter), 120)
      : 60;
    await new Promise((resolve) =>
      setTimeout(resolve, retryAfterSeconds * 1000)
    );
  }

  const estimates = Array.isArray(result?.estimates) ? result.estimates : [];
  if (!response.ok || estimates.length !== sections.length) {
    throw new Error(
      `generation cost estimate failed (${response.status}): ${
        String(
          result?.errorMessage ?? result?.message ?? "invalid bulk estimate",
        )
      }`,
    );
  }
  const costs = estimates.map((estimate) =>
    Number((estimate as Record<string, unknown>).estimatedCredits)
  );
  if (costs.some((cost) => !Number.isFinite(cost))) {
    throw new Error(
      "generation cost estimate failed: invalid section estimate",
    );
  }

  // A continuation can normalize one legacy section before each generated
  // section. Reserve those auxiliary stages too, using bounded raw-text and
  // canonical-context sizes rather than the old fixed container cost.
  const maxPosition = Math.max(
    ...sections.map((section) => Number(section.position ?? 0)),
  );
  const { data: priorSections, error: priorSectionError } = await adminClient
    .from("outline_sections")
    .select("id, position")
    .eq("outline_id", outlineId)
    .lt("position", maxPosition);
  if (priorSectionError) {
    throw new Error(
      `legacy memory section estimate failed: ${priorSectionError.message}`,
    );
  }
  const priorSectionIds = (priorSections ?? []).map((
    section: Record<string, unknown>,
  ) => String(section.id));
  const { data: legacyRows, error: legacyError } = priorSectionIds.length
    ? await adminClient
      .from("section_embeddings")
      .select(
        "outline_section_id, generation_output_id, raw_text, memory_pipeline_version",
      )
      .eq("project_id", String(outline.local_project_id))
      .in("outline_section_id", priorSectionIds)
    : { data: [], error: null };
  if (legacyError) {
    throw new Error(`legacy memory estimate failed: ${legacyError.message}`);
  }
  const positionById = new Map(
    (priorSections ?? []).map((section: Record<string, unknown>) => [
      String(section.id),
      Number(section.position ?? 0),
    ]),
  );
  const legacy = (legacyRows ?? []).filter((row: Record<string, unknown>) =>
    row.generation_output_id &&
    !isCurrentMemoryPipelineVersion(row.memory_pipeline_version)
  ).sort((a: Record<string, unknown>, b: Record<string, unknown>) =>
    (positionById.get(String(a.outline_section_id)) ?? 0) -
    (positionById.get(String(b.outline_section_id)) ?? 0)
  );
  let legacyCost = 0;
  if (legacy.length) {
    const outputIds = legacy.map((row) => String(row.generation_output_id));
    const { data: events, error: eventError } = await adminClient
      .from("generation_usage_events")
      .select("generation_output_id, idempotency_key, status")
      .eq("purpose", "embed-section")
      .eq("status", "complete")
      .in("generation_output_id", outputIds);
    if (eventError) {
      throw new Error(`legacy billing estimate failed: ${eventError.message}`);
    }
    const settled = new Set(
      (events ?? []).map((event: Record<string, unknown>) =>
        String(event.idempotency_key ?? "")
      ),
    );
    const extractor = await getEnabledModelByProviderModel(
      adminClient,
      Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini",
    );
    const embedder = await getEnabledModelByProviderModel(
      adminClient,
      "text-embedding-3-small",
    );
    if (!extractor || !embedder) {
      throw new Error("legacy memory pricing unavailable");
    }
    const extractorPricing = snapshotPricing(extractor);
    const embedderPricing = snapshotPricing(embedder);
    for (const row of legacy.slice(0, sections.length)) {
      const outputId = String(row.generation_output_id);
      const rawTokens = Math.min(
        8_192,
        Math.max(1, Math.ceil(String(row.raw_text ?? "").length / 4)),
      );
      if (!settled.has(`${outputId}:scene-memory-extraction`)) {
        legacyCost += computeMaxChargeCredits({
          uncachedInputTokens: rawTokens + 6_000,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 8_192,
          toolCostUsd: 0,
        }, extractorPricing);
      }
      if (!settled.has(`${outputId}:scene-memory-embedding`)) {
        legacyCost += computeMaxChargeCredits({
          uncachedInputTokens: 1_500,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 0,
          toolCostUsd: 0,
        }, embedderPricing);
      }
    }
  }
  return costs.reduce((sum, cost) => sum + cost, 0) + legacyCost;
}

async function collectSectionsToGenerate(
  adminClient: ReturnType<typeof createClient>,
  outlineId: string,
  startParentSectionId: string,
  scope: string = "single",
): Promise<
  Array<{
    id: string;
    title: string;
    position: number;
    summary: string;
    container: string | null;
    pov: string | null;
    terminal_beat: string | null;
    story_arc_beat_id: string | null;
    target_words: number | null;
    target_words_min: number | null;
    target_words_max: number | null;
  }>
> {
  // Look up the start section (need parent_id for chapter walk + position for from_here)
  const { data: startSection, error: parentErr } = await adminClient
    .from("outline_sections")
    .select("id, parent_id, position")
    .eq("id", startParentSectionId)
    .single();
  if (parentErr || !startSection) {
    throw new Error(
      `start_parent_section_id not found: ${startParentSectionId}`,
    );
  }

  // 'single' scope: return just the start section (default, preserves current behavior)
  if (scope === "single") {
    const { data: leaf, error: leafErr } = await adminClient
      .from("outline_sections")
      .select(
        "id, title, position, summary, container, pov, terminal_beat, story_arc_beat_id, target_words, target_words_min, target_words_max",
      )
      .eq("id", startParentSectionId)
      .single();
    if (leafErr || !leaf) throw new Error("leaf section not found");
    return [
      leaf as {
        id: string;
        title: string;
        position: number;
        summary: string;
        container: string | null;
        pov: string | null;
        terminal_beat: string | null;
        story_arc_beat_id: string | null;
        target_words: number | null;
        target_words_min: number | null;
        target_words_max: number | null;
      },
    ];
  }

  // 'chapter' and 'from_here' need every section in the outline (parent_id for the tree walk, position for ordering)
  const { data: allSections, error: allErr } = await adminClient
    .from("outline_sections")
    .select(
      "id, parent_id, position, title, summary, container, pov, terminal_beat, story_arc_beat_id, target_words, target_words_min, target_words_max",
    )
    .eq("outline_id", outlineId)
    .order("position", { ascending: true });
  if (allErr) {
    throw new Error(`failed to fetch outline sections: ${allErr.message}`);
  }
  if (!allSections || allSections.length === 0) return [];

  if (scope === "from_here") {
    // Start + every section that comes after it in outline order (by position)
    return allSections.filter((s) => s.position >= startSection.position);
  }

  if (scope === "chapter") {
    // Walk up to find the chapter (top-level ancestor). If start is already top-level, it's the chapter.
    let chapterId = startSection.id;
    let current: { id: string; parent_id: string | null } = startSection;
    while (current.parent_id !== null) {
      const parent = allSections.find((s) => s.id === current.parent_id);
      if (!parent) break;
      chapterId = parent.id;
      current = parent;
    }
    // Walk down: collect every descendant of the chapter (including the chapter itself)
    const chapterDescendants = new Set<string>([chapterId]);
    let added = true;
    while (added) {
      added = false;
      for (const s of allSections) {
        if (
          s.parent_id && chapterDescendants.has(s.parent_id) &&
          !chapterDescendants.has(s.id)
        ) {
          chapterDescendants.add(s.id);
          added = true;
        }
      }
    }
    return allSections
      .filter((s) => chapterDescendants.has(s.id))
      .sort((a, b) => a.position - b.position);
  }

  // Unknown scope: fall back to single-section (safe default)
  const { data: leaf, error: leafErr } = await adminClient
    .from("outline_sections")
    .select(
      "id, title, position, summary, container, pov, terminal_beat, story_arc_beat_id",
    )
    .eq("id", startParentSectionId)
    .single();
  if (leafErr || !leaf) throw new Error("leaf section not found");
  return [
    leaf as {
      id: string;
      title: string;
      position: number;
      summary: string;
      container: string | null;
      pov: string | null;
      terminal_beat: string | null;
      story_arc_beat_id: string | null;
    },
  ];
}

// ---- fetchPriorContext (Deep pull, no manual input) -------------------
//
// Per Kevin's hard rule (2026-08-10 18:01 EDT): schema tight, pull deep.
// The pull fetches ALL structured state from ALL prior sections (in outline
// order) and aggregates. No manual intent fields. No narrow filtering.
// The schema (5 structured columns: character_deltas, plot_thread_deltas,
// continuity_facts, open_loops, scene_ending_state) IS the design.
//
// Per Locked Design Rules (PR #310 / #311, the structural improvements):
//   Rule 2: character_deltas merge fields per character_name
//   Rule 3: stable thread/loop IDs across scenes
//   Rule 4: continuity_facts filter by active=true
//   Rule 5: ALWAYS inject immediately previous section's summary + ending_state
//   Rule 6: retrieve by outline order (position), NOT created_at
//   Rule 8: pipeline order generate → persist → extract → next
async function fetchPriorContext(
  adminClient: ReturnType<typeof createClient>,
  outlineId: string,
  currentSectionId: string,
): Promise<string> {
  // 1. Get current section's position.
  const { data: section } = await adminClient
    .from("outline_sections")
    .select("position")
    .eq("id", currentSectionId)
    .single();
  if (!section) return "";
  const currentPosition: number = (section.position as number) ?? 0;

  // 2. Get project_id.
  const { data: outlineRow } = await adminClient
    .from("outlines")
    .select("local_project_id")
    .eq("id", outlineId)
    .single();
  const projectId = outlineRow?.local_project_id;
  if (!projectId) return "";

  // 3. Fetch all scenes for the project. We use a separate fetch + JS join
  //    (vs a Postgres RPC) for v1; same design, just less performant.
  const { data: allScenes } = await adminClient
    .from("section_embeddings")
    .select(
      "outline_section_id, extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state",
    )
    .eq("project_id", projectId);
  if (!allScenes || allScenes.length === 0) return "";

  // 4. Fetch outline positions (Rule 6: outline order, not created_at).
  const outlineSectionIds = allScenes
    .map((s) => s.outline_section_id)
    .filter((id): id is string => typeof id === "string");
  const { data: outlineSections } = await adminClient
    .from("outline_sections")
    .select("id, position")
    .in("id", outlineSectionIds);
  const positionById = new Map<string, number>();
  for (const os of outlineSections ?? []) {
    positionById.set(os.id, os.position);
  }

  // 5. Sort by outline position and filter to scenes BEFORE current section.
  const priorScenes = allScenes
    .filter((s) => positionById.has(s.outline_section_id))
    .filter((s) =>
      (positionById.get(s.outline_section_id) ?? 0) < currentPosition
    )
    .sort((a, b) =>
      (positionById.get(a.outline_section_id) ?? 0) -
      (positionById.get(b.outline_section_id) ?? 0)
    );
  if (priorScenes.length === 0) return "";

  // 6. The immediately previous section (Rule 5: ALWAYS inject).
  const previousScene = priorScenes[priorScenes.length - 1];

  // 7. Aggregate: pull ALL structured state from prior sections.
  return aggregateProjectState(priorScenes, previousScene);
}

// ---- aggregateProjectState (New shape per Locked design rules 2-4) ------
//
// Builds the markdown emitted as `project_state_context` for the LLM.
// Always emits the previous section's summary + ending_state first (Rule 5).
// Then aggregates:
//   - Characters: merge fields per character_name (Rule 2)
//   - Plot threads: latest status by stable thread_id (Rule 3)
//   - Continuity facts: only active (Rule 4)
//   - Open loops: by stable loop_id (Rule 3)
function aggregateProjectState(
  scenes: Array<Record<string, unknown>>,
  previousScene?: Record<string, unknown>,
): string {
  return formatCanonicalProjectState(scenes, previousScene);
}

// ---- Rule 8: pipeline order (generate → persist → extract → next) ------

async function findRunOutput(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  sectionId: string,
  userId: string,
  projectId: string,
): Promise<string | null> {
  const { data, error } = await adminClient.from("generation_outputs")
    .select("id, status, was_truncated")
    .eq("run_id", runId)
    .eq("run_section_id", sectionId)
    .eq("outline_section_id", sectionId)
    .eq("user_id", userId)
    .eq("project_local_id", projectId)
    .eq("status", "complete")
    .maybeSingle();
  if (error || !data?.id || data.was_truncated === true) return null;
  return String(data.id);
}

class RetryableGenerationError extends Error {
  readonly retryAfterSeconds: number;

  constructor(message: string, retryAfterSeconds: number) {
    super(message);
    this.name = "RetryableGenerationError";
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

async function callGenerateStory(
  payload: Record<string, unknown>,
  authHeader: string,
): Promise<
  {
    output_id: string;
    status: string;
    wasTruncated: boolean;
    finishReason: string | null;
  }
> {
  const url = `${SUPABASE_URL}/functions/v1/generate-story`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      // Pass the user's JWT through — generate-story validates via auth.getUser(),
      // which rejects the service role key with 401.
      "Authorization": authHeader,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const errBody = await response.text();
    if (response.status === 429) {
      let retryAfterSeconds = Number(response.headers.get("Retry-After"));
      try {
        const parsed = JSON.parse(errBody) as { retryAfterSeconds?: number };
        if (typeof parsed.retryAfterSeconds === "number") {
          retryAfterSeconds = parsed.retryAfterSeconds;
        }
      } catch {
        // Fall back to the HTTP Retry-After header below.
      }
      if (!Number.isFinite(retryAfterSeconds) || retryAfterSeconds <= 0) {
        retryAfterSeconds = 60;
      }
      retryAfterSeconds = Math.min(Math.ceil(retryAfterSeconds), 3600);
      throw new RetryableGenerationError(
        `generate-story returned 429: ${errBody.slice(0, 200)}`,
        retryAfterSeconds,
      );
    }
    throw new Error(
      `generate-story returned ${response.status}: ${errBody.slice(0, 200)}`,
    );
  }
  const result = await response.json() as Record<string, unknown>;
  const outputId = generationOutputId(result);
  if (!outputId) {
    throw new Error("generate-story response missing cloudGenerationOutputID");
  }
  return {
    output_id: outputId,
    status: String(result.status ?? ""),
    wasTruncated: result.wasTruncated === true,
    finishReason: result.finishReason == null
      ? null
      : String(result.finishReason),
  };
}

// Fetch raw_text from generation_outputs given the output_id returned by
// generate-story. This is the post-persist read in the Rule 8 pipeline.
async function fetchRawTextFromOutput(
  adminClient: ReturnType<typeof createClient>,
  outputId: string,
): Promise<string> {
  if (!outputId) return "";
  const { data, error } = await adminClient
    .from("generation_outputs")
    .select("output_text")
    .eq("id", outputId)
    .single();
  if (error || !data) {
    throw new Error(
      `persisted generation output ${outputId} could not be read: ${
        error?.message ?? "not found"
      }`,
    );
  }
  const outputText = String(
    (data as { output_text?: string }).output_text ?? "",
  );
  if (!outputText) {
    throw new Error(`persisted generation output ${outputId} has no prose`);
  }
  return outputText;
}

// Call embed-section to extract structured memory from the persisted output.
// Per Rule 8: this happens AFTER the output is persisted to generation_outputs,
// giving us raw_text. Per Rule 9: raw_text is passed to embed-section for
// extraction but NOT used in the embedding vector itself.
async function callEmbedSection(
  payload: {
    outline_section_id: string;
    outline_id: string;
    project_id: string;
    position: number;
    title: string;
    summary: string;
    container: string | null;
    pov: string | null;
    terminal_beat: string | null;
    story_arc_beat_id: string | null;
    raw_text: string;
    // Kevin 2026-08-21 12:00 EDT fix: lineage from section memory to the
    // generation output that produced it. embed-section persists this
    // on the section_embeddings row; the DELETE trigger on
    // generation_outputs uses it to clean up orphaned memory when the
    // output is deleted.
    output_id: string;
    // The same prior context that run-outline fetches. Passed to
    // embed-section so the LLM extraction pass knows what is already
    // stored and can decide what to add/update/supersede.
    prior_context: string;
  },
  _adminClient: ReturnType<typeof createClient>,
  authHeader: string,
): Promise<void> {
  const url = `${SUPABASE_URL}/functions/v1/embed-section`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      // Pass the user's JWT through — embed-section validates the JWT the same
      // way generate-story does, and rejects the service role key with 401.
      "Authorization": authHeader,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const errBody = await response.text();
    throw new Error(
      `embed-section returned ${response.status}: ${errBody.slice(0, 200)}`,
    );
  }
}

async function updateSectionStatus(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  sectionStatus: Record<string, unknown>,
): Promise<void> {
  const { data: run } = await adminClient
    .from("chapter_runs")
    .select("sections")
    .eq("id", runId)
    .single();
  if (!run) return;
  const sections = Array.isArray(run.sections)
    ? (run.sections as Array<Record<string, unknown>>)
    : [];
  const idx = sections.findIndex((s) => s.id === sectionStatus.id);
  if (idx >= 0) sections[idx] = { ...sections[idx], ...sectionStatus };
  else sections.push(sectionStatus);
  const { error } = await adminClient.from("chapter_runs").update({ sections })
    .eq("id", runId)
    .eq("status", "running")
    .eq("worker_attempt", Number(sectionStatus.worker_attempt ?? -1));
  if (error) {
    throw new Error(`could not persist section progress: ${error.message}`);
  }
}

async function renewRunLease(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  workerAttempt: number,
): Promise<void> {
  const { data, error } = await (adminClient as any).rpc(
    "renew_chapter_run_lease",
    {
      p_run_id: runId,
      p_worker_attempt: workerAttempt,
      p_lease_seconds: 420,
    },
  );
  if (error || !(data === true || (Array.isArray(data) && data.length > 0))) {
    throw new Error(
      `run lease is no longer owned: ${error?.message ?? "expired"}`,
    );
  }
}

async function loadActualCredits(
  adminClient: ReturnType<typeof createClient>,
  sections: Array<Record<string, unknown>>,
): Promise<number> {
  const outputIds = sections.map((section) => String(section.output_id ?? ""))
    .filter(Boolean);
  if (!outputIds.length) return 0;
  const { data, error } = await adminClient.from("user_credit_ledger")
    .select("delta").in("related_generation_output_id", outputIds);
  if (error) {
    throw new Error(`could not load actual billing ledger: ${error.message}`);
  }
  return (data ?? []).reduce((sum: number, row: Record<string, unknown>) => {
    const delta = Number(row.delta ?? 0);
    return sum + (delta < 0 ? -delta : 0);
  }, 0);
}

async function markRunFailed(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  error: string,
): Promise<void> {
  const { data: run } = await adminClient.from("chapter_runs")
    .select("sections").eq("id", runId).maybeSingle();
  const sections = Array.isArray(run?.sections)
    ? run.sections as Array<Record<string, unknown>>
    : [];
  const actual = await loadActualCredits(adminClient, sections);
  // generate-story owns the real debit. The orchestrator reports successful
  // section charges and clears its estimate on failure (no failed-call charge).
  await adminClient.from("chapter_runs").update({
    status: "failed",
    error,
    credits_reserved: 0,
    credits_actual: actual,
    completed_at: new Date().toISOString(),
    worker_lease_until: null,
  }).eq("id", runId);
}
