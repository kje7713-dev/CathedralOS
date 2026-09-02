import { getCreditCost, type LengthMode } from "./_credits.ts";

export const DEFAULT_GENERATION_MODEL_ID = "gpt-4o-mini";

export interface GenerationModel {
  id: string;
  provider: string;
  provider_model: string;
  display_name: string;
  description: string | null;
  input_credit_rate: number;
  output_credit_rate: number;
  minimum_charge_credits: number;
  max_output_tokens: number | null;
  enabled: boolean;
  sort_order: number;
  // Phase 3 pricing fields (raw provider USD rates + 2x markup multiplier).
  // Read by snapshotPricing() to derive the per-1K credit rate snapshot.
  // Supabase JS returns NUMERIC as a string; mapModelRow coerces via toNumber.
  billing_multiplier: number;
  provider_input_usd_per_1m: number;
  provider_cached_input_usd_per_1m: number;
  /**
   * PR-372: provider's USD rate per 1M cache-write input tokens. OpenAI
   * charges 1.25x the standard input rate on GPT-5.6+ when a prefix is
   * written to the cache. Default to standard input × 1.25 if the column
   * is missing (matches the OpenAI GPT-5.6+ contract; safe for older models
   * that don't report cache_write_tokens because the COGS math only reads
   * this when cache_write_input_tokens > 0).
   */
  provider_cache_write_usd_per_1m: number;
  provider_output_usd_per_1m: number;
  pricing_effective_at: string;
  /**
   * PR-372: cache capability enum. Replaces the planned `cache_supported`
   * boolean with the actual OpenAI API terminology.
   *   "none"     — model/provider does not support prompt caching
   *   "implicit" — automatic prefix matching (prompt_cache_key only,
   *                no explicit breakpoints). Default for most OpenAI models.
   *   "explicit" — explicit cache boundary via prompt_cache_options +
   *                prompt_cache_breakpoint (GPT-5.6+ only).
   */
  cacheMode: "none" | "implicit" | "explicit";
}

export type PublicGenerationModel = Pick<
  GenerationModel,
  | "id"
  | "display_name"
  | "description"
  | "input_credit_rate"
  | "output_credit_rate"
  | "minimum_charge_credits"
  | "max_output_tokens"
  | "sort_order"
>;

export interface GenerationModelStore {
  getEnabledModelById(modelId: string): Promise<GenerationModel | null>;
  listEnabledModels(): Promise<PublicGenerationModel[]>;
}

function toNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function mapModelRow(row: Record<string, unknown>): GenerationModel {
  // Phase 3 default multiplier is 2.0 (50% gross margin). Older rows that
  // pre-date the migration won't have the column populated; toNumber's
  // fallback handles that.
  const providerInput = toNumber(row.provider_input_usd_per_1m, 0);
  const providerCached = toNumber(row.provider_cached_input_usd_per_1m, 0);
  const providerOutput = toNumber(row.provider_output_usd_per_1m, 0);
  const multiplier = toNumber(row.billing_multiplier, 2.0);
  // PR-372 cache write rate: default to standard input rate × 1.25 (OpenAI
  // GPT-5.6+ cache-write multiplier). Older rows won't have the column;
  // computed fallback matches the documented provider contract.
  const providerCacheWrite = toNumber(
    row.provider_cache_write_usd_per_1m,
    providerInput * 1.25,
  );
  // PR-372 cache mode: default "implicit" (automatic prefix matching with
  // prompt_cache_key). Models that don't support caching at all will still
  // work — the provider skips the cache fields. Set cache_mode explicitly
  // per model row when adding support for "explicit" or "none".
  const rawCacheMode = String(row.cache_mode ?? "implicit");
  const cacheMode: "none" | "implicit" | "explicit" =
    rawCacheMode === "none" || rawCacheMode === "explicit"
      ? rawCacheMode
      : "implicit";
  return {
    id: String(row.id ?? ""),
    provider: String(row.provider ?? "openai"),
    provider_model: String(row.provider_model ?? ""),
    display_name: String(row.display_name ?? ""),
    description: row.description == null ? null : String(row.description),
    input_credit_rate: toNumber(row.input_credit_rate, 1),
    output_credit_rate: toNumber(row.output_credit_rate, 1),
    minimum_charge_credits: Math.max(
      0,
      Math.round(toNumber(row.minimum_charge_credits, 1)),
    ),
    max_output_tokens: row.max_output_tokens == null
      ? null
      : Math.max(1, Math.round(toNumber(row.max_output_tokens, 1))),
    enabled: Boolean(row.enabled),
    sort_order: Math.round(toNumber(row.sort_order, 0)),
    // Phase 3 pricing fields — populated by migration 20260803194600.
    billing_multiplier: multiplier,
    provider_input_usd_per_1m: providerInput,
    provider_cached_input_usd_per_1m: providerCached,
    provider_cache_write_usd_per_1m: providerCacheWrite,
    provider_output_usd_per_1m: providerOutput,
    pricing_effective_at: row.pricing_effective_at == null
      ? new Date(0).toISOString()
      : String(row.pricing_effective_at),
    cacheMode,
  };
}

export async function getEnabledModelByProviderModel(
  db: any,
  providerModel: string,
): Promise<GenerationModel | null> {
  const { data, error } = await db
    .from("generation_models")
    .select("*")
    .eq("provider_model", providerModel)
    .eq("enabled", true)
    .maybeSingle();
  if (error || !data) return null;
  return mapModelRow(data as Record<string, unknown>);
}

export class SupabaseGenerationModelStore implements GenerationModelStore {
  // deno-lint-ignore no-explicit-any
  constructor(private readonly db: any) {}

  async getEnabledModelById(modelId: string): Promise<GenerationModel | null> {
    const { data, error } = await this.db
      .from("generation_models")
      .select("*")
      .eq("id", modelId)
      .eq("enabled", true)
      .single();

    if (error || !data) return null;
    return mapModelRow(data as Record<string, unknown>);
  }

  async listEnabledModels(): Promise<PublicGenerationModel[]> {
    const { data, error } = await this.db
      .from("generation_models")
      .select(
        "id, display_name, description, input_credit_rate, output_credit_rate, minimum_charge_credits, max_output_tokens, sort_order",
      )
      .eq("enabled", true)
      .order("sort_order", { ascending: true })
      .order("id", { ascending: true });

    if (error || !data) return [];
    return (data as Record<string, unknown>[]).map((row) => {
      const mapped = mapModelRow({
        ...row,
        provider: "openai",
        provider_model: "",
        enabled: true,
      });
      return {
        id: mapped.id,
        display_name: mapped.display_name,
        description: mapped.description,
        input_credit_rate: mapped.input_credit_rate,
        output_credit_rate: mapped.output_credit_rate,
        minimum_charge_credits: mapped.minimum_charge_credits,
        max_output_tokens: mapped.max_output_tokens,
        sort_order: mapped.sort_order,
      };
    });
  }
}

export function normalizedModelId(selectedModelId: unknown): string {
  if (
    typeof selectedModelId === "string" && selectedModelId.trim().length > 0
  ) {
    return selectedModelId.trim();
  }
  return DEFAULT_GENERATION_MODEL_ID;
}

export function estimateTokensFromText(text: string): number {
  if (!text.trim()) return 0;
  // Conservative heuristic to avoid under-estimating preflight charge.
  // Uses ~3 chars/token plus 25% safety headroom.
  // This is intentionally dependency-free for Edge runtime portability; switch
  // to a provider-specific tokenizer if exact preflight estimates are required.
  const baseEstimate = Math.ceil(text.length / 3);
  return Math.max(1, Math.ceil(baseEstimate * 1.25));
}

export function computeGenerationCreditCharge(
  lengthMode: LengthMode,
  model: GenerationModel,
): number {
  // Phase 1 (legacy): fixed charge per length mode × model rate, with a
  // per-model minimum floor. Kept for backwards compat; new code should use
  // computeActualChargeCredits (post-flight) and computeMaxChargeCredits
  // (pre-flight) instead.
  const baseLengthCost = getCreditCost(lengthMode);
  const modelMultiplier = model.output_credit_rate;
  const raw = baseLengthCost * modelMultiplier;
  return Math.max(model.minimum_charge_credits, Math.ceil(raw));
}

// =============================================================================
// Phase 3 pricing: 2× markup on provider cost, fractional credits, snapshot
// pricing at request start. See supabase/migrations/20260803194600_*.sql.
// =============================================================================

export interface PricingSnapshot {
  // -----------------------------------------------------------------------
  // Customer-facing rates (credits per 1K tokens, with markup already applied)
  // -----------------------------------------------------------------------

  /** Credits per 1K input tokens charged to the customer. PR-372: ALL input
   *  tokens (uncached + cached + cacheWrite) are charged at this normal
   *  rate. The customer is NEVER discounted on cache hits — cache savings
   *  are Cathedral's margin, not a customer-side concession. */
  inputCreditRatePer1k: number;
  /** Credits per 1K output tokens charged to the customer. */
  outputCreditRatePer1k: number;
  /** Billing multiplier (e.g., 2.0 for 2× markup → 50% gross margin). */
  billingMultiplier: number;
  /** Product floor (NOT the OpenAI minimum). 0.25 credits by default. */
  minimumChargeCredits: number;
  /** USD value of one credit. 0.01 by default. */
  creditValueUsd: number;
  /** ISO timestamp of when this pricing snapshot became effective. */
  effectiveAt: string;

  // -----------------------------------------------------------------------
  // PR-372 provider-facing rates (USD per 1M tokens) — used for provider
  // COGS calculation. These are the rates OpenAI actually bills Cathedral,
  // NOT the customer-facing rates.
  // -----------------------------------------------------------------------

  /** Provider's USD per 1M uncached input tokens. */
  providerInputUsdPer1m: number;
  /** Provider's USD per 1M cache-read input tokens (0.1× on GPT-5.6+). */
  providerCachedInputUsdPer1m: number;
  /** Provider's USD per 1M cache-write input tokens (1.25× on GPT-5.6+). */
  providerCacheWriteUsdPer1m: number;
  /** Provider's USD per 1M output tokens. */
  providerOutputUsdPer1m: number;
}

export interface GenerationUsage {
  /** Uncached input tokens (ordinary, non-cached, non-cache-write).
   *  Counted into customer total input AND billed at provider normal rate
   *  on the COGS side. */
  uncachedInputTokens: number;
  /** Cached input tokens (cache-read). Counted into customer total input at
   *  the NORMAL rate (no customer discount — Kevin correction #1). Billed at
   *  the provider cached-input rate on the COGS side. */
  cachedInputTokens: number;
  /** PR-372: cache-write input tokens. Counted into customer total input at
   *  the NORMAL rate. Billed at the provider cache-write rate on the COGS
   *  side (separately priced on GPT-5.6+ — 1.25× standard input rate). */
  cacheWriteInputTokens: number;
  /** Output tokens (charged at the output rate). */
  outputTokens: number;
  /** Tool / function-call / web-search / image-gen cost in USD. */
  toolCostUsd: number;
}

export interface PricingDefaults {
  /** Product floor (NOT the OpenAI minimum). */
  minimumChargeCredits: number;
  /** USD value of one credit. */
  creditValueUsd: number;
}

export const DEFAULT_PRICING: PricingDefaults = {
  minimumChargeCredits: 0.25,
  creditValueUsd: 0.01,
};

/**
 * Capture the pricing snapshot from a GenerationModel at the moment of the
 * request. Used to freeze the rate so admin updates don't change charges for
 * in-flight or completed requests.
 */
export function snapshotPricing(
  model: GenerationModel,
  defaults: PricingDefaults = DEFAULT_PRICING,
): PricingSnapshot {
  const multiplier = model.billing_multiplier;
  return {
    // Customer-facing rates (with markup)
    inputCreditRatePer1k: (model.provider_input_usd_per_1m ?? 0) * multiplier /
      10,
    outputCreditRatePer1k: (model.provider_output_usd_per_1m ?? 0) *
      multiplier / 10,
    billingMultiplier: multiplier,
    minimumChargeCredits: model.minimum_charge_credits ??
      defaults.minimumChargeCredits,
    creditValueUsd: defaults.creditValueUsd,
    effectiveAt: model.pricing_effective_at,
    // PR-372 provider-facing rates for COGS math
    providerInputUsdPer1m: model.provider_input_usd_per_1m ?? 0,
    providerCachedInputUsdPer1m: model.provider_cached_input_usd_per_1m ?? 0,
    providerCacheWriteUsdPer1m: model.provider_cache_write_usd_per_1m ?? 0,
    providerOutputUsdPer1m: model.provider_output_usd_per_1m ?? 0,
  };
}

/**
 * Compute the customer charge in credits, given actual token usage and the
 * pricing snapshot.
 *
 * PR-372 corrected rule (Kevin correction #1): the customer is NEVER
 * discounted on cache hits. ALL input tokens — uncached, cached, and
 * cache-write — are charged at the same normal rate (inputCreditRatePer1k).
 * Cache savings are Cathedral's margin, not a customer-side concession.
 *
 *   inputCredits  = (uncached + cached + cacheWrite) × inputCreditRatePer1k / 1000
 *   outputCredits = output × outputCreditRatePer1k / 1000
 *   toolCredits   = toolCostUsd / creditValueUsd
 *   charge        = max(minimumChargeCredits, inputCredits + outputCredits + toolCredits)
 *
 * 6-decimal precision. Does NOT ceil per-component — fractional credits are
 * preserved so cheap models and short requests aren't materially overcharged.
 */
export function computeActualChargeCredits(
  usage: GenerationUsage,
  pricing: PricingSnapshot,
): number {
  const totalInputTokens = Math.max(
    0,
    usage.uncachedInputTokens +
      usage.cachedInputTokens +
      usage.cacheWriteInputTokens,
  );
  const inputCredits = (totalInputTokens * pricing.inputCreditRatePer1k) / 1000;
  const outputCredits = (usage.outputTokens * pricing.outputCreditRatePer1k) /
    1000;
  const toolCredits = usage.toolCostUsd > 0
    ? usage.toolCostUsd / pricing.creditValueUsd
    : 0;
  const providerCostCredits = inputCredits + outputCredits + toolCredits;
  const charge = Math.max(
    pricing.minimumChargeCredits,
    providerCostCredits,
  );
  // Round to 6 decimal places for storage. Do NOT ceil.
  return Math.round(charge * 1_000_000) / 1_000_000;
}

/**
 * Pre-flight: compute the maximum possible charge for the upcoming generation.
 * Uses the estimated input token count and the container's output hard cap.
 * Used as the affordability check before invoking the LLM.
 */
export function computeMaxChargeCredits(
  estimatedUsage: GenerationUsage,
  pricing: PricingSnapshot,
): number {
  return computeActualChargeCredits(estimatedUsage, pricing);
}

// =============================================================================
// PR-372: provider COGS + margin math (separate from customer charge)
//
// Customer charge and provider COGS are computed independently:
//   Customer charge (credits) — ALL input tokens at normal rate (no cache
//     discount); invariant on cache outcome. See computeActualChargeCredits.
//   Provider COGS (cents)     — uses the corrected uncached / cached /
//     cacheWrite split (see computeProviderCogsCents below).
//   Margin (cents)            — customerRevenueCents − providerCogsCents.
//
// This separation is load-bearing: Cathedral's cache savings are margin,
// not a discount to the customer.
// =============================================================================

/** Breakdown of the provider COGS computation. Diagnostic-only fields. */
export interface ProviderCogsBreakdown {
  /** Ordinary (non-cached, non-cache-write) input tokens. */
  ordinaryUncachedInputTokens: number;
  /** Cache-read input tokens (from `usage.input_tokens_details.cached_tokens`). */
  cachedInputTokens: number;
  /** Cache-write input tokens (from `usage.input_tokens_details.cache_write_tokens`). */
  cacheWriteInputTokens: number;
  /** Output tokens (sanitized). */
  outputTokens: number;
  /** Tool cost in USD (sanitized). */
  toolCostUsd: number;
  /** Provider cost in cents (USD). 6-decimal precision. */
  providerCogsCents: number;
  /** True iff the provider returned inconsistent usage
   *  (`cached + cacheWrite > totalInput`). Clamped to `ordinaryUncached = 0`
   *  in that case; the anomaly is surfaced for diagnostics only —
   *  customer billing is driven by totalInput at normal rate, which is
   *  unaffected by this clamp. */
  anomaly: boolean;
}

/**
 * Compute the provider's cost-of-goods in cents for a single generation.
 * Uses the corrected split formula (OpenAI GPT-5.6+ pattern):
 *
 *   ordinaryUncached = max(0, totalInput − cached − cacheWrite)
 *
 *   providerCogsCents =
 *       ordinaryUncached     × providerInputUsdPer1m      / 1_000_000 × 100
 *     + cachedInputTokens    × providerCachedInputUsdPer1m / 1_000_000 × 100
 *     + cacheWriteInputTokens × providerCacheWriteUsdPer1m / 1_000_000 × 100
 *     + outputTokens          × providerOutputUsdPer1m      / 1_000_000 × 100
 *     + toolCostUsd           × 100
 *
 * Defensive: if `cached + cacheWrite > totalInput`, clamp
 * `ordinaryUncached = 0` (no negative token counts ever reported), log an
 * anomaly for diagnostics, but DO NOT change customer billing. The customer
 * is still charged at the normal rate on `totalInput`, which the anomaly
 * does not affect.
 */
export function computeProviderCogsCents(
  usage: GenerationUsage,
  pricing: PricingSnapshot,
): ProviderCogsBreakdown {
  // Detect anomaly on RAW values before sanitization — otherwise
  // Math.max(0, uncached) makes the inequality unsatisfiable and the
  // anomaly branch never fires.
  const rawUncached = usage.uncachedInputTokens;
  const rawCached = usage.cachedInputTokens;
  const rawCacheWrite = usage.cacheWriteInputTokens;
  const rawTotalInput = rawUncached + rawCached + rawCacheWrite;
  const anomaly = (rawCached + rawCacheWrite) > rawTotalInput;
  const uncached = Math.max(0, rawUncached);
  const cached = Math.max(0, rawCached);
  const cacheWrite = Math.max(0, rawCacheWrite);
  const totalInput = uncached + cached + cacheWrite;
  const output = Math.max(0, usage.outputTokens);
  const tool = Math.max(0, usage.toolCostUsd);
  const ordinaryUncached = anomaly ? 0 : totalInput - cached - cacheWrite;
  // USD per 1M tokens × tokens / 1_000_000 = USD. × 100 = cents.
  const ordinaryUncachedCents =
    (ordinaryUncached * pricing.providerInputUsdPer1m) / 1_000_000 * 100;
  const cachedCents = (cached * pricing.providerCachedInputUsdPer1m) /
    1_000_000 * 100;
  const cacheWriteCents = (cacheWrite * pricing.providerCacheWriteUsdPer1m) /
    1_000_000 * 100;
  const outputCents = (output * pricing.providerOutputUsdPer1m) / 1_000_000 *
    100;
  const toolCents = tool * 100;
  const cogsCents = ordinaryUncachedCents + cachedCents + cacheWriteCents +
    outputCents + toolCents;
  if (anomaly) {
    console.error(
      `[compute-provider-cogs] anomaly: cached+cacheWrite ` +
        `(${cached + cacheWrite}) > totalInput (${totalInput}); ` +
        `clamped ordinaryUncached to 0; customer billing unchanged.`,
    );
  }
  return {
    ordinaryUncachedInputTokens: ordinaryUncached,
    cachedInputTokens: cached,
    cacheWriteInputTokens: cacheWrite,
    outputTokens: output,
    toolCostUsd: tool,
    providerCogsCents: Math.round(cogsCents * 1_000_000) / 1_000_000,
    anomaly,
  };
}

/**
 * Compute customer revenue in cents and the resulting margin in cents given
 * the actual customer charge (credits) and the provider COGS (cents).
 *
 *   customerRevenueCents = actualChargeCredits × creditValueUsd × 100
 *   marginCents          = customerRevenueCents − providerCogsCents
 *
 * Margin is positive on cache hits (revenue unchanged, COGS drops); may be
 * smaller or temporarily negative on cache writes (1.25× cost on GPT-5.6+
 * if no reuse on this call). Customer billing is never reduced on cache
 * hits — see computeActualChargeCredits.
 */
export function computeMarginCents(
  actualChargeCredits: number,
  pricing: PricingSnapshot,
  providerCogsCents: number,
): { customerRevenueCents: number; marginCents: number } {
  const customerRevenueCents = Math.round(
    actualChargeCredits * pricing.creditValueUsd * 100 * 1_000_000,
  ) / 1_000_000;
  const marginCents = Math.round(
    (customerRevenueCents - providerCogsCents) * 1_000_000,
  ) / 1_000_000;
  return { customerRevenueCents, marginCents };
}

/**
 * Phase 2: max possible credit charge for a generation.
 * Used by the pre-flight check to verify the user has enough credits before
 * invoking the LLM. No minimum floor — OpenAI has no minimum per request,
 * so we don't either (per policy).
 *
 * @param estimatedInputTokens - estimated input tokens (recipe + system msg)
 * @param containerHardCap - the output hard cap for the chosen container
 * @param model - the selected generation model
 */
export function computeMaxCreditCharge(
  estimatedInputTokens: number,
  containerHardCap: number,
  model: GenerationModel,
): number {
  const inputCost = (estimatedInputTokens * model.input_credit_rate) / 1000;
  const outputCost = (containerHardCap * model.output_credit_rate) / 1000;
  return Math.ceil(inputCost + outputCost);
}

/**
 * Phase 2: actual credit charge for a completed generation.
 * Uses real input + output tokens from the LLM response. No minimum floor.
 *
 * @param inputTokens - actual input tokens used (from LLM response)
 * @param outputTokens - actual output tokens produced (from LLM response)
 * @param model - the selected generation model
 */
export function computeActualCreditCharge(
  inputTokens: number,
  outputTokens: number,
  model: GenerationModel,
): number {
  const inputCost = (inputTokens * model.input_credit_rate) / 1000;
  const outputCost = (outputTokens * model.output_credit_rate) / 1000;
  return Math.ceil(inputCost + outputCost);
}
