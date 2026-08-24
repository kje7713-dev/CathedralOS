// =============================================================================
// coherence-check Edge Function (Coherence v2.1 — general-purpose, 2026-08-20,
// refactored onto _shared/billable-llm.ts 2026-08-24)
//
// General-purpose coherence check. Compares the generated output text against
// the current section's intent and prior accepted canon. Surfaces genuine
// inconsistencies as a soft-warn list. Never blocks anything — just returns
// warnings.
//
// After refactor: this file is the FEATURE handler only. The LLM call,
// pricing, provider, usage-event insert, and credit-charge machinery live in
// supabase/functions/_shared/billable-llm.ts. The shared runner is also used
// by generate-story. iOS contract and behavior preserved exactly.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// user_id is derived EXCLUSIVELY from the verified JWT — never from the body.
// Cost: server-side charged via the shared billable-LLM runner
//       (purpose="coherence-check", action="check"). Uses the SAME pricing
//       model as generate-story (computeActualChargeCredits + snapshotPricing).
//       Idempotency: server-derived from request fingerprint + 60s minute
//       bucket. Partial unique index on (user_id, idempotency_key) prevents
//       duplicate usage rows from double-taps / network retries.
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
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  runBillableLLM,
  BillableLLMError,
  type BillableProviderResult,
} from "../_shared/billable-llm.ts";
import {
  COHERENCE_RESPONSE_FORMAT,
  buildMessages,
} from "./_prompts.ts";
import { validateRequest, validateAndFilterWarnings } from "./_validation.ts";
import { computeIdempotencyKey } from "./_idempotency.ts";
import {
  GenerationModel,
  PricingSnapshot,
} from "../generate-story/_generation_models.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { OpenAIProvider, LLMProvider } from "../generate-story/_provider.ts";
import type { LLMMessage } from "../generate-story/_provider.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = ***"SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = ***"SUPABASE_SERVICE_ROLE_KEY") ?? "";
const OPENAI_API_KEY = ***"OPENAI_API_KEY")!;
const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5-mini";
const COHERENCE_TEMPERATURE = 0.2;
const COHERENCE_MAX_COMPLETION_TOKENS = 1500;

// Service-role admin client — owned by the feature, passed to the shared
// runner for billing writes (generation_usage_events INSERT). Never used for
// the JWT-scoped auth path; never accepts a user JWT for writes.
const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const creditStore = new SupabaseCreditStore(adminClient);

// LLM provider for the coherence feature. Uses chat/completions + Structured
// Outputs via the 4th options argument (LLMProviderOptions.responseFormat).
// This is feature-specific — generate-story uses the Responses API path
// (4th arg unset). Same OpenAIProvider class, different code path inside.
const provider: LLMProvider = new OpenAIProvider(OPENAI_API_KEY, OPENAI_MODEL_DEFAULT);

// Fallback model row when the env-var-provided model isn\'t in
// generation_models. Used for snapshotPricing() only — the actual LLM call
// still uses OPENAI_MODEL_DEFAULT. Keeps the billing flow working when the
// catalog is missing a row for the deployed model.
const FALLBACK_MODEL: GenerationModel = {
  id: "__fallback__",
  provider: "openai",
  provider_model: OPENAI_MODEL_DEFAULT,
  display_name: OPENAI_MODEL_DEFAULT,
  description: "Fallback pricing for coherence-check when model not in generation_models",
  input_credit_rate: 0,
  output_credit_rate: 0,
  minimum_charge_credits: 1,
  max_output_tokens: null,
  enabled: true,
  sort_order: 0,
  billing_multiplier: 2.0,
  provider_input_usd_per_1m: 0.40,
  provider_cached_input_usd_per_1m: 0.10,
  provider_output_usd_per_1m: 1.60,
  pricing_effective_at: new Date().toISOString(),
};

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

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth via user JWT. user_id is derived EXCLUSIVELY from the verified JWT.
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

  // 2. Parse + validate the request body using the production validator
  //    extracted to _validation.ts (no mirror in the test file anymore).
  let body: unknown;
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

  // 3. Resolve the GenerationModel. Feature-specific: OPENAI_MODEL_DEFAULT
  //    env var → generation_models lookup → FALLBACK_MODEL. This preserves
  //    the original coherence-check model-selection policy unchanged.
  const { data: modelRow } = await adminClient
    .from("generation_models")
    .select("*")
    .eq("provider_model", OPENAI_MODEL_DEFAULT)
    .eq("enabled", true)
    .maybeSingle();
  const model: GenerationModel =
    (modelRow as GenerationModel | null) ?? FALLBACK_MODEL;

  // 4. Build the messages (system + user) using the production builder
  //    extracted to _prompts.ts. Structured Outputs schema is also there.
  const messages = buildMessages(request);

  // 5. Compute idempotency key (extracted to _idempotency.ts). Server-derived
  //    from user_id + body fingerprint + 60s minute bucket.
  const idempotencyKey = await computeIdempotencyKey(userId, request);

  // 6. Call the shared billable-LLM runner. Owns: preflight credit check →
  //    provider call → onProviderSuccess callback → usage event insert →
  //    credit charge. On provider failure: records a 'failed' usage event
  //    then rethrows (so we don\'t double-log here).
  let providerResult: BillableProviderResult;
  try {
    const llmMessages: LLMMessage[] = [
      { role: "system", content: messages.system },
      { role: "user", content: messages.user },
    ];
    const runnerResult = await runBillableLLM({
      userID: userId,
      purpose: "coherence-check",
      action: "check",
      model,
      messages: llmMessages,
      maxOutputTokens: COHERENCE_MAX_COMPLETION_TOKENS,
      providerOptions: {
        responseFormat: COHERENCE_RESPONSE_FORMAT,
        temperature: COHERENCE_TEMPERATURE,
      },
      usageContext: {
        projectID: request.project_id ?? null,
        generationOutputID: null,
        generationLengthMode: "short",
        outputBudget: COHERENCE_MAX_COMPLETION_TOKENS,
        idempotencyKey,
      },
      // Coherence-check has no feature-specific persistence. The runner
      // already records the usage event + charges credits on success.
      onProviderSuccess: async (result) => {
        providerResult = result;
        return null;
      },
    });
    // Capture providerResult from the closure (assigned in callback).
    providerResult = runnerResult.providerResult;
  } catch (err) {
    if (err instanceof BillableLLMError) {
      if (err.code === "insufficient_credits") {
        return errorResponse("insufficient_credits", err.message, 402);
      }
      if (err.code === "usage_event_insert_failed") {
        return errorResponse(
          "internal_error",
          "Failed to record usage event; please retry.",
          500,
        );
      }
    }
    // Provider-level failure (runner already recorded the 'failed' usage
    // event). Surface to the iOS app as 502 — preserve pre-refactor behavior.
    const message = err instanceof Error ? err.message : String(err);
    const code = (err as { errorCode?: string })?.errorCode ?? "openai_error";
    return errorResponse(code, message, 502);
  }

  // 7. Parse + validate the LLM response (Structured Outputs JSON).
  let parsed: unknown;
  try {
    parsed = JSON.parse(providerResult.content);
  } catch (e) {
    return errorResponse(
      "openai_invalid_json",
      `LLM returned invalid JSON: ${(e as Error).message}`,
      502,
    );
  }
  const { warnings, preFilterCount, postFilterCount } =
    validateAndFilterWarnings(parsed);

  // 8. Best-effort audit log to llm_prompts. Uses the user-scoped client
  //    (matches pre-refactor behavior — preserves any RLS policy that
  //    restricts audit writes to the JWT subject). Failure here must not
  //    fail the main response.
  try {
    await userClient.from("llm_prompts").insert({
      call_type: "coherence-check",
      project_id: request.project_id ?? null,
      outline_section_id: request.current_section?.id ?? null,
      model: providerResult.modelName,
      prompt: JSON.stringify(messages),
      response: providerResult.content,
      prompt_tokens: providerResult.inputTokens,
      completion_tokens: providerResult.outputTokens,
      total_tokens:
        (providerResult.inputTokens ?? 0) +
        (providerResult.outputTokens ?? 0),
    });
  } catch (logErr) {
    console.error(
      `[coherence-check] llm_prompts insert failed: ${
        logErr instanceof Error ? logErr.message : String(logErr)
      }`,
    );
  }

  // 9. Format the response. Shape is byte-compatible with the iOS decoder.
  const diagnostics = {
    raw_content: providerResult.content,
    finish_reason: providerResult.finishReason ?? "unknown",
    model: providerResult.modelName,
    pre_filter_count: preFilterCount,
    post_filter_count: postFilterCount,
    prompt_tokens: providerResult.inputTokens,
    completion_tokens: providerResult.outputTokens,
  };
  return corsResponse(
    JSON.stringify({ warnings, diagnostics }),
    { status: 200 },
  );
});
