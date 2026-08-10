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
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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
  let sections: Array<{
    id: string; title: string; position: number;
    summary: string; container: string | null; pov: string | null;
    terminal_beat: string | null; story_arc_beat_id: string | null;
  }>;
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
  sections: Array<{
    id: string; title: string; position: number;
    summary: string; container: string | null; pov: string | null;
    terminal_beat: string | null; story_arc_beat_id: string | null;
  }>,
): Promise<void> {
  // Initialize per-section progress in the jsonb column
  await adminClient.from("chapter_runs").update({
    sections: sections.map((s) => ({
      id: s.id, title: s.title, position: s.position, status: "pending",
    })),
  }).eq("id", runId);

  // We need project_id for embed-section calls (Rule 8: pipeline order).
  const { data: outlineRow } = await adminClient
    .from("outlines")
    .select("local_project_id")
    .eq("id", outlineId)
    .single();
  const projectId = outlineRow?.local_project_id;
  if (!projectId) {
    await adminClient.from("chapter_runs").update({
      status: "failed", error: "outline.local_project_id missing",
      completed_at: new Date().toISOString(),
    }).eq("id", runId);
    return;
  }

  // Iterate sequentially; stop-the-chain on first failure (Kevin 14:22 EDT)
  let actualCost = 0;
  for (const section of sections) {
    await updateSectionStatus(adminClient, runId, {
      id: section.id, title: section.title, position: section.position,
      status: "running", started_at: new Date().toISOString(),
    });
    try {
      // 1. Build the prior context (narrow queries, outline order, ALWAYS-inject previous).
      //    No K, no recency limit. The current section knows what it needs.
      const priorContext = await fetchPriorContext(adminClient, outlineId, section.id);

      // 2. Generate the prose (Rule 8: generate first).
      const result = await callGenerateStory({
        outline_id: outlineId,
        outline_section_id: section.id,
        model: model ?? null,
        project_state_context: priorContext,
      }, adminClient);

      // 3. Persist the output (Rule 8: generate-story has persisted to generation_outputs;
      //    fetch raw_text by output_id to pass to embed-section for structured memory
      //    extraction). The output is persisted BEFORE the next section reads.
      const rawText = await fetchRawTextFromOutput(adminClient, result.output_id);

      // 4. Extract structured memory (Rule 8: extract AFTER output is persisted).
      //    This populates section_embeddings with the new shape (stable UUIDs,
      //    source_section_id, lifecycle) so the next section's prior-context
      //    query sees this section's structured state.
      await callEmbedSection({
        outline_section_id: section.id,
        outline_id: outlineId,
        project_id: projectId,
        position: section.position,
        title: section.title,
        summary: section.summary,
        container: section.container,
        pov: section.pov,
        terminal_beat: section.terminal_beat,
        story_arc_beat_id: section.story_arc_beat_id,
        raw_text: rawText,
        prior_context: priorContext,
      }, adminClient);

      // 5. Per-section cost tracking.
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
      // Rollback the cost reserve since this section failed (per
      // _credits.ts policy: "If the LLM provider call fails: do NOT charge credits").
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
): Promise<Array<{
  id: string; title: string; position: number;
  summary: string; container: string | null; pov: string | null;
  terminal_beat: string | null; story_arc_beat_id: string | null;
}>> {
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
      .select("id, title, position, summary, container, pov, terminal_beat, story_arc_beat_id")
      .eq("id", startParentSectionId)
      .single();
    if (leafErr || !leaf) throw new Error("leaf section not found");
    return [leaf as {
      id: string; title: string; position: number;
      summary: string; container: string | null; pov: string | null;
      terminal_beat: string | null; story_arc_beat_id: string | null;
    }];
  }
  const { data: children, error: childErr } = await adminClient
    .from("outline_sections")
    .select("id, title, position, summary, container, pov, terminal_beat, story_arc_beat_id")
    .eq("parent_id", startParentSectionId)
    .order("position", { ascending: true });
  if (childErr) throw new Error(`failed to fetch children: ${childErr.message}`);
  return children ?? [];
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
    .select("outline_section_id, extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state")
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
    .filter((s) => (positionById.get(s.outline_section_id) ?? 0) < currentPosition)
    .sort((a, b) => (positionById.get(a.outline_section_id) ?? 0) - (positionById.get(b.outline_section_id) ?? 0));
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
  const charactersByName = new Map<string, Record<string, unknown>>();
  const threadsById = new Map<string, Record<string, unknown>>();
  const activeFactsById = new Map<string, Record<string, unknown>>();
  const openLoopsById = new Map<string, Record<string, unknown>>();
  const lines: string[] = ["## Project state (cumulative across all accepted scenes)"];
  lines.push("");

  // 1. ALWAYS emit the immediately previous section's summary + ending_state FIRST (Rule 5).
  if (previousScene) {
    lines.push("### Immediately previous section (always injected)");
    lines.push("");
    if (typeof previousScene.extracted_summary === "string" && previousScene.extracted_summary) {
      lines.push(`**Summary:** ${previousScene.extracted_summary}`);
      lines.push("");
    }
    if (previousScene.scene_ending_state && typeof previousScene.scene_ending_state === "object") {
      lines.push("**Ending state:**");
      lines.push("```json");
      lines.push(JSON.stringify(previousScene.scene_ending_state, null, 2));
      lines.push("```");
      lines.push("");
    }
  }

  // 2. Process all scenes for the aggregate.
  for (const scene of scenes) {
    // Rule 2: character_deltas merge fields per character_name (not latest-overwrites).
    if (Array.isArray(scene.character_deltas)) {
      for (const delta of scene.character_deltas) {
        if (delta && typeof delta === "object" && typeof (delta as { character_name?: unknown }).character_name === "string") {
          const name = (delta as { character_name: string }).character_name;
          const existing = charactersByName.get(name) ?? {};
          // Merge: existing fields preserved, new fields override (latest wins per field).
          charactersByName.set(name, { ...existing, ...(delta as Record<string, unknown>) });
        }
      }
    }
    // Rule 3: plot_thread_deltas use stable IDs. Latest wins by thread_id.
    if (Array.isArray(scene.plot_thread_deltas)) {
      for (const thread of scene.plot_thread_deltas) {
        if (thread && typeof thread === "object" && typeof (thread as { id?: unknown }).id === "string") {
          const id = (thread as { id: string }).id;
          threadsById.set(id, thread as Record<string, unknown>);
        }
      }
    }
    // Rule 4: continuity_facts filter by active/superseded. active=false
    // means this fact was superseded by a later one; remove it from the set.
    if (Array.isArray(scene.continuity_facts)) {
      for (const fact of scene.continuity_facts) {
        if (fact && typeof fact === "object" && typeof (fact as { id?: unknown }).id === "string") {
          const id = (fact as { id: string }).id;
          if ((fact as { active?: boolean }).active === true) {
            activeFactsById.set(id, fact as Record<string, unknown>);
          } else {
            activeFactsById.delete(id);
          }
        }
      }
    }
    // Rule 3: open_loops use stable IDs. Latest wins by loop_id.
    if (Array.isArray(scene.open_loops)) {
      for (const loop of scene.open_loops) {
        if (loop && typeof loop === "object" && typeof (loop as { id?: unknown }).id === "string") {
          const id = (loop as { id: string }).id;
          openLoopsById.set(id, loop as Record<string, unknown>);
        }
      }
    }
  }

  // 3. Emit the aggregate.
  if (charactersByName.size > 0) {
    lines.push("### Characters (merged across scenes — Rule 2)");
    for (const delta of charactersByName.values()) {
      const name = String((delta as { character_name?: string }).character_name ?? "(unnamed)");
      lines.push(`- **${name}**: ${JSON.stringify(delta)}`);
    }
    lines.push("");
  }
  if (threadsById.size > 0) {
    lines.push("### Plot threads (latest status by thread_id — Rule 3)");
    for (const thread of threadsById.values()) {
      const name = String((thread as { thread_name?: string }).thread_name ?? "(unnamed)");
      const status = String((thread as { status?: string }).status ?? "unknown");
      const id = String((thread as { id: string }).id).slice(0, 8);
      const desc = String((thread as { description?: string }).description ?? "");
      lines.push(`- **${name}** [${status}] (id=${id}): ${desc}`);
    }
    lines.push("");
  }
  if (activeFactsById.size > 0) {
    lines.push("### Active continuity facts (must not be contradicted — Rule 4)");
    for (const fact of activeFactsById.values()) {
      const text = String((fact as { fact?: string }).fact ?? JSON.stringify(fact));
      lines.push(`- ${text}`);
    }
    lines.push("");
  }
  if (openLoopsById.size > 0) {
    lines.push("### Open loops (unresolved — Rule 3)");
    for (const loop of openLoopsById.values()) {
      const type = String((loop as { type?: string }).type ?? "unknown");
      const desc = String((loop as { description?: string }).description ?? "");
      lines.push(`- [${type}] ${desc}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

// ---- Rule 8: pipeline order (generate → persist → extract → next) ------

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
    console.error(`[run-outline] fetchRawTextFromOutput failed for ${outputId}: ${error?.message}`);
    return "";
  }
  return String((data as { output_text?: string }).output_text ?? "");
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
    // The same prior context that run-outline fetches. Passed to
    // embed-section so the LLM extraction pass knows what is already
    // stored and can decide what to add/update/supersede.
    prior_context: string;
  },
  _adminClient: ReturnType<typeof createClient>,
): Promise<void> {
  const url = `${SUPABASE_URL}/functions/v1/embed-section`;
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
    throw new Error(`embed-section returned ${response.status}: ${errBody.slice(0, 200)}`);
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
