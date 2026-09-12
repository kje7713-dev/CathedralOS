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
  responseFormatTarget?: "chat" | "responses";
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

export interface BillableLLMDependencies {
  adminClient: unknown;
  provider: LLMProvider;
  creditStore: CreditStore;
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
  // PR-372: provider COGS (cents) + margin (cents) for telemetry.
  const providerCogs = computeProviderCogsCents(actualUsage, pricing);
  const marginInfo = computeMarginCents(
    actualCharge,
    pricing,
    providerCogs.providerCogsCents,
  );

  // 5. PR5 atomic billable settlement. The previous INSERT-then-charge
  //    sequence left three failure windows open:
  //      - usage_event INSERT succeeded, credit charge failed -> free-output
  //        audit escape hatch.
  //      - entitlement UPDATE succeeded, ledger INSERT failed -> silent
  //        COGS leakage.
  //      - ledger UPDATE/INSERT race on concurrent calls.
  //    settle_billable_usage (migration 20260912110000) locks the
  //    entitlement, dedupes by idempotency_key, and writes all three rows
  //    in one transaction. The "duplicate" branch preserves the existing
  //    idempotent-replay contract (charged=false, no double-charge).
  const rpcPayload = {
    p_user_id: req.userID,
    p_action: req.action,
    p_purpose: req.purpose,
    p_model_name: providerResult.modelName,
    p_idempotency_key: req.usageContext.idempotencyKey ?? null,
    p_charge_credits: actualCharge,
    p_input_tokens: providerResult.inputTokens,
    p_output_tokens: providerResult.outputTokens,
    p_generation_length_mode: req.usageContext.generationLengthMode ?? "short",
    p_output_budget: req.usageContext.outputBudget ?? req.maxOutputTokens,
    p_generation_output_id: req.usageContext.generationOutputID ?? null,
    p_uncached_input_tokens: ordinaryUncachedInputTokens,
    p_cached_input_tokens: cachedInputTokens,
    p_cache_write_input_tokens: cacheWriteInputTokens,
    p_provider_cogs_cents: providerCogs.providerCogsCents,
    p_customer_revenue_cents: marginInfo.customerRevenueCents,
    p_margin_cents: marginInfo.marginCents,
    p_stable_prefix_hash: req.stablePrefixHash ?? null,
    p_credit_value_usd: pricing.creditValueUsd,
  };
  type RpcRow = {
    settlement_status: "settled" | "duplicate";
    usage_event_id: string;
    ledger_id: string | null;
    remaining_credits: number;
  };
  const rpcResult = await (deps.adminClient as unknown as {
    rpc: (
      name: string,
      params: Record<string, unknown>,
    ) => Promise<{ data: RpcRow[] | null; error: { message?: string } | null }>;
  }).rpc("settle_billable_usage", rpcPayload);

  if (rpcResult?.error) {
    const msg = rpcResult.error.message ?? "";
    // Race-loss insufficient credits (pre-flight passed but atomic settle
    // observes the post-charge entitlement). Map to insufficient_credits so
    // callers get a non-2xx and no audit row is ever written.
    if (msg.includes("insufficient credits")) {
      throw new BillableLLMError(
        "insufficient_credits",
        `Billable LLM call requires ${actualCharge.toFixed(2)} credits; ` +
          `entitlement drained concurrently.`,
        { requiredCredits: actualCharge, purpose: req.purpose },
      );
    }
    if (msg.includes("idempotency_key parameters do not match")) {
      throw new BillableLLMError(
        "usage_event_insert_failed",
        `idempotency_key reused with mismatched parameters: ${msg}`,
        rpcResult.error,
      );
    }
    console.error(
      `[billable-llm] settle_billable_usage RPC failed: ` +
        JSON.stringify(rpcResult.error),
    );
    throw new BillableLLMError(
      "credit_charge_failed",
      `settle_billable_usage failed for purpose=${req.purpose}, ` +
        `action=${req.action}: ${msg}`,
      rpcResult.error,
    );
  }

  const row = rpcResult?.data?.[0];
  if (!row) {
    throw new BillableLLMError(
      "usage_event_insert_failed",
      `settle_billable_usage returned no row for purpose=${req.purpose}, ` +
        `action=${req.action}.`,
      { rpcResult },
    );
  }

  const remainingCredits = row.remaining_credits ?? 0;

  if (row.settlement_status === "duplicate") {
    return {
      featureResult,
      providerResult,
      actualCharge,
      // Idempotent replay: no new charge, no new usage row.
      charged: false,
      usageEventInserted: false,
      remainingCredits,
      providerCogsCents: providerCogs.providerCogsCents,
      customerRevenueCents: marginInfo.customerRevenueCents,
      marginCents: marginInfo.marginCents,
    };
  }

  return {
    featureResult,
    providerResult,
    actualCharge,
    charged: true,
    usageEventInserted: true,
    remainingCredits,
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
