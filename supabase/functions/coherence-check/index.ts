// =============================================================================
// coherence-check Edge Function (Coherence v2.1 — general-purpose, 2026-08-20)
//
// General-purpose coherence check. Compares the generated output text against
// the current section's intent and prior accepted canon. Surfaces genuine
// inconsistencies as a soft-warn list. Never blocks anything — just returns
// warnings.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Cost: charged via generation_usage_events (purpose: "coherence-check"),
//       routed by the iOS client. The edge function itself does NOT charge.
//
// Request:  POST {
//             output_text:     string,
//             current_section: CurrentSection | null,
//             prior_canon:     { sections: CanonSection[] },
//             project_id?:     string   // for llm_prompts logging only
//           }
// Response: 200 {
//             warnings: [{ reason: string, severity: "warn" | "high" }],
//             diagnostics: {
//               raw_content: string,
//               finish_reason: string,
//               model: string,
//               pre_filter_count: number,
//               post_filter_count: number,
//               prompt_tokens: number | null,
//               completion_tokens: number | null,
//             }
//           }
//
// v2.1 changes from v2:
// - Restored section intent comparison (current_section included in request)
// - Section-aware RAG (prior_canon.sections preserves section identity,
//   recency, pov, container, and per-section structured layers)
// - Provider-response diagnostics so we can distinguish "LLM returned []" from
//   "warnings were filtered out" from "LLM truncated"
// - Prompt no longer suppresses internal inconsistencies
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

interface CurrentSection {
  id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  beat_label: string | null;
}

interface CanonSection {
  section_id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  created_at: string;
  extracted_summary: string | null;
  character_deltas: unknown[];
  plot_thread_deltas: unknown[];
  continuity_facts: unknown[];
  open_loops: unknown[];
  scene_ending_state: unknown;
}

interface PriorCanon {
  sections: CanonSection[];
}

interface CoherenceCheckRequest {
  output_text: string;
  current_section: CurrentSection | null;
  prior_canon: PriorCanon;
  project_id?: string;
}

interface CoherenceWarning {
  reason: string;
  severity: "warn" | "high";
}

interface CoherenceDiagnostics {
  raw_content: string;
  finish_reason: string;
  model: string;
  pre_filter_count: number;
  post_filter_count: number;
  prompt_tokens: number | null;
  completion_tokens: number | null;
}

interface CoherenceCheckResponse {
  warnings: CoherenceWarning[];
  diagnostics: CoherenceDiagnostics;
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

const SYSTEM_PROMPT = `You are a story-coherence checker. The user generated output text for a section. Your job is to identify real inconsistencies in the generated output.

CONTEXT YOU WILL RECEIVE:
- CURRENT SECTION INTENT: what this section was supposed to be (title, summary, POV, container, beat_label). If null, the section has no current intent.
- PRIOR CANON: structured memory from previously accepted sections, ordered by recency (newest first). Each entry is a section with its identity, summary, POV, container, and structured layers.
- GENERATED OUTPUT: the prose the user wrote for this section.

FIND INCONSISTENCIES. Categories include but are not limited to:
- Contradictions with prior canon (character states, locations, plot events, continuity facts)
- Output contradicts the current section's intended premise/summary/POV/container
- Internal inconsistencies within the output itself (POV shifts, character/name confusion, impossible sequencing, factual self-contradictions)
- Unresolved plot threads being silently dropped, or open threads being prematurely closed
- Tone/voice continuity breaks (NOT surface-level style)

FOR EACH FINDING, write \`reason\` as a one-sentence plain-English explanation. Cite the contradicting canon element when the inconsistency is canon-related. When the inconsistency is entirely inside the output (no canon element to cite), state that explicitly.

SEVERITY:
- "high" — clear factual contradiction, premise mismatch, or POV drift
- "warn" — softer concern (anachronism, lesser inconsistency)

If there are no real inconsistencies, return {"warnings": []}.`;

const buildUserPrompt = (input: {
  output_text: string;
  current_section: CurrentSection | null;
  prior_canon: PriorCanon;
}): string => {
  const parts: string[] = [
    "GENERATED OUTPUT:",
    input.output_text,
    "",
    "CURRENT SECTION INTENT:",
    input.current_section
      ? `Title: ${input.current_section.title}\nSummary: ${input.current_section.summary}\nPOV: ${input.current_section.pov ?? "(unspecified)"}\nContainer: ${input.current_section.container ?? "(unspecified)"}\nTerminal Beat: ${input.current_section.beat_label ?? "(unspecified)"}`
      : "(none)",
    "",
    "PRIOR CANON (ordered by recency, newest first):",
  ];
  if (input.prior_canon.sections.length === 0) {
    parts.push("(no prior accepted sections)");
  } else {
    const sectionBlocks = input.prior_canon.sections.map((s, i) =>
      `[Section ${i + 1}] id=${s.section_id}\n` +
      `Title: ${s.title}\n` +
      `Summary: ${s.summary}\n` +
      `POV: ${s.pov ?? "(unspecified)"}\n` +
      `Container: ${s.container ?? "(unspecified)"}\n` +
      `Extracted summary: ${s.extracted_summary ?? "(none)"}\n` +
      `Created at: ${s.created_at}\n` +
      `Character deltas: ${JSON.stringify(s.character_deltas, null, 2)}\n` +
      `Plot thread deltas: ${JSON.stringify(s.plot_thread_deltas, null, 2)}\n` +
      `Continuity facts: ${JSON.stringify(s.continuity_facts, null, 2)}\n` +
      `Open loops: ${JSON.stringify(s.open_loops, null, 2)}\n` +
      `Scene ending state: ${JSON.stringify(s.scene_ending_state, null, 2)}`
    );
    parts.push(sectionBlocks.join("\n\n"));
  }
  return parts.join("\n");
};

const validateRequest = (body: any): { ok: true; request: CoherenceCheckRequest } | { ok: false; error: string } => {
  if (typeof body?.output_text !== "string" || body.output_text.length === 0) {
    return { ok: false, error: "output_text required (non-empty string)" };
  }
  if (!body.prior_canon || typeof body.prior_canon !== "object") {
    return { ok: false, error: "prior_canon required (object)" };
  }
  if (!Array.isArray(body.prior_canon.sections)) {
    return { ok: false, error: "prior_canon.sections required (array)" };
  }
  if (body.current_section !== null && body.current_section !== undefined) {
    const cs = body.current_section;
    if (typeof cs.id !== "string" || typeof cs.title !== "string" || typeof cs.summary !== "string") {
      return { ok: false, error: "current_section requires id, title, summary (strings)" };
    }
  }
  return { ok: true, request: body as CoherenceCheckRequest };
};

const validateAndFilterWarnings = (raw: any): {
  warnings: CoherenceWarning[];
  preFilterCount: number;
  postFilterCount: number;
} => {
  if (!raw || typeof raw !== "object") {
    return { warnings: [], preFilterCount: 0, postFilterCount: 0 };
  }
  const list = Array.isArray(raw.warnings) ? raw.warnings : [];
  const preFilterCount = list.length;
  const warnings: CoherenceWarning[] = list
    .filter((w: any) =>
      typeof w === "object" &&
      w !== null &&
      typeof w.reason === "string" &&
      w.reason.length > 0 &&
      (w.severity === "warn" || w.severity === "high")
    )
    .map((w: any) => ({
      reason: w.reason as string,
      severity: w.severity === "high" ? "high" : "warn",
    }));
  return { warnings, preFilterCount, postFilterCount: warnings.length };
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
  let body: any;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  const validation = validateRequest(body);
  if (!validation.ok) {
    return errorResponse("invalid_body", validation.error, 400);
  }
  const request = validation.request;

  // 3. Build the prompt
  const userPrompt = buildUserPrompt({
    output_text: request.output_text,
    current_section: request.current_section,
    prior_canon: request.prior_canon,
  });

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
          { role: "system", content: SYSTEM_PROMPT },
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
  const finishReason = openaiData.choices?.[0]?.finish_reason ?? "unknown";
  const modelUsed = openaiData.model ?? OPENAI_MODEL_DEFAULT;
  const promptTokens = openaiData.usage?.prompt_tokens ?? null;
  const completionTokens = openaiData.usage?.completion_tokens ?? null;
  if (typeof content !== "string") {
    return errorResponse("openai_empty", "OpenAI returned no content", 502);
  }

  // 5. Log to llm_prompts (best-effort). project_id is optional in v2.
  const llmDurationMs = Date.now() - llmStartMs;
  try {
    await userClient.from("llm_prompts").insert({
      call_type: "coherence-check",
      project_id: request.project_id ?? null,
      outline_section_id: request.current_section?.id ?? null,
      model: modelUsed,
      prompt: JSON.stringify({
        system: SYSTEM_PROMPT,
        user: userPrompt,
      }),
      response: content,
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      total_tokens: openaiData.usage?.total_tokens ?? null,
      duration_ms: llmDurationMs,
    });
  } catch (logErr) {
    console.error(`[coherence-check] llm_prompts insert failed: ${(logErr as Error).message}`);
  }

  // 6. Parse + validate response
  let parsed: any;
  try {
    parsed = JSON.parse(content);
  } catch (e) {
    return errorResponse(
      "openai_invalid_json",
      `LLM returned invalid JSON: ${(e as Error).message}`,
      502,
    );
  }
  const { warnings, preFilterCount, postFilterCount } = validateAndFilterWarnings(parsed);

  // 7. Return with diagnostics
  const diagnostics: CoherenceDiagnostics = {
    raw_content: content,
    finish_reason: finishReason,
    model: modelUsed,
    pre_filter_count: preFilterCount,
    post_filter_count: postFilterCount,
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
  };
  const response: CoherenceCheckResponse = { warnings, diagnostics };
  return corsResponse(JSON.stringify(response), { status: 200 });
});
