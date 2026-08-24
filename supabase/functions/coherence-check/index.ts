// =============================================================================
// coherence-check Edge Function (Coherence v2.1 — general-purpose, 2026-08-20,
// Phase A refactor onto _shared/billable-llm.ts 2026-08-24)
//
// General-purpose coherence check. Compares the generated output text against
// the current section's intent and prior accepted canon. Surfaces genuine
// inconsistencies as a soft-warn list. Never blocks anything — just returns
// warnings.
//
// After Phase A refactor: this file is the FEATURE handler only. The LLM
// call, pricing, provider, usage-event insert, and credit-charge machinery
// live in supabase/functions/_shared/billable-llm.ts. Generate-story
// migration is deferred to PR B (see PR #407 description). iOS contract
// and behavior preserved byte-shape.
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
  BillableLLMError,
  type BillableProviderResult,
  recordFailedUsageEvent,
  runBillableLLM,
} from "../_shared/billable-llm.ts";
import { buildMessages, COHERENCE_RESPONSE_FORMAT } from "./_prompts.ts";
import { validateAndFilterWarnings, validateRequest } from "./_validation.ts";
import { computeIdempotencyKey } from "./_idempotency.ts";
import { GenerationModel } from "../generate-story/_generation_models.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { LLMProvider, OpenAIProvider } from "../generate-story/_provider.ts";
import type { LLMMessage } from "../generate-story/_provider.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ??
  "gpt-5-mini";
const COHERENCE_TEMPERATURE = 0.2;
const COHERENCE_MAX_COMPLETION_TOKENS = 1500;

// Service-role admin client. Owned by the feature handler; passed to the
// shared runner for billing writes (generation_usage_events INSERT) AND used
// directly here for the llm_prompts audit insert (per Blocker 6: server-side
// audit, no client INSERT policy).
const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const creditStore = new SupabaseCreditStore(adminClient);

// LLM provider for the coherence feature. Uses chat/completions + Structured
// Outputs via the 4th options argument (LLMProviderOptions.responseFormat).
// Different code path inside OpenAIProvider than generate-story (which uses
// the Responses API path with options unset).
const provider: LLMProvider = new OpenAIProvider(
  OPENAI_API_KEY,
  OPENAI_MODEL_DEFAULT,
);

// Fallback model row when the env-var-provided model isn't in
// generation_models. Used for snapshotPricing() only — the actual LLM call
// still uses OPENAI_MODEL_DEFAULT.
const FALLBACK_MODEL: GenerationModel = {
  id: "__fallback__",
  provider: "openai",
  provider_model: OPENAI_MODEL_DEFAULT,
  display_name: OPENAI_MODEL_DEFAULT,
  description:
    "Fallback pricing for coherence-check when model not in generation_models",
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

// ---------------------------------------------------------------------------
// Feature-callback error types. Thrown by onProviderSuccess to signal
// validation failures BEFORE billing. The runner rethrows them; the
// handler maps them to the same 502 error responses the pre-refactor code
// produced so iOS sees no contract change.
// ---------------------------------------------------------------------------

class EmptyContentError extends Error {
  readonly code = "openai_empty";
  constructor(message = "OpenAI returned no content") {
    super(message);
    this.name = "EmptyContentError";
  }
}

class InvalidJsonError extends Error {
  readonly code = "openai_invalid_json";
  constructor(message: string) {
    super(message);
    this.name = "InvalidJsonError";
  }
}

// ---------------------------------------------------------------------------
// llm_prompts audit helper. Extracted so the error-handling pattern can be
// tested without importing an active Deno.serve entry point. Uses the
// adminClient (server-side persistence, no client INSERT policy). Inspects
// the returned PostgREST error and logs it; never throws — audit failure
// must not mask the main response.
// ---------------------------------------------------------------------------

async function writeCoherenceAuditLog(
  // userClientForAuth is unused here (server-side persistence uses adminClient)
  // but reserved for future audit fields that need to be tied to the JWT
  // subject.
  // deno-lint-ignore no-explicit-any
  _userClientForAuth: any,
  _userID: string,
  request: { project_id?: string; current_section: { id: string } | null },
  messages: { system: string; user: string },
  providerResult: BillableProviderResult,
  llmDurationMs: number,
): Promise<void> {
  try {
    // deno-lint-ignore no-explicit-any
    const result: any = await (adminClient as any).from("llm_prompts").insert({
      call_type: "coherence-check",
      project_id: request.project_id ?? null,
      outline_section_id: request.current_section?.id ?? null,
      model: providerResult.modelName,
      prompt: JSON.stringify(messages),
      response: providerResult.content,
      prompt_tokens: providerResult.inputTokens,
      completion_tokens: providerResult.outputTokens,
      total_tokens: (providerResult.inputTokens ?? 0) +
        (providerResult.outputTokens ?? 0),
      duration_ms: llmDurationMs,
    });
    // Inspect returned error explicitly.
    if (result?.error) {
      console.error(
        `[coherence-check] llm_prompts insert failed: ` +
          JSON.stringify(result.error),
      );
    }
  } catch (err) {
    console.error(
      `[coherence-check] llm_prompts insert threw: ` +
        (err instanceof Error ? err.message : String(err)),
    );
  }
}

// ---------------------------------------------------------------------------
// Feature result type returned by onProviderSuccess. The runner exposes it
// on runnerResult.featureResult so the handler can build the response WITHOUT
// re-parsing the LLM output.
// ---------------------------------------------------------------------------

interface CoherenceFeatureResult {
  warnings: Array<{ reason: string; severity: "warn" | "high" }>;
  preFilterCount: number;
  postFilterCount: number;
  rawContent: string;
  llmDurationMs: number;
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth via user JWT.
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

  // 2. Parse + validate the request body.
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
  //    → generation_models lookup → FALLBACK_MODEL.
  const { data: modelRow } = await adminClient
    .from("generation_models")
    .select("*")
    .eq("provider_model", OPENAI_MODEL_DEFAULT)
    .eq("enabled", true)
    .maybeSingle();
  const model: GenerationModel = (modelRow as GenerationModel | null) ??
    FALLBACK_MODEL;

  // 4. Build messages + idempotency key.
  const messages = buildMessages(request);
  const idempotencyKey = await computeIdempotencyKey(userId, request);

  // 5. Call the shared billable-LLM runner. The onProviderSuccess callback
  //    does ALL feature-side validation BEFORE the runner records a
  //    status="complete" usage event or charges credits:
  //      a. Reject empty/blank provider content (record failed event).
  //      b. Parse the JSON response (record failed event on parse error).
  //      c. Filter warnings via the real production validateAndFilterWarnings.
  //      d. Return a typed feature result the handler uses directly.
  //    On any failure inside the callback: a status="failed" usage event is
  //    recorded, no "complete" event, no charge, and the runner rethrows.
  let featureResult: CoherenceFeatureResult;
  let providerResult: BillableProviderResult;
  try {
    const llmMessages: LLMMessage[] = [
      { role: "system", content: messages.system },
      { role: "user", content: messages.user },
    ];
    const startMs = Date.now();
    const runnerResult = await runBillableLLM<CoherenceFeatureResult>({
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
      onProviderSuccess: async (result) => {
        providerResult = result;
        const cbStart = Date.now();

        // (a) Reject empty/blank content.
        if (
          typeof result.content !== "string" || result.content.trim() === ""
        ) {
          await recordFailedUsageEvent(adminClient, {
            userID: userId,
            purpose: "coherence-check",
            action: "check",
            modelName: result.modelName,
            generationLengthMode: "short",
            outputBudget: COHERENCE_MAX_COMPLETION_TOKENS,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
          });
          throw new EmptyContentError();
        }

        // (b) Parse the JSON response.
        let parsed: unknown;
        try {
          parsed = JSON.parse(result.content);
        } catch (e) {
          await recordFailedUsageEvent(adminClient, {
            userID: userId,
            purpose: "coherence-check",
            action: "check",
            modelName: result.modelName,
            generationLengthMode: "short",
            outputBudget: COHERENCE_MAX_COMPLETION_TOKENS,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
          });
          throw new InvalidJsonError(
            `LLM returned invalid JSON: ${(e as Error).message}`,
          );
        }

        // (c) Filter warnings via the real production validator.
        const { warnings, preFilterCount, postFilterCount } =
          validateAndFilterWarnings(parsed);

        // (d) Return typed feature result. The handler builds the response
        //     from this without re-parsing.
        return {
          warnings,
          preFilterCount,
          postFilterCount,
          rawContent: result.content,
          llmDurationMs: Date.now() - cbStart,
        };
      },
    }, {
      // Shared runner dependencies — admin client for usage-event writes,
      // the LLM provider, and the credit store for entitlement + charge.
      adminClient,
      provider,
      creditStore,
    });
    featureResult = runnerResult.featureResult;
    providerResult = runnerResult.providerResult;
    void startMs; // tracked via featureResult.llmDurationMs
  } catch (err) {
    // Feature-callback validation failures: map to pre-refactor error codes.
    if (err instanceof EmptyContentError) {
      return errorResponse(err.code, err.message, 502);
    }
    if (err instanceof InvalidJsonError) {
      return errorResponse(err.code, err.message, 502);
    }
    // BillableLLMError: insufficient credits / usage-event insert failure /
    // credit charge failure / idempotency conflict.
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
      if (err.code === "credit_charge_failed") {
        // The audit row was already inserted. Surface as a non-2xx so the
        // client never sees warnings as a "successful" paid result.
        return errorResponse(
          "billing_charge_failed",
          "Credit charge failed after a successful coherence check; please retry.",
          500,
        );
      }
    }
    // Provider-level failure (runner already recorded the 'failed' usage
    // event). Surface to iOS as 502 — preserve pre-refactor behavior.
    const message = err instanceof Error ? err.message : String(err);
    const code = (err as { errorCode?: string })?.errorCode ?? "openai_error";
    return errorResponse(code, message, 502);
  }

  // 6. Write the llm_prompts audit row via adminClient (server-side
  //    persistence; no client INSERT policy; error inspected but never
  //    thrown). Best-effort — failure here must NOT fail the main response.
  await writeCoherenceAuditLog(
    userClient,
    userId,
    request,
    messages,
    providerResult,
    featureResult.llmDurationMs,
  );

  // 7. Build the response from runnerResult.featureResult directly — no
  //    re-parsing. Shape is byte-compatible with the iOS decoder.
  const diagnostics = {
    raw_content: featureResult.rawContent,
    finish_reason: providerResult.finishReason ?? "unknown",
    model: providerResult.modelName,
    pre_filter_count: featureResult.preFilterCount,
    post_filter_count: featureResult.postFilterCount,
    prompt_tokens: providerResult.inputTokens,
    completion_tokens: providerResult.outputTokens,
  };
  return corsResponse(
    JSON.stringify({
      warnings: featureResult.warnings,
      diagnostics,
    }),
    { status: 200 },
  );
});
