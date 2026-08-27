import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
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
  const { data, error } = await client.rpc("reserve_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
    p_cost: estimatedBilling.actualCharge,
    p_model_name: modelName,
    p_input_tokens: estimatedBilling.usage.uncachedInputTokens,
    p_output_tokens: estimatedBilling.usage.outputTokens,
    p_provider_cogs_cents: estimatedBilling.providerCogsCents,
    p_customer_revenue_cents: estimatedBilling.customerRevenueCents,
    p_margin_cents: estimatedBilling.marginCents,
  }).maybeSingle();
  if (error) {
    if (error.message?.includes("insufficient_ai_cover_credits")) {
      throw new AiCoverInsufficientCreditsError(error.message);
    }
    throw new Error(`AI cover credit reservation failed: ${error.message}`);
  }
  if (!data) throw new Error("AI cover credit reservation returned no result");
  const result = data as {
    available_credits?: number;
    already_reserved?: boolean;
  };
  return {
    remainingCredits: Number(result.available_credits ?? 0),
    alreadyReserved: Boolean(result.already_reserved),
  };
}

export async function settleAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
  billing: AiCoverBilling,
): Promise<number> {
  const { data, error } = await client.rpc("settle_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
    p_actual_cost: billing.actualCharge,
    p_input_tokens: billing.usage.uncachedInputTokens,
    p_output_tokens: billing.usage.outputTokens,
    p_provider_cogs_cents: billing.providerCogsCents,
    p_customer_revenue_cents: billing.customerRevenueCents,
    p_margin_cents: billing.marginCents,
  }).maybeSingle();
  if (error) {
    throw new Error(`AI cover credit settlement failed: ${error.message}`);
  }
  if (!data) throw new Error("AI cover credit settlement returned no result");
  return Number(
    (data as { available_credits?: number }).available_credits ?? 0,
  );
}

export async function refundAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
): Promise<void> {
  const { error } = await client.rpc("refund_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
  });
  if (error) console.error("AI cover credit refund failed:", error.message);
}
