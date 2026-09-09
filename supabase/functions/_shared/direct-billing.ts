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
import { CURRENT_MEMORY_PIPELINE_VERSION } from "./memory-pipeline.ts";

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

export async function hasCompletedDirectStage(
  context: DirectBillingContext,
  stage: string,
): Promise<boolean> {
  if (!context.outputID) return false;
  const stageIdentity =
    `${context.outputID}:${CURRENT_MEMORY_PIPELINE_VERSION}:${stage}`;
  const { data, error } = await context.adminClient.from(
    "generation_usage_events",
  )
    .select("stage_identity, stage_version, stage_status, status")
    .eq("user_id", context.userID)
    .eq("stage_identity", stageIdentity)
    .maybeSingle();
  if (error) throw new Error(`stage lookup failed: ${error.message}`);
  if (
    data?.stage_identity === stageIdentity &&
    data?.stage_version === CURRENT_MEMORY_PIPELINE_VERSION &&
    data?.stage_status === "complete" && data?.status === "complete"
  ) return true;
  // PR #521 used output_id:stage as idempotency_key. Treat a completed legacy
  // event as the same semantic stage, but never use it to match a different
  // output or stage.
  const { data: legacy, error: legacyError } = await context.adminClient.from(
    "generation_usage_events",
  )
    .select("id, status")
    .eq("user_id", context.userID)
    .eq("idempotency_key", `${context.outputID}:${stage}`)
    .eq("generation_output_id", context.outputID)
    .eq("purpose", "embed-section")
    .eq("status", "complete")
    .maybeSingle();
  if (legacyError) {
    throw new Error(`legacy stage lookup failed: ${legacyError.message}`);
  }
  return Boolean(legacy?.id);
}

export async function settleDirectUsage(
  context: DirectBillingContext,
  stage: string,
  modelName: string,
  inputTokens: number,
  outputTokens: number,
): Promise<number> {
  if (!context.outputID) {
    throw new Error(`stable output identity required for ${stage}`);
  }
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
  const stageIdentity =
    `${context.outputID}:${CURRENT_MEMORY_PIPELINE_VERSION}:${stage}`;
  // The SQL RPC locks the entitlement and writes the usage event + ledger debit
  // in one transaction. Integer credit storage is legacy, so charge the
  // conservative whole-credit amount while retaining the real provider tokens.
  const chargeCredits = Math.max(0, Math.ceil(charge));
  const { data, error } = await context.adminClient.rpc(
    "settle_scene_memory_stage",
    {
      p_user_id: context.userID,
      p_stage_identity: stageIdentity,
      p_stage_version: CURRENT_MEMORY_PIPELINE_VERSION,
      p_stage: stage,
      p_output_id: context.outputID,
      p_model_name: modelName,
      p_input_tokens: Math.max(0, Math.round(inputTokens)),
      p_output_tokens: Math.max(0, Math.round(outputTokens)),
      p_charge: chargeCredits,
      p_provider_cogs_cents: cogs.providerCogsCents,
      p_customer_revenue_cents: margin.customerRevenueCents,
      p_margin_cents: margin.marginCents,
    },
  );
  if (error || !Array.isArray(data) || !data[0]) {
    throw new Error(
      `atomic stage settlement failed: ${error?.message ?? "no row"}`,
    );
  }
  return chargeCredits;
}
