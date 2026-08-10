// =============================================================================
// embed-section Edge Function (Phase 3 of novel-building per docs/novel-building.md)
//
// Called from iOS on OutlineSection Accept. On-demand pipeline:
//   1. UPSERT outline (id = client-provided outline_id, project_id)
//   2. UPSERT outline_section (id = client-provided outline_section_id)
//   3. LLM extraction pass — ~200-500 token distillation (gpt-4o-mini)
//   4. Embed the summary (text-embedding-3-small, 1536-dim)
//   5. UPSERT into section_embeddings via service role
//
// The function creates the outline + section on-demand. The iOS app does
// NOT need to sync them to supabase first — this was the v1 bug: the
// edge function did a `select outline_id, outlines!inner(project_id) from
// outline_sections where id = $1` and 400'd when the section didn't exist
// in the DB. v2 (this file) UPSERTs the section from the iOS payload.
//
// v2.2 (2026-08-06): write `story_arc_beat_id` to outline_sections now
// that the DB column exists (migration 20260806120000). v2.1 deferred this
// with "Future migration + function update deferred" — this is that
// follow-up (PR #284).
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Service-role key is used server-side only (never exposed to iOS).
//
// Request:  POST {
//             outline_section_id, outline_id, project_id, position,
//             title, summary, container?, pov?, terminal_beat?,
//             story_arc_beat_id?, raw_text
//           }
// Response: 200 { outline_section_id, extracted_summary, embedding_dim }
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini";
const OPENAI_EMBED_MODEL = "text-embedding-3-small";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, { ...init, headers: { ...CORS_HEADERS, ...(init.headers || {}) } });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface EmbedSectionRequest {
  outline_section_id?: string;
  outline_id?: string;
  project_id?: string;
  position?: number;
  title?: string;
  summary?: string;
  container?: string;
  pov?: string;
  terminal_beat?: string;
  story_arc_beat_id?: string;
  raw_text?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") return errorResponse("method_not_allowed", "POST only", 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return errorResponse("not_authenticated", "Missing Authorization header", 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const openaiKey = Deno.env.get("OPENAI_API_KEY");

  if (!supabaseUrl || !supabaseAnonKey) {
    return errorResponse("not_configured", "Supabase URL or anon key missing", 500);
  }
  if (!supabaseServiceKey) {
    return errorResponse("not_configured", "SUPABASE_SERVICE_ROLE_KEY missing", 500);
  }
  if (!openaiKey) {
    return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) {
    return errorResponse("not_authenticated", "Invalid token", 401);
  }

  let body: EmbedSectionRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }
  if (!body.outline_section_id || !body.outline_id || !body.project_id || !body.title || !body.raw_text) {
    return errorResponse(
      "invalid_request",
      "outline_section_id, outline_id, project_id, title, and raw_text are required",
      400
    );
  }

  console.log(`[embed-section] start user=${user.id} section=${body.outline_section_id} outline=${body.outline_id} project=${body.project_id}`);

  const adminClient = createClient(supabaseUrl, supabaseServiceKey);

  // Step 1: UPSERT outline (id = client-provided, user_id from auth, local_project_id + lineage_id).
  // The actual `outlines` schema uses user_id / local_project_id / lineage_id — NOT project_id
  // (which doesn't exist; my v2 guessed wrong from the v1 join syntax that was never exercised).
  // We do this first so the outline_section FK has a target.
  const { error: outlineErr } = await adminClient.from("outlines").upsert({
    id: body.outline_id,
    user_id: user.id,
    local_project_id: body.project_id,
    lineage_id: body.project_id,
    name: "Outline",
  }, { onConflict: "id" });
  if (outlineErr) {
    console.error(`[embed-section] outline upsert failed: ${outlineErr.message}`);
    return errorResponse("database_error", `outline upsert failed: ${outlineErr.message}`, 500);
  }
  console.log(`[embed-section] outline upserted id=${body.outline_id}`);

  // Step 1.5: Validate story_arc_beat_id exists in story_arc_beats before
  // the section upsert. iOS may send a beat UUID that wasn't synced (timing
  // race, beat regen, missing beats in sync payload). If bogus, null it so
  // the FK doesn't reject the upsert — Accept All succeeds even with a stale
  // beat ID. Defensive fix; root cause of the missing beats is sync-side.
  let validatedBeatID: string | null = body.story_arc_beat_id ?? null;
  if (validatedBeatID) {
    const { data: beatExists, error: beatCheckErr } = await adminClient
      .from("story_arc_beats")
      .select("id")
      .eq("id", validatedBeatID)
      .maybeSingle();
    if (beatCheckErr) {
      console.warn(`[embed-section] beat check error (nulling FK): ${beatCheckErr.message}`);
      validatedBeatID = null;
    } else if (!beatExists) {
      console.warn(`[embed-section] dropping bogus story_arc_beat_id: ${validatedBeatID}`);
      validatedBeatID = null;
    }
  }

  // Step 2: UPSERT outline_section (id = client-provided, all fields).
  // status stays "draft" here — the iOS app flips it to "accepted" locally
  // on 200 response. Server-side status flips live in a future PR if needed.
  const { error: sectionErr } = await adminClient.from("outline_sections").upsert({
    id: body.outline_section_id,
    outline_id: body.outline_id,
    position: body.position ?? 0,
    title: body.title,
    summary: body.summary ?? "",
    container: body.container ?? null,
    pov: body.pov ?? null,
    terminal_beat: body.terminal_beat ?? null,
    // story_arc_beat_id: column added in migration 20260806120000 (PR #284).
    // Was deferred in v2.1 with "Future migration + function update
    // deferred" comment.
    story_arc_beat_id: validatedBeatID,
    status: "draft",
  }, { onConflict: "id" });
  if (sectionErr) {
    console.error(`[embed-section] section upsert failed: ${sectionErr.message}`);
    return errorResponse("database_error", `outline_section upsert failed: ${sectionErr.message}`, 500);
  }
  console.log(`[embed-section] section upserted id=${body.outline_section_id}`);

  // Step 3: extract the full scene memory via LLM (one pass, JSON output).
  //
  // Produces all 6 layers in a single call (cheaper than 6 separate calls):
  //   - extracted_summary      (200-500 token distillation of what happened)
  //   - character_deltas       (per-character state changes this scene)
  //   - plot_thread_deltas     (plot-thread open/advance/resolve/complicate)
  //   - continuity_facts       (concrete facts future scenes must respect)
  //   - open_loops             (promises, mysteries, unanswered questions)
  //   - scene_ending_state     (where everyone is, immediate pressure)
  //
  // Uses OpenAI JSON mode (response_format: json_object) for structured output.
  // Each layer defaults to an empty array/object so the schema is forgiving.
  type SceneMemory = {
    extracted_summary: string;
    character_deltas: Array<Record<string, unknown>>;
    plot_thread_deltas: Array<Record<string, unknown>>;
    continuity_facts: string[];
    open_loops: Array<Record<string, unknown>>;
    scene_ending_state: Record<string, unknown>;
  };
  let sceneMemory: SceneMemory;
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 120_000);
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_MODEL_DEFAULT,
        messages: [
          {
            role: "system",
            content:
              "You are a fiction scene-memory extractor. Given a scene, output JSON with these 6 keys: " +
              "`extracted_summary` (200-500 token distillation of what happened), " +
              "`character_deltas` (array of {character_name, location?, knowledge_delta?, relationship_delta?, injuries?, goals?, possessions?, emotional_stance?}), " +
              "`plot_thread_deltas` (array of {thread_name, status in [opened,advanced,resolved,complicated], description}), " +
              "`continuity_facts` (array of concrete fact strings future scenes must not contradict), " +
              "`open_loops` (array of {type in [promise,mystery,question,threat,pending_action], description}), " +
              "`scene_ending_state` ({character_positions: [{character, location, immediate_state}], immediate_pressure: string}). " +
              "Output ONLY valid JSON. Empty arrays/objects are fine when a layer has nothing.",
          },
          { role: "user", content: body.raw_text },
        ],
        max_completion_tokens: 1500,
        temperature: 0.2,
        response_format: { type: "json_object" },
      }),
      signal: ac.signal,
    });
    clearTimeout(t);
    if (!r.ok) {
      const errText = await r.text();
      console.error(`[embed-section] OpenAI extract ${r.status}: ${errText.slice(0, 500)}`);
      return errorResponse(
        "provider_error",
        `OpenAI extract ${r.status}: ${errText.slice(0, 500)}`,
        502
      );
    }
    const data = await r.json();
    const raw = (data.choices?.[0]?.message?.content ?? "").trim();
    if (!raw) {
      console.error(`[embed-section] LLM extraction returned empty content`);
      return errorResponse("provider_error", "LLM extraction returned empty content", 502);
    }
    let parsed: Partial<SceneMemory>;
    try {
      parsed = JSON.parse(raw) as Partial<SceneMemory>;
    } catch (parseErr) {
      console.error(`[embed-section] LLM extraction returned invalid JSON: ${String(parseErr)} raw=${raw.slice(0, 300)}`);
      return errorResponse("provider_error", "LLM extraction returned invalid JSON", 502);
    }
    // Defaults: empty arrays/objects so the schema is forgiving if a layer is missing.
    sceneMemory = {
      extracted_summary: typeof parsed.extracted_summary === "string" ? parsed.extracted_summary : "",
      character_deltas: Array.isArray(parsed.character_deltas) ? parsed.character_deltas : [],
      plot_thread_deltas: Array.isArray(parsed.plot_thread_deltas) ? parsed.plot_thread_deltas : [],
      continuity_facts: Array.isArray(parsed.continuity_facts) ? parsed.continuity_facts : [],
      open_loops: Array.isArray(parsed.open_loops) ? parsed.open_loops : [],
      scene_ending_state:
        parsed.scene_ending_state && typeof parsed.scene_ending_state === "object"
          ? parsed.scene_ending_state
          : {},
    };
    if (!sceneMemory.extracted_summary) {
      console.error(`[embed-section] LLM extraction returned empty summary`);
      return errorResponse("provider_error", "LLM extraction returned empty summary", 502);
    }
  } catch (err) {
    console.error(`[embed-section] LLM extract threw: ${String(err)}`);
    return errorResponse("provider_error", String(err), 502);
  }
  console.log(`[embed-section] extract OK summary_len=${sceneMemory.extracted_summary.length} layers=6`);

  // Compute the compressed scene memory string. This is what we embed for
  // similarity search — encodes the structured state, not just the summary.
  // The goal is "needed context without sending tons of tokens": the retrieval
  // ranking picks the right scenes, and the generator injects the structured
  // fields (cheap) rather than the raw prose (expensive).
  const compressedMemory = JSON.stringify({
    summary: sceneMemory.extracted_summary,
    character_deltas: sceneMemory.character_deltas,
    plot_thread_deltas: sceneMemory.plot_thread_deltas,
    open_loops: sceneMemory.open_loops,
    ending_pressure: (sceneMemory.scene_ending_state as Record<string, unknown>)?.immediate_pressure ?? "",
  });

  // Step 4: embed the compressed scene memory (not just the summary).
  // The vector encodes the structured state — character deltas, plot thread
  // deltas, open loops, ending pressure — so similarity search ranks scenes
  // by relevance to the new scene's planned context, not just topical
  // similarity in the prose.
  let embedding: number[] = [];
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 60_000);
    const r = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_EMBED_MODEL,
        input: compressedMemory,
      }),
      signal: ac.signal,
    });
    clearTimeout(t);
    if (!r.ok) {
      const errText = await r.text();
      console.error(`[embed-section] OpenAI embed ${r.status}: ${errText.slice(0, 500)}`);
      return errorResponse(
        "provider_error",
        `OpenAI embed ${r.status}: ${errText.slice(0, 500)}`,
        502
      );
    }
    const data = await r.json();
    const vec = data.data?.[0]?.embedding;
    const extractedSummary = sceneMemory.extracted_summary;
    if (!Array.isArray(vec)) {
      console.error(`[embed-section] Embedding API returned invalid data`);
      return errorResponse("provider_error", "Embedding API returned invalid data", 502);
    }
    embedding = vec;
  } catch (err) {
    console.error(`[embed-section] embed threw: ${String(err)}`);
    return errorResponse("provider_error", String(err), 502);
  }
  console.log(`[embed-section] embed OK dim=${embedding.length}`);

  // Step 5: upsert into section_embeddings (UPSERT on outline_section_id).
  // Re-accepting an already-accepted section overwrites all 6 memory layers.
  const { error: upsertErr } = await adminClient.from("section_embeddings").upsert({
    project_id: body.project_id,
    outline_section_id: body.outline_section_id,
    embedding,
    extracted_summary: sceneMemory.extracted_summary,
    raw_text: body.raw_text,
    container: body.container ?? null,
    pov: body.pov ?? null,
    character_deltas: sceneMemory.character_deltas,
    plot_thread_deltas: sceneMemory.plot_thread_deltas,
    continuity_facts: sceneMemory.continuity_facts,
    open_loops: sceneMemory.open_loops,
    scene_ending_state: sceneMemory.scene_ending_state,
  }, { onConflict: "outline_section_id" });
  if (upsertErr) {
    console.error(`[embed-section] section_embeddings upsert failed: ${upsertErr.message}`);
    return errorResponse("database_error", upsertErr.message, 500);
  }
  console.log(`[embed-section] section_embeddings upserted section=${body.outline_section_id}`);

  return corsResponse(
    JSON.stringify({
      outline_section_id: body.outline_section_id,
      extracted_summary: extractedSummary,
      embedding_dim: embedding.length,
    }),
    { status: 200 }
  );
});
