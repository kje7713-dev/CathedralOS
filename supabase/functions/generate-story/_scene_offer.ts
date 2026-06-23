import type { LengthMode } from "./_credits.ts";

export const SCENE_OFFER_PRICING_VERSION = "scene-offer-v1";
export const STANDARD_CONTEXT_TOKENS = 10_000;
export const DEEP_CONTEXT_STEP_TOKENS = 5_000;

export interface SceneOffer {
  lengthMode: LengthMode;
  primaryOutputTokens: number;
  completionReserveTokens: number;
  targetWords: string;
  totalReservedOutputTokens: number;
  pricingVersion: typeof SCENE_OFFER_PRICING_VERSION;
  includesAutomaticEndingPass: true;
}

interface ScenePricePolicy {
  short: number;
  medium: number;
  long: number;
  chapter: number;
  deepContextSurcharge: number;
}

export interface SceneOfferQuote {
  estimatedCredits: number;
  baseCredits: number;
  deepContextSurchargeCredits: number;
  deepContextSurchargeUnits: number;
  estimatedInputTokens: number;
  primaryOutputTokens: number;
  completionReserveTokens: number;
  totalReservedOutputTokens: number;
  pricingVersion: typeof SCENE_OFFER_PRICING_VERSION;
  includesAutomaticEndingPass: true;
}

export class SceneOfferPricingError extends Error {
  constructor(
    message: string,
    public readonly errorCode: "pricing_not_configured",
  ) {
    super(message);
    this.name = "SceneOfferPricingError";
  }
}

const SCENE_OFFERS: Record<LengthMode, Omit<SceneOffer, "lengthMode">> = {
  short: {
    primaryOutputTokens: 1600,
    completionReserveTokens: 500,
    targetWords: "300-500",
    totalReservedOutputTokens: 2100,
    pricingVersion: SCENE_OFFER_PRICING_VERSION,
    includesAutomaticEndingPass: true,
  },
  medium: {
    primaryOutputTokens: 3200,
    completionReserveTokens: 800,
    targetWords: "700-900",
    totalReservedOutputTokens: 4000,
    pricingVersion: SCENE_OFFER_PRICING_VERSION,
    includesAutomaticEndingPass: true,
  },
  long: {
    primaryOutputTokens: 5500,
    completionReserveTokens: 1200,
    targetWords: "1200-1700",
    totalReservedOutputTokens: 6700,
    pricingVersion: SCENE_OFFER_PRICING_VERSION,
    includesAutomaticEndingPass: true,
  },
  chapter: {
    primaryOutputTokens: 8500,
    completionReserveTokens: 1600,
    targetWords: "2500-3200",
    totalReservedOutputTokens: 10100,
    pricingVersion: SCENE_OFFER_PRICING_VERSION,
    includesAutomaticEndingPass: true,
  },
};

const SCENE_PRICE_POLICIES: Record<string, ScenePricePolicy> = {
  "gpt-4o-mini": {
    short: 1,
    medium: 1,
    long: 2,
    chapter: 3,
    deepContextSurcharge: 1,
  },
  "gpt-4.1-mini": {
    short: 2,
    medium: 2,
    long: 4,
    chapter: 6,
    deepContextSurcharge: 1,
  },
  "gpt-4.1": {
    short: 4,
    medium: 5,
    long: 10,
    chapter: 15,
    deepContextSurcharge: 2,
  },
  "gpt-5.4-nano": {
    short: 3,
    medium: 3,
    long: 6,
    chapter: 9,
    deepContextSurcharge: 1,
  },
  "gpt-5.4-mini": {
    short: 4,
    medium: 5,
    long: 10,
    chapter: 15,
    deepContextSurcharge: 2,
  },
  "gpt-5.4": {
    short: 8,
    medium: 12,
    long: 24,
    chapter: 36,
    deepContextSurcharge: 4,
  },
  "gpt-5.5": {
    short: 16,
    medium: 24,
    long: 48,
    chapter: 72,
    deepContextSurcharge: 8,
  },
};

export function resolveSceneOffer(lengthMode: LengthMode): SceneOffer {
  return {
    lengthMode,
    ...SCENE_OFFERS[lengthMode],
  };
}

export function computeDeepContextSurchargeUnits(
  estimatedInputTokens: number,
): number {
  if (estimatedInputTokens <= STANDARD_CONTEXT_TOKENS) return 0;
  return Math.ceil(
    (estimatedInputTokens - STANDARD_CONTEXT_TOKENS) / DEEP_CONTEXT_STEP_TOKENS,
  );
}

export function quoteSceneOffer(params: {
  lengthMode: LengthMode;
  modelId: string;
  estimatedInputTokens: number;
}): SceneOfferQuote {
  const offer = resolveSceneOffer(params.lengthMode);
  const policy = SCENE_PRICE_POLICIES[params.modelId];
  if (!policy) {
    throw new SceneOfferPricingError(
      `No complete-scene pricing policy is configured for model '${params.modelId}'.`,
      "pricing_not_configured",
    );
  }

  const baseCredits = policy[params.lengthMode];
  const deepContextSurchargeUnits = computeDeepContextSurchargeUnits(
    params.estimatedInputTokens,
  );
  const deepContextSurchargeCredits = deepContextSurchargeUnits *
    policy.deepContextSurcharge;

  return {
    estimatedCredits: baseCredits + deepContextSurchargeCredits,
    baseCredits,
    deepContextSurchargeCredits,
    deepContextSurchargeUnits,
    estimatedInputTokens: params.estimatedInputTokens,
    primaryOutputTokens: offer.primaryOutputTokens,
    completionReserveTokens: offer.completionReserveTokens,
    totalReservedOutputTokens: offer.totalReservedOutputTokens,
    pricingVersion: offer.pricingVersion,
    includesAutomaticEndingPass: true,
  };
}
