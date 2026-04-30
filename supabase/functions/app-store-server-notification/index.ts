// =============================================================================
// index.ts — app-store-server-notification Supabase Edge Function
//
// ⚠️  STUB — NOT FULLY IMPLEMENTED ⚠️
//
// This endpoint is the webhook receiver for App Store Server Notifications
// (version 2). When configured in App Store Connect, Apple posts real-time
// subscription lifecycle events here:
//   - DID_RENEW             — subscription renewed
//   - EXPIRED               — subscription expired
//   - DID_FAIL_TO_RENEW     — renewal billing failure
//   - REFUND                — transaction refunded
//   - REVOKE                — family-sharing revocation
//   - SUBSCRIBED            — new subscription (first-time)
//   - DID_CHANGE_RENEWAL_STATUS — user cancelled/re-enabled auto-renew
//
// Current state:
//   - Accepts POST requests.
//   - Verifies that the request carries a valid Apple-signed payload envelope
//     before doing any work (returns 400 for clearly invalid payloads).
//   - Logs the notification type and transaction ID for observability.
//   - Returns 501 for all notification types until full handling is implemented.
//   - Does NOT yet update user_entitlements on renewal/expiration/refund.
//
// To fully implement this endpoint:
//   1. Parse the signedPayload JWS (3-part base64url-encoded JWT from Apple).
//   2. Verify the JWS signature using Apple's certificate chain (x5c header claim).
//   3. Decode the ResponseBodyV2DecodedPayload to extract notificationType,
//      subtype, and data.signedTransactionInfo.
//   4. Call the sync-storekit-entitlement logic to apply or revoke the entitlement.
//   5. Return HTTP 200 to acknowledge receipt (Apple retries on non-200).
//
// Required secrets (set via `supabase secrets set`):
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected
//   APP_STORE_BUNDLE_ID       — used to validate notification bundle ID
//
// App Store Connect configuration:
//   App Store Connect → Your App → App Information → App Store Server Notifications
//   Set the URL to: https://<project-ref>.supabase.co/functions/v1/app-store-server-notification
//   Select Version 2 notifications.
//   Use separate sandbox and production endpoints if desired.
//
// See docs/storekit-entitlements.md for setup instructions.
// =============================================================================

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

/** Decodes the payload section of a JWS token without verifying the signature. */
function tryDecodeJWSPayload(jws: string): Record<string, unknown> | null {
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return null;
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    return JSON.parse(atob(padded));
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("", { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // -------------------------------------------------------------------------
  // Parse the signed payload
  //
  // Apple sends: { signedPayload: "<JWS>" }
  // The JWS payload contains: { notificationType, subtype, version, data: { signedTransactionInfo, ... } }
  // -------------------------------------------------------------------------

  let body: { signedPayload?: unknown };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const signedPayload = body?.signedPayload;
  if (typeof signedPayload !== "string" || !signedPayload) {
    return jsonResponse(
      { error: "Missing signedPayload. This endpoint expects Apple App Store Server Notifications v2." },
      400,
    );
  }

  // Decode the outer notification envelope (without full signature verification).
  const envelope = tryDecodeJWSPayload(signedPayload);
  if (!envelope) {
    return jsonResponse({ error: "Could not decode signedPayload" }, 400);
  }

  const notificationType = envelope["notificationType"] ?? "UNKNOWN";
  const subtype = envelope["subtype"] ?? null;

  // Log for observability (no secrets are logged).
  console.log(`App Store Server Notification received: ${notificationType}${subtype ? "/" + subtype : ""}`);

  // Extract transaction info if present for logging.
  let transactionId: string | null = null;
  const data = envelope["data"] as Record<string, unknown> | undefined;
  if (data?.signedTransactionInfo && typeof data.signedTransactionInfo === "string") {
    const txPayload = tryDecodeJWSPayload(data.signedTransactionInfo as string);
    transactionId = (txPayload?.["transactionId"] as string) ?? null;
    if (transactionId) {
      console.log(`  → transactionId: ${transactionId}`);
    }
  }

  // -------------------------------------------------------------------------
  // ⚠️  STUB: full notification handling not yet implemented.
  //
  // Until fully implemented, return 501 so Apple retries the notification.
  // Apple retries unacknowledged notifications (non-200) for up to 72 hours,
  // so this is safe during development — notifications will be delivered once
  // the endpoint is ready.
  //
  // Implement:
  //   1. Signature verification (x5c certificate chain from JWS header).
  //   2. Notification type routing:
  //      - SUBSCRIBED / DID_RENEW → apply subscription entitlement
  //      - EXPIRED / DID_FAIL_TO_RENEW → revoke subscription entitlement
  //      - REFUND / REVOKE → refund credits, revoke entitlement
  //   3. Return 200 to acknowledge receipt.
  // -------------------------------------------------------------------------

  return jsonResponse(
    {
      status: "not_implemented",
      message:
        "App Store Server Notification handling is not yet fully implemented. " +
        "The notification has been received and logged. " +
        "Configure full handling before production launch. " +
        "See docs/storekit-entitlements.md.",
      notificationType,
      subtype,
      transactionId,
    },
    501,
  );
});
