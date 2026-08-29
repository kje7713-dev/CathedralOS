// =============================================================================
// _shared/billable-llm.ts
//
// Shared server-side billable LLM runner. Owns the "LLM call with billing"
// pipeline (preflight credit check → provider call → feature-specific
// persistence callback → usage event insert with idempotency → credit
// charge). Phase A: used by coherence-check. Generate-story migration is
// deferred to PR B — _shared/ temporarily imports model, provider, and
// credit primitives from generate-story's module tree.
//
// Out of scope (deliberately NOT here): feature prompt construction, feature
// response parsing, generation_outputs insert logic, embed-section launch,
// llm_prompts audit writes, iOS response formatting. Those stay in the
// feature handlers — this module is feature-agnostic.
//
// Import-safe: no Deno.serve, no env reads at module top level, no
// server-registration side effects. Safe to import into unit tests.
// =============================================================================

import {
  computeActualChargeCredits,
  computeMarginCents,
  computeMaxChargeCredits,
  computeProviderCogsCents,
  type GenerationModel,
  type GenerationUsage,
  snapshotPricing,
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

export interface BillableProviderResult {
  content: string;
  modelName: string;
  inputTokens: number | null;
  outputTokens: number | null;
  cachedInputTokens: number | null;
  /** PR-372: cache-write input tokens (separately priced on GPT-5.6+). */
  cacheWriteInputTokens: number | null;
  finishReason: string | undefined;
  toolCostUsd: number;
}

export interface BillableUsageContext {
  projectID?: string | null;
  generationOutputID?: string | null;
  generationLengthMode?: string | null;
  outputBudget?: number | null;
  idempotencyKey?: string | null;
}

/** Provider-specific knobs. Coherence-check sets `responseFormat` to enable
 * Structured Outputs via the chat/completions endpoint. Generate-story
 * leaves it unset and uses the Responses API path. `temperature` is
 * forwarded to chat/completions when set; ignored by the Responses API.
 *
 * PR-372 additions: `cacheMode` + `promptCacheKey` enable OpenAI prompt
 * caching on the Responses API path. `cacheMode === "explicit"` adds
 * `prompt_cache_options: { mode: "explicit" }` and the `prompt_cache_key`
 * to the request. Caller (index.ts) is responsible for adding
 * `prompt_cache_breakpoint: { mode: "explicit" }` to the LAST stable
 * content block; this interface just threads the metadata through. */
export interface BillableProviderOptions {
  responseFormat?: unknown;
  temperature?: number;
  /** PR-372: cache capability for this request. */
  cacheMode?: "none" | "implicit" | "explicit";
  /** PR-372: stable cache key for grouping related requests. */
  promptCacheKey?: string;
}

export interface BillableLLMRequest<T> {
  userID: string;
  purpose: "generate" | "coherence-check" | "outline-suggestion";
  action: string;
  model: GenerationModel;
  messages: LLMMessage[];
  maxOutputTokens: number;
  providerOptions?: BillableProviderOptions;
  usageContext: BillableUsageContext;
  /** PR-372: SHA-256 hex of the serialized stable prefix sent to the
   *  provider. For diagnostics only — never reverse to prompt content.
   *  Persisted to generation_usage_events.stable_prefix_hash. Coherence-check
   *  doesn't have a stable prefix and leaves this undefined. */
  stablePrefixHash?: string;
  /** Feature-specific persistence callback. May throw on validation /
   * persistence failure; the runner rethrows without recording a
   * "complete" usage event (and without charging). The callback may itself
   * call recordFailedUsageEvent() to record a status="failed" row before
   * throwing — that is the supported pattern for feature-validation
   * failures (e.g., empty provider content, invalid JSON). */
  onProviderSuccess: (result: BillableProviderResult) => Promise<T>;
  preflightUsageOverride?: GenerationUsage;
  /** Generate-story historically omits failed usage rows for provider timeout
   * and provider-account quota failures. Feature callers can disable the
   * runner's best-effort failure audit to preserve that contract. */
  recordProviderFailureUsage?: boolean;
}

export interface BillableLLMResult<T> {
  featureResult: T;
  providerResult: BillableProviderResult;
  /** Credits charged (0 if charge failed, idempotency conflict, or
   * feature-validation failure). */
  actualCharge: number;
  /** True iff creditStore.charge() succeeded for this call. */
  charged: boolean;
  /** True iff a usage_event row was INSERTed (false on confirmed
   * idempotency conflict or non-uniqueness DB error). */
  usageEventInserted: boolean;
  /** Remaining monthly + purchased credits after a successful charge. */
  remainingCredits: number;
  /** PR-372: provider cost-of-goods (cents). Uses the corrected split
   *  formula (ordinary * normalRate + cached * cachedRate + cacheWrite *
   *  cacheWriteRate + output * outputRate + toolCost) with defensive
   *  anomaly handling. Always present after a successful run. */
  providerCogsCents: number;
  /** PR-372: customer revenue in cents (charge × creditValueUsd × 100).
   *  Invariant on cache outcome — same total input at normal rate. */
  customerRevenueCents: number;
  /** PR-372: margin in cents (customerRevenueCents - providerCogsCents).
   *  Improves on cache hits; may be negative on cache writes without reuse. */
  marginCents: number;
}

export interface BillableUsageEventWriteResult {
  data: { id: string } | null;
  error: { message?: string; [key: string]: unknown } | null;
}

export interface BillableLLMDependencies {
  adminClient: unknown;
  provider: LLMProvider;
  creditStore: CreditStore;
  /** Optional feature-specific writer. Generate-story supplies its existing
   * persistence store here so margin telemetry and test seams remain intact. */
  usageEventWriter?: (
    row: Record<string, unknown>,
  ) => Promise<BillableUsageEventWriteResult>;
}

export type BillableLLMErrorCode =
  | "insufficient_credits"
  | "usage_event_insert_failed"
  | "credit_charge_failed"
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
  purpose: "generate" | "coherence-check" | "outline-suggestion";
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

function defaultPreflightUsage(maxOutputTokens: number): GenerationUsage {
  return {
    uncachedInputTokens: 5000,
    cachedInputTokens: 0,
    // PR-372: preflight assumes zero cache savings (cache hit is not
    // guaranteed — only count after the provider responds).
    cacheWriteInputTokens: 0,
    outputTokens: maxOutputTokens,
    toolCostUsd: 0,
  };
}

/** Detect a Postgres unique_violation from a Supabase / PostgREST error
 * shape. We only treat `code === "23505"` as a confirmed idempotency
 * conflict; any other error code is treated as a generic failure. */
function isUniqueViolation(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const e = error as Record<string, unknown>;
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

  // 2. Provider call. MUST forward req.providerOptions — the OpenAIProvider
  //    uses options.responseFormat to route between chat/completions +
  //    Structured Outputs (coherence-check) and the Responses API
  //    (generate-story). Without the forward, the provider falls onto the
  //    Responses API and loses responseFormat / temperature / the existing
  //    Chat Completions response contract.
  let llmResponse: LLMResponse;
  try {
    llmResponse = await deps.provider.complete(
      req.messages,
      req.maxOutputTokens,
      req.model.provider_model,
      req.providerOptions,
    );
  } catch (err) {
    if (req.recordProviderFailureUsage !== false) {
      await recordFailedUsageEvent(deps.adminClient, {
        userID: req.userID,
        purpose: req.purpose,
        action: req.action,
        modelName: req.model.provider_model,
        generationLengthMode: req.usageContext.generationLengthMode ?? null,
        outputBudget: req.usageContext.outputBudget ?? req.maxOutputTokens,
      });
    }
    throw err;
  }

  // 3. Feature-specific persistence callback. The callback may throw on
  //    validation / persistence failure. The runner does NOT auto-record a
  //    "failed" event here — generate-story's persistence-failure path
  //    historically does NOT record one (only a rate_limiter entry), so we
  //    preserve that behavior. The callback MAY itself call
  //    recordFailedUsageEvent() to log a status="failed" row before
  //    throwing — that is the supported pattern for feature-validation
  //    failures (e.g., empty content, invalid JSON).
  const providerResult: BillableProviderResult = {
    content: llmResponse.content,
    modelName: llmResponse.modelName,
    inputTokens: llmResponse.inputTokens ?? null,
    outputTokens: llmResponse.outputTokens ?? null,
    cachedInputTokens: llmResponse.cachedInputTokens ?? null,
    // PR-372: extract cache-write tokens from the OpenAI response.
    cacheWriteInputTokens: llmResponse.cacheWriteInputTokens ?? null,
    finishReason: llmResponse.finishReason,
    toolCostUsd: llmResponse.toolCostUsd ?? 0,
  };
  const featureResult = await req.onProviderSuccess(providerResult);

  // 4. PR-372 corrected token accounting + provider COGS math.
  //
  // The provider returns:
  //   - inputTokens             = TOTAL input (includes cached + cacheWrite)
  //   - cachedInputTokens       = subset of total that hit the cache read
  //   - cacheWriteInputTokens   = subset of total written to cache this call
  //
  // We compute:
  //   ordinaryUncached = max(0, totalInput - cached - cacheWrite)
  //
  // and pass that into computeActualChargeCredits (which charges ALL input
  // at normal rate — no customer discount on cache hits) and into
  // computeProviderCogsCents (which uses the corrected split formula for
  // the provider COGS side).
  //
  // Customer charge and provider COGS are computed independently so cache
  // savings stay Cathedral's margin, never a customer-side concession.
  const totalInputTokens = Math.max(0, providerResult.inputTokens ?? 0);
  const cachedInputTokens = Math.max(
    0,
    Math.min(totalInputTokens, providerResult.cachedInputTokens ?? 0),
  );
  const cacheWriteInputTokens = Math.max(
    0,
    Math.min(totalInputTokens, providerResult.cacheWriteInputTokens ?? 0),
  );
  const ordinaryUncachedInputTokens = Math.max(
    0,
    totalInputTokens - cachedInputTokens - cacheWriteInputTokens,
  );
  const actualUsage: GenerationUsage = {
    uncachedInputTokens: ordinaryUncachedInputTokens,
    cachedInputTokens,
    cacheWriteInputTokens,
    outputTokens: Math.max(0, providerResult.outputTokens ?? 0),
    toolCostUsd: providerResult.toolCostUsd,
  };
  const actualCharge = computeActualChargeCredits(actualUsage, pricing);
  // Keep credit_revenue_usd (legacy column) in sync with customer charge.
  const creditRevenueUsd = actualCharge * pricing.creditValueUsd;
  // PR-372: provider COGS (cents) + margin (cents) for telemetry.
  const providerCogs = computeProviderCogsCents(actualUsage, pricing);
  const marginInfo = computeMarginCents(
    actualCharge,
    pricing,
    providerCogs.providerCogsCents,
  );

  // 5. INSERT generation_usage_events. Partial unique index on
  //    (user_id, idempotency_key) WHERE purpose='coherence-check'
  //    deduplicates identical repeat calls within the same minute.
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
    // PR-372 cache economics telemetry (migration 20260824220000).
    uncached_input_tokens: ordinaryUncachedInputTokens,
    cached_input_tokens: cachedInputTokens,
    cache_write_input_tokens: cacheWriteInputTokens,
    provider_cogs_cents: providerCogs.providerCogsCents,
    customer_revenue_cents: marginInfo.customerRevenueCents,
    margin_cents: marginInfo.marginCents,
    stable_prefix_hash: req.stablePrefixHash ?? null,
  };

  const insertResult = deps.usageEventWriter
    ? await deps.usageEventWriter(usageEventRow)
    : (await (deps.adminClient as unknown as {
      from: (t: string) => {
        insert: (r: unknown) => {
          select: (c?: string) => {
            maybeSingle: () => Promise<BillableUsageEventWriteResult>;
          };
        };
      };
    })
      .from("generation_usage_events")
      .insert(usageEventRow)
      .select("id")
      .maybeSingle());

  // 6. Confirmed uniqueness conflict (idempotency hit) — no charge.
  if (insertResult?.error && isUniqueViolation(insertResult.error)) {
    return {
      featureResult,
      providerResult,
      actualCharge,
      charged: false,
      usageEventInserted: false,
      remainingCredits: entitlement.monthly_credit_allowance +
        entitlement.purchased_credit_balance,
      // PR-372: COGS/margin still reported even when charge skipped
      // (idempotency replay is a successful LLM call, not a free one).
      providerCogsCents: providerCogs.providerCogsCents,
      customerRevenueCents: marginInfo.customerRevenueCents,
      marginCents: marginInfo.marginCents,
    };
  }

  // 7. Any insert error that is NOT a unique-violation — log + throw so
  //    the caller can follow the existing diagnostic conventions. We do NOT
  //    silently treat this as a duplicate (the prior "return charged:false"
  //    path was unsafe).
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

  // 8. Insert returned neither an error nor data — Supabase/PostgREST
  //    usually returns the inserted row via .select("id").maybeSingle().
  //    Missing data is a contract violation: we must NOT proceed to
  //    charging as if persistence succeeded.
  if (!insertResult?.data) {
    console.error(
      `[billable-llm] generation_usage_events insert returned no data row ` +
        `(purpose=${req.purpose}, action=${req.action})`,
    );
    throw new BillableLLMError(
      "usage_event_insert_failed",
      `generation_usage_events insert returned no data row for purpose=` +
        `${req.purpose}, action=${req.action}.`,
      { insertResult },
    );
  }

  // 9. Charge credits via the same path generate-story uses. If this
  //    throws, surface as credit_charge_failed so the caller maps it to a
  //    non-2xx response. We DO NOT silently swallow the error (the prior
  //    "return charged:false" path created a free-output escape hatch).
  //    The usage_event row is already inserted; the spec's follow-up
  //    (atomic billing) covers reconciliation for that audit row.
  let remainingCredits = 0;
  try {
    const updatedEntitlement = await deps.creditStore.charge(
      req.userID,
      actualCharge,
      entitlement,
      req.usageContext.generationOutputID ?? null,
    );
    remainingCredits = updatedEntitlement.monthly_credit_allowance +
      updatedEntitlement.purchased_credit_balance;
  } catch (err) {
    console.error(
      `[billable-llm] credit charge failed (usage event already inserted at ` +
        `row ${insertResult.data?.id ?? "?"}, no rollback): ` +
        (err instanceof Error ? err.message : String(err)),
    );
    throw new BillableLLMError(
      "credit_charge_failed",
      `creditStore.charge failed for purpose=${req.purpose}, ` +
        `action=${req.action}: ` +
        (err instanceof Error ? err.message : String(err)),
      err,
    );
  }

  return {
    featureResult,
    providerResult,
    actualCharge,
    charged: true,
    usageEventInserted: true,
    remainingCredits,
    // PR-372 cache economics telemetry.
    providerCogsCents: providerCogs.providerCogsCents,
    customerRevenueCents: marginInfo.customerRevenueCents,
    marginCents: marginInfo.marginCents,
  };
}

// ---------------------------------------------------------------------------
// recordFailedUsageEvent
// ---------------------------------------------------------------------------

/**
 * Best-effort insert of a status="failed" usage event. Used by the runner
 * on provider failure and by feature callbacks that want to log a
 * feature-level failure to the billing ledger.
 *
 * Inspects the returned `error` from PostgREST and logs it. Failures here
 * are logged but never thrown — billing audit must not crash the main
 * response or mask the original provider/feature failure.
 */
type PostgrestWriteResult = {
  data?: unknown;
  error?: { message?: string; [key: string]: unknown } | null;
};

export async function recordFailedUsageEvent(
  adminClient: unknown,
  input: FailedUsageEventInput,
): Promise<void> {
  if (!adminClient) return;
  try {
    const result = await (adminClient as unknown as {
      from: (
        t: string,
      ) => { insert: (r: unknown) => Promise<PostgrestWriteResult> };
    })
      .from("generation_usage_events")
      .insert({
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
    // Inspect the returned error explicitly. Supabase returns
    // { data, error }; ordinary DB failures do not need to throw.
    if (result?.error) {
      console.error(
        `[billable-llm] failed-usage insert failed: ` +
          JSON.stringify(result.error),
      );
    }
  } catch (err) {
    console.error(
      `[billable-llm] failed-usage insert threw: ` +
        (err instanceof Error ? err.message : String(err)),
    );
  }
}
