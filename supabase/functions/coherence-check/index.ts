// =============================================================================
// coherence-check Edge Function (Phase 7 per docs/novel-building.md)
//
// Pre-generation soft-warn check. Compares a proposed outline section's
// premise against the project's already-accepted sections, and surfaces
// genuine contradictions as a non-blocking warning list.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Cost: NO credit charge. This is a free pre-check that runs before the
// user commits credits to the actual generation run.
//
// Request:  POST {
//             project_id,
//             section: { title, summary, container?, pov?, beat_label?,
//                        characters?, prompt_pack_notes? },
//             top_k?: 1..10    (default 5)
//           }
// Response: 200 { warnings: [{ section_id, section_title, reason, severity }] }
//
// No content is persisted. No embeddings are computed. We compare against
// the 200-500 token summaries stored in section_embeddings.summary
// (per Phase 3 locked design rule).
//
// Edge cases:
//   - 0 accepted neighbors       -> { warnings: [] }    (200, not an error)
//   - LLM returns no warnings    -> { warnings: [] }    (200)
//   - LLM returns garbage        -> 502 "LLM returned invalid JSON"
//   - OpenAI 5xx / rate-limit    -> 502 with body surfaced (do not mask)
//   - Auth missing/invalid       -> 401
//   - Wrong method / bad JSON    -> 400/405
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5-mini";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, {
    ...init,
    headers: { ...CORS_HEADERS, ...(init.headers ?? {}) },
  });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface CoherenceSectionInput {
  title: string;
  summary: string;
  container?: string;
  pov?: string;
  beat_label?: string;
  characters?: string[];
  prompt_pack_notes?: string;
}

interface CoherenceCheckRequest {
  project_id: string;
  section: CoherenceSectionInput;
  top_k?: number;
}

interface CoherenceWarning {
  section_id: string;
  section_title: string;
  reason: string;
  severity: "warn";
}

// OpenAI Structured Outputs schema — strict, no additional properties.
// Mirrors the SCENE_MEMORY_RESPONSE_FORMAT pattern from embed-section/index.ts.
const COHERENCE_RESPONSE_FORMAT = {
  type: "json_schema",
  json_schema: {
    name: "coherence_warnings",
    strict: true,
    schema: {
      type: "object",
      properties: {
        warnings: {
          type: "array",
          items: {
            type: "object",
            properties: {
              section_id: { type: "string" },
              section_title: { type: "string" },
              reason: { type: "string" },
            },
            required: ["section_id", "section_title", "reason"],
            additionalProperties: false,
          },
        },
      },
      required: ["warnings"],
      additionalProperties: false,
    },
  },
} as const;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth via user's JWT (service role is never accepted)
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

  // 2. Parse + validate request body
  let body: CoherenceCheckRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  if (!body.project_id || typeof body.project_id !== "string") {
    return errorResponse("invalid_body", "project_id required", 400);
  }
  if (
    !body.section ||
    typeof body.section.title !== "string" ||
    typeof body.section.summary !== "string"
  ) {
    return errorResponse(
      "invalid_body",
      "section.title and section.summary required",
      400,
    );
  }
  const topK = Math.max(1, Math.min(body.top_k ?? 5, 10));

  // 3. Fetch accepted-section neighbors for this project.
  const { data: neighborRows, error: qErr } = await userClient
    .from("section_embeddings")
    .select(`
      outline_section_id,
      summary,
      created_at,
      outline_sections!inner(
        id,
        title,
        position,
        status,
        project_id
      )
    `)
    .eq("outline_sections.project_id", body.project_id)
    .eq("outline_sections.status", "accepted")
    .order("created_at", { ascending: false })
    .limit(topK);

  if (qErr) {
    return errorResponse(
      "neighbor_query_failed",
      `Could not load accepted sections: ${qErr.message}`,
      500,
    );
  }

  const neighbors = neighborRows ?? [];
  if (neighbors.length === 0) {
    // No accepted neighbors yet — nothing to contradict against.
    return corsResponse(JSON.stringify({ warnings: [] }), { status: 200 });
  }

  // 4. Build the prompt. Keep it small + focused.
  const neighborText = neighbors
    .map((row: any, i: number) => {
      const sec = row.outline_sections;
      return `[#${i + 1}] "${sec.title}" (id: ${sec.id}, position ${sec.position})\n${
        row.summary ?? "(no summary available)"
      }`;
    })
    .join("\n\n");

  const proposedDesc = [
    `Title: ${body.section.title}`,
    `Summary: ${body.section.summary}`,
    body.section.container ? `Container: ${body.section.container}` : null,
    body.section.pov ? `POV: ${body.section.pov}` : null,
    body.section.beat_label ? `Beat: ${body.section.beat_label}` : null,
    body.section.characters?.length
      ? `Characters: ${body.section.characters.join(", ")}`
      : null,
    body.section.prompt_pack_notes ? `Prompt pack notes: ${body.section.prompt_pack_notes}` : null,
  ].filter(Boolean).join("\n");

  const systemPrompt = `You are a story-coherence assistant. Compare a proposed outline section against the project's already-accepted sections. Surface only GENUINE, HIGH-CONFIDENCE contradictions: state drift, broken continuity, character actions that contradict established facts, POV drift, or major tone inconsistencies. Do NOT surface stylistic preferences, weak thematic echoes, or speculative concerns. If there are no real contradictions, return {warnings: []}. Be sparing and accurate.`;

  const userPrompt = `PROPOSED SECTION:
${proposedDesc}

ACCEPTED SECTIONS (most recent first):
${neighborText}

For each real contradiction, return one warning with:
- section_id: the UUID (in the parenthesis above) of the contradicting accepted section
- section_title: that section's title
- reason: one-sentence plain-English explanation

Return JSON {"warnings": []} if no genuine conflicts.`;

  // 5. Call OpenAI with Structured Outputs (strict schema).
  let openaiRes: Response;
  try {
    openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL_DEFAULT,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        response_format: COHERENCE_RESPONSE_FORMAT,
        max_completion_tokens: 1500,
        temperature: 0.2,
      }),
    });
  } catch (e) {
    return errorResponse(
      "openai_unreachable",
      `OpenAI request failed: ${(e as Error).message}`,
      502,
    );
  }

  if (!openaiRes.ok) {
    const errText = await openaiRes.text();
    return corsResponse(
      JSON.stringify({
        errorCode: "openai_error",
        message: `OpenAI error ${openaiRes.status}: ${errText}`,
      }),
      { status: 502 },
    );
  }

  const openaiData = await openaiRes.json();
  const content = openaiData.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    return errorResponse("openai_empty", "OpenAI returned no content", 502);
  }

  let parsed: {
    warnings?: Array<{
      section_id?: string;
      section_title?: string;
      reason?: string;
    }>;
  };
  try {
    parsed = JSON.parse(content);
  } catch (e) {
    return errorResponse(
      "openai_invalid_json",
      `LLM returned invalid JSON: ${(e as Error).message}`,
      502,
    );
  }

  // 6. Validate, clamp severity, drop warnings that reference sections we
  //    didn't actually pass to the LLM (LLM hallucination guard).
  const validIds = new Set<string>(
    neighbors.map((row: any) => row.outline_sections.id as string),
  );
  const warnings: CoherenceWarning[] = (parsed.warnings ?? [])
    .filter((w) =>
      typeof w.section_id === "string" &&
      validIds.has(w.section_id) &&
      typeof w.reason === "string" &&
      w.reason.length > 0
    )
    .map((w) => ({
      section_id: w.section_id as string,
      section_title: typeof w.section_title === "string" && w.section_title.length > 0
        ? (w.section_title as string)
        : "(untitled)",
      reason: w.reason as string,
      severity: "warn" as const,
    }));

  return corsResponse(JSON.stringify({ warnings }), { status: 200 });
});
