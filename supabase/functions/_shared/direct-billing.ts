import {
  computeActualChargeCredits,
  computeMarginCents,
  computeMaxChargeCredits,
  computeProviderCogsCents,
  type GenerationUsage,
  getEnabledModelByProviderModel,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";
import {
  availableCredits,
  type CreditStore,
} from "../generate-story/_credits.ts";

export interface DirectBillingContext {
  userID: string;
  action: string;
  outputID?: string | null;
  projectID?: string | null;
  outlineSectionID?: string | null;
  adminClient: any;
  creditStore: CreditStore;
}

export async function preflightDirectUsage(
  context: DirectBillingContext,
  modelName: string,
  inputTokens: number,
  outputBudget: number,
): Promise<void> {
  const model = await getEnabledModelByProviderModel(
    context.adminClient,
    modelName,
  );
  if (!model) throw new Error(`billing model unavailable: ${modelName}`);
  const pricing = snapshotPricing(model);
  const estimate: GenerationUsage = {
    uncachedInputTokens: Math.max(0, inputTokens),
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: Math.max(0, outputBudget),
    toolCostUsd: 0,
  };
  const entitlement = await context.creditStore.loadOrDefault(context.userID);
  const required = computeMaxChargeCredits(estimate, pricing);
  if (availableCredits(entitlement) < required) {
    throw new Error(
      `insufficient_credits: need ${required}, have ${
        availableCredits(entitlement)
      }`,
    );
  }
}

export async function settleDirectUsage(
  context: DirectBillingContext,
  stage: string,
  modelName: string,
  inputTokens: number,
  outputTokens: number,
): Promise<number> {
  const model = await getEnabledModelByProviderModel(
    context.adminClient,
    modelName,
  );
  if (!model) throw new Error(`billing model unavailable: ${modelName}`);
  const pricing = snapshotPricing(model);
  const usage: GenerationUsage = {
    uncachedInputTokens: Math.max(0, inputTokens),
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: Math.max(0, outputTokens),
    toolCostUsd: 0,
  };
  const charge = computeActualChargeCredits(usage, pricing);
  const cogs = computeProviderCogsCents(usage, pricing);
  const margin = computeMarginCents(charge, pricing, cogs.providerCogsCents);
  const { data, error } = await context.adminClient.from(
    "generation_usage_events",
  ).insert({
    user_id: context.userID,
    generation_output_id: context.outputID ?? null,
    action: context.action,
    purpose: "embed-section",
    model_name: modelName,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    generation_length_mode: "section-memory",
    output_budget: outputTokens,
    status: "complete",
    credit_revenue_usd: charge * pricing.creditValueUsd,
    idempotency_key: context.outputID ? `${context.outputID}:${stage}` : null,
    uncached_input_tokens: inputTokens,
    cached_input_tokens: 0,
    cache_write_input_tokens: 0,
    provider_cogs_cents: cogs.providerCogsCents,
    customer_revenue_cents: margin.customerRevenueCents,
    margin_cents: margin.marginCents,
  }).select("id").maybeSingle();
  if (error || !data?.id) {
    throw new Error(`usage event insert failed: ${error?.message ?? "no row"}`);
  }
  const entitlement = await context.creditStore.loadOrDefault(context.userID);
  await context.creditStore.charge(
    context.userID,
    charge,
    entitlement,
    context.outputID ?? null,
  );
  return charge;
}
