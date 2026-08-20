// =============================================================================
// coherence-check Edge Function (Coherence v2, locked 2026-08-20 09:01 EDT)
//
// User-initiated opt-in coherence check. Compares the generated output text
// against the FULL RAG retrieval (all structured-memory layers) the caller
// provides. Surfaces genuine inconsistencies as a soft-warn list. Never
// blocks anything — just returns warnings.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Cost: charged via generation_usage_events (purpose: "coherence-check"),
//       routed by the iOS client. The edge function itself does NOT charge.
//
// Request:  POST {
//             output_text:  string,
//             rag_context:  RagRetrieval,
//             project_id?:  string   // for llm_prompts logging only
//           }
// Response: 200 { warnings: [{ reason: string, severity: "warn" | "high" }] }
//
// General-prompt design (Coherence v2): the LLM does all reasoning. We give
// it the output + the full structured canon and ask "find inconsistencies."
// No pre-engineered category list, no explicit-claim extraction, no
// ALIVE/DEAD/INJURED rendering. The LLM judges.
//
// Edge cases:
//   - empty rag_context            -> { warnings: [] }    (200)
//   - LLM returns no warnings      -> { warnings: [] }    (200)
//   - LLM returns garbage          -> 502 "LLM returned invalid JSON"
//   - OpenAI 5xx / rate-limit      -> 502 with body surfaced (do not mask)
//   - Auth missing/invalid         -> 401
//   - Wrong method / bad JSON      -> 400/405
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

interface RagRetrieval {
  character_deltas: unknown[];
  plot_thread_deltas: unknown[];
  continuity_facts: unknown[];
  open_loops: unknown[];
  scene_ending_state: unknown;
  extracted_summary?: string;
}

interface CoherenceCheckRequest {
  output_text: string;
  rag_context: RagRetrieval;
  project_id?: string;
}

interface CoherenceWarning {
  reason: string;
  severity: "warn" | "high";
}

// OpenAI Structured Outputs schema — strict, no additional properties.
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
              reason: { type: "string" },
              severity: {
                type: "string",
                enum: ["warn", "high"],
              },
            },
            required: ["reason", "severity"],
            additionalProperties: false,
          },
        },
      },
      required: ["warnings"],
      additionalProperties: false,
    },
  },
};

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
  if (typeof body.output_text !== "string" || body.output_text.length === 0) {
    return errorResponse("invalid_body", "output_text required (non-empty string)", 400);
  }
  if (!body.rag_context || typeof body.rag_context !== "object") {
    return errorResponse("invalid_body", "rag_context required (object)", 400);
  }

  // 3. Build the prompt — general "find inconsistencies" against the
  //    full RAG context the caller provided. LLM does all reasoning.
  const systemPrompt = `You are a story-coherence assistant. Find any inconsistencies between the generated output and the canon context (full RAG retrieval).

Compare carefully:
- Character names in the output vs canon
- Character states (alive/dead/injured) vs canon
- Locations vs canon
- Plot events vs established continuity facts
- POV consistency within the output
- Premise consistency (does the output match what was supposed to happen?)

Be specific. Cite the contradicting canon element in the reason field. Skip stylistic concerns.

Severity rules:
- "high" — clear contradiction (e.g., character written as alive when canon has them dead, POV drift, invented character not in canon)
- "warn" — softer concerns (anachronism, slight inconsistency, tone drift)

If there are no real inconsistencies, return {"warnings": []}.`;

  const ragContextStr = JSON.stringify(body.rag_context, null, 2);
  const userPrompt = `GENERATED OUTPUT:
${body.output_text}

CANON CONTEXT (full RAG retrieval — all structured-memory layers):
${ragContextStr}

For each real inconsistency, return one warning with:
- reason: one-sentence plain-English explanation of the inconsistency, citing the contradicting canon element
- severity: "high" if it's a clear contradiction, "warn" for softer concerns

Return {"warnings": []} if no real inconsistencies.`;

  // 4. Call OpenAI with Structured Outputs (strict schema).
  const llmStartMs = Date.now();
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

  // 5. Log to llm_prompts (best-effort). project_id is optional in v2.
  const llmDurationMs = Date.now() - llmStartMs;
  try {
    await userClient.from("llm_prompts").insert({
      call_type: "coherence-check",
      project_id: body.project_id ?? null,
      outline_section_id: null,
      model: OPENAI_MODEL_DEFAULT,
      prompt: JSON.stringify({
        system: systemPrompt,
        user: userPrompt,
      }),
      response: content,
      prompt_tokens: openaiData.usage?.prompt_tokens ?? null,
      completion_tokens: openaiData.usage?.completion_tokens ?? null,
      total_tokens: openaiData.usage?.total_tokens ?? null,
      duration_ms: llmDurationMs,
    });
  } catch (logErr) {
    console.error(`[coherence-check] llm_prompts insert failed: ${(logErr as Error).message}`);
  }

  // 6. Parse + return
  let parsed: { warnings?: Array<{ reason?: string; severity?: string }> };
  try {
    parsed = JSON.parse(content);
  } catch (e) {
    return errorResponse(
      "openai_invalid_json",
      `LLM returned invalid JSON: ${(e as Error).message}`,
      502,
    );
  }

  const warnings: CoherenceWarning[] = (parsed.warnings ?? [])
    .filter((w) =>
      typeof w.reason === "string" &&
      w.reason.length > 0 &&
      (w.severity === "warn" || w.severity === "high")
    )
    .map((w) => ({
      reason: w.reason as string,
      severity: w.severity === "high" ? "high" : "warn",
    }));

  return corsResponse(JSON.stringify({ warnings }), { status: 200 });
});
