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
  provider_output_usd_per_1m: number;
  pricing_effective_at: string;
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
  return {
    id: String(row.id ?? ""),
    provider: String(row.provider ?? "openai"),
    provider_model: String(row.provider_model ?? ""),
    display_name: String(row.display_name ?? ""),
    description: row.description == null ? null : String(row.description),
    input_credit_rate: toNumber(row.input_credit_rate, 1),
    output_credit_rate: toNumber(row.output_credit_rate, 1),
    minimum_charge_credits: Math.max(0, Math.round(toNumber(row.minimum_charge_credits, 1))),
    max_output_tokens: row.max_output_tokens == null
      ? null
      : Math.max(1, Math.round(toNumber(row.max_output_tokens, 1))),
    enabled: Boolean(row.enabled),
    sort_order: Math.round(toNumber(row.sort_order, 0)),
    // Phase 3 pricing fields — populated by migration 20260803194600.
    billing_multiplier: multiplier,
    provider_input_usd_per_1m: providerInput,
    provider_cached_input_usd_per_1m: providerCached,
    provider_output_usd_per_1m: providerOutput,
    pricing_effective_at: row.pricing_effective_at == null
      ? new Date(0).toISOString()
      : String(row.pricing_effective_at),
  };
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
      const mapped = mapModelRow({ ...row, provider: "openai", provider_model: "", enabled: true });
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
  if (typeof selectedModelId === "string" && selectedModelId.trim().length > 0) {
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
  /** Credits per 1K uncached input tokens (derived from provider × multiplier / 10). */
  inputCreditRatePer1k: number;
  /** Credits per 1K cached input tokens (0 if the model does not support caching). */
  cachedInputCreditRatePer1k: number;
  /** Credits per 1K output tokens (derived from provider × multiplier / 10). */
  outputCreditRatePer1k: number;
  /** Billing multiplier (e.g., 2.0 for 2× markup → 50% gross margin). */
  billingMultiplier: number;
  /** Product floor (NOT the OpenAI minimum). 0.25 credits by default. */
  minimumChargeCredits: number;
  /** USD value of one credit. 0.01 by default. */
  creditValueUsd: number;
  /** ISO timestamp of when this pricing snapshot became effective. */
  effectiveAt: string;
}

export interface GenerationUsage {
  /** Uncached input tokens (charged at full rate). */
  uncachedInputTokens: number;
  /** Cached input tokens (charged at the cached rate). */
  cachedInputTokens: number;
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
    inputCreditRatePer1k:
      (model.provider_input_usd_per_1m ?? 0) * multiplier / 10,
    cachedInputCreditRatePer1k:
      (model.provider_cached_input_usd_per_1m ?? 0) * multiplier / 10,
    outputCreditRatePer1k:
      (model.provider_output_usd_per_1m ?? 0) * multiplier / 10,
    billingMultiplier: multiplier,
    minimumChargeCredits: defaults.minimumChargeCredits,
    creditValueUsd: defaults.creditValueUsd,
    effectiveAt: model.pricing_effective_at,
  };
}

/**
 * Compute the customer charge in credits, given actual token usage and the
 * pricing snapshot. Pricing: provider cost (input + cached + output + tool) ×
 * billing_multiplier / credit_value_usd, floored by the product minimum.
 *
 * 6-decimal precision. Does NOT ceil per-component — fractional credits are
 * preserved so cheap models and short requests aren't materially overcharged.
 */
export function computeActualChargeCredits(
  usage: GenerationUsage,
  pricing: PricingSnapshot,
): number {
  const uncachedCredits =
    (usage.uncachedInputTokens * pricing.inputCreditRatePer1k) / 1000;
  const cachedCredits =
    (usage.cachedInputTokens * pricing.cachedInputCreditRatePer1k) / 1000;
  const outputCredits =
    (usage.outputTokens * pricing.outputCreditRatePer1k) / 1000;
  const toolCredits =
    usage.toolCostUsd > 0 ? usage.toolCostUsd / pricing.creditValueUsd : 0;
  const providerCostCredits =
    uncachedCredits + cachedCredits + outputCredits + toolCredits;
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
