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
    story_arc_beat_id: body.story_arc_beat_id ?? null,
    status: "draft",
  }, { onConflict: "id" });
  if (sectionErr) {
    console.error(`[embed-section] section upsert failed: ${sectionErr.message}`);
    return errorResponse("database_error", `outline_section upsert failed: ${sectionErr.message}`, 500);
  }
  console.log(`[embed-section] section upserted id=${body.outline_section_id}`);

  // Step 3: extract summary via LLM
  let extractedSummary = "";
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 90_000);
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
              "You are a concise fiction editor. Summarize the following section in 200-500 tokens. Capture essential characters, conflict, setting, and emotional arc. Output ONLY the summary, no preamble.",
          },
          { role: "user", content: body.raw_text },
        ],
        max_completion_tokens: 700,
        temperature: 0.3,
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
    extractedSummary = (data.choices?.[0]?.message?.content ?? "").trim();
    if (!extractedSummary) {
      console.error(`[embed-section] LLM extraction returned empty summary`);
      return errorResponse("provider_error", "LLM extraction returned empty summary", 502);
    }
  } catch (err) {
    console.error(`[embed-section] LLM extract threw: ${String(err)}`);
    return errorResponse("provider_error", String(err), 502);
  }
  console.log(`[embed-section] extract OK len=${extractedSummary.length}`);

  // Step 4: embed summary
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
        input: extractedSummary,
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
  // Re-accepting an already-accepted section overwrites the embedding.
  const { error: upsertErr } = await adminClient.from("section_embeddings").upsert({
    project_id: body.project_id,
    outline_section_id: body.outline_section_id,
    embedding,
    extracted_summary: extractedSummary,
    raw_text: body.raw_text,
    container: body.container ?? null,
    pov: body.pov ?? null,
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
