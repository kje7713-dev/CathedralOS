// =============================================================================
// _shared/billable-llm.ts
//
// Shared server-side billable LLM runner. Owns the entire "LLM call with
// billing" pipeline that was previously duplicated between generate-story and
// coherence-check:
//
//   1. Pre-flight credit check (rejects before provider call).
//   2. Provider call.
//   3. Feature-specific persistence callback (onProviderSuccess).
//   4. Compute actual charge from real tokens + pricing snapshot.
//   5. INSERT generation_usage_events with purpose/action/idempotency_key.
//   6. On confirmed uniqueness conflict (idempotency hit): skip the charge.
//   7. Otherwise: charge credits via the existing SupabaseCreditStore.
//
// Feature handlers import this and supply:
//   - Resolved GenerationModel (each feature preserves its own model selection).
//   - Constructed messages + maxOutputTokens + providerOptions.
//   - onProviderSuccess callback for feature-specific persistence
//     (e.g., generate-story inserts generation_outputs; coherence-check is
//     a no-op that just returns the provider result).
//
// This module is import-safe: no Deno.serve, no env reads at module top
// level. It can be unit-tested by injecting mock LLMProvider + CreditStore
// + admin client.
//
// Out of scope (deliberately NOT here): feature prompt construction, feature
// response parsing, generation_outputs insert logic, embed-section launch,
// llm_prompts audit writes, iOS response formatting. Those stay in the
// feature handlers — this module is feature-agnostic.
// =============================================================================

import {
  computeActualChargeCredits,
  computeMaxChargeCredits,
  snapshotPricing,
  type GenerationModel,
  type GenerationUsage,
} from "../generate-story/_generation_models.ts";
import {
  availableCredits,
  type CreditStore,
} from "../generate-story/_credits.ts";
import type {
  LLMMessage,
  LLMProvider,
  LLMResponse,
} from "../generate-story/_provider.ts";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/** Normalized provider result returned to the feature callback. */
export interface BillableProviderResult {
  content: string;
  modelName: string;
  inputTokens: number | null;
  outputTokens: number | null;
  cachedInputTokens: number | null;
  finishReason: string | undefined;
  toolCostUsd: number;
}

/** Usage-context fields persisted alongside the usage event. */
export interface BillableUsageContext {
  projectID?: string | null;
  generationOutputID?: string | null;
  generationLengthMode?: string | null;
  outputBudget?: number | null;
  /** When set, the partial unique index on (user_id, idempotency_key)
   * WHERE purpose='coherence-check' deduplicates repeated identical calls. */
  idempotencyKey?: string | null;
}

/** Optional provider-specific knobs (Structured Outputs, temperature, etc.). */
export interface BillableProviderOptions {
  /** OpenAI Structured Outputs `response_format` payload (json_schema). */
  responseFormat?: unknown;
  temperature?: number;
}

export interface BillableLLMRequest<T> {
  userID: string;
  purpose: "generate" | "coherence-check";
  action: string;
  /** Resolved GenerationModel. The feature handler preserves its own model
   * selection policy (generate-story uses selectedModelId from the request,
   * coherence-check uses OPENAI_MODEL_DEFAULT env with a fallback row). */
  model: GenerationModel;
  messages: LLMMessage[];
  maxOutputTokens: number;
  providerOptions?: BillableProviderOptions;
  usageContext: BillableUsageContext;
  /** Feature-specific persistence callback. Throw to abort the rest of the
   * pipeline (the runner will rethrow without recording a 'failed' usage
   * event — that's the caller's call). */
  onProviderSuccess: (result: BillableProviderResult) => Promise<T>;
  /** Override the preflight token estimate. Default: 5000 input + maxOutput
   * output. Used by callers that know the prompt is unusually large. */
  preflightUsageOverride?: GenerationUsage;
}

export interface BillableLLMResult<T> {
  featureResult: T;
  providerResult: BillableProviderResult;
  /** Credits charged (or 0 if a duplicate was detected). */
  actualCharge: number;
  /** True iff creditStore.charge() succeeded for this call. */
  charged: boolean;
  /** True iff a usage_event row was INSERTed (false on confirmed idempotency
   * conflict or non-uniqueness DB error). */
  usageEventInserted: boolean;
}

export interface BillableLLMDependencies {
  /** Supabase client with service-role key (bypasses RLS). The shared runner
   * uses this ONLY for generation_usage_events writes. The feature callback
   * may use it for its own feature-specific writes. */
  adminClient: unknown;
  provider: LLMProvider;
  creditStore: CreditStore;
}

export type BillableLLMErrorCode =
  | "insufficient_credits"
  | "usage_event_insert_failed"
  | "idempotency_unique_violation";

export class BillableLLMError extends Error {
  readonly code: BillableLLMErrorCode;
  readonly details?: unknown;
  constructor(
    code: BillableLLMErrorCode,
    message: string,
    details?: unknown,
  ) {
    super(message);
    this.name = "BillableLLMError";
    this.code = code;
    this.details = details;
  }
}

export interface FailedUsageEventInput {
  userID: string;
  purpose: "generate" | "coherence-check";
  action: string;
  modelName: string;
  generationLengthMode?: string | null;
  outputBudget?: number | null;
  inputTokens?: number | null;
  outputTokens?: number | null;
}

// ---------------------------------------------------------------------------
// runBillableLLM
// ---------------------------------------------------------------------------

/**
 * Conservative default preflight estimate when the caller does not supply
 * one. Assumes 5000 uncached input tokens + maxOutputTokens output + 0 cached
 * + 0 tool cost. Overestimating is fine (rejects early); underestimating is
 * not (would let through requests that later hit the actual-charge floor).
 */
function defaultPreflightUsage(maxOutputTokens: number): GenerationUsage {
  return {
    uncachedInputTokens: 5000,
    cachedInputTokens: 0,
    outputTokens: maxOutputTokens,
    toolCostUsd: 0,
  };
}

/**
 * Detect a Postgres unique_violation from a Supabase / PostgREST error shape.
 * We only treat `code === "23505"` as a confirmed idempotency conflict; any
 * other error code is logged and rethrown so the caller can follow the
 * existing diagnostic conventions.
 */
function isUniqueViolation(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  // deno-lint-ignore no-explicit-any
  const e = error as any;
  return e.code === "23505";
}

export async function runBillableLLM<T>(
  req: BillableLLMRequest<T>,
  deps: BillableLLMDependencies,
): Promise<BillableLLMResult<T>> {
  const pricing = snapshotPricing(req.model);

  // 1. Pre-flight credit check.
  const preflightUsage = req.preflightUsageOverride ??
    defaultPreflightUsage(req.maxOutputTokens);
  const estimatedCharge = computeMaxChargeCredits(preflightUsage, pricing);
  const entitlement = await deps.creditStore.loadOrDefault(req.userID);
  if (availableCredits(entitlement) < estimatedCharge) {
    throw new BillableLLMError(
      "insufficient_credits",
      `Billable LLM call requires ~${estimatedCharge.toFixed(2)} credits; ` +
        `you have ${availableCredits(entitlement).toFixed(2)}.`,
      {
        requiredCredits: estimatedCharge,
        availableCredits: availableCredits(entitlement),
        purpose: req.purpose,
      },
    );
  }

  // 2. Provider call. On any provider failure we record a 'failed' usage
  //    event (best-effort, idempotency_key=null, no credit debit) and
  //    rethrow the original provider error.
  let llmResponse: LLMResponse;
  try {
    llmResponse = await deps.provider.complete(
      req.messages,
      req.maxOutputTokens,
      req.model.provider_model,
    );
  } catch (err) {
    await recordFailedUsageEvent(deps.adminClient, {
      userID: req.userID,
      purpose: req.purpose,
      action: req.action,
      modelName: req.model.provider_model,
      generationLengthMode: req.usageContext.generationLengthMode ?? null,
      outputBudget: req.usageContext.outputBudget ?? req.maxOutputTokens,
    });
    throw err;
  }

  // 3. Feature-specific persistence callback. We propagate throws verbatim —
  //    no 'failed' usage event here. Generate-story's persistence-failure
  //    path historically does NOT record a 'failed' usage event (only a
  //    rate_limiter entry); preserving that means we don't auto-record on
  //    callback failure either. The caller may still call
  //    recordFailedUsageEvent() explicitly if it wants a 'failed' row.
  const providerResult: BillableProviderResult = {
    content: llmResponse.content,
    modelName: llmResponse.modelName,
    inputTokens: llmResponse.inputTokens ?? null,
    outputTokens: llmResponse.outputTokens ?? null,
    cachedInputTokens: llmResponse.cachedInputTokens ?? null,
    finishReason: llmResponse.finishReason,
    toolCostUsd: llmResponse.toolCostUsd ?? 0,
  };
  const featureResult = await req.onProviderSuccess(providerResult);

  // 4. Compute actual charge from real tokens. Cached-token columns don't
  //    exist on generation_usage_events yet (PR-372 will add them); for now
  //    we pass through the cached value from LLMResponse so the math is
  //    already correct when the schema lands.
  const actualUsage: GenerationUsage = {
    uncachedInputTokens: providerResult.inputTokens ?? 0,
    cachedInputTokens: providerResult.cachedInputTokens ?? 0,
    outputTokens: providerResult.outputTokens ?? 0,
    toolCostUsd: providerResult.toolCostUsd,
  };
  const actualCharge = computeActualChargeCredits(actualUsage, pricing);
  const creditRevenueUsd = actualCharge * 0.05;

  // 5. INSERT generation_usage_events. Partial unique index on
  //    (user_id, idempotency_key) WHERE purpose='coherence-check'
  //    deduplicates identical repeat calls within the same minute.
  // deno-lint-ignore no-explicit-any
  const usageEventRow: Record<string, unknown> = {
    user_id: req.userID,
    generation_output_id: req.usageContext.generationOutputID ?? null,
    action: req.action,
    purpose: req.purpose,
    model_name: providerResult.modelName,
    input_tokens: providerResult.inputTokens,
    output_tokens: providerResult.outputTokens,
    generation_length_mode: req.usageContext.generationLengthMode ?? "short",
    output_budget: req.usageContext.outputBudget ?? req.maxOutputTokens,
    status: "complete",
    credit_revenue_usd: creditRevenueUsd,
    idempotency_key: req.usageContext.idempotencyKey ?? null,
  };

  // deno-lint-ignore no-explicit-any
  const insertResult: any = await (deps.adminClient as any)
    .from("generation_usage_events")
    .insert(usageEventRow)
    .select("id")
    .maybeSingle();

  // 6. Handle uniqueness conflict (idempotency hit) — no charge.
  if (insertResult?.error && isUniqueViolation(insertResult.error)) {
    return {
      featureResult,
      providerResult,
      actualCharge,
      charged: false,
      usageEventInserted: false,
    };
  }

  // 7. Any other insert error is NOT a duplicate — log and throw so the
  //    caller can follow the existing diagnostic conventions.
  if (insertResult?.error) {
    console.error(
      `[billable-llm] generation_usage_events insert failed: ` +
        JSON.stringify(insertResult.error),
    );
    throw new BillableLLMError(
      "usage_event_insert_failed",
      `Failed to insert generation_usage_events for purpose=${req.purpose}, ` +
        `action=${req.action}: ` +
        (insertResult.error.message ?? "unknown error"),
      insertResult.error,
    );
  }

  // 8. Charge credits via the same path generate-story uses. If this throws,
  //    log and surface to the caller — the usage event is already inserted
  //    so we don't roll back, but the caller can decide what to do.
  try {
    await deps.creditStore.charge(
      req.userID,
      actualCharge,
      entitlement,
      req.usageContext.generationOutputID ?? null,
    );
  } catch (err) {
    console.error(
      `[billable-llm] credit charge failed (usage event already inserted, ` +
        `no rollback): ${(err as Error)?.message ?? String(err)}`,
    );
    return {
      featureResult,
      providerResult,
      actualCharge,
      charged: false,
      usageEventInserted: true,
    };
  }

  return {
    featureResult,
    providerResult,
    actualCharge,
    charged: true,
    usageEventInserted: true,
  };
}

// ---------------------------------------------------------------------------
// recordFailedUsageEvent
// ---------------------------------------------------------------------------

/**
 * Best-effort insert of a `status='failed'` usage event. Used by the runner
 * when the provider call fails, and exposed for callers that want to record
 * a feature-level failure (e.g., a callback that wants to log a persistence
 * failure to the billing ledger for audit).
 *
 * Failures here are logged but never thrown — billing audit must not crash
 * the main response.
 */
export async function recordFailedUsageEvent(
  adminClient: unknown,
  input: FailedUsageEventInput,
): Promise<void> {
  try {
    // deno-lint-ignore no-explicit-any
    await (adminClient as any).from("generation_usage_events").insert({
      user_id: input.userID,
      generation_output_id: null,
      action: input.action,
      purpose: input.purpose,
      model_name: input.modelName,
      input_tokens: input.inputTokens ?? null,
      output_tokens: input.outputTokens ?? null,
      generation_length_mode: input.generationLengthMode ?? "short",
      output_budget: input.outputBudget ?? null,
      status: "failed",
      idempotency_key: null,
    });
  } catch (err) {
    console.error(
      `[billable-llm] failed-usage insert failed: ` +
        (err instanceof Error ? err.message : String(err)),
    );
  }
}
