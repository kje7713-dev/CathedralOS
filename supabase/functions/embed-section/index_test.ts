// =============================================================================
// embed-section HTTP-boundary tests (Kevin 2026-09-21 v2 #1).
//
// Asserts the customer-facing response when the upstream OpenAI call
// returns HTTP 429 with code=credit_balance_exhausted (or any equivalent
// non-retryable billing signal). The public message MUST be exactly
// "Temporarily unavailable — try again later." with no provider,
// billing, or quota wording leaked. Internal SectionEmbeddingError
// surface preserves the upstream code so the operator alert has it.
// =============================================================================

import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { embedSectionErrorResponse } from "./index.ts";
import { SectionEmbeddingError } from "../_shared/section-embedding.ts";

// Stub EdgeRuntime globally — the alert path calls EdgeRuntime.waitUntil
// but in test context the global is undefined. The try/catch in the
// handler swallows the error but logs noise; stubbing here keeps tests
// quiet. (EdgeRuntime IS defined in production via @supabase/functions-js
// shim; we just don't import that shim in deno test runs.)
// deno-lint-ignore no-explicit-any
(globalThis as any).EdgeRuntime = { waitUntil: (_p: Promise<unknown>) => {} };

Deno.test("embed-section: SectionEmbeddingError(code=provider_billing_unavailable) → HTTP 503 + exact friendly message", async () => {
  const err = new SectionEmbeddingError(
    "provider_billing_unavailable",
    "OpenAI extract 429 (upstream=credit_balance_exhausted): You have no credits remaining...",
  );
  const resp = embedSectionErrorResponse(err, {
    rpcClient: null,
    requestID: null,
    providerModel: null,
  });
  assertEquals(resp.status, 503);
  const body = await resp.json();
  assertEquals(body.errorCode, "provider_billing_unavailable");
  assertEquals(
    body.message,
    "Temporarily unavailable \u2014 try again later.",
  );
});

Deno.test("embed-section: friendly public message contains NONE of the forbidden provider / billing / quota words", async () => {
  const err = new SectionEmbeddingError(
    "provider_billing_unavailable",
    "OpenAI embed 429 (upstream=credit_balance_exhausted): You have no credits remaining on this organization. Check your API key billing.",
  );
  const resp = embedSectionErrorResponse(err, {
    rpcClient: null,
    requestID: null,
    providerModel: null,
  });
  const body = await resp.json();
  const msg = String(body.message).toLowerCase();
  for (
    const forbidden of [
      "openai",
      "credit",
      "balance",
      "billing",
      "insufficient",
      "quota",
      "organization",
      "api key",
      "apikey",
      "provider",
      "account",
      "exhaust",
    ]
  ) {
    assertEquals(
      msg.includes(forbidden),
      false,
      `public message must not contain forbidden word "${forbidden}", got: ${body.message}`,
    );
  }
});

Deno.test("embed-section: insufficient_credits HTTP-boundary remains 402 (no regression)", async () => {
  const err = { code: "insufficient_credits" };
  const resp = embedSectionErrorResponse(err, {
    rpcClient: null,
    requestID: null,
    providerModel: null,
  });
  assertEquals(resp.status, 402);
  const body = await resp.json();
  assertEquals(body.errorCode, "insufficient_credits");
  assertStringIncludes(
    String(body.message),
    "Insufficient credits",
  );
});

Deno.test("embed-section: generic provider_error remains 502 (no regression)", async () => {
  const err = new SectionEmbeddingError("provider_error", "OpenAI extract 500: oops");
  const resp = embedSectionErrorResponse(err, {
    rpcClient: null,
    requestID: null,
    providerModel: null,
  });
  assertEquals(resp.status, 502);
  const body = await resp.json();
  assertEquals(body.errorCode, "provider_error");
});
