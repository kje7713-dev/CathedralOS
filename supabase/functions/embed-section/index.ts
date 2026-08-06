// =============================================================================
// embed-section Edge Function (Phase 3 of novel-building per docs/novel-building.md)
//
// Called from iOS on OutlineSection Accept. Three-step pipeline:
//   1. LLM extraction pass — ~200-500 token distillation (gpt-4o-mini)
//   2. Embed the summary (text-embedding-3-small, 1536-dim)
//   3. UPSERT into section_embeddings via service role
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Service-role key is used server-side only (never exposed to iOS).
//
// Request:  POST { outline_section_id, raw_text, container?, pov? }
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
  raw_text?: string;
  container?: string;
  pov?: string;
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
  if (!body.outline_section_id || !body.raw_text) {
    return errorResponse("invalid_request", "outline_section_id and raw_text required", 400);
  }

  // Step 1: extract summary via LLM
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
      return errorResponse(
        "provider_error",
        `OpenAI extract ${r.status}: ${errText.slice(0, 500)}`,
        502
      );
    }
    const data = await r.json();
    extractedSummary = (data.choices?.[0]?.message?.content ?? "").trim();
    if (!extractedSummary) {
      return errorResponse("provider_error", "LLM extraction returned empty summary", 502);
    }
  } catch (err) {
    return errorResponse("provider_error", String(err), 502);
  }

  // Step 2: embed summary
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
      return errorResponse(
        "provider_error",
        `OpenAI embed ${r.status}: ${errText.slice(0, 500)}`,
        502
      );
    }
    const data = await r.json();
    const vec = data.data?.[0]?.embedding;
    if (!Array.isArray(vec)) {
      return errorResponse("provider_error", "Embedding API returned invalid data", 502);
    }
    embedding = vec;
  } catch (err) {
    return errorResponse("provider_error", String(err), 502);
  }

  // Step 3: resolve project_id via outline_sections → outlines
  const adminClient = createClient(supabaseUrl, supabaseServiceKey);
  const { data: sectionRow, error: lookupErr } = await adminClient
    .from("outline_sections")
    .select("outline_id, outlines!inner(project_id)")
    .eq("id", body.outline_section_id)
    .single();
  if (lookupErr || !sectionRow) {
    return errorResponse(
      "invalid_request",
      `outline_section_id lookup failed: ${lookupErr?.message ?? "no row"}`,
      400
    );
  }
  const projectId = (sectionRow as { outlines: { project_id: string } | null }).outlines?.project_id;
  if (!projectId) {
    return errorResponse("invalid_request", "outline has no project_id", 400);
  }

  // Step 4: upsert
  const { error: upsertErr } = await adminClient.from("section_embeddings").upsert({
    project_id: projectId,
    outline_section_id: body.outline_section_id,
    embedding,
    extracted_summary: extractedSummary,
    raw_text: body.raw_text,
    container: body.container ?? null,
    pov: body.pov ?? null,
  }, { onConflict: "outline_section_id" });
  if (upsertErr) {
    return errorResponse("database_error", upsertErr.message, 500);
  }

  return corsResponse(
    JSON.stringify({
      outline_section_id: body.outline_section_id,
      extracted_summary: extractedSummary,
      embedding_dim: embedding.length,
    }),
    { status: 200 }
  );
});
