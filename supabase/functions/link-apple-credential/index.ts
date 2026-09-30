import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const raw = pem.replace(/-----BEGIN (?:EC |)PRIVATE KEY-----/, "")
    .replace(/-----END (?:EC |)PRIVATE KEY-----/, "").replace(/\s+/g, "");
  const binary = atob(raw);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

export async function createAppleClientSecret(): Promise<string> {
  const teamId = Deno.env.get("APPLE_TEAM_ID");
  const keyId = Deno.env.get("APPLE_KEY_ID");
  const clientId = Deno.env.get("APPLE_CLIENT_ID");
  const privateKey = Deno.env.get("APPLE_PRIVATE_KEY");
  if (!teamId || !keyId || !clientId || !privateKey) throw new Error("apple_revocation_not_configured");
  const header = base64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(JSON.stringify({ iss: teamId, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: clientId }));
  const input = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(privateKey), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${base64url(new Uint8Array(signature))}`;
}

export async function exchangeAuthorizationCode(code: string): Promise<string> {
  const clientId = Deno.env.get("APPLE_CLIENT_ID");
  if (!clientId) throw new Error("apple_revocation_not_configured");
  const clientSecret = await createAppleClientSecret();
  const body = new URLSearchParams({ client_id: clientId, client_secret: clientSecret, code, grant_type: "authorization_code" });
  const response = await fetch("https://appleid.apple.com/auth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || typeof data.refresh_token !== "string" || !data.refresh_token) throw new Error("apple_token_exchange_failed");
  return data.refresh_token;
}

export async function linkAppleCredential(adminClient: SupabaseClient, userId: string, code: string): Promise<void> {
  const refreshToken = await exchangeAuthorizationCode(code);
  const { error } = await adminClient.from("apple_account_tokens").upsert({ user_id: userId, refresh_token: refreshToken, updated_at: new Date().toISOString() });
  if (error) throw new Error("apple_token_store_failed");
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) return json({ error: "server_configuration_error" }, 500);
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);
  let body: { authorization_code?: unknown };
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }
  if (typeof body.authorization_code !== "string" || !body.authorization_code) return json({ error: "authorization_code_required" }, 400);
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { global: { headers: { Authorization: authorization } } });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) return json({ error: "unauthorized" }, 401);
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    await linkAppleCredential(adminClient, data.user.id, body.authorization_code);
    return json({ linked: true });
  } catch (error) {
    console.error("[link-apple-credential] linking failed", error);
    return json({ error: error instanceof Error ? error.message : "apple_credential_link_failed" }, 502);
  }
}

if (import.meta.main) serve(handler);
