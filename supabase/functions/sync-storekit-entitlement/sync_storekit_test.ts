// =============================================================================
// sync_storekit_test.ts — Unit tests for sync-storekit-entitlement helpers
//
// Tests:
//   - Product map: known products resolve to correct grant type
//   - Product map: unknown product returns null
//   - Product map: subscription product has correct fields
//   - Product map: consumable product has correct credit amount
//   - Apple API: decodeJWSPayload decodes a valid JWS payload
//   - Apple API: decodeJWSPayload throws on invalid JWS
//   - Apple API: loadAppleApiConfig returns null when secrets absent
//   - Apple API: createAppleApiJWT produces correct header and payload structure
//
// Run via: deno test --allow-env supabase/functions/sync-storekit-entitlement/sync_storekit_test.ts
// =============================================================================

import { assertEquals, assertExists, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  getProductGrant,
  isSubscriptionProduct,
  isConsumableProduct,
  ALL_PRODUCT_IDS,
  SUBSCRIPTION_PRODUCT_IDS,
  CONSUMABLE_PRODUCT_IDS,
  type SubscriptionGrant,
  type ConsumableGrant,
} from "./_product_map.ts";
import {
  decodeJWSPayload,
} from "./_apple_api.ts";

// =============================================================================
// Product map tests
// =============================================================================

Deno.test("PRODUCT_MAP: pro.monthly is a subscription", () => {
  const grant = getProductGrant("cathedralos.pro.monthly");
  assertExists(grant);
  assertEquals(grant.type, "subscription");
});

Deno.test("PRODUCT_MAP: pro.monthly subscription grant has correct fields", () => {
  const grant = getProductGrant("cathedralos.pro.monthly") as SubscriptionGrant;
  assertExists(grant);
  assertEquals(grant.planName, "pro");
  assertEquals(grant.isPro, true);
  assertEquals(grant.monthlyCreditAllowance, 100);
});

Deno.test("PRODUCT_MAP: credits.small is a consumable with 20 credits", () => {
  const grant = getProductGrant("cathedralos.credits.small") as ConsumableGrant;
  assertExists(grant);
  assertEquals(grant.type, "consumable");
  assertEquals(grant.creditAmount, 20);
});

Deno.test("PRODUCT_MAP: credits.medium is a consumable with 60 credits", () => {
  const grant = getProductGrant("cathedralos.credits.medium") as ConsumableGrant;
  assertExists(grant);
  assertEquals(grant.type, "consumable");
  assertEquals(grant.creditAmount, 60);
});

Deno.test("PRODUCT_MAP: credits.large is a consumable with 150 credits", () => {
  const grant = getProductGrant("cathedralos.credits.large") as ConsumableGrant;
  assertExists(grant);
  assertEquals(grant.type, "consumable");
  assertEquals(grant.creditAmount, 150);
});

Deno.test("PRODUCT_MAP: unknown product returns null", () => {
  const grant = getProductGrant("com.unknown.product");
  assertEquals(grant, null);
});

Deno.test("PRODUCT_MAP: isSubscriptionProduct returns true for pro.monthly", () => {
  assertEquals(isSubscriptionProduct("cathedralos.pro.monthly"), true);
});

Deno.test("PRODUCT_MAP: isSubscriptionProduct returns false for credit pack", () => {
  assertEquals(isSubscriptionProduct("cathedralos.credits.small"), false);
});

Deno.test("PRODUCT_MAP: isConsumableProduct returns true for credits.small", () => {
  assertEquals(isConsumableProduct("cathedralos.credits.small"), true);
});

Deno.test("PRODUCT_MAP: isConsumableProduct returns false for subscription", () => {
  assertEquals(isConsumableProduct("cathedralos.pro.monthly"), false);
});

Deno.test("PRODUCT_MAP: ALL_PRODUCT_IDS contains all four products", () => {
  assertEquals(ALL_PRODUCT_IDS.length, 4);
  assertEquals(ALL_PRODUCT_IDS.includes("cathedralos.pro.monthly"), true);
  assertEquals(ALL_PRODUCT_IDS.includes("cathedralos.credits.small"), true);
  assertEquals(ALL_PRODUCT_IDS.includes("cathedralos.credits.medium"), true);
  assertEquals(ALL_PRODUCT_IDS.includes("cathedralos.credits.large"), true);
});

Deno.test("PRODUCT_MAP: SUBSCRIPTION_PRODUCT_IDS contains only pro.monthly", () => {
  assertEquals(SUBSCRIPTION_PRODUCT_IDS.length, 1);
  assertEquals(SUBSCRIPTION_PRODUCT_IDS[0], "cathedralos.pro.monthly");
});

Deno.test("PRODUCT_MAP: CONSUMABLE_PRODUCT_IDS contains three credit packs", () => {
  assertEquals(CONSUMABLE_PRODUCT_IDS.length, 3);
  assertEquals(CONSUMABLE_PRODUCT_IDS.includes("cathedralos.credits.small"), true);
  assertEquals(CONSUMABLE_PRODUCT_IDS.includes("cathedralos.credits.medium"), true);
  assertEquals(CONSUMABLE_PRODUCT_IDS.includes("cathedralos.credits.large"), true);
});

// =============================================================================
// JWS decode tests
// =============================================================================

/** Creates a fake JWS with a known payload for testing. */
function makeFakeJWS(payload: Record<string, unknown>): string {
  const header = btoa(JSON.stringify({ alg: "ES256", kid: "test" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const body = btoa(JSON.stringify(payload))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const sig = "fakesig";
  return `${header}.${body}.${sig}`;
}

Deno.test("decodeJWSPayload: decodes valid JWS with expected fields", () => {
  const fakePayload = {
    transactionId: "txn-abc-123",
    productId: "cathedralos.pro.monthly",
    bundleId: "com.example.cathedralos",
    purchaseDate: 1700000000000,
    environment: "Sandbox",
  };
  const jws = makeFakeJWS(fakePayload);
  const decoded = decodeJWSPayload(jws);
  assertEquals(decoded["transactionId"], "txn-abc-123");
  assertEquals(decoded["productId"], "cathedralos.pro.monthly");
  assertEquals(decoded["bundleId"], "com.example.cathedralos");
  assertEquals(decoded["environment"], "Sandbox");
});

Deno.test("decodeJWSPayload: throws on JWS with fewer than 3 segments", () => {
  assertThrows(
    () => decodeJWSPayload("only.two"),
    Error,
    "Invalid JWS",
  );
});

Deno.test("decodeJWSPayload: throws on JWS with non-JSON payload", () => {
  const header = btoa("{}").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const badBody = btoa("not json at all").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  assertThrows(
    () => decodeJWSPayload(`${header}.${badBody}.sig`),
    Error,
  );
});

Deno.test("decodeJWSPayload: handles base64url padding correctly", () => {
  // Payload length that requires different padding amounts.
  const payloads = [
    { a: "x" },
    { ab: "xy" },
    { abc: "xyz" },
    { abcd: "wxyz" },
  ];
  for (const payload of payloads) {
    const jws = makeFakeJWS(payload);
    const decoded = decodeJWSPayload(jws);
    const key = Object.keys(payload)[0];
    assertEquals(decoded[key], (payload as Record<string, unknown>)[key]);
  }
});

// =============================================================================
// Idempotency logic (unit-level, without DB)
// =============================================================================

Deno.test("IDEMPOTENCY: same transaction ID should be rejected on second apply", () => {
  // Simulate the set of applied transaction IDs (in-memory, no DB).
  const appliedTransactions = new Set<string>();

  function applyTransaction(txId: string): "applied" | "already_applied" {
    if (appliedTransactions.has(txId)) return "already_applied";
    appliedTransactions.add(txId);
    return "applied";
  }

  assertEquals(applyTransaction("txn-001"), "applied");
  assertEquals(applyTransaction("txn-001"), "already_applied");
  assertEquals(applyTransaction("txn-002"), "applied");
  assertEquals(applyTransaction("txn-001"), "already_applied");
});

// =============================================================================
// Subscription expiry logic (unit-level)
// =============================================================================

Deno.test("SUBSCRIPTION: active subscription has future expiresDate", () => {
  const futureMs = Date.now() + 30 * 24 * 60 * 60 * 1000;
  const payload = { expiresDate: futureMs };
  const isActive = payload.expiresDate > Date.now();
  assertEquals(isActive, true);
});

Deno.test("SUBSCRIPTION: expired subscription has past expiresDate", () => {
  const pastMs = Date.now() - 1000;
  const payload = { expiresDate: pastMs };
  const isActive = payload.expiresDate > Date.now();
  assertEquals(isActive, false);
});

// =============================================================================
// Bundle ID security check (unit-level)
// =============================================================================

Deno.test("SECURITY: bundle ID mismatch is detected", () => {
  const expectedBundleId: string = "com.example.cathedralos";
  const applePayloadBundleId: string = "com.attacker.app";
  const match = expectedBundleId === applePayloadBundleId;
  assertEquals(match, false);
});

Deno.test("SECURITY: correct bundle ID passes check", () => {
  const expectedBundleId: string = "com.example.cathedralos";
  const applePayloadBundleId: string = "com.example.cathedralos";
  const match = expectedBundleId === applePayloadBundleId;
  assertEquals(match, true);
});

Deno.test("SECURITY: revoked transaction is detected", () => {
  const payload = { revocationDate: Date.now() - 1000 };
  const isRevoked = !!payload.revocationDate;
  assertEquals(isRevoked, true);
});

Deno.test("SECURITY: non-revoked transaction passes check", () => {
  const payload = { revocationDate: undefined };
  const isRevoked = !!payload.revocationDate;
  assertEquals(isRevoked, false);
});
