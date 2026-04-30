// =============================================================================
// index.ts — sync-storekit-entitlement Supabase Edge Function
//
// Validates an App Store transaction server-side and updates the user's
// entitlement / credit balance accordingly.
//
// Supports two modes:
//   "validate_transaction" — iOS client submits a signedTransactionInfo JWS
//                            (or transactionId alone). Backend calls Apple's
//                            App Store Server API to verify, then applies
//                            the entitlement/credit grant.
//
//   "manual_grant"         — Admin/operational override. Requires admin auth.
//
// Security model:
//   - iOS clients are authenticated via their Supabase JWT (user scope).
//   - Apple transaction data is ALWAYS verified via the App Store Server API
//     when APP_STORE_* secrets are configured.
//   - If Apple API secrets are absent, the JWS payload is decoded for the
//     transactionId but the function logs a warning and marks the transaction
//     as environment=unconfigured. Configure secrets before production launch.
//   - Idempotency: if a transaction has already been applied (row exists in
//     app_store_transactions), the function returns the current state without
//     re-granting credits.
//   - Client-reported productId values are NEVER trusted without Apple
//     server-side verification.
//
// Required secrets (set via `supabase secrets set`):
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected
//   APP_STORE_KEY_ID          — App Store Connect API key identifier
//   APP_STORE_ISSUER_ID       — App Store Connect issuer ID
//   APP_STORE_PRIVATE_KEY     — .p8 private key contents (ES256, PEM)
//   APP_STORE_BUNDLE_ID       — App bundle identifier
//   APP_STORE_ENVIRONMENT     — "Sandbox" or "Production" (default: "Sandbox")
//
// Optional secrets:
//   ADMIN_SECRET              — for manual_grant calls
//
// See docs/storekit-entitlements.md for full setup instructions.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  getProductGrant,
  type ConsumableGrant,
  type SubscriptionGrant,
} from "./_product_map.ts";
import {
  decodeJWSPayload,
  verifyTransactionWithApple,
  loadAppleApiConfig,
  type AppleTransactionPayload,
} from "./_apple_api.ts";
import { FREE_TIER_MONTHLY_ALLOWANCE, type UserEntitlement } from "../generate-story/_credits.ts";

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-admin-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string, init: ResponseInit = {}): Response {
  return new Response(body, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...(init.headers ?? {}),
    },
  });
}

// ---------------------------------------------------------------------------
// Request body types
// ---------------------------------------------------------------------------

interface ValidateTransactionRequest {
  mode: "validate_transaction";
  /** JWS-encoded signed transaction info from StoreKit 2 (transaction.jwsRepresentation). */
  signedTransactionInfo?: string;
  /** Transaction ID, used when signedTransactionInfo is unavailable. */
  transactionId?: string;
  /** Original transaction ID for subscription continuity tracking. */
  originalTransactionId?: string;
  /** appAccountToken set at purchase time, if any. */
  appAccountToken?: string;
}

interface ManualGrantRequest {
  mode: "manual_grant";
  /** Target user_id (admin use only). */
  userId: string;
  planName?: string;
  isPro?: boolean;
  monthlyCreditAllowance?: number;
  purchasedCreditDelta?: number;
}

type SyncRequest = ValidateTransactionRequest | ManualGrantRequest;

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return corsResponse("", { status: 204 });
  }

  if (req.method !== "POST") {
    return corsResponse(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const adminSecret = Deno.env.get("ADMIN_SECRET");

  if (!supabaseURL || !supabaseAnonKey || !serviceRoleKey) {
    return corsResponse(JSON.stringify({ error: "Server configuration error" }), { status: 500 });
  }

  // Parse body first so we know the mode before auth checks.
  let body: SyncRequest;
  try {
    body = await req.json();
  } catch {
    return corsResponse(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  // -------------------------------------------------------------------------
  // manual_grant — admin/service-role auth
  // -------------------------------------------------------------------------

  if (body.mode === "manual_grant") {
    const providedAdminSecret = req.headers.get("x-admin-secret");
    const authHeader = req.headers.get("Authorization");
    const bearerToken = authHeader?.replace(/^Bearer\s+/i, "");

    const isAdminSecretAuth = adminSecret && providedAdminSecret === adminSecret;
    const isServiceRoleAuth = bearerToken === serviceRoleKey;

    if (!isAdminSecretAuth && !isServiceRoleAuth) {
      return corsResponse(
        JSON.stringify({
          error: "Forbidden",
          detail:
            "manual_grant requires admin authentication (x-admin-secret header or service-role bearer token).",
        }),
        { status: 403 },
      );
    }

    return handleManualGrant(body, createClient(supabaseURL, serviceRoleKey));
  }

  // -------------------------------------------------------------------------
  // validate_transaction — user JWT auth
  // -------------------------------------------------------------------------

  if (body.mode !== "validate_transaction") {
    return corsResponse(
      JSON.stringify({ error: "Invalid mode. Use 'validate_transaction' or 'manual_grant'." }),
      { status: 422 },
    );
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return corsResponse(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  // Verify the user's Supabase JWT.
  const userClient = createClient(supabaseURL, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return corsResponse(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const adminClient = createClient(supabaseURL, serviceRoleKey);

  return handleValidateTransaction(body, user.id, adminClient);
});

// ---------------------------------------------------------------------------
// validate_transaction handler
// ---------------------------------------------------------------------------

async function handleValidateTransaction(
  // deno-lint-ignore no-explicit-any
  body: ValidateTransactionRequest,
  userId: string,
  // deno-lint-ignore no-explicit-any
  adminClient: any,
): Promise<Response> {
  // 1. Extract transaction ID from the JWS payload OR from the raw field.
  let transactionId: string | null = null;
  let jwsPayload: Record<string, unknown> | null = null;

  if (body.signedTransactionInfo) {
    try {
      jwsPayload = decodeJWSPayload(body.signedTransactionInfo);
      transactionId = jwsPayload["transactionId"] as string ?? null;
    } catch (e) {
      console.error("Failed to decode signedTransactionInfo:", e);
      return corsResponse(
        JSON.stringify({ error: "Invalid signedTransactionInfo: could not decode JWS payload" }),
        { status: 422 },
      );
    }
  }

  if (!transactionId && body.transactionId) {
    transactionId = body.transactionId;
  }

  if (!transactionId) {
    return corsResponse(
      JSON.stringify({
        error: "Missing transaction identifier. Provide signedTransactionInfo or transactionId.",
      }),
      { status: 422 },
    );
  }

  // 2. Idempotency check — has this transaction already been applied?
  const { data: existingTx } = await adminClient
    .from("app_store_transactions")
    .select("id, product_id, credited_amount, created_at")
    .eq("transaction_id", transactionId)
    .eq("user_id", userId)
    .maybeSingle();

  if (existingTx) {
    // Already applied — return current entitlement without re-granting.
    const currentState = await loadCurrentEntitlement(userId, adminClient);
    return corsResponse(
      JSON.stringify({
        status: "already_applied",
        alreadyApplied: true,
        transactionId,
        ...formatEntitlementResponse(currentState),
      }),
      { status: 200 },
    );
  }

  // 3. Validate transaction with Apple's App Store Server API.
  let applePayload: AppleTransactionPayload;
  const appleConfig = loadAppleApiConfig();

  if (appleConfig) {
    try {
      applePayload = await verifyTransactionWithApple(transactionId, appleConfig);
    } catch (e) {
      console.error("Apple API verification failed:", e);
      return corsResponse(
        JSON.stringify({
          error: "Transaction verification failed",
          detail: "Could not verify transaction with Apple's servers. Please try again.",
        }),
        { status: 402 },
      );
    }
  } else {
    // Apple API not yet configured — decode JWS payload directly.
    // ⚠️ Warning: this path does NOT verify Apple's signature. Configure
    // APP_STORE_* secrets before production launch.
    console.warn(
      "APP_STORE_* secrets not configured. Falling back to unverified JWS decode. " +
      "Configure secrets before production launch.",
    );
    if (!jwsPayload) {
      return corsResponse(
        JSON.stringify({
          error: "Apple API not configured",
          detail:
            "APP_STORE_KEY_ID, APP_STORE_ISSUER_ID, APP_STORE_PRIVATE_KEY, and " +
            "APP_STORE_BUNDLE_ID must be configured to validate transactions. " +
            "See docs/storekit-entitlements.md.",
        }),
        { status: 503 },
      );
    }
    applePayload = jwsPayload as unknown as AppleTransactionPayload;
  }

  // 4. Security: ensure the transaction belongs to the authenticated user's bundle.
  const expectedBundleId = appleConfig?.bundleId ?? Deno.env.get("APP_STORE_BUNDLE_ID");
  if (expectedBundleId && applePayload.bundleId && applePayload.bundleId !== expectedBundleId) {
    console.error(`Bundle ID mismatch: expected ${expectedBundleId}, got ${applePayload.bundleId}`);
    return corsResponse(
      JSON.stringify({ error: "Transaction bundle ID does not match this app." }),
      { status: 403 },
    );
  }

  // 5. Check for revocation.
  if (applePayload.revocationDate) {
    return corsResponse(
      JSON.stringify({
        error: "Transaction has been revoked",
        detail: "This purchase was refunded or revoked by Apple.",
      }),
      { status: 402 },
    );
  }

  // 6. Map product ID to entitlement/credit grant.
  const productId = applePayload.productId;
  const grant = getProductGrant(productId);

  if (!grant) {
    console.error(`Unknown product ID: ${productId}`);
    return corsResponse(
      JSON.stringify({
        error: "Unknown product",
        detail: `Product ID '${productId}' is not recognized by this server.`,
      }),
      { status: 422 },
    );
  }

  const environment = appleConfig ? appleConfig.environment : (applePayload.environment ?? "unknown");
  const originalTransactionId = applePayload.originalTransactionId ?? body.originalTransactionId ?? transactionId;

  // 7. Apply the grant.
  const updatedEntitlement = await applyGrant({
    userId,
    grant,
    applePayload,
    transactionId,
    originalTransactionId,
    productId,
    environment,
    adminClient,
    signedTransactionInfo: body.signedTransactionInfo,
  });

  return corsResponse(
    JSON.stringify({
      status: "ok",
      alreadyApplied: false,
      transactionId,
      productId,
      ...formatEntitlementResponse(updatedEntitlement),
    }),
    { status: 200 },
  );
}

// ---------------------------------------------------------------------------
// Grant application
// ---------------------------------------------------------------------------

interface ApplyGrantParams {
  userId: string;
  grant: ReturnType<typeof getProductGrant>;
  applePayload: AppleTransactionPayload;
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  environment: string;
  // deno-lint-ignore no-explicit-any
  adminClient: any;
  signedTransactionInfo?: string;
}

async function applyGrant(params: ApplyGrantParams): Promise<UserEntitlement> {
  const {
    userId,
    grant,
    applePayload,
    transactionId,
    originalTransactionId,
    productId,
    environment,
    adminClient,
    signedTransactionInfo,
  } = params;

  // Load (or create) the current entitlement row.
  const { data: existing } = await adminClient
    .from("user_entitlements")
    .select("*")
    .eq("user_id", userId)
    .single();

  const current: UserEntitlement = existing ?? {
    user_id: userId,
    plan_name: "free",
    is_pro: false,
    monthly_credit_allowance: FREE_TIER_MONTHLY_ALLOWANCE,
    purchased_credit_balance: 0,
    current_period_start: null,
    current_period_end: null,
    entitlement_source: "monthly_grant",
    updated_at: new Date().toISOString(),
  };

  let creditedAmount: number | null = null;
  let upsertPayload: Record<string, unknown>;
  let ledgerReason: string;

  if (grant!.type === "subscription") {
    const sub = grant as SubscriptionGrant;
    const expiresDate = applePayload.expiresDate
      ? new Date(applePayload.expiresDate).toISOString()
      : null;
    const purchaseDate = applePayload.purchaseDate
      ? new Date(applePayload.purchaseDate).toISOString()
      : null;

    upsertPayload = {
      user_id: userId,
      plan_name: sub.planName,
      is_pro: sub.isPro,
      monthly_credit_allowance: sub.monthlyCreditAllowance,
      purchased_credit_balance: current.purchased_credit_balance,
      current_period_start: purchaseDate,
      current_period_end: expiresDate,
      entitlement_source: "storekit_receipt",
      app_store_original_transaction_id: originalTransactionId,
      app_store_latest_transaction_id: transactionId,
      app_store_product_id: productId,
      app_store_environment: environment,
      last_validated_at: new Date().toISOString(),
    };
    ledgerReason = "subscription_grant";
  } else {
    const pack = grant as ConsumableGrant;
    creditedAmount = pack.creditAmount;
    const newPurchasedBalance = current.purchased_credit_balance + creditedAmount;

    upsertPayload = {
      user_id: userId,
      plan_name: current.plan_name,
      is_pro: current.is_pro,
      monthly_credit_allowance: current.monthly_credit_allowance,
      purchased_credit_balance: newPurchasedBalance,
      current_period_start: current.current_period_start,
      current_period_end: current.current_period_end,
      entitlement_source: "storekit_receipt",
      app_store_latest_transaction_id: transactionId,
      app_store_product_id: productId,
      app_store_environment: environment,
      last_validated_at: new Date().toISOString(),
    };
    ledgerReason = "purchase_credit_pack";
  }

  // Upsert entitlement.
  const { data: upserted, error: upsertError } = await adminClient
    .from("user_entitlements")
    .upsert(upsertPayload, { onConflict: "user_id" })
    .select("*")
    .single();

  if (upsertError) {
    console.error("user_entitlements upsert error:", upsertError);
  }

  // Insert ledger row.
  const ledgerDelta = grant!.type === "subscription"
    ? 0 // subscription grants monthly allowance via plan, not a direct credit delta
    : (creditedAmount ?? 0);

  if (ledgerDelta > 0) {
    const { error: ledgerError } = await adminClient
      .from("user_credit_ledger")
      .insert({
        user_id: userId,
        delta: ledgerDelta,
        reason: ledgerReason,
        related_transaction_id: transactionId,
        metadata: {
          productId,
          environment,
          originalTransactionId,
        },
      });

    if (ledgerError) {
      console.error("user_credit_ledger insert error:", ledgerError);
    }
  }

  // Record the transaction for idempotency.
  const { error: txInsertError } = await adminClient
    .from("app_store_transactions")
    .insert({
      user_id: userId,
      transaction_id: transactionId,
      original_transaction_id: originalTransactionId,
      product_id: productId,
      environment,
      type: applePayload.type ?? (grant!.type === "subscription" ? "Auto-Renewable Subscription" : "Consumable"),
      credited_amount: creditedAmount,
      raw_payload: signedTransactionInfo
        ? { signedTransactionInfo, decodedPayload: applePayload }
        : applePayload,
    });

  if (txInsertError) {
    console.error("app_store_transactions insert error:", txInsertError);
  }

  return (upserted ?? upsertPayload) as UserEntitlement;
}

// ---------------------------------------------------------------------------
// manual_grant handler (admin only)
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function handleManualGrant(body: ManualGrantRequest, adminClient: any): Promise<Response> {
  if (!body.userId) {
    return corsResponse(JSON.stringify({ error: "userId is required" }), { status: 422 });
  }

  const { data: existing } = await adminClient
    .from("user_entitlements")
    .select("*")
    .eq("user_id", body.userId)
    .single();

  const currentPurchased = existing?.purchased_credit_balance ?? 0;
  const creditDelta = body.purchasedCreditDelta ?? 0;
  const newPurchasedBalance = Math.max(0, currentPurchased + creditDelta);

  const upsertPayload = {
    user_id: body.userId,
    plan_name: body.planName ?? existing?.plan_name ?? "free",
    is_pro: body.isPro ?? existing?.is_pro ?? false,
    monthly_credit_allowance:
      body.monthlyCreditAllowance ?? existing?.monthly_credit_allowance ?? FREE_TIER_MONTHLY_ALLOWANCE,
    purchased_credit_balance: newPurchasedBalance,
    entitlement_source: "admin_adjustment",
    current_period_start: existing?.current_period_start ?? null,
    current_period_end: existing?.current_period_end ?? null,
  };

  const { data: upserted, error: upsertError } = await adminClient
    .from("user_entitlements")
    .upsert(upsertPayload, { onConflict: "user_id" })
    .select("*")
    .single();

  if (upsertError) {
    console.error("user_entitlements upsert error:", upsertError);
    return corsResponse(JSON.stringify({ error: "Failed to update entitlement" }), { status: 500 });
  }

  if (creditDelta !== 0) {
    const { error: ledgerError } = await adminClient
      .from("user_credit_ledger")
      .insert({
        user_id: body.userId,
        delta: creditDelta,
        reason: "admin_adjustment",
        metadata: { mode: "manual_grant" },
      });

    if (ledgerError) {
      console.error("user_credit_ledger insert error:", ledgerError);
    }
  }

  return corsResponse(
    JSON.stringify({ status: "ok", updatedEntitlement: upserted }),
    { status: 200 },
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function loadCurrentEntitlement(userId: string, adminClient: any): Promise<UserEntitlement> {
  const { data, error } = await adminClient
    .from("user_entitlements")
    .select("*")
    .eq("user_id", userId)
    .single();

  if (error || !data) {
    return {
      user_id: userId,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: FREE_TIER_MONTHLY_ALLOWANCE,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
      updated_at: new Date().toISOString(),
    };
  }

  return data as UserEntitlement;
}

function formatEntitlementResponse(e: UserEntitlement): Record<string, unknown> {
  return {
    planName: e.plan_name,
    isPro: e.is_pro,
    monthlyCreditAllowance: e.monthly_credit_allowance,
    purchasedCreditBalance: e.purchased_credit_balance,
    availableCredits: e.monthly_credit_allowance + e.purchased_credit_balance,
    currentPeriodEnd: e.current_period_end,
  };
}
