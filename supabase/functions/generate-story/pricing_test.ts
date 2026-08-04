// =============================================================================
// pricing_test.ts — Phase 3 pricing: 2× markup on provider cost, fractional
// credits, snapshot pricing, 0.25 floor, cached input, tool charges,
// failed-request policy.
//
// All tests use pure unit math; no live OpenAI calls.
// =============================================================================

import {
  assertAlmostEquals,
  assertEquals,
} from "https://deno.land/std@0.208.0/assert/mod.ts";

import {
  computeActualChargeCredits,
  computeMaxChargeCredits,
  DEFAULT_PRICING,
  snapshotPricing,
} from "./_generation_models.ts";

import type {
  GenerationModel,
  GenerationUsage,
  PricingSnapshot,
} from "./_generation_models.ts";

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

function makeModel(overrides: Partial<GenerationModel> = {}): GenerationModel {
  return {
    id: "gpt-5.5",
    provider: "openai",
    provider_model: "gpt-5.5-2026-04-23",
    display_name: "GPT-5.5",
    description: null,
    input_credit_rate: 0, // legacy, unused in Phase 3
    output_credit_rate: 0, // legacy, unused in Phase 3
    minimum_charge_credits: 0, // legacy, unused in Phase 3
    max_output_tokens: 8000,
    enabled: true,
    sort_order: 10,
    // Phase 3 fields
    provider_input_usd_per_1m: 5.0,
    provider_cached_input_usd_per_1m: 0.5,
    provider_output_usd_per_1m: 30.0,
    billing_multiplier: 2.0,
    pricing_effective_at: "2026-08-01T00:00:00Z",
    ...overrides,
  };
}

function makeSnapshot(overrides: Partial<PricingSnapshot> = {}): PricingSnapshot {
  return {
    inputCreditRatePer1k: 1.0, // (5.0 × 2.0 / 10)
    cachedInputCreditRatePer1k: 0.1, // (0.5 × 2.0 / 10)
    outputCreditRatePer1k: 6.0, // (30.0 × 2.0 / 10)
    billingMultiplier: 2.0,
    minimumChargeCredits: 0.25,
    creditValueUsd: 0.01,
    effectiveAt: "2026-08-01T00:00:00Z",
    ...overrides,
  };
}

function makeUsage(overrides: Partial<GenerationUsage> = {}): GenerationUsage {
  return {
    uncachedInputTokens: 1000,
    cachedInputTokens: 0,
    outputTokens: 0,
    toolCostUsd: 0,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// 1. Input and output are both charged
// ---------------------------------------------------------------------------

Deno.test("pricing: input AND output are both charged", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000,
    outputTokens: 500,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 1000 × 1.0 / 1000 = 1.0 (input)
  // 500 × 6.0 / 1000 = 3.0 (output)
  // total = 4.0, above 0.25 floor
  assertEquals(charge, 4.0);
});

// ---------------------------------------------------------------------------
// 2. Cached input receives the correct rate
// ---------------------------------------------------------------------------

Deno.test("pricing: cached input receives the cached rate (not full rate)", () => {
  const pricing = makeSnapshot(); // cached = 0.1 / 1K
  const usage = makeUsage({
    uncachedInputTokens: 0,
    cachedInputTokens: 5000,
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 5000 × 0.1 / 1000 = 0.5
  assertEquals(charge, 0.5);
});

Deno.test("pricing: uncached + cached input mixed, each at its own rate", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000, // → 1.0 credit
    cachedInputTokens: 2000, // → 0.2 credit
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 1.0 + 0.2 = 1.2, above floor
  assertEquals(charge, 1.2);
});

// ---------------------------------------------------------------------------
// 3. The 0.25-credit product floor works
// ---------------------------------------------------------------------------

Deno.test("pricing: 0.25 floor applies for trivially small requests", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 10, // → 0.01 credit
    outputTokens: 5, // → 0.03 credit
  });
  // raw = 0.04, floor to 0.25
  assertEquals(computeActualChargeCredits(usage, pricing), 0.25);
});

Deno.test("pricing: floor does not apply when raw >= minimum", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 100,
    outputTokens: 50,
  });
  // 0.1 + 0.3 = 0.4, above floor
  assertEquals(computeActualChargeCredits(usage, pricing), 0.4);
});

Deno.test("pricing: floor customizable per snapshot", () => {
  const pricing = makeSnapshot({ minimumChargeCredits: 1.0 });
  const usage = makeUsage({ uncachedInputTokens: 100, outputTokens: 50 });
  // raw = 0.4, floored to 1.0
  assertEquals(computeActualChargeCredits(usage, pricing), 1.0);
});

// ---------------------------------------------------------------------------
// 4. Charges preserve fractional credits (no ceil per-component)
// ---------------------------------------------------------------------------

Deno.test("pricing: fractional credits preserved (not ceil'd per component)", () => {
  const pricing = makeSnapshot();
  // 333 uncached + 167 output → 0.333 + 1.002 = 1.335 credits
  const usage = makeUsage({
    uncachedInputTokens: 333,
    outputTokens: 167,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // If we'd ceil'd per component: 0.333→1 + 1.002→2 = 3 credits (overcharged)
  // Correct Phase 3: 0.333 + 1.002 = 1.335
  assertEquals(charge, 1.335);
});

Deno.test("pricing: 6-decimal precision (no rounding beyond 6 dp)", () => {
  const pricing = makeSnapshot();
  // Tiny amounts that would accumulate rounding error
  const usage = makeUsage({
    uncachedInputTokens: 1234567, // → 1234.567
    cachedInputTokens: 0,
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 1234567 × 1.0 / 1000 = 1234.567 (exact, 3 dp)
  assertAlmostEquals(charge, 1234.567, 1e-9);
});

// ---------------------------------------------------------------------------
// 5. A 2× rate produces a 50% API gross margin
// ---------------------------------------------------------------------------

Deno.test("pricing: 2× billing multiplier produces 50% margin (gpt-5.5 example)", () => {
  // Per Kevin's spec: 1000 uncached + 1600 output gpt-5.5 = 10.6 credits
  // = $0.106. OpenAI cost = $0.053. 50% gross margin.
  const pricing = makeSnapshot(); // multiplier = 2.0
  const usage = makeUsage({
    uncachedInputTokens: 1000,
    outputTokens: 1600,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // input: 1000 × 1.0 / 1000 = 1.0
  // output: 1600 × 6.0 / 1000 = 9.6
  // total = 10.6
  assertEquals(charge, 10.6);
  // Provider cost: (1000 × $5 / 1M) + (1600 × $30 / 1M) = $0.005 + $0.048 = $0.053
  // Customer charge: $0.053 × 2.0 / $0.01 = 10.6 credits = $0.106 ✓
});

Deno.test("pricing: margin is exactly 50% regardless of token count", () => {
  // Property: customer_charge = provider_cost × multiplier / credit_value
  // Therefore customer - provider = provider × (multiplier - 1) / credit_value
  // Margin = (customer - provider) / customer = (multiplier - 1) / multiplier
  // For multiplier = 2: margin = 1 / 2 = 50%
  const pricing = makeSnapshot({ billingMultiplier: 2.0 });
  for (const tokens of [100, 500, 1000, 5000, 16000]) {
    const usage = makeUsage({
      uncachedInputTokens: tokens,
      outputTokens: tokens * 2,
    });
    const charge = computeActualChargeCredits(usage, pricing);
    // Provider cost in credits = (tokens × 1.0 + tokens*2 × 6.0) / 1000 = 13 × tokens / 1000
    const providerCostCredits = (tokens * 1.0 + tokens * 2 * 6.0) / 1000;
    // Margin = (charge - providerCost) / charge
    const margin = (charge - providerCostCredits) / charge;
    assertAlmostEquals(margin, 0.5, 1e-9);
  }
});

Deno.test("pricing: snapshotPricing derives rates correctly from model fields", () => {
  const model = makeModel({
    provider_input_usd_per_1m: 5.0,
    provider_cached_input_usd_per_1m: 0.5,
    provider_output_usd_per_1m: 30.0,
    billing_multiplier: 2.0,
    pricing_effective_at: "2026-08-01T00:00:00Z",
  });
  const snap = snapshotPricing(model);
  // credit_rate_per_1k = provider_usd_per_1m × multiplier / 10
  assertEquals(snap.inputCreditRatePer1k, 1.0); // 5 × 2 / 10
  assertEquals(snap.cachedInputCreditRatePer1k, 0.1); // 0.5 × 2 / 10
  assertEquals(snap.outputCreditRatePer1k, 6.0); // 30 × 2 / 10
  assertEquals(snap.billingMultiplier, 2.0);
  assertEquals(snap.effectiveAt, "2026-08-01T00:00:00Z");
});

Deno.test("pricing: snapshotPricing uses DEFAULT_PRICING defaults", () => {
  const model = makeModel();
  const snap = snapshotPricing(model);
  assertEquals(snap.minimumChargeCredits, DEFAULT_PRICING.minimumChargeCredits);
  assertEquals(snap.minimumChargeCredits, 0.25);
  assertEquals(snap.creditValueUsd, DEFAULT_PRICING.creditValueUsd);
  assertEquals(snap.creditValueUsd, 0.01);
});

// ---------------------------------------------------------------------------
// 6. Long-context and tool charges are included
// ---------------------------------------------------------------------------

Deno.test("pricing: tool cost is included in charge", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 0,
    outputTokens: 0,
    toolCostUsd: 0.10, // $0.10 = 10 credits at 0.01 credit/USD
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // tool credits = 0.10 / 0.01 = 10.0
  // Above 0.25 floor → 10.0
  assertEquals(charge, 10.0);
});

Deno.test("pricing: long-context input is charged normally", () => {
  // No long-context premium modifier in v1; large input is just charged at
  // the regular rate. This test guards against accidental future regression.
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 100000, // 100K tokens
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 100000 × 1.0 / 1000 = 100.0
  assertEquals(charge, 100.0);
});

Deno.test("pricing: tool + input + output all combine", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000, // → 1.0
    cachedInputTokens: 2000, // → 0.2
    outputTokens: 500, // → 3.0
    toolCostUsd: 0.02, // → 2.0
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 1.0 + 0.2 + 3.0 + 2.0 = 6.2
  assertEquals(charge, 6.2);
});

// ---------------------------------------------------------------------------
// computeMaxChargeCredits (pre-flight) — same formula as actual
// ---------------------------------------------------------------------------

Deno.test("pricing: pre-flight max matches actual formula", () => {
  const pricing = makeSnapshot();
  const estimated = makeUsage({
    uncachedInputTokens: 1000,
    outputTokens: 1600,
  });
  const max = computeMaxChargeCredits(estimated, pricing);
  const actual = computeActualChargeCredits(estimated, pricing);
  assertEquals(max, actual);
  assertEquals(max, 10.6);
});

// ---------------------------------------------------------------------------
// 7. Failed requests are not charged — pure math can't directly test
//    the handler flow, but we test that a zero-usage call with the
//    floor still respects minimum floor semantics (a $0.00 raw cost is
//    floored, NOT zero-credited). The handler's catch-block already
//    short-circuits before any charge call (see index.ts).
// ---------------------------------------------------------------------------

Deno.test(
  "pricing: a zero-token, zero-tool call is floored to minimum (not zero)",
  () => {
    // Important semantics: floor prevents free generations. The handler
    // never calls store.charge for failed LLM calls (catch block returns
    // early), but for any successfully-completed LLM call with absurdly
    // small output, the floor still applies.
    const pricing = makeSnapshot();
    const usage = makeUsage({
      uncachedInputTokens: 0,
      outputTokens: 0,
      toolCostUsd: 0,
    });
    assertEquals(computeActualChargeCredits(usage, pricing), 0.25);
  },
);
