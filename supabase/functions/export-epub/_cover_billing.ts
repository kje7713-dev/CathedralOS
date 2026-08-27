import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  availableCredits,
  SupabaseCreditStore,
} from "../generate-story/_credits.ts";
import {
  computeActualChargeCredits,
  computeMarginCents,
  computeProviderCogsCents,
  estimateTokensFromText,
  type GenerationUsage,
  type PricingSnapshot,
} from "../generate-story/_generation_models.ts";

// gpt-image-1 charges image output as specialized image tokens. These are the
// documented token counts for the current cover request (1024x1536/high).
export const AI_COVER_MODEL = "gpt-image-1";
export const AI_COVER_SIZE = "1024x1536";
export const AI_COVER_QUALITY = "high";
export const AI_COVER_IMAGE_OUTPUT_TOKENS = 6240;

// OpenAI pricing is USD per 1M tokens. The customer-facing rates below are
// derived with the same 2x markup and $0.01/credit convention as text paths.
const AI_COVER_TEXT_INPUT_USD_PER_1M = 5;
const AI_COVER_IMAGE_OUTPUT_USD_PER_1M = 40;
const AI_COVER_BILLING_MULTIPLIER = 2;
const AI_COVER_CREDIT_VALUE_USD = 0.01;
const AI_COVER_MINIMUM_CHARGE_CREDITS = 0.25;

export class AiCoverInsufficientCreditsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AiCoverInsufficientCreditsError";
  }
}

export interface AiCoverBilling {
  usage: GenerationUsage;
  actualCharge: number;
  providerCogsCents: number;
  customerRevenueCents: number;
  marginCents: number;
}

export function aiCoverPricing(): PricingSnapshot {
  return {
    inputCreditRatePer1k: AI_COVER_TEXT_INPUT_USD_PER_1M *
      AI_COVER_BILLING_MULTIPLIER / 10,
    outputCreditRatePer1k: AI_COVER_IMAGE_OUTPUT_USD_PER_1M *
      AI_COVER_BILLING_MULTIPLIER / 10,
    billingMultiplier: AI_COVER_BILLING_MULTIPLIER,
    minimumChargeCredits: AI_COVER_MINIMUM_CHARGE_CREDITS,
    creditValueUsd: AI_COVER_CREDIT_VALUE_USD,
    effectiveAt: new Date().toISOString(),
    providerInputUsdPer1m: AI_COVER_TEXT_INPUT_USD_PER_1M,
    providerCachedInputUsdPer1m: 0,
    providerCacheWriteUsdPer1m: 0,
    providerOutputUsdPer1m: AI_COVER_IMAGE_OUTPUT_USD_PER_1M,
  };
}

export function estimateAiCoverBilling(prompt: string): AiCoverBilling {
  return computeAiCoverBilling({
    uncachedInputTokens: estimateTokensFromText(prompt),
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: AI_COVER_IMAGE_OUTPUT_TOKENS,
    toolCostUsd: 0,
  });
}

export function actualAiCoverBilling(
  inputTokens: number | null | undefined,
  outputTokens: number | null | undefined,
  prompt: string,
): AiCoverBilling {
  return computeAiCoverBilling({
    // Some Image API responses omit usage. In that case, use the conservative
    // prompt estimate and the deterministic size/quality image-token count.
    uncachedInputTokens: Number.isFinite(inputTokens) && (inputTokens ?? 0) >= 0
      ? Math.floor(inputTokens as number)
      : estimateTokensFromText(prompt),
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: Number.isFinite(outputTokens) && (outputTokens ?? 0) >= 0
      ? Math.floor(outputTokens as number)
      : AI_COVER_IMAGE_OUTPUT_TOKENS,
    toolCostUsd: 0,
  });
}

function computeAiCoverBilling(usage: GenerationUsage): AiCoverBilling {
  const pricing = aiCoverPricing();
  // Credit balances and the public credit ledger are whole-credit units; use
  // the established generation-path ceiling after calculating usage-based
  // provider cost plus markup. Telemetry retains the exact COGS/revenue cents.
  const actualCharge = Math.ceil(computeActualChargeCredits(usage, pricing));
  const cogs = computeProviderCogsCents(usage, pricing);
  const margin = computeMarginCents(
    actualCharge,
    pricing,
    cogs.providerCogsCents,
  );
  return {
    usage,
    actualCharge,
    providerCogsCents: cogs.providerCogsCents,
    customerRevenueCents: margin.customerRevenueCents,
    marginCents: margin.marginCents,
  };
}

export async function reserveAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
  estimatedBilling: AiCoverBilling,
  modelName = Deno.env.get("OPENAI_IMAGE_MODEL") ?? AI_COVER_MODEL,
): Promise<{ remainingCredits: number; alreadyReserved: boolean }> {
  const store = new SupabaseCreditStore(client);
  try {
    return await store.reserve(
      userId,
      estimatedBilling.actualCharge,
      exportJobId,
      {
        purpose: "ai-cover",
        model_name: modelName,
        estimated_input_tokens: estimatedBilling.usage.uncachedInputTokens,
        estimated_output_tokens: estimatedBilling.usage.outputTokens,
        estimated_provider_cogs_cents: estimatedBilling.providerCogsCents,
        estimated_customer_revenue_cents: estimatedBilling.customerRevenueCents,
        estimated_margin_cents: estimatedBilling.marginCents,
      },
    );
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (message.includes("insufficient_credits")) {
      throw new AiCoverInsufficientCreditsError(message);
    }
    throw new Error(`AI cover credit reservation failed: ${message}`);
  }
}

export async function settleAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
  billing: AiCoverBilling,
): Promise<number> {
  const store = new SupabaseCreditStore(client);
  const updated = await store.settleReservation(
    userId,
    billing.actualCharge,
    exportJobId,
    {
      purpose: "ai-cover",
      model_name: AI_COVER_MODEL,
      input_tokens: billing.usage.uncachedInputTokens,
      output_tokens: billing.usage.outputTokens,
      provider_cogs_cents: billing.providerCogsCents,
      customer_revenue_cents: billing.customerRevenueCents,
      margin_cents: billing.marginCents,
    },
  );
  const { error } = await client.from("generation_usage_events").upsert({
    user_id: userId,
    action: "generate",
    purpose: "ai-cover",
    model_name: AI_COVER_MODEL,
    generation_length_mode: "short",
    status: "complete",
    idempotency_key: `export-job:${exportJobId}`,
    input_tokens: billing.usage.uncachedInputTokens,
    output_tokens: billing.usage.outputTokens,
    credit_revenue_usd: billing.customerRevenueCents / 100,
    provider_cogs_cents: billing.providerCogsCents,
    customer_revenue_cents: billing.customerRevenueCents,
    margin_cents: billing.marginCents,
  }, { onConflict: "user_id,idempotency_key" });
  if (error) {
    throw new Error(`AI cover telemetry write failed: ${error.message}`);
  }
  return availableCredits(updated);
}

export async function refundAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
): Promise<void> {
  await new SupabaseCreditStore(client).refundReservation(userId, exportJobId);
}
