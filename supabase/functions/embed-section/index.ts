// =============================================================================
// embed-section Edge Function (Phase 4 redesign per locked RAG rules)
//
// Called from iOS on OutlineSection Accept. On-demand pipeline:
//   1. UPSERT outline (id = client-provided outline_id, project_id)
//   2. UPSERT outline_section (id = client-provided outline_section_id)
//   3. LLM extraction pass — semantic content only (per Rule 1-3: no IDs,
//      no source_section_id, no status fields from the LLM; the function
//      adds these server-side)
//   4. Embed the summary (text-embedding-3-small, 1536-dim)
//   5. UPSERT into section_embeddings via service role with the new
//      shape: stable IDs, source_section_id, status, created_at, raw_text
//
// The function creates the outline + section on-demand. The iOS app does
// NOT need to sync them to supabase first — this was the v1 bug.
//
// Per Locked Design Rules (Kevin 2026-08-10 16:28 EDT, PR #306 RFC):
//   - Rule 1: keep the 5 structured memory layers
//   - Rule 2: character_deltas aggregate merges fields per character (not per-scene merge; the function emits per-scene character deltas and the aggregate does the merge)
//   - Rule 3: plot_thread_deltas + open_loops have stable IDs + explicit lifecycle
//   - Rule 4: continuity_facts have provenance + active/superseded
//   - Rule 8: pipeline order generate → persist → extract; this function is called AFTER the output is persisted by the caller (run-outline does the persist)
//   - Rule 9: raw_text is stored but not injected by default
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

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
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

import {
  type EmbedSectionRequest,
  processEmbedSection,
  SectionEmbeddingError,
} from "../_shared/section-embedding.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST only", 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse(
      "not_authenticated",
      "Missing Authorization header",
      401,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const openaiKey = Deno.env.get("OPENAI_API_KEY");

  if (!supabaseUrl || !supabaseAnonKey) {
    return errorResponse(
      "not_configured",
      "Supabase URL or anon key missing",
      500,
    );
  }
  if (!supabaseServiceKey) {
    return errorResponse(
      "not_configured",
      "SUPABASE_SERVICE_ROLE_KEY missing",
      500,
    );
  }
  if (!openaiKey) {
    return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
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

  if (
    !body.outline_section_id || !body.outline_id || !body.project_id ||
    !body.title || !body.raw_text
  ) {
    return errorResponse(
      "invalid_request",
      "outline_section_id, outline_id, project_id, title, and raw_text are required",
      400,
    );
  }

  console.log(
    `[embed-section] start user=${user.id} section=${body.outline_section_id} outline=${body.outline_id} project=${body.project_id}`,
  );

  const adminClient = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const result = await processEmbedSection(
      body,
      user.id,
      adminClient,
      openaiKey,
    );
    return corsResponse(JSON.stringify(result), { status: 200 });
  } catch (err) {
    if (err instanceof SectionEmbeddingError) {
      const status = err.code === "database_error" ? 500 : 502;
      return errorResponse(err.code, err.message, status);
    }
    return errorResponse("provider_error", String(err), 502);
  }
});
