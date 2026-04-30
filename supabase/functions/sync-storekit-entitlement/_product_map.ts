// =============================================================================
// _product_map.ts — Centralized App Store product → entitlement mapping
//
// This is the SINGLE SOURCE OF TRUTH for product IDs and what they grant.
// Do NOT scatter product ID logic across multiple Edge Functions.
//
// Keep in sync with:
//   iOS: StoreKitProductIDs.swift
//   iOS: StoreKitEntitlementModel.swift (StoreKitPlan.monthlyCreditAllowance)
//
// Adding a new product:
//   1. Add the product ID to the map below.
//   2. Assign the correct type ("subscription" | "consumable").
//   3. Fill in the grant fields for that type.
//   4. Update StoreKitProductIDs.swift on iOS.
// =============================================================================

// ---------------------------------------------------------------------------
// Subscription product grant
// ---------------------------------------------------------------------------

export interface SubscriptionGrant {
  type: "subscription";
  /** Value to write to user_entitlements.plan_name */
  planName: string;
  /** Value to write to user_entitlements.is_pro */
  isPro: boolean;
  /** Value to write to user_entitlements.monthly_credit_allowance */
  monthlyCreditAllowance: number;
}

// ---------------------------------------------------------------------------
// Consumable (credit pack) product grant
// ---------------------------------------------------------------------------

export interface ConsumableGrant {
  type: "consumable";
  /** Credits to add to user_entitlements.purchased_credit_balance */
  creditAmount: number;
}

export type ProductGrant = SubscriptionGrant | ConsumableGrant;

// ---------------------------------------------------------------------------
// Product map
// ---------------------------------------------------------------------------

export const PRODUCT_MAP: Record<string, ProductGrant> = {
  // Subscriptions
  "cathedralos.pro.monthly": {
    type: "subscription",
    planName: "pro",
    isPro: true,
    monthlyCreditAllowance: 100,
  },

  // Consumable credit packs (amounts mirror StoreKitProductIDs.creditAmount)
  "cathedralos.credits.small": {
    type: "consumable",
    creditAmount: 20,
  },
  "cathedralos.credits.medium": {
    type: "consumable",
    creditAmount: 60,
  },
  "cathedralos.credits.large": {
    type: "consumable",
    creditAmount: 150,
  },
};

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

/** Returns the grant for a product ID, or null if unknown. */
export function getProductGrant(productId: string): ProductGrant | null {
  return PRODUCT_MAP[productId] ?? null;
}

/** Returns true if the product ID is a known subscription. */
export function isSubscriptionProduct(productId: string): boolean {
  const grant = PRODUCT_MAP[productId];
  return grant?.type === "subscription";
}

/** Returns true if the product ID is a known consumable credit pack. */
export function isConsumableProduct(productId: string): boolean {
  const grant = PRODUCT_MAP[productId];
  return grant?.type === "consumable";
}

/** All known product IDs. */
export const ALL_PRODUCT_IDS = Object.keys(PRODUCT_MAP);

/** All known subscription product IDs. */
export const SUBSCRIPTION_PRODUCT_IDS = ALL_PRODUCT_IDS.filter(
  (id) => PRODUCT_MAP[id].type === "subscription",
);

/** All known consumable product IDs. */
export const CONSUMABLE_PRODUCT_IDS = ALL_PRODUCT_IDS.filter(
  (id) => PRODUCT_MAP[id].type === "consumable",
);
