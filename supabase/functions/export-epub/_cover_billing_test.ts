import {
  assertEquals,
  assertGreater,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  actualAiCoverBilling,
  AI_COVER_IMAGE_OUTPUT_TOKENS,
  estimateAiCoverBilling,
} from "./_cover_billing.ts";

Deno.test("AI cover pricing charges actual image-token usage plus markup", () => {
  const billing = actualAiCoverBilling(
    1000,
    AI_COVER_IMAGE_OUTPUT_TOKENS,
    "cover prompt",
  );

  // gpt-image-1 high portrait output: 6,240 × $40/1M × 2x / $0.01
  // plus 1,000 text input tokens at $5/1M × 2x / $0.01 = 51 credits.
  assertEquals(billing.actualCharge, 51);
  assertGreater(billing.customerRevenueCents, billing.providerCogsCents);
  assertEquals(billing.providerCogsCents, 25.46);
});

Deno.test("AI cover preflight covers the configured portrait output budget", () => {
  const billing = estimateAiCoverBilling("A cohesive story-wide cover prompt.");
  assertEquals(billing.usage.outputTokens, AI_COVER_IMAGE_OUTPUT_TOKENS);
  assertEquals(billing.actualCharge, 50);
});

Deno.test("AI cover billing falls back to conservative usage when provider omits it", () => {
  const billing = actualAiCoverBilling(undefined, undefined, "A short prompt");
  assertEquals(billing.usage.outputTokens, AI_COVER_IMAGE_OUTPUT_TOKENS);
  assertGreater(billing.actualCharge, 49);
});
