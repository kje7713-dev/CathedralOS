// =============================================================================
// index.ts — sync-storekit-entitlement Supabase Edge Function
//
// ⚠️  PLACEHOLDER — NOT PRODUCTION READY ⚠️
//
// This function is a placeholder for future App Store Server transaction
// validation. It must NOT be called from the iOS client directly with raw
// StoreKit transaction data; the backend must validate transactions via the
// App Store Server API before trusting any entitlement claim.
//
// Current state (this PR):
//   - Accepts only requests authenticated with the Supabase service-role key
//     (i.e., only callable from trusted server-to-server contexts, not from
//     the iOS client).
//   - Returns 501 Not Implemented for the receipt validation path.
//   - Allows an admin/manual entitlement update via the service-role path for
//     testing and operational use.
//
// Before production paid launch you MUST:
//   1. Integrate with the App Store Server API to validate transaction JWTs.
//      See: https://developer.apple.com/documentation/appstoreserverapi
//   2. Verify Apple's JWS signature using Apple's public key (do not skip).
//   3. Record the transactionId as related_transaction_id in user_credit_ledger.
//   4. Only then update user_entitlements.
//
// Security invariant:
//   Do NOT add a client-accessible path that trusts iOS-supplied entitlement
//   claims without server-side App Store receipt validation.
//
// Secrets required:
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected; required for all writes
//   ADMIN_SECRET              — set via `supabase secrets set ADMIN_SECRET=...`
//                               Used to authenticate admin/manual calls.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
// Request body
// ---------------------------------------------------------------------------

interface SyncStoreKitRequest {
  /** Target user_id to update. Required. */
  userId: string;

  /**
   * Mode of sync operation.
   *
   * "manual_grant"           — admin/operational override: set entitlement directly.
   *                            Only allowed when called with the admin secret.
   *
   * "storekit_receipt"       — (NOT IMPLEMENTED) will validate a StoreKit receipt
   *                            via App Store Server API before granting entitlement.
   */
  mode: "manual_grant" | "storekit_receipt";

  // Fields for mode = "manual_grant"
  planName?: string;
  isPro?: boolean;
  monthlyCreditAllowance?: number;
  purchasedCreditDelta?: number; // positive = add credits

  // Fields for mode = "storekit_receipt" (NOT IMPLEMENTED YET)
  // transactionId?: string;
  // signedTransactionInfo?: string; // JWS token from StoreKit 2
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return corsResponse("", { status: 204 });
  }

  if (req.method !== "POST") {
    return corsResponse(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405 },
    );
  }

  // -------------------------------------------------------------------------
  // Admin authentication
  //
  // This endpoint is service-role / admin only.
  // The iOS client must NOT call this endpoint directly.
  //
  // Two accepted authentication methods:
  //   1. x-admin-secret header matching ADMIN_SECRET env var.
  //   2. Authorization: Bearer <service-role-key> (for server-to-server calls).
  // -------------------------------------------------------------------------

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const adminSecret = Deno.env.get("ADMIN_SECRET");

  if (!supabaseURL || !serviceRoleKey) {
    return corsResponse(
      JSON.stringify({ error: "Server configuration error" }),
      { status: 500 },
    );
  }

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
          "This endpoint requires admin authentication. " +
          "Provide a valid x-admin-secret header or service-role bearer token.",
      }),
      { status: 403 },
    );
  }

  // -------------------------------------------------------------------------
  // Parse body
  // -------------------------------------------------------------------------

  let body: SyncStoreKitRequest;
  try {
    body = await req.json();
  } catch {
    return corsResponse(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400 },
    );
  }

  if (!body.userId) {
    return corsResponse(
      JSON.stringify({ error: "userId is required" }),
      { status: 422 },
    );
  }

  // -------------------------------------------------------------------------
  // Mode: storekit_receipt — NOT IMPLEMENTED
  // -------------------------------------------------------------------------

  if (body.mode === "storekit_receipt") {
    // ⚠️  PLACEHOLDER
    //
    // Before implementing this path:
    //   1. Receive signedTransactionInfo (JWS) from App Store Server Notification
    //      or from iOS client via a server-to-server relay (never direct client trust).
    //   2. Verify the JWS signature using Apple's public key from
    //      https://appleid.apple.com/auth/keys
    //   3. Parse the decoded payload to extract:
    //         - productId, transactionId, purchaseDate, expiresDate (if subscription)
    //   4. Check transactionId has not already been applied (idempotency).
    //   5. Update user_entitlements accordingly.
    //   6. Insert a user_credit_ledger row with reason = "purchase_credit_pack" or
    //      "monthly_allowance_grant".
    //
    // Do NOT trust raw claims from the iOS client. Always validate with Apple.

    return corsResponse(
      JSON.stringify({
        status: "not_implemented",
        message:
          "StoreKit receipt validation is not yet implemented. " +
          "App Store Server API integration is required before production launch. " +
          "See docs/backend-credit-enforcement.md for the required steps.",
      }),
      { status: 501 },
    );
  }

  // -------------------------------------------------------------------------
  // Mode: manual_grant — admin/operational override
  // -------------------------------------------------------------------------

  if (body.mode !== "manual_grant") {
    return corsResponse(
      JSON.stringify({ error: "Invalid mode. Use 'manual_grant' or 'storekit_receipt'." }),
      { status: 422 },
    );
  }

  const adminClient = createClient(supabaseURL, serviceRoleKey);

  // Load current entitlement (may not exist for new users).
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
      body.monthlyCreditAllowance ?? existing?.monthly_credit_allowance ?? 10,
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
    return corsResponse(
      JSON.stringify({ error: "Failed to update entitlement" }),
      { status: 500 },
    );
  }

  // Insert a ledger row for auditing.
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
    JSON.stringify({
      status: "ok",
      updatedEntitlement: upserted,
    }),
    { status: 200 },
  );
});
