import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { availableCredits, normalizeUserEntitlement } from "./_credits.ts";

Deno.test("normalizeUserEntitlement converts PostgREST NUMERIC strings before arithmetic", () => {
  const entitlement = normalizeUserEntitlement({
    user_id: "u", plan_name: "free", is_pro: false,
    monthly_credit_allowance: "90.728480",
    purchased_credit_balance: "5.500000",
    current_period_start: null, current_period_end: null,
    entitlement_source: "test", updated_at: "2026-09-15T00:00:00Z",
  });
  assertEquals(entitlement.monthly_credit_allowance, 90.72848);
  assertEquals(entitlement.purchased_credit_balance, 5.5);
  assertEquals(availableCredits(entitlement), 96.22848);
});
