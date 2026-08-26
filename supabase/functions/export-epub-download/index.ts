// =============================================================================
// index.ts — export-epub-download Supabase Edge Function
//
// PR-4100-C: iOS read path for exported EPUBs.
// Per Kevin's 2026-08-26 10:42 EDT scope: per-user ownership enforcement
// with the authenticated download/signing path explicitly verifying the export
// belongs to the current user. Bucket stays private. No service-role
// credential in iOS — only user JWT.
//
// Endpoint:
//   POST /export-epub-download
//   Body: { export_metadata_id: "<uuid>" }
//   Auth: Authorization: Bearer <user_jwt>
//   Response 200: { signed_url, expires_at, export_metadata_id, book_title,
//                  author_name, epub_sha256, file_size_bytes, is_current,
//                  is_active, local_project_id, project_id, created_at }
//   Response 401: missing_authorization | invalid_token
//   Response 400: invalid_json | missing_export_metadata_id
//   Response 403: forbidden (ownership_mismatch — non-owner)
//   Response 404: export_not_found
//   Response 410: export_inactive
//   Response 500: lookup_failed | signing_failed
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get(
  "SUPABASE_SERVICE_ROLE_KEY",
)!;
const SIGNED_URL_EXPIRY_SECONDS = 300;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export interface ExportMetadataRow {
  id: string;
  project_id: string;
  local_project_id: string;
  book_title: string;
  author_name: string;
  epub_storage_path: string;
  epub_sha256: string;
  is_current: boolean;
  is_active: boolean;
  exported_by_user_id: string;
  created_at: string;
}

export interface DownloadResponse {
  signed_url: string;
  expires_at: string;
  export_metadata_id: string;
  book_title: string;
  author_name: string;
  epub_sha256: string;
  file_size_bytes: number | null;
  is_current: boolean;
  is_active: boolean;
  local_project_id: string;
  project_id: string;
  created_at: string;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

function log(...args: unknown[]) {
  console.log("[export-epub-download]", ...args);
}

/**
 * Verify the user's JWT via Supabase auth. Returns user id or null.
 * Extracted for testability (see index_test.ts).
 */
export async function verifyUserJwt(
  userClient: SupabaseClient,
  jwt: string,
): Promise<string | null> {
  const { data, error } = await userClient.auth.getUser(jwt);
  if (error || !data?.user) {
    log("auth.getUser failed:", error?.message ?? "no user");
    return null;
  }
  return data.user.id;
}

/**
 * Look up export_metadata row by id. Returns row or null.
 * Uses service-role client (RLS would block the user from SELECTing other
 * users' rows; ownership check below is the real gate).
 */
export async function lookupExportMetadata(
  adminClient: SupabaseClient,
  id: string,
): Promise<ExportMetadataRow | null> {
  const { data, error } = await adminClient
    .from("export_metadata")
    .select(
      "id, project_id, local_project_id, book_title, author_name, epub_storage_path, epub_sha256, is_current, is_active, exported_by_user_id, created_at",
    )
    .eq("id", id)
    .maybeSingle();
  if (error) {
    log("export_metadata lookup error:", error.message);
    return null;
  }
  return data as ExportMetadataRow | null;
}

/**
 * Generate a signed URL for the EPUB in the exports bucket.
 * 5-minute expiry; only the requester (who proved ownership above) gets it.
 */
export async function generateSignedUrl(
  adminClient: SupabaseClient,
  storagePath: string,
  expirySeconds: number,
): Promise<string | null> {
  const { data, error } = await adminClient.storage
    .from("exports")
    .createSignedUrl(storagePath, expirySeconds);
  if (error || !data) {
    log("createSignedUrl error:", error?.message ?? "no data");
    return null;
  }
  return data.signedUrl;
}

/**
 * OWNERSHIP CHECK — explicit per Kevin's 2026-08-26 10:42 EDT directive.
 * Returns null if OK, or an error code string.
 */
export function ownershipError(
  row: ExportMetadataRow,
  userId: string,
): string | null {
  if (row.exported_by_user_id !== userId) return "forbidden";
  if (!row.is_active) return "export_inactive";
  return null;
}

serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders, status: 204 });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  // 1. User JWT from Authorization header
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return json({ error: "missing_authorization" }, 401);
  }
  const userJwt = authHeader.slice("Bearer ".length).trim();

  // 2. Verify user
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${userJwt}` } },
    auth: { persistSession: false },
  });
  const userId = await verifyUserJwt(userClient, userJwt);
  if (!userId) {
    return json({ error: "invalid_token" }, 401);
  }

  // 3. Parse request body
  let body: { export_metadata_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (
    !body.export_metadata_id ||
    typeof body.export_metadata_id !== "string"
  ) {
    return json({ error: "missing_export_metadata_id" }, 400);
  }

  // 4. Lookup via service-role
  const adminClient = createClient(
    SUPABASE_URL,
    SUPABASE_SERVICE_ROLE_KEY,
    { auth: { persistSession: false } },
  );
  const row = await lookupExportMetadata(adminClient, body.export_metadata_id);
  if (!row) {
    return json({ error: "export_not_found" }, 404);
  }

  // 5. OWNERSHIP CHECK (explicit per Kevin's directive)
  const ownErr = ownershipError(row, userId);
  if (ownErr === "forbidden") {
    log(
      `ownership_mismatch: requested_by=${userId} exported_by=${row.exported_by_user_id} metadata_id=${row.id}`,
    );
    return json({ error: "forbidden" }, 403);
  }
  if (ownErr === "export_inactive") {
    return json({ error: "export_inactive" }, 410);
  }

  // 6. Signed URL
  const signedUrl = await generateSignedUrl(
    adminClient,
    row.epub_storage_path,
    SIGNED_URL_EXPIRY_SECONDS,
  );
  if (!signedUrl) {
    return json({ error: "signing_failed" }, 500);
  }

  const expiresAt = new Date(
    Date.now() + SIGNED_URL_EXPIRY_SECONDS * 1000,
  ).toISOString();

  const response: DownloadResponse = {
    signed_url: signedUrl,
    expires_at: expiresAt,
    export_metadata_id: row.id,
    book_title: row.book_title,
    author_name: row.author_name,
    epub_sha256: row.epub_sha256,
    file_size_bytes: null,
    is_current: row.is_current,
    is_active: row.is_active,
    local_project_id: row.local_project_id,
    project_id: row.project_id,
    created_at: row.created_at,
  };
  return json(response, 200);
});
