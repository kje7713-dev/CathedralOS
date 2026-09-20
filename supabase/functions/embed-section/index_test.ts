import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { DirectBillingInsufficientCreditsError } from "../_shared/direct-billing.ts";
import { embedSectionErrorResponse } from "./index.ts";
import { SectionEmbeddingError } from "../_shared/section-embedding.ts";

Deno.test("embed-section preserves canonical insufficient-credit errors at HTTP boundary", async () => {
  // settleDirectUsage() produces this typed error after the atomic RPC reports
  // the raw entitlement-lock race message. The public adapter must not flatten
  // its code into provider_error or expose the RPC wording.
  const response = embedSectionErrorResponse(
    new DirectBillingInsufficientCreditsError(),
  );
  const body = await response.json();

  assertEquals(response.status, 402);
  assertEquals(body.errorCode, "insufficient_credits");
  assertEquals(
    body.message,
    "Insufficient credits for the next billable stage.",
  );
  assertStringIncludes(JSON.stringify(body), "insufficient_credits");
  assertEquals(
    JSON.stringify(body).includes("insufficient credits for stage"),
    false,
  );
});

Deno.test("embed-section still preserves SectionEmbeddingError responses", async () => {
  const response = embedSectionErrorResponse(
    new SectionEmbeddingError("provider_error", "provider unavailable"),
  );
  const body = await response.json();

  assertEquals(response.status, 502);
  assertEquals(body.errorCode, "provider_error");
});
