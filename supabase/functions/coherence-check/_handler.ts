// =============================================================================
// coherence-check/_handler.ts
//
// Import-safe production unit for the coherence-check handler. Extracted from
// index.ts so the integration logic (auth-resolved -> validate provider result
// -> insert usage event + audit log -> format response) can be tested without
// importing index.ts (which calls Deno.serve at module top level).
//
// Public surface used by index.ts:
//   - handleCoherenceCheck(userId, request, deps, config) -> Response
//   - EmptyContentError, InvalidJsonError (caught by index.ts error mapping)
//
// Public surface used by _handler_test.ts:
//   - handleCoherenceCheck (full integration)
//   - CoherenceRuntimeDeps, CoherenceConfig (mock injection points)
//   - CoherenceFeatureResult (typed callback return value)
//
// The shared billable-LLM runner (runBillableLLM in
// supabase/functions/_shared/billable-llm.ts) owns the LLM-call-with-billing
// pipeline. This module adds the coherence-specific validation, audit log,
// and HTTP response shaping on top.
// =============================================================================

import {
  BillableLLMError,
  type BillableProviderResult,
  recordFailedUsageEvent,
  runBillableLLM,
} from "../_shared/billable-llm.ts";
import { buildMessages, COHERENCE_RESPONSE_FORMAT } from "./_prompts.ts";
import { validateAndFilterWarnings } from "./_validation.ts";
import { computeIdempotencyKey } from "./_idempotency.ts";
import type { CoherenceCheckRequest, CoherenceWarning } from "./_validation.ts";
import { GenerationModel } from "../generate-story/_generation_models.ts";
import type { LLMMessage, LLMProvider } from "../generate-story/_provider.ts";
import { checkCredits, type CreditStore } from "../generate-story/_credits.ts";
import {
  computeMaxChargeCredits,
  estimateTokensFromText,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export class EmptyContentError extends Error {
  readonly code = "openai_empty";
  constructor(message = "OpenAI returned no content") {
    super(message);
    this.name = "EmptyContentError";
  }
}

export class InvalidJsonError extends Error {
  readonly code = "openai_invalid_json";
  constructor(message: string) {
    super(message);
    this.name = "InvalidJsonError";
  }
}

export interface CoherenceFeatureResult {
  warnings: CoherenceWarning[];
  preFilterCount: number;
  postFilterCount: number;
  rawContent: string;
  /** Total wall-clock duration from immediately before runBillableLLM to
   * the provider result landing in onProviderSuccess. Captures the
   * full LLM call (model lookup + provider call + preflight + runner
   * orchestration), not just the callback's local work. */
  llmDurationMs: number;
}

export interface CoherenceRuntimeDeps {
  /** Service-role admin client. Used for the model lookup (read),
   * generation_usage_events insert (write — but only via runBillableLLM),
   * and the llm_prompts audit insert (write — best-effort, never throws). */
  adminClient: unknown;
  provider: LLMProvider;
  creditStore: CreditStore;
}

export interface CoherenceConfig {
  openaiModelDefault: string;
  fallbackModel: GenerationModel;
  maxCompletionTokens: number;
  temperature: number;
}

/** GPT-5-family OpenAI models only support their default temperature (1). */
export function supportsCustomTemperature(model: GenerationModel): boolean {
  return !(model.provider === "openai" &&
    /^gpt-5(?:[.-]|$)/i.test(model.provider_model));
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Validate the provider result and build the typed coherence feature result.
 *
 * Throws:
 *   - EmptyContentError if the provider content is empty / blank.
 *   - InvalidJsonError if the JSON parse fails.
 *
 * On validation failure: records a `status='failed'` usage event with the
 * available provider model + token counts (best-effort) before throwing,
 * so the runner does NOT also need to record one for these paths. The
 * shared runner's own `recordFailedUsageEvent` only fires on provider
 * throw; this path uses the same helper for symmetry.
 *
 * `startMs` MUST be the wall-clock instant captured immediately before the
 * `runBillableLLM` call so `llmDurationMs` measures the full LLM call
 * (provider round-trip + runner orchestration), not just the callback's
 * local validation work.
 */
async function buildCoherenceResult(
  providerResult: BillableProviderResult,
  startMs: number,
  adminClient: unknown,
): Promise<CoherenceFeatureResult> {
  // (a) Reject empty/blank content.
  if (
    typeof providerResult.content !== "string" ||
    providerResult.content.trim() === ""
  ) {
    await recordFailedUsageEvent(adminClient, {
      userID: "", // intentionally empty — provider failure has no verified user
      purpose: "coherence-check",
      action: "check",
      modelName: providerResult.modelName,
      generationLengthMode: "short",
      outputBudget: null,
      inputTokens: providerResult.inputTokens,
      outputTokens: providerResult.outputTokens,
    });
    throw new EmptyContentError();
  }

  // (b) Parse JSON.
  let parsed: unknown;
  try {
    parsed = JSON.parse(providerResult.content);
  } catch (e) {
    await recordFailedUsageEvent(adminClient, {
      userID: "",
      purpose: "coherence-check",
      action: "check",
      modelName: providerResult.modelName,
      generationLengthMode: "short",
      outputBudget: null,
      inputTokens: providerResult.inputTokens,
      outputTokens: providerResult.outputTokens,
    });
    throw new InvalidJsonError(
      `LLM returned invalid JSON: ${(e as Error).message}`,
    );
  }

  // (c) Filter warnings via the real production validator.
  const { warnings, preFilterCount, postFilterCount } =
    validateAndFilterWarnings(parsed);

  // (d) Return typed feature result. The duration spans the entire
  // runBillableLLM call (provider call + orchestration), not just this
  // callback's local work.
  return {
    warnings,
    preFilterCount,
    postFilterCount,
    rawContent: providerResult.content,
    llmDurationMs: Date.now() - startMs,
  };
}

/**
 * Best-effort insert of the llm_prompts audit row. Uses the admin client
 * (server-side persistence, no authenticated INSERT policy). Inspects the
 * returned PostgREST error and logs it; never throws — audit failure must
 * not crash the main response or mask the original provider/feature failure.
 *
 * Preserves all fields the pre-refactor code wrote: call_type, project_id,
 * outline_section_id, model, prompt, response, prompt_tokens,
 * completion_tokens, total_tokens, duration_ms.
 */
type PostgrestWriteResult = {
  data?: unknown;
  error?: { message?: string; [key: string]: unknown } | null;
};

async function writeCoherenceAuditLog(
  adminClient: unknown,
  request: CoherenceCheckRequest,
  messages: { system: string; user: string },
  providerResult: BillableProviderResult,
  llmDurationMs: number,
): Promise<void> {
  try {
    const result = await (adminClient as unknown as {
      from: (
        t: string,
      ) => { insert: (r: unknown) => Promise<PostgrestWriteResult> };
    }).from("llm_prompts").insert({
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
    if (result?.error) {
      console.error(
        "[coherence-check] llm_prompts insert failed: " +
          JSON.stringify(result.error),
      );
    }
  } catch (err) {
    console.error(
      "[coherence-check] llm_prompts insert threw: " +
        (err instanceof Error ? err.message : String(err)),
    );
  }
}

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
// Public handler
// ---------------------------------------------------------------------------

/**
 * Handle a verified coherence-check request. Caller must have:
 *   - verified the JWT and extracted the userId
 *   - parsed + validated the request body via validateRequest()
 *
 * Flow:
 *   1. Resolve the GenerationModel (admin lookup + FALLBACK_MODEL fallback).
 *   2. Build messages + idempotency key.
 *   3. Capture startMs for the duration metric.
 *   4. Call runBillableLLM with onProviderSuccess callback. The callback
 *      validates the provider result (empty / invalid-JSON paths record a
 *      `status='failed'` event before throwing). On success it returns a
 *      typed CoherenceFeatureResult with `llmDurationMs` = now - startMs.
 *   5. Map BillableLLMError / EmptyContentError / InvalidJsonError to HTTP
 *      responses (402 / 502 / 500 as per the spec's smoke gate).
 *   6. Write the llm_prompts audit row (best-effort).
 *   7. Format the iOS response byte-shape.
 */
export async function handleCoherenceCheck(
  userId: string,
  request: CoherenceCheckRequest,
  deps: CoherenceRuntimeDeps,
  config: CoherenceConfig,
): Promise<Response> {
  // 1. Resolve the GenerationModel.
  const modelTable = (deps.adminClient as unknown as {
    from: (t: string) => {
      select: (c?: string) => {
        eq: (col: string, v: unknown) => {
          maybeSingle: () => Promise<
            { data: GenerationModel | null; error: unknown }
          >;
        };
      };
    };
  }).from("generation_models").select("*");
  const modelRow = request.selected_model_id
    ? await modelTable.eq("id", request.selected_model_id).maybeSingle()
    : await modelTable.eq("provider_model", config.openaiModelDefault)
      .maybeSingle();
  const model: GenerationModel = (modelRow?.data as GenerationModel | null) ??
    config.fallbackModel;

  // 2. Build messages. Estimate uses the exact same prompt shape as the
  // billable call, but never invokes the provider or writes usage rows.
  const messages = buildMessages(request);
  if ((request.action ?? "check") === "estimate") {
    const entitlement = await deps.creditStore.loadOrDefault(userId);
    const estimatedInputTokens = estimateTokensFromText(messages.system) +
      estimateTokensFromText(messages.user);
    const estimatedCredits = computeMaxChargeCredits(
      {
        uncachedInputTokens: estimatedInputTokens,
        cachedInputTokens: 0,
        // PR-372: preflight assumes zero cache savings.
        cacheWriteInputTokens: 0,
        outputTokens: config.maxCompletionTokens,
        toolCostUsd: 0,
      },
      snapshotPricing(model),
    );
    const creditCheck = checkCredits(entitlement, estimatedCredits);
    return corsResponse(
      JSON.stringify({
        status: "ok",
        action: "estimate",
        selectedModelId: model.id,
        modelDisplayName: model.display_name,
        estimatedInputTokens,
        estimatedOutputTokens: config.maxCompletionTokens,
        estimatedCredits,
        availableCredits: creditCheck.availableCredits,
        allowed: creditCheck.allowed,
        minimumChargeCredits: model.minimum_charge_credits,
      }),
      { status: 200 },
    );
  }

  // 3. Actual checks get a stable idempotency key. Estimate requests never
  // participate in the billable idempotency path.
  const idempotencyKey = await computeIdempotencyKey(userId, request);

  // 3. Capture the duration start IMMEDIATELY before the runner call so
  //    the resulting llmDurationMs spans the full LLM call.
  const startMs = Date.now();

  let featureResult: CoherenceFeatureResult;
  let providerResult: BillableProviderResult;
  try {
    const llmMessages: LLMMessage[] = [
      { role: "system", content: messages.system },
      { role: "user", content: messages.user },
    ];
    const providerOptions = {
      responseFormat: COHERENCE_RESPONSE_FORMAT,
      ...(supportsCustomTemperature(model)
        ? { temperature: config.temperature }
        : {}),
    };
    const runnerResult = await runBillableLLM<CoherenceFeatureResult>({
      userID: userId,
      purpose: "coherence-check",
      action: "check",
      model,
      messages: llmMessages,
      maxOutputTokens: config.maxCompletionTokens,
      providerOptions,
      usageContext: {
        projectID: request.project_id ?? null,
        generationOutputID: null,
        generationLengthMode: "short",
        outputBudget: config.maxCompletionTokens,
        idempotencyKey,
      },
      onProviderSuccess: async (result) => {
        providerResult = result;
        return await buildCoherenceResult(result, startMs, deps.adminClient);
      },
    }, {
      adminClient: deps.adminClient,
      provider: deps.provider,
      creditStore: deps.creditStore,
    });
    featureResult = runnerResult.featureResult;
    providerResult = runnerResult.providerResult;
  } catch (err) {
    // Feature-callback validation failures.
    if (err instanceof EmptyContentError) {
      return errorResponse(err.code, err.message, 502);
    }
    if (err instanceof InvalidJsonError) {
      return errorResponse(err.code, err.message, 502);
    }
    // BillableLLMError codes.
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
        return errorResponse(
          "billing_charge_failed",
          "Credit charge failed after a successful coherence check; please retry.",
          500,
        );
      }
    }
    // Provider-level failure (runner already recorded the 'failed' event).
    const message = err instanceof Error ? err.message : String(err);
    const code = (err as { errorCode?: string })?.errorCode ??
      "openai_error";
    return errorResponse(code, message, 502);
  }

  // 5. Audit log (best-effort, never throws).
  await writeCoherenceAuditLog(
    deps.adminClient,
    request,
    messages,
    providerResult,
    featureResult.llmDurationMs,
  );

  // 6. Format the iOS response byte-shape.
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
}

// Re-export for index.ts convenience (not strictly needed — index.ts can
// import from here directly).
export { errorResponse as handlerErrorResponse };
export { corsResponse as handlerCorsResponse };
