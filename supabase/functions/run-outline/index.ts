// =============================================================================
// run-outline Edge Function (Phase 8 per docs/multi-section-generation.md)
//
// Multi-section generation orchestrator. Kicks off a chapter run that walks
// outline_sections by parent_id (leaf = single; chapter parent = walks
// children in position order). Per-section generation calls generate-story
// with narrow prior-context queries against the 5 structured columns.
//
// Day 3 (this PR): rate-limit + cost reserve before kickoff; commit on
//   chain completion; rollback on failure. Per docs/multi-section-generation.md.
// Narrow-query refactor of fetchPriorContext deferred to a separate PR
// (the current "limit to most recent N sections" is the simplest narrow
// that works; a proper character/thread-based filter requires the section's
// intent metadata which isn't yet on outline_sections).
//
// Endpoints:
//   POST /functions/v1/run-outline          — kickoff (auth + idempotency + cost-reserve + run loop)
//   GET  /functions/v1/run-outline?run_id=… — status poll
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type LengthMode,
  type UserEntitlement,
  availableCredits,
  checkCredits,
  getCreditCost,
} from "../generate-story/_credits.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = ***"SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = ***"SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, { ...init, headers: { ...CORS_HEADERS, ...(init.headers ?? {}) } });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface RunOutlineRequest {
  outline_id: string;
  start_parent_section_id: string;
  model?: string;
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
  if (!authHeader) return errorResponse("unauthorized", "missing Authorization header", 401);
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return errorResponse("unauthorized", "invalid JWT", 401);
  const userId = userData.user.id;

  // 2. Parse + validate body
  let body: RunOutlineRequest;
  try { body = await req.json(); }
  catch { return errorResponse("invalid_body", "JSON body required", 400); }
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
  const idempotencyKey = `${userId}:${body.outline_id}:${body.start_parent_section_id}`;
  const { data: run, error: insertErr } = await adminClient
    .from("chapter_runs")
    .insert({
      outline_id: body.outline_id,
      start_parent_section_id: body.start_parent_section_id,
      idempotency_key: idempotencyKey,
      status: "running",
      sections: [],
      cost_cents_reserved: 0,
    })
    .select()
    .single();
  if (insertErr) {
    if (insertErr.code === "23505") {
      const { data: existing } = await adminClient
        .from("chapter_runs")
        .select()
        .eq("idempotency_key", idempotencyKey)
        .eq("status", "running")
        .maybeSingle();
      if (existing) {
        return corsResponse(
          JSON.stringify({ errorCode: "already_running", run_id: existing.id }),
          { status: 409 },
        );
      }
    }
    console.error(`[run-outline] insert failed: ${insertErr.message}`);
    return errorResponse("db_error", insertErr.message, 500);
  }

  // 4. Walk the outline so we can estimate cost before the loop.
  let sections: Array<{ id: string; title: string; position: number; container: string | null; pov: string | null; terminal_beat: string | null }>;
  try {
    sections = await collectSectionsToGenerate(adminClient, body.outline_id, body.start_parent_section_id);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await adminClient.from("chapter_runs").update({
      status: "failed", error: msg, completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse("walk_failed", msg, 400);
  }
  if (sections.length === 0) {
    await adminClient.from("chapter_runs").update({
      status: "failed", error: "no sections to generate", completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse("no_sections", "start_parent_section_id has no children and is itself a leaf — but the leaf wasn't found by the walker", 400);
  }

  // 5. Estimate total cost (per docs/multi-section-generation.md: cost reserve at
  //    kickoff; release on failure). Per _credits.ts policy: "Monthly allowance is
  //    drained first, then purchased balance." We use the same drain order at
  //    commit time. cost_cents_reserved is in integer credits for now (the
  //    column naming pre-dates the credit/cent distinction; semantics are
  //    "credits" today).
  const estimatedCost = sections.reduce(
    (sum, s) => sum + estimateSectionCost(s.container),
    0,
  );

  // 6. Credit check: load entitlement + verify available >= estimated.
  const { data: entData, error: entErr } = await adminClient
    .from("user_entitlements")
    .select("user_id, plan_name, is_pro, monthly_credit_allowance, purchased_credit_balance, current_period_start, current_period_end, entitlement_source, updated_at")
    .eq("user_id", userId)
    .single();
  if (entErr || !entData) {
    await adminClient.from("chapter_runs").update({
      status: "failed", error: "could not load user entitlement", completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse("entitlement_error", "could not load user entitlement", 500);
  }
  const ent = entData as UserEntitlement;
  const check = checkCredits(ent, estimatedCost);
  if (!check.allowed) {
    await adminClient.from("chapter_runs").update({
      status: "failed",
      error: `insufficient_credits: needed ${estimatedCost}, have ${check.availableCredits}`,
      cost_cents_reserved: 0,
      completed_at: new Date().toISOString(),
    }).eq("id", run.id);
    return errorResponse(
      "insufficient_credits",
      `needed ${estimatedCost}, have ${check.availableCredits}`,
      402,
    );
  }

  // 7. Update cost_cents_reserved + log the kickoff
  await adminClient.from("chapter_runs").update({
    cost_cents_reserved: estimatedCost,
  }).eq("id", run.id);
  console.log(
    `[run-outline] kickoff run_id=${run.id} user=${userId} outline=${body.outline_id} parent=${body.start_parent_section_id} sections=${sections.length} estimated_cost=${estimatedCost} model=${body.model ?? "(default)"}`,
  );

  // 8. Run the outline-walker + per-section loop synchronously. Day 4 will
  //    move this to EdgeRuntime.waitUntil for true async.
  await runOutline(run.id, body.outline_id, body.start_parent_section_id, body.model, adminClient, userId, estimatedCost, sections);

  // 9. Re-fetch and return final state.
  const { data: finalRun } = await adminClient
    .from("chapter_runs")
    .select()
    .eq("id", run.id)
    .single();
  return corsResponse(JSON.stringify({
    run_id: run.id,
    status: finalRun?.status ?? "unknown",
    sections: finalRun?.sections ?? [],
    cost_cents_reserved: finalRun?.cost_cents_reserved ?? estimatedCost,
    cost_cents_actual: finalRun?.cost_cents_actual ?? 0,
    error: finalRun?.error,
    created_at: finalRun?.created_at,
    updated_at: finalRun?.updated_at,
    completed_at: finalRun?.completed_at,
  }), { status: 200 });
}

// ---- GET /functions/v1/run-outline?run_id=… ------------------------------
async function handleStatus(req: Request, url: URL): Promise<Response> {
  const runId = url.searchParams.get("run_id");
  if (!runId) return errorResponse("missing_param", "run_id query param required", 400);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return errorResponse("unauthorized", "missing Authorization header", 401);
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return errorResponse("unauthorized", "invalid JWT", 401);

  const { data: run, error: runErr } = await userClient
    .from("chapter_runs")
    .select("id, outline_id, start_parent_section_id, status, sections, cost_cents_reserved, cost_cents_actual, error, created_at, updated_at, completed_at")
    .eq("id", runId)
    .single();
  if (runErr || !run) return errorResponse("not_found", "run not found", 404);

  const sections = Array.isArray(run.sections) ? run.sections : [];
  const sections_done = sections.filter((s: { status?: string }) => s?.status === "completed").length;
  const sections_failed = sections.filter((s: { status?: string }) => s?.status === "failed").length;
  const current_section = sections.find((s: { status?: string }) => s?.status === "running");

  return corsResponse(JSON.stringify({
    run_id: run.id,
    status: run.status,
    outline_id: run.outline_id,
    start_parent_section_id: run.start_parent_section_id,
    sections_done,
    sections_total: sections.length,
    sections_failed,
    current_section: current_section ? { id: (current_section as { id: string }).id, title: (current_section as { title: string }).title } : null,
    sections,
    error: run.error,
    cost_cents_reserved: run.cost_cents_reserved,
    cost_cents_actual: run.cost_cents_actual,
    created_at: run.created_at,
    updated_at: run.updated_at,
    completed_at: run.completed_at,
  }), { status: 200 });
}

// ---- outline-walker + per-section loop (Day 2) -------------------------
async function runOutline(
  runId: string,
  outlineId: string,
  startParentSectionId: string,
  model: string | undefined,
  adminClient: ReturnType<typeof createClient>,
  userId: string,
  estimatedCost: number,
  sections: Array<{ id: string; title: string; position: number; container: string | null; pov: string | null; terminal_beat: string | null }>,
): Promise<void> {
  // Initialize per-section progress in the jsonb column
  await adminClient.from("chapter_runs").update({
    sections: sections.map((s) => ({
      id: s.id, title: s.title, position: s.position, status: "pending",
    })),
  }).eq("id", runId);

  // Iterate sequentially; stop-the-chain on first failure (Kevin 14:22 EDT)
  let actualCost = 0;
  for (const section of sections) {
    await updateSectionStatus(adminClient, runId, {
      id: section.id, title: section.title, position: section.position,
      status: "running", started_at: new Date().toISOString(),
    });
    try {
      const priorContext = await fetchPriorContext(adminClient, outlineId, section.id);
      const result = await callGenerateStory({
        outline_id: outlineId,
        outline_section_id: section.id,
        model: model ?? null,
        project_state_context: priorContext,
      }, adminClient);
      // Day 3: per-section cost tracking. cost_cents_reserved was set at
      // kickoff; cost_cents_actual is the sum of per-section actual costs.
      const sectionCost = estimateSectionCost(section.container);
      actualCost += sectionCost;
      await updateSectionStatus(adminClient, runId, {
        id: section.id, title: section.title, position: section.position,
        status: "completed", output_id: result.output_id,
        cost: sectionCost,
        completed_at: new Date().toISOString(),
      });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      const sectionCost = estimateSectionCost(section.container);
      // Day 3: rollback the cost reserve since this section failed (per
      // _credits.ts policy: "If the LLM provider call fails: do NOT charge credits").
      // For now: leave cost_cents_actual unchanged (the per-section cost
      // isn't added since the section didn't actually complete) and mark
      // the run failed. The cost_cents_reserved is freed because cost_cents_actual
      // never reached it.
      await updateSectionStatus(adminClient, runId, {
        id: section.id, title: section.title, position: section.position,
        status: "failed", error: msg,
        completed_at: new Date().toISOString(),
      });
      await adminClient.from("chapter_runs").update({
        status: "failed",
        error: `section ${section.id} (${section.title}) failed: ${msg}`,
        cost_cents_actual: actualCost,
        completed_at: new Date().toISOString(),
      }).eq("id", runId);
      console.log(`[run-outline] run_id=${runId} failed at section ${section.id}: ${msg}`);
      return; // stop the chain
    }
  }

  // All sections completed. Day 3: commit the actual cost to the user's
  // entitlement and insert a user_credit_ledger entry. Drains monthly first,
  // then purchased (per _credits.ts).
  await commitCredits(adminClient, userId, actualCost, `run-outline:${runId}`);
  await adminClient.from("chapter_runs").update({
    status: "completed",
    cost_cents_actual: actualCost,
    completed_at: new Date().toISOString(),
  }).eq("id", runId);
  console.log(`[run-outline] run_id=${runId} completed; actual_cost=${actualCost} reserved=${estimatedCost}`);
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
  if (container === "chapter" || container === "episode" || container === "novella") return "chapter";
  if (container === "shortStory") return "short";
  return "long";
}

function estimateSectionCost(container: string | null): number {
  return getCreditCost(estimateLengthModeFromContainer(container));
}

async function collectSectionsToGenerate(
  adminClient: ReturnType<typeof createClient>,
  outlineId: string,
  startParentSectionId: string,
): Promise<Array<{ id: string; title: string; position: number; container: string | null; pov: string | null; terminal_beat: string | null }>> {
  const { data: startParent, error: parentErr } = await adminClient
    .from("outline_sections")
    .select("id, parent_id, title")
    .eq("id", startParentSectionId)
    .single();
  if (parentErr || !startParent) {
    throw new Error(`start_parent_section_id not found: ${startParentSectionId}`);
  }
  if (startParent.parent_id === null) {
    const { data: leaf, error: leafErr } = await adminClient
      .from("outline_sections")
      .select("id, title, position, container, pov, terminal_beat")
      .eq("id", startParentSectionId)
      .single();
    if (leafErr || !leaf) throw new Error("leaf section not found");
    return [leaf];
  }
  const { data: children, error: childErr } = await adminClient
    .from("outline_sections")
    .select("id, title, position, container, pov, terminal_beat")
    .eq("parent_id", startParentSectionId)
    .order("position", { ascending: true });
  if (childErr) throw new Error(`failed to fetch children: ${childErr.message}`);
  return children ?? [];
}

// Day 3: TODO — narrow query refactor. Currently limits to most recent N
// sections with structured data as a heuristic. A proper character/thread-
// based filter requires the section's intent metadata which isn't yet on
// outline_sections. A future PR will add that to the section schema and
// replace this with targeted jsonb @> queries on character_deltas /
// plot_thread_deltas.
const DAY3_NARROW_LIMIT = 5;

async function fetchPriorContext(
  adminClient: ReturnType<typeof createClient>,
  outlineId: string,
  _currentSectionId: string,
): Promise<string> {
  const { data: outlineRow } = await adminClient
    .from("outlines")
    .select("local_project_id")
    .eq("id", outlineId)
    .single();
  const projectId = outlineRow?.local_project_id;
  if (!projectId) return "";
  const { data, error } = await adminClient
    .from("section_embeddings")
    .select("extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state, created_at")
    .eq("project_id", projectId)
    .order("created_at", { ascending: false })  // Day 3: most-recent first (narrow)
    .limit(DAY3_NARROW_LIMIT);
  if (error || !data) return "";
  // Reverse to chronological order for the aggregate (oldest first)
  return aggregateProjectState([...data].reverse());
}

function aggregateProjectState(scenes: Array<Record<string, unknown>>): string {
  const charactersByName = new Map<string, any>();
  const threadsByName = new Map<string, any>();
  const continuityFacts = new Set<string>();
  const openLoopsByDesc = new Map<string, any>();
  let latestSummary = "";
  let latestEndingState: any = {};
  let latestCreatedAt = "";
  for (const scene of scenes) {
    if (Array.isArray(scene.character_deltas)) {
      for (const delta of scene.character_deltas) {
        if (delta && typeof delta === "object" && delta.character_name) {
          charactersByName.set(delta.character_name, delta);
        }
      }
    }
    if (Array.isArray(scene.plot_thread_deltas)) {
      for (const thread of scene.plot_thread_deltas) {
        if (thread && typeof thread === "object" && thread.thread_name) {
          threadsByName.set(thread.thread_name, thread);
        }
      }
    }
    if (Array.isArray(scene.continuity_facts)) {
      for (const fact of scene.continuity_facts) {
        if (typeof fact === "string") continuityFacts.add(fact);
      }
    }
    if (Array.isArray(scene.open_loops)) {
      for (const loop of scene.open_loops) {
        if (loop && typeof loop === "object" && loop.description) {
          openLoopsByDesc.set(loop.description, loop);
        }
      }
    }
    if (scene.created_at > latestCreatedAt) {
      latestCreatedAt = scene.created_at;
      latestSummary = scene.extracted_summary ?? "";
      latestEndingState = scene.scene_ending_state ?? {};
    }
  }
  const lines: string[] = ["## Project state (cumulative across all accepted scenes)"];
  lines.push("");
  if (latestSummary) { lines.push(`**Latest summary:** ${latestSummary}`); lines.push(""); }
  if (charactersByName.size > 0) {
    lines.push("### Characters (latest known state)");
    for (const delta of charactersByName.values()) lines.push(`- **${delta.character_name}**: ${JSON.stringify(delta)}`);
    lines.push("");
  }
  if (threadsByName.size > 0) {
    lines.push("### Plot threads (latest status)");
    for (const thread of threadsByName.values()) lines.push(`- **${thread.thread_name}** [${thread.status}]: ${thread.description}`);
    lines.push("");
  }
  if (continuityFacts.size > 0) {
    lines.push("### Continuity facts (must not be contradicted)");
    for (const fact of continuityFacts) lines.push(`- ${fact}`);
    lines.push("");
  }
  if (openLoopsByDesc.size > 0) {
    lines.push("### Open loops (unresolved)");
    for (const loop of openLoopsByDesc.values()) lines.push(`- [${loop.type}] ${loop.description}`);
    lines.push("");
  }
  if (latestEndingState && typeof latestEndingState === "object" && Object.keys(latestEndingState).length > 0) {
    lines.push("### Ending state (latest scene)");
    lines.push("```json");
    lines.push(JSON.stringify(latestEndingState, null, 2));
    lines.push("```");
  }
  return lines.join("\n");
}

async function callGenerateStory(
  payload: {
    outline_id: string;
    outline_section_id: string;
    model: string | null;
    project_state_context: string;
  },
  _adminClient: ReturnType<typeof createClient>,
): Promise<{ output_id: string }> {
  const url = `${SUPABASE_URL}/functions/v1/generate-story`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const errBody = await response.text();
    throw new Error(`generate-story returned ${response.status}: ${errBody.slice(0, 200)}`);
  }
  const result = await response.json();
  return { output_id: (result as { output_id?: string }).output_id ?? (result as { id?: string }).id ?? "" };
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
  const sections = Array.isArray(run.sections) ? (run.sections as Array<Record<string, unknown>>) : [];
  const idx = sections.findIndex((s) => s.id === sectionStatus.id);
  if (idx >= 0) sections[idx] = { ...sections[idx], ...sectionStatus };
  else sections.push(sectionStatus);
  await adminClient.from("chapter_runs").update({ sections }).eq("id", runId);
}

async function markRunFailed(
  adminClient: ReturnType<typeof createClient>,
  runId: string,
  error: string,
): Promise<void> {
  await adminClient.from("chapter_runs").update({
    status: "failed",
    error,
    completed_at: new Date().toISOString(),
  }).eq("id", runId);
}

// Day 3: commit credits. Drains monthly first, then purchased (per _credits.ts).
// Insert user_credit_ledger row with negative delta. Update
// user_entitlements.{monthly_credit_allowance, purchased_credit_balance}.
//
// Called only on all-sections-success (chain completion). On chain failure,
// no commit — per _credits.ts policy, "If the LLM provider call fails:
// do NOT charge credits."
async function commitCredits(
  adminClient: ReturnType<typeof createClient>,
  userId: string,
  cost: number,
  reason: string,
): Promise<void> {
  if (cost <= 0) return;

  // 1. Load current entitlement
  const { data: ent, error: entErr } = await adminClient
    .from("user_entitlements")
    .select("monthly_credit_allowance, purchased_credit_balance")
    .eq("user_id", userId)
    .single();
  if (entErr || !ent) {
    console.error(`[run-outline] commitCredits: failed to load entitlement for ${userId}: ${entErr?.message}`);
    throw new Error(`could not load entitlement for ${userId}`);
  }
  const monthly = (ent as { monthly_credit_allowance: number }).monthly_credit_allowance;
  const purchased = (ent as { purchased_credit_balance: number }).purchased_credit_balance;

  // 2. Drain monthly first, then purchased
  let newMonthly = monthly;
  let newPurchased = purchased;
  let remaining = cost;
  if (remaining > 0 && newMonthly > 0) {
    const drain = Math.min(remaining, newMonthly);
    newMonthly -= drain;
    remaining -= drain;
  }
  if (remaining > 0 && newPurchased > 0) {
    const drain = Math.min(remaining, newPurchased);
    newPurchased -= drain;
    remaining -= drain;
  }
  if (remaining > 0) {
    // Insufficient — should have been caught at kickoff. Log and fail the commit
    // (the run is already marked completed; the user has used the credit).
    console.error(`[run-outline] commitCredits: insufficient balance to cover actual cost ${cost} (remaining ${remaining}); user=${userId}`);
  }

  // 3. Update entitlement
  await adminClient.from("user_entitlements").update({
    monthly_credit_allowance: newMonthly,
    purchased_credit_balance: newPurchased,
  }).eq("user_id", userId);

  // 4. Insert ledger entry (negative delta = debit)
  await adminClient.from("user_credit_ledger").insert({
    user_id: userId,
    delta: -cost,
    reason,
    metadata: { source: "run-outline" },
  });
}
