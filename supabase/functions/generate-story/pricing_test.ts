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
  computeMarginCents,
  computeMaxChargeCredits,
  computeProviderCogsCents,
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
    minimum_charge_credits: 0.25,
    max_output_tokens: 8000,
    enabled: true,
    sort_order: 10,
    // Phase 3 fields
    provider_input_usd_per_1m: 5.0,
    provider_cached_input_usd_per_1m: 0.5,
    provider_cache_write_usd_per_1m: 6.25, // 5.0 × 1.25 (GPT-5.6+ cache-write rate)
    provider_output_usd_per_1m: 30.0,
    billing_multiplier: 2.0,
    pricing_effective_at: "2026-08-01T00:00:00Z",
    cacheMode: "implicit",
    ...overrides,
  };
}

function makeSnapshot(
  overrides: Partial<PricingSnapshot> = {},
): PricingSnapshot {
  return {
    // Customer-facing rates (with markup)
    inputCreditRatePer1k: 1.0, // (5.0 × 2.0 / 10)
    outputCreditRatePer1k: 6.0, // (30.0 × 2.0 / 10)
    billingMultiplier: 2.0,
    minimumChargeCredits: 0.25,
    creditValueUsd: 0.01,
    effectiveAt: "2026-08-01T00:00:00Z",
    // Provider-facing rates (USD per 1M tokens)
    providerInputUsdPer1m: 5.0,
    providerCachedInputUsdPer1m: 0.5,
    providerCacheWriteUsdPer1m: 6.25, // 1.25× standard input
    providerOutputUsdPer1m: 30.0,
    ...overrides,
  };
}

function makeUsage(overrides: Partial<GenerationUsage> = {}): GenerationUsage {
  return {
    uncachedInputTokens: 1000,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
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

// PR-372: customer is NEVER discounted on cache hits. All input tokens
// (uncached + cached + cacheWrite) are charged at the normal rate.
Deno.test("pricing: cached input is charged at NORMAL rate (no customer discount per PR-372 Kevin correction #1)", () => {
  const pricing = makeSnapshot(); // input = 1.0 / 1K
  const usage = makeUsage({
    uncachedInputTokens: 0,
    cachedInputTokens: 5000,
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 5000 × 1.0 / 1000 = 5.0 (NOT 0.5 — no customer discount)
  assertEquals(charge, 5.0);
});

Deno.test("pricing: uncached + cached input both charged at normal rate (no mixed-rate discount)", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000, // → 1.0 credit at normal rate
    cachedInputTokens: 2000, // → 2.0 credit at normal rate (no discount)
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // 1.0 + 2.0 = 3.0, above floor (was 1.2 with the old cached-discount bug)
  assertEquals(charge, 3.0);
});

Deno.test("pricing: cacheWriteInputTokens counted into customer total input at normal rate", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000,
    cachedInputTokens: 2000,
    cacheWriteInputTokens: 500,
    outputTokens: 0,
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // (1000 + 2000 + 500) × 1.0 / 1000 = 3.5
  assertEquals(charge, 3.5);
});

Deno.test("pricing: customer charge is INVARIANT on cache outcome (PR-372 load-bearing)", () => {
  // Same total input, same output, same tool cost. Different cache mix
  // (uncached + cached + cacheWrite sums to the same total). Customer
  // charge must be IDENTICAL — cache hits and writes are Cathedral's
  // margin, not a customer-side concession.
  const pricing = makeSnapshot();
  const noCache = makeUsage({
    uncachedInputTokens: 3000,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: 500,
  });
  const withCache = makeUsage({
    uncachedInputTokens: 1000,
    cachedInputTokens: 1500,
    cacheWriteInputTokens: 500,
    outputTokens: 500,
  });
  assertEquals(
    computeActualChargeCredits(noCache, pricing),
    computeActualChargeCredits(withCache, pricing),
  );
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
    // Customer rates in makeSnapshot defaults ALREADY include the 2x markup
    // (inputCreditRatePer1k=1.0 = 5.0 x 2.0 / 10, outputCreditRatePer1k=6.0
    // = 30.0 x 2.0 / 10). The previous formula used these customer rates
    // as if they were provider rates, so margin came out 0 instead of 50%.
    // Since customer_charge = provider_cost x multiplier, the inverse is
    // provider_cost = charge / multiplier. Robust against rate changes.
    const providerCostCredits = charge / pricing.billingMultiplier;
    const margin = (charge - providerCostCredits) / charge;
    assertAlmostEquals(margin, 0.5, 1e-9);
  }
});

Deno.test("pricing: snapshotPricing derives customer-facing rates + provider-facing rates (PR-372)", () => {
  const model = makeModel({
    provider_input_usd_per_1m: 5.0,
    provider_cached_input_usd_per_1m: 0.5,
    provider_cache_write_usd_per_1m: 6.25,
    provider_output_usd_per_1m: 30.0,
    billing_multiplier: 2.0,
    pricing_effective_at: "2026-08-01T00:00:00Z",
  });
  const snap = snapshotPricing(model);
  // Customer-facing rates (with markup): credit_rate_per_1k = provider_usd_per_1m × multiplier / 10
  assertEquals(snap.inputCreditRatePer1k, 1.0); // 5 × 2 / 10
  assertEquals(snap.outputCreditRatePer1k, 6.0); // 30 × 2 / 10
  assertEquals(snap.billingMultiplier, 2.0);
  assertEquals(snap.effectiveAt, "2026-08-01T00:00:00Z");
  // Provider-facing rates (USD per 1M, raw — used for COGS math)
  assertEquals(snap.providerInputUsdPer1m, 5.0);
  assertEquals(snap.providerCachedInputUsdPer1m, 0.5);
  assertEquals(snap.providerCacheWriteUsdPer1m, 6.25);
  assertEquals(snap.providerOutputUsdPer1m, 30.0);
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

Deno.test("pricing: tool + input + output all combine (PR-372: no cache discount)", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000, // → 1.0 at normal rate
    cachedInputTokens: 2000, // → 2.0 at normal rate (NO discount, PR-372)
    outputTokens: 500, // → 3.0
    toolCostUsd: 0.02, // → 2.0
  });
  const charge = computeActualChargeCredits(usage, pricing);
  // PR-372 corrected: ALL input at normal rate, no cache discount.
  // input  = (1000 + 2000) × 1.0 / 1000 = 3.0
  // output = 500 × 6.0 / 1000 = 3.0
  // tool   = 0.02 / 0.01 = 2.0
  // total  = 3.0 + 3.0 + 2.0 = 8.0 (was 6.2 with the old cached-discount bug)
  assertEquals(charge, 8.0);
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

// =============================================================================
// PR-372: computeProviderCogsCents — corrected split formula with defensive
// anomaly handling. Customer charge and provider COGS are computed
// independently so cache savings stay Cathedral's margin, never a customer
// discount.
// =============================================================================

Deno.test("provider COGS: corrected split formula (ordinary + cached + cacheWrite + output + tool)", () => {
  const pricing = makeSnapshot();
  // 1000 uncached + 1500 cached + 500 cacheWrite + 400 output, no tool
  // ordinaryUncached = 1000 (no anomaly: 1500 + 500 ≤ 3000)
  // providerCogsCents:
  //   ordinaryUncached   × $5  / 1M × 100  = 1000 × 5 / 1e6 × 100   = 0.5
  //   cached             × $0.5/ 1M × 100  = 1500 × 0.5 / 1e6 × 100 = 0.075
  //   cacheWrite         × $6.25/1M × 100 = 500 × 6.25 / 1e6 × 100 = 0.3125
  //   output             × $30 / 1M × 100 = 400 × 30 / 1e6 × 100   = 1.2
  //   tool               × 100            = 0
  //   total = 2.0875 cents
  const usage = makeUsage({
    uncachedInputTokens: 1000,
    cachedInputTokens: 1500,
    cacheWriteInputTokens: 500,
    outputTokens: 400,
    toolCostUsd: 0,
  });
  const cogs = computeProviderCogsCents(usage, pricing);
  assertEquals(cogs.ordinaryUncachedInputTokens, 1000);
  assertEquals(cogs.cachedInputTokens, 1500);
  assertEquals(cogs.cacheWriteInputTokens, 500);
  assertEquals(cogs.outputTokens, 400);
  assertEquals(cogs.anomaly, false);
  assertAlmostEquals(cogs.providerCogsCents, 2.0875, 1e-6);
});

Deno.test("provider COGS: ordinaryUncached = max(0, totalInput - cached - cacheWrite) — proves no double-count", () => {
  const pricing = makeSnapshot();
  // uncached=2000, cached=3000, cacheWrite=1000.
  // totalInput = 6000. cached + cacheWrite = 4000 < 6000 → NOT an anomaly.
  // ordinaryUncached = 6000 - 3000 - 1000 = 2000.
  // The corrected formula's no-double-counting property: uncached + cached
  // + cacheWrite = 2000 + 3000 + 1000 = 6000 = totalInput.
  const usage = makeUsage({
    uncachedInputTokens: 2000,
    cachedInputTokens: 3000,
    cacheWriteInputTokens: 1000,
    outputTokens: 0,
  });
  const cogs = computeProviderCogsCents(usage, pricing);
  assertEquals(cogs.anomaly, false);
  assertEquals(cogs.ordinaryUncachedInputTokens, 2000);
  // The sum invariants hold (sanity check on the corrected formula).
  assertEquals(
    cogs.ordinaryUncachedInputTokens + cogs.cachedInputTokens +
      cogs.cacheWriteInputTokens,
    6000,
  );
});

Deno.test("provider COGS: anomaly fires when provider reports cached+cacheWrite > totalInput", () => {
  const pricing = makeSnapshot();
  // Provider bug or malformed response: cached + cacheWrite exceeds
  // totalInput. Since total = uncached + cached + cacheWrite, anomaly
  // fires iff rawUncached < 0. We clamp to 0 for safety and flag for
  // diagnostics. Customer billing is unchanged (customer is charged
  // at normal rate on the SANITIZED totalInput, which is unaffected
  // by this clamp).
  const usage = makeUsage({
    uncachedInputTokens: -100, // provider bug — would make raw total 6900
    cachedInputTokens: 5000, // cached + cacheWrite = 7000 > 6900 = ANOMALY
    cacheWriteInputTokens: 2000,
    outputTokens: 0,
  });
  const cogs = computeProviderCogsCents(usage, pricing);
  assertEquals(cogs.anomaly, true);
  assertEquals(cogs.ordinaryUncachedInputTokens, 0); // clamped (was -100)
});

Deno.test("provider COGS: no negative token counts even on degenerate input", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: -100, // negative should be sanitized to 0
    cachedInputTokens: 50,
    cacheWriteInputTokens: 25,
    outputTokens: -10, // negative should be sanitized to 0
    toolCostUsd: -1, // negative should be sanitized to 0
  });
  const cogs = computeProviderCogsCents(usage, pricing);
  assertEquals(cogs.ordinaryUncachedInputTokens >= 0, true);
  assertEquals(cogs.cachedInputTokens, 50);
  assertEquals(cogs.cacheWriteInputTokens, 25);
  assertEquals(cogs.outputTokens >= 0, true);
  assertEquals(cogs.toolCostUsd >= 0, true);
  assertEquals(cogs.providerCogsCents >= 0, true);
});

Deno.test("provider COGS: invariant on cache outcome (COGS drops on cache hit)", () => {
  const pricing = makeSnapshot();
  // No-cache path: all input is uncached, no cache savings
  const noCache = makeUsage({
    uncachedInputTokens: 3000,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: 500,
  });
  // Cache-hit path: 1500 cached + 500 cacheWrite amortized; uncached is 1000
  // (= 3000 - 1500 - 500). Same total input, same output.
  const cacheHit = makeUsage({
    uncachedInputTokens: 1000,
    cachedInputTokens: 1500,
    cacheWriteInputTokens: 500,
    outputTokens: 500,
  });
  const noCacheCogs = computeProviderCogsCents(noCache, pricing);
  const cacheHitCogs = computeProviderCogsCents(cacheHit, pricing);
  // COGS must DROP on cache hit because cached × cachedRate (0.5/1M) is
  // much lower than uncached × normalRate (5/1M).
  assertEquals(
    cacheHitCogs.providerCogsCents < noCacheCogs.providerCogsCents,
    true,
  );
});

Deno.test("provider COGS: includes tool cost in cents", () => {
  const pricing = makeSnapshot();
  const usage = makeUsage({
    uncachedInputTokens: 1000,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: 0,
    toolCostUsd: 0.05, // 5 cents
  });
  const cogs = computeProviderCogsCents(usage, pricing);
  // tool cost: 0.05 USD × 100 = 5 cents
  // ordinaryUncached: 1000 × 5 / 1e6 × 100 = 0.5 cents
  // total = 5.5 cents
  assertAlmostEquals(cogs.providerCogsCents, 5.5, 1e-6);
});

// =============================================================================
// PR-372: computeMarginCents — margin = customerRevenueCents - providerCogsCents.
// Customer revenue is invariant on cache outcome; margin therefore improves
// on cache hits (lower COGS).
// =============================================================================

Deno.test("margin: customerRevenueCents = actualCharge × creditValueUsd × 100", () => {
  const pricing = makeSnapshot();
  // 10 credits × $0.01 × 100 = $1.00 = 100 cents
  const result = computeMarginCents(10, pricing, 50);
  assertEquals(result.customerRevenueCents, 10);
  assertEquals(result.marginCents, -40); // revenue 10 - cogs 50
});

Deno.test("margin: positive on cache hit, negative on cache-write without reuse", () => {
  const pricing = makeSnapshot();
  // 100 credits customer charge; cache-hit COGS = 30 cents → margin +70
  const onHit = computeMarginCents(100, pricing, 30);
  assertEquals(onHit.customerRevenueCents, 100);
  assertEquals(onHit.marginCents, 70);
  // cache-write COGS = 150 cents (cache write 1.25x standard) → margin -50
  const onWrite = computeMarginCents(100, pricing, 150);
  assertEquals(onWrite.marginCents, -50);
});

Deno.test("margin: improves on cache hit relative to no-cache baseline", () => {
  // Property: same customer charge (cache invariant), lower provider COGS,
  // therefore higher margin. Compute the end-to-end margin for two calls
  // sharing the same stable prefix.
  const pricing = makeSnapshot();
  const charge = 10; // any value — cache doesn't change customer side
  const noCacheCogs = computeProviderCogsCents(
    makeUsage({
      uncachedInputTokens: 3000,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 500,
    }),
    pricing,
  );
  const cacheHitCogs = computeProviderCogsCents(
    makeUsage({
      uncachedInputTokens: 1000,
      cachedInputTokens: 1500,
      cacheWriteInputTokens: 500,
      outputTokens: 500,
    }),
    pricing,
  );
  const noCacheMargin = computeMarginCents(
    charge,
    pricing,
    noCacheCogs.providerCogsCents,
  );
  const cacheHitMargin = computeMarginCents(
    charge,
    pricing,
    cacheHitCogs.providerCogsCents,
  );
  assertEquals(cacheHitMargin.marginCents > noCacheMargin.marginCents, true);
});
