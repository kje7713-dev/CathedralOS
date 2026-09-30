import {
  assertEquals,
  assertGreater,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  actualAiCoverBilling,
  AI_COVER_IMAGE_OUTPUT_TOKENS,
  estimateAiCoverBilling,
} from "./_cover_billing.ts";

Deno.test("AI cover pricing charges exactly 20 credits", () => {
  const billing = actualAiCoverBilling(
    1000,
    AI_COVER_IMAGE_OUTPUT_TOKENS,
    "cover prompt",
  );

  // Provider usage affects telemetry only; the authoritative customer charge
  // is the fixed 20-credit AI-cover product price.
  assertEquals(billing.actualCharge, 20);
  assertGreater(billing.customerRevenueCents, billing.providerCogsCents);
  assertEquals(billing.providerCogsCents, 25.46);
});

Deno.test("AI cover preflight covers the configured portrait output budget", () => {
  const billing = estimateAiCoverBilling("A cohesive story-wide cover prompt.");
  assertEquals(billing.usage.outputTokens, AI_COVER_IMAGE_OUTPUT_TOKENS);
  assertEquals(billing.actualCharge, 20);
});

Deno.test("AI cover billing falls back to conservative usage when provider omits it", () => {
  const billing = actualAiCoverBilling(undefined, undefined, "A short prompt");
  assertEquals(billing.usage.outputTokens, AI_COVER_IMAGE_OUTPUT_TOKENS);
  assertEquals(billing.actualCharge, 20);
});
