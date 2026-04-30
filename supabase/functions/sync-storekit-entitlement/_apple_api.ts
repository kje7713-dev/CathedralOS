// =============================================================================
// _apple_api.ts — App Store Server API helpers
//
// Provides:
//  - createAppleApiJWT()  — creates the JWT used to authenticate with Apple's
//                           App Store Server API (signed with your private key)
//  - verifyTransactionWithApple() — calls GET /inApps/v1/transactions/{id}
//  - decodeJWSPayload()   — decodes a JWS payload segment (without signature
//                           verification; use verifyTransactionWithApple for
//                           authoritative data)
//
// Required secrets (set via `supabase secrets set`):
//   APP_STORE_KEY_ID        — Key ID from App Store Connect → Users & Access → Keys
//   APP_STORE_ISSUER_ID     — Issuer ID from App Store Connect → Users & Access → Keys
//   APP_STORE_PRIVATE_KEY   — Contents of the .p8 file (ES256 private key, PEM format)
//   APP_STORE_BUNDLE_ID     — Your app's bundle identifier (e.g. com.example.cathedralos)
//   APP_STORE_ENVIRONMENT   — "Sandbox" or "Production"
//
// Security note:
//   These secrets are NEVER placed in the iOS app. They live server-side only.
// =============================================================================

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** Decoded payload from a StoreKit 2 JWS signed transaction. */
export interface AppleTransactionPayload {
  transactionId: string;
  originalTransactionId: string;
  bundleId: string;
  productId: string;
  purchaseDate: number; // ms since epoch
  originalPurchaseDate: number;
  quantity: number;
  type: string; // "Auto-Renewable Subscription" | "Non-Consumable" | "Consumable" | etc.
  inAppOwnershipType: string;
  signedDate: number;
  environment: string; // "Sandbox" | "Production"
  // Subscription-specific fields (may be absent for consumables)
  expiresDate?: number;
  isUpgraded?: boolean;
  offerType?: number;
  offerIdentifier?: string;
  revocationDate?: number;
  revocationReason?: number;
  // Consumable-specific
  appAccountToken?: string;
}

export interface AppleApiConfig {
  keyId: string;
  issuerId: string;
  privateKeyPem: string;
  bundleId: string;
  environment: string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Decodes the payload section of a JWS token without verifying the signature. */
export function decodeJWSPayload(jws: string): Record<string, unknown> {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error("Invalid JWS: expected three dot-separated segments");
  }
  // base64url → standard base64
  const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  try {
    return JSON.parse(atob(padded));
  } catch {
    throw new Error("Invalid JWS: could not parse payload");
  }
}

/** Converts a PEM-formatted private key string to a DER ArrayBuffer. */
function pemToDer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN (?:EC |)PRIVATE KEY-----/, "")
    .replace(/-----END (?:EC |)PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/** base64url-encodes a string or Uint8Array. */
function base64url(input: string | Uint8Array): string {
  let binary: string;
  if (typeof input === "string") {
    binary = input;
  } else {
    binary = String.fromCharCode(...input);
  }
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

// ---------------------------------------------------------------------------
// JWT creation for Apple API authentication
// ---------------------------------------------------------------------------

/**
 * Creates a signed JWT for authenticating with the App Store Server API.
 * Uses ES256 (ECDSA P-256) as required by Apple.
 *
 * Ref: https://developer.apple.com/documentation/appstoreserverapi/generating_tokens_for_api_requests
 */
export async function createAppleApiJWT(config: AppleApiConfig): Promise<string> {
  const header = {
    alg: "ES256",
    kid: config.keyId,
    typ: "JWT",
  };

  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: config.issuerId,
    iat: now,
    exp: now + 60 * 20, // 20-minute expiry (Apple maximum)
    aud: "appstoreconnect-v1",
    bid: config.bundleId,
  };

  const headerB64 = base64url(JSON.stringify(header));
  const payloadB64 = base64url(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;

  // Import the PKCS#8 private key. Apple's .p8 files may be PKCS#8 wrapped
  // or raw EC private key — try PKCS#8 first.
  let cryptoKey: CryptoKey;
  try {
    cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      pemToDer(config.privateKeyPem),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
  } catch {
    throw new Error(
      "Failed to import APP_STORE_PRIVATE_KEY. " +
      "Ensure it is a valid PKCS#8 PEM-encoded ES256 private key (the .p8 file from App Store Connect).",
    );
  }

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );

  const sigB64 = base64url(new Uint8Array(signature));
  return `${signingInput}.${sigB64}`;
}

// ---------------------------------------------------------------------------
// App Store Server API — transaction lookup
// ---------------------------------------------------------------------------

/**
 * Calls the App Store Server API to fetch and verify a transaction by ID.
 * Returns the decoded Apple-signed transaction payload.
 *
 * Throws on network error, non-200 response, or parse failure.
 */
export async function verifyTransactionWithApple(
  transactionId: string,
  config: AppleApiConfig,
): Promise<AppleTransactionPayload> {
  const jwt = await createAppleApiJWT(config);

  const baseUrl = config.environment === "Sandbox"
    ? "https://api.storekit-sandbox.itunes.apple.com"
    : "https://api.storekit.itunes.apple.com";

  const url = `${baseUrl}/inApps/v1/transactions/${encodeURIComponent(transactionId)}`;

  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${jwt}`,
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Apple API returned ${response.status} for transaction ${transactionId}: ${body}`,
    );
  }

  const json: { signedTransactionInfo?: string } = await response.json();

  if (!json.signedTransactionInfo) {
    throw new Error(
      `Apple API response missing signedTransactionInfo for transaction ${transactionId}`,
    );
  }

  // Decode the Apple-returned JWS (Apple signed this, not the client).
  const payload = decodeJWSPayload(json.signedTransactionInfo);
  return payload as unknown as AppleTransactionPayload;
}

// ---------------------------------------------------------------------------
// Config loading from Deno environment
// ---------------------------------------------------------------------------

/** Reads Apple API config from Deno.env. Returns null if any required key is missing. */
export function loadAppleApiConfig(): AppleApiConfig | null {
  const keyId = Deno.env.get("APP_STORE_KEY_ID");
  const issuerId = Deno.env.get("APP_STORE_ISSUER_ID");
  const privateKeyPem = Deno.env.get("APP_STORE_PRIVATE_KEY");
  const bundleId = Deno.env.get("APP_STORE_BUNDLE_ID");
  const environment = Deno.env.get("APP_STORE_ENVIRONMENT") ?? "Sandbox";

  if (!keyId || !issuerId || !privateKeyPem || !bundleId) {
    return null;
  }

  return { keyId, issuerId, privateKeyPem, bundleId, environment };
}

/** Returns true when all required Apple API secrets are present in Deno.env. */
export function isAppleApiConfigured(): boolean {
  return loadAppleApiConfig() !== null;
}
