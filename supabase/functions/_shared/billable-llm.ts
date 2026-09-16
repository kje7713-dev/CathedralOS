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
  featureRunID?: string | null;
  promptBytes?: number | null;
  stablePrefixBytes?: number | null;
  volatileBytes?: number | null;
  providerAttemptKey?: string | null;
  logicalStageKey?: string | null;
  attemptOrdinal?: number | null;
  promptCacheKeyHash?: string | null;
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
  /** Credits charged. For outline-suggestion, provider-complete feature
   * validation failures are billed because provider usage incurred COGS;
   * generate/coherence retain their established failure semantics. */
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
  | "idempotency_unique_violation"
  | "provider_attempt_allocation_failed";

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

// Provider-attempt telemetry is best effort: it must never mask the
// provider or settlement result, but it records usage before feature parsing.
async function updateProviderAttempt(adminClient: unknown, attemptID: string | null, patch: Record<string, unknown>): Promise<void> {
  if (!adminClient || !attemptID) return;
  try {
    const result = await (adminClient as any).from("generation_provider_attempts").update(patch).eq("id", attemptID);
    if (result?.error) console.error(`[billable-llm] provider-attempt update failed: ${JSON.stringify(result.error)}`);
  } catch (error) { console.error(`[billable-llm] provider-attempt update threw: ${error instanceof Error ? error.message : String(error)}`); }
}

async function reconcileOutlineRun(adminClient: unknown, runID: string | null | undefined): Promise<void> {
  if (!adminClient || !runID) return;
  try {
    const result = await (adminClient as any).rpc("reconcile_outline_provider_attempts", { p_run_id: runID });
    if (result?.error) console.error(`[billable-llm] outline reconciliation failed: ${JSON.stringify(result.error)}`);
  } catch (error) { console.error(`[billable-llm] outline reconciliation threw: ${error instanceof Error ? error.message : String(error)}`); }
}

async function beginOutlineProviderAttempt(
  adminClient: unknown,
  req: BillableLLMRequest<unknown>,
): Promise<{ id: string; key: string; ordinal: number }> {
  if (!adminClient) throw new BillableLLMError("provider_attempt_allocation_failed", "outline provider attempt allocation requires an admin database client");
  const logicalStageKey = req.usageContext.logicalStageKey ?? req.usageContext.idempotencyKey;
  if (!logicalStageKey) throw new BillableLLMError("provider_attempt_allocation_failed", "outline provider attempt requires a logical stage key");
  const result = await (adminClient as any).rpc("begin_outline_provider_attempt", {
    p_user_id: req.userID,
    p_feature_run_id: req.usageContext.featureRunID ?? null,
    p_purpose: req.purpose,
    p_action: req.action,
    p_logical_stage_key: logicalStageKey,
    p_model_name: req.model.provider_model,
    p_billing_idempotency_key: req.usageContext.idempotencyKey ?? null,
    p_stable_prefix_hash: req.stablePrefixHash ?? null,
    p_prompt_cache_key_hash: req.usageContext.promptCacheKeyHash ?? null,
    p_prompt_bytes: req.usageContext.promptBytes ?? null,
    p_stable_prefix_bytes: req.usageContext.stablePrefixBytes ?? null,
    p_volatile_bytes: req.usageContext.volatileBytes ?? null,
  });
  const row = Array.isArray(result?.data) ? result.data[0] : result?.data;
  if (result?.error || !row?.attempt_id || !row?.attempt_key || !row?.attempt_ordinal) {
    throw new BillableLLMError("provider_attempt_allocation_failed", result?.error?.message ?? "could not allocate durable outline provider attempt", result?.error ?? undefined);
  }
  return { id: String(row.attempt_id), key: String(row.attempt_key), ordinal: Number(row.attempt_ordinal) };
}

async function startProviderAttempt(adminClient: unknown, req: BillableLLMRequest<unknown>, billingAttemptKey: string): Promise<string | null> {
  if (!adminClient) return null;
  try {
    const table = (adminClient as any).from("generation_provider_attempts");
    if (!table || typeof table.insert !== "function" || typeof table.select !== "function") return null;
    // This key identifies one physical dispatch, not the customer settlement.
    // Never query/reuse an existing row: a replay may call the provider again.
    const physicalAttemptKey = `${billingAttemptKey}:dispatch:${crypto.randomUUID()}`;
    const insertBuilder = table.insert({
      user_id: req.userID, purpose: req.purpose, action: req.action,
      feature_run_id: req.usageContext.featureRunID ?? null,
      billing_idempotency_key: req.usageContext.idempotencyKey ?? null,
      attempt_key: physicalAttemptKey, logical_stage_key: req.usageContext.logicalStageKey ?? req.usageContext.idempotencyKey ?? billingAttemptKey,
      attempt_ordinal: req.usageContext.attemptOrdinal ?? 1,
      model_name: req.model.provider_model, status: "started",
      stable_prefix_hash: req.stablePrefixHash ?? null,
      prompt_bytes: req.usageContext.promptBytes ?? null,
      stable_prefix_bytes: req.usageContext.stablePrefixBytes ?? null,
      volatile_bytes: req.usageContext.volatileBytes ?? null,
    });
    // The production Supabase builder supports select().single(). Tiny unit
    // test doubles often return a Promise directly; do not add an extra audit
    // write to those doubles or mask the feature's own failure assertions.
    if (!insertBuilder || typeof insertBuilder.select !== "function") return null;
    const result = await insertBuilder.select("id").single();
    if (result?.error) { console.error(`[billable-llm] provider-attempt insert failed: ${JSON.stringify(result.error)}`); return null; }
    return result?.data?.id ?? null;
  } catch (error) { console.error(`[billable-llm] provider-attempt insert threw: ${error instanceof Error ? error.message : String(error)}`); return null; }
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
  let attemptKey = req.usageContext.providerAttemptKey ??
    `${req.usageContext.idempotencyKey ?? crypto.randomUUID()}:attempt:1`;
  let attemptID: string | null = null;

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

  if (req.purpose === "outline-suggestion") {
    const allocated = await beginOutlineProviderAttempt(deps.adminClient, req);
    attemptID = allocated.id;
    attemptKey = allocated.key;
  } else {
    attemptID = await startProviderAttempt(deps.adminClient, req, attemptKey);
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
    await updateProviderAttempt(deps.adminClient, attemptID, { status: "provider_failed", completed_at: new Date().toISOString(), provider_error_code: err instanceof Error ? err.name : "provider_error" });
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

  // 3. Feature-specific persistence callback. Generate/coherence preserve
  //    their historical failure semantics. Outline provider-complete
  //    validation failures are settled below using the durable provider
  //    attempt key because the provider already incurred usage/COGS.
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
  const totalProviderInput = Math.max(0, providerResult.inputTokens ?? 0);
  const providerCached = Math.max(0, providerResult.cachedInputTokens ?? 0);
  const providerCacheWrite = Math.max(0, providerResult.cacheWriteInputTokens ?? 0);
  const providerCogsSnapshot = computeProviderCogsCents({ uncachedInputTokens: Math.max(0, totalProviderInput - providerCached - providerCacheWrite), cachedInputTokens: providerCached, cacheWriteInputTokens: providerCacheWrite, outputTokens: Math.max(0, providerResult.outputTokens ?? 0), toolCostUsd: providerResult.toolCostUsd }, pricing);
  await updateProviderAttempt(deps.adminClient, attemptID, { status: "provider_succeeded", provider_completed_at: new Date().toISOString(), model_name: providerResult.modelName, input_tokens: providerResult.inputTokens, output_tokens: providerResult.outputTokens, cached_input_tokens: providerResult.cachedInputTokens, cache_write_input_tokens: providerResult.cacheWriteInputTokens, provider_cogs_cents: providerCogsSnapshot.providerCogsCents });
  const preCallbackUsage: GenerationUsage = {
    uncachedInputTokens: Math.max(0, totalProviderInput - providerCached - providerCacheWrite),
    cachedInputTokens: providerCached,
    cacheWriteInputTokens: providerCacheWrite,
    outputTokens: Math.max(0, providerResult.outputTokens ?? 0),
    toolCostUsd: providerResult.toolCostUsd,
  };
  const preCallbackCharge = computeActualChargeCredits(preCallbackUsage, pricing);
  const preCallbackMargin = computeMarginCents(preCallbackCharge, pricing, providerCogsSnapshot.providerCogsCents);
  let featureResult: T;
  try { featureResult = await req.onProviderSuccess(providerResult); }
  catch (error) {
    // Outline provider responses with real usage are billable even when the
    // feature rejects malformed JSON/contracts. This prevents retry storms
    // from hiding provider COGS; the attempt key makes the debit idempotent.
    if (req.purpose === "outline-suggestion" && (totalProviderInput > 0 || (providerResult.outputTokens ?? 0) > 0)) {
      try {
        const settlement = await (deps.adminClient as any).rpc(
          req.purpose === "outline-suggestion" ? "settle_outline_provider_attempt" : "settle_billable_usage",
          req.purpose === "outline-suggestion"
            ? {
              p_user_id: req.userID, p_feature_run_id: req.usageContext.featureRunID,
              p_attempt_key: attemptKey, p_attempt_outcome: "feature_validation_failed",
              p_action: req.action, p_purpose: req.purpose, p_model_name: providerResult.modelName,
              p_charge_credits: preCallbackCharge, p_input_tokens: providerResult.inputTokens,
              p_output_tokens: providerResult.outputTokens, p_generation_length_mode: req.usageContext.generationLengthMode ?? "short",
              p_output_budget: req.usageContext.outputBudget ?? req.maxOutputTokens,
              p_uncached_input_tokens: preCallbackUsage.uncachedInputTokens,
              p_cached_input_tokens: preCallbackUsage.cachedInputTokens,
              p_cache_write_input_tokens: preCallbackUsage.cacheWriteInputTokens,
              p_provider_cogs_cents: providerCogsSnapshot.providerCogsCents,
              p_customer_revenue_cents: preCallbackMargin.customerRevenueCents,
              p_margin_cents: preCallbackMargin.marginCents,
              p_stable_prefix_hash: req.stablePrefixHash ?? null,
              p_credit_value_usd: pricing.creditValueUsd,
            }
            : {
              p_user_id: req.userID, p_action: req.action, p_purpose: req.purpose,
              p_model_name: providerResult.modelName, p_idempotency_key: attemptKey,
              p_charge_credits: preCallbackCharge, p_input_tokens: providerResult.inputTokens,
              p_output_tokens: providerResult.outputTokens, p_generation_length_mode: req.usageContext.generationLengthMode ?? "short",
              p_output_budget: req.usageContext.outputBudget ?? req.maxOutputTokens,
              p_uncached_input_tokens: preCallbackUsage.uncachedInputTokens,
              p_cached_input_tokens: preCallbackUsage.cachedInputTokens,
              p_cache_write_input_tokens: preCallbackUsage.cacheWriteInputTokens,
              p_provider_cogs_cents: providerCogsSnapshot.providerCogsCents,
              p_customer_revenue_cents: preCallbackMargin.customerRevenueCents,
              p_margin_cents: preCallbackMargin.marginCents,
              p_stable_prefix_hash: req.stablePrefixHash ?? null,
              p_credit_value_usd: pricing.creditValueUsd,
            },
        );
        if (settlement?.error) throw new Error(settlement.error.message ?? "validation-failure settlement failed");
        const settledRow = settlement?.data?.[0] ?? {};
        await updateProviderAttempt(deps.adminClient, attemptID, { status: "feature_validation_failed", completed_at: new Date().toISOString(), feature_error_code: error instanceof Error ? error.name : "feature_error", calculated_charge_credits: preCallbackCharge, settled_charge_credits: preCallbackCharge, usage_event_id: settledRow.usage_event_id ?? null, ledger_id: settledRow.ledger_id ?? null });
        await reconcileOutlineRun(deps.adminClient, req.usageContext.featureRunID);
      } catch (settlementError) {
        await updateProviderAttempt(deps.adminClient, attemptID, { status: "settlement_failed", completed_at: new Date().toISOString(), feature_error_code: error instanceof Error ? error.name : "feature_error", calculated_charge_credits: preCallbackCharge });
        console.error(`[billable-llm] provider-complete outline validation settlement failed: ${settlementError instanceof Error ? settlementError.message : String(settlementError)}`);
      }
    } else {
      await updateProviderAttempt(deps.adminClient, attemptID, { status: "feature_validation_failed", completed_at: new Date().toISOString(), feature_error_code: error instanceof Error ? error.name : "feature_error" });
    }
    throw error;
  }

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
    p_idempotency_key: req.purpose === "outline-suggestion" ? attemptKey : (req.usageContext.idempotencyKey ?? null),
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
  }).rpc(
    req.purpose === "outline-suggestion" ? "settle_outline_provider_attempt" : "settle_billable_usage",
    req.purpose === "outline-suggestion"
      ? { ...rpcPayload, p_feature_run_id: req.usageContext.featureRunID, p_attempt_key: attemptKey, p_attempt_outcome: "settled" }
      : rpcPayload,
  );

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
    await updateProviderAttempt(deps.adminClient, attemptID, { status: "settlement_failed", completed_at: new Date().toISOString(), calculated_charge_credits: actualCharge });
    throw new BillableLLMError(
      "credit_charge_failed",
      `settle_billable_usage failed for purpose=${req.purpose}, ` +
        `action=${req.action}: ${msg}`,
      rpcResult.error,
    );
  }

  const row = rpcResult?.data?.[0];
  if (!row) {
    await updateProviderAttempt(deps.adminClient, attemptID, { status: "settlement_failed", completed_at: new Date().toISOString(), calculated_charge_credits: actualCharge });
    throw new BillableLLMError(
      "usage_event_insert_failed",
      `settle_billable_usage returned no row for purpose=${req.purpose}, ` +
        `action=${req.action}.`,
      { rpcResult },
    );
  }

  const remainingCredits = row.remaining_credits ?? 0;

  if (row.settlement_status === "duplicate") {
    if (req.purpose !== "outline-suggestion") {
      await updateProviderAttempt(deps.adminClient, attemptID, { status: "settled", completed_at: new Date().toISOString(), calculated_charge_credits: actualCharge });
    }
    await reconcileOutlineRun(deps.adminClient, req.usageContext.featureRunID);
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

  await updateProviderAttempt(deps.adminClient, attemptID, { status: "settled", completed_at: new Date().toISOString(), calculated_charge_credits: actualCharge, settled_charge_credits: actualCharge, usage_event_id: row.usage_event_id, ledger_id: row.ledger_id });
  await reconcileOutlineRun(deps.adminClient, req.usageContext.featureRunID);
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
