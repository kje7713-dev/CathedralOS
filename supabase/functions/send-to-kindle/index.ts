// =============================================================================
// send-to-kindle — authenticated StoryDonkey -> Amazon Send-to-Kindle email flow
//
// The client never supplies a destination address when sending. The server reads
// the authenticated user's saved @kindle.com address from public.profiles,
// verifies export ownership, downloads the canonical private EPUB, and sends it
// through Resend from the stable address the user approved with Amazon.
// =============================================================================
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const KINDLE_FROM_EMAIL = Deno.env.get("KINDLE_FROM_EMAIL") ?? "";

// Resend's current message-size limit is 40 MB. Keep the raw EPUB below that
// ceiling so JSON/base64/MIME overhead cannot push the request over provider
// limits. Amazon itself permits up to 50 MB total by email.
export const MAX_EPUB_BYTES = 35 * 1024 * 1024;
export const SEND_WINDOW_MINUTES = 10;
export const MAX_SENDS_PER_WINDOW = 5;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonRecord = Record<string, unknown>;
type FetchLike = typeof fetch;

interface HandlerDependencies {
  userClient: SupabaseClient;
  adminClient: SupabaseClient;
  fetchImpl?: FetchLike;
  resendApiKey?: string;
  kindleFromEmail?: string;
  now?: () => Date;
}

interface KindleProfileRow {
  id: string;
  kindle_email: string | null;
  kindle_sender_approved_at: string | null;
}

interface ExportRow {
  id: string;
  book_title: string;
  author_name: string;
  epub_storage_path: string | null;
  exported_by_user_id: string;
  is_active: boolean;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeKindleEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (!/^[^@\s]+@kindle\.com$/.test(normalized)) return null;
  return normalized;
}

function normalizeSender(value: string): string | null {
  const match = value.trim().match(/(?:<)?([^<>\s]+@[^<>\s]+)(?:>)?$/);
  return match?.[1]?.toLowerCase() ?? null;
}

function safeFilename(title: string): string {
  const stripped = title
    .replace(/[\x00-\x1F\\/:*?"<>|]/g, "")
    .trim()
    .replace(/^\.+|\.+$/g, "")
    .trim();
  const base = stripped || "Untitled";
  return `${Array.from(base).slice(0, 160).join("")}.epub`;
}

async function authenticatedUserID(
  req: Request,
  client: SupabaseClient,
): Promise<string | null> {
  const auth = req.headers.get("Authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  const token = auth.slice("Bearer ".length).trim();
  if (!token) return null;
  const { data: { user }, error } = await client.auth.getUser(token);
  return error || !user ? null : user.id;
}

async function loadProfile(
  admin: SupabaseClient,
  userID: string,
): Promise<KindleProfileRow | null> {
  const { data, error } = await admin
    .from("profiles")
    .select("id, kindle_email, kindle_sender_approved_at")
    .eq("id", userID)
    .maybeSingle();
  if (error) throw new Error(`profile_lookup_failed:${error.message}`);
  return data as KindleProfileRow | null;
}

async function saveSettings(
  admin: SupabaseClient,
  userID: string,
  kindleEmail: string,
  approved: boolean,
  now: Date,
): Promise<void> {
  const { error } = await admin.from("profiles").upsert({
    id: userID,
    kindle_email: kindleEmail,
    kindle_sender_approved_at: approved ? now.toISOString() : null,
  }, { onConflict: "id" });
  if (error) throw new Error(`profile_update_failed:${error.message}`);
}

async function clearSettings(admin: SupabaseClient, userID: string): Promise<void> {
  const { error } = await admin.from("profiles").update({
    kindle_email: null,
    kindle_sender_approved_at: null,
  }).eq("id", userID);
  if (error) throw new Error(`profile_update_failed:${error.message}`);
}

async function loadOwnedExport(
  admin: SupabaseClient,
  exportID: string,
): Promise<ExportRow | null> {
  const { data, error } = await admin
    .from("export_metadata")
    .select(
      "id, book_title, author_name, epub_storage_path, exported_by_user_id, is_active",
    )
    .eq("id", exportID)
    .maybeSingle();
  if (error) throw new Error(`export_lookup_failed:${error.message}`);
  return data as ExportRow | null;
}

async function recentSendCount(
  admin: SupabaseClient,
  userID: string,
  since: Date,
): Promise<number> {
  const { count, error } = await admin
    .from("kindle_delivery_events")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userID)
    .eq("status", "sent")
    .gte("created_at", since.toISOString());
  if (error) throw new Error(`rate_limit_lookup_failed:${error.message}`);
  return count ?? 0;
}

async function recordEvent(
  admin: SupabaseClient,
  values: {
    userID: string;
    exportID: string;
    status: "sent" | "failed";
    providerMessageID?: string | null;
    errorCode?: string | null;
  },
): Promise<void> {
  const { error } = await admin.from("kindle_delivery_events").insert({
    user_id: values.userID,
    export_metadata_id: values.exportID,
    status: values.status,
    provider_message_id: values.providerMessageID ?? null,
    error_code: values.errorCode ?? null,
  });
  if (error) {
    console.error("[send-to-kindle] audit insert failed", error.message);
  }
}

async function sendViaResend(
  fetchImpl: FetchLike,
  apiKey: string,
  from: string,
  to: string,
  exportRow: ExportRow,
  bytes: Uint8Array,
): Promise<{ id: string | null; ok: boolean; status: number }> {
  const response = await fetchImpl("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from,
      to: [to],
      subject: exportRow.book_title || "StoryDonkey EPUB",
      text:
        "Sent from StoryDonkey for delivery through Amazon Send to Kindle. The EPUB is attached.",
      attachments: [{
        filename: safeFilename(exportRow.book_title),
        content: encodeBase64(bytes),
      }],
    }),
  });

  if (!response.ok) {
    await response.text().catch(() => "");
    return { id: null, ok: false, status: response.status };
  }
  const body = await response.json().catch(() => ({})) as JsonRecord;
  return {
    id: typeof body.id === "string" ? body.id : null,
    ok: true,
    status: response.status,
  };
}

export async function handleRequest(
  req: Request,
  deps: HandlerDependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const userID = await authenticatedUserID(req, deps.userClient);
  if (!userID) return json({ error: "unauthorized" }, 401);

  let body: JsonRecord;
  try {
    body = await req.json() as JsonRecord;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const action = typeof body.action === "string" ? body.action : "send";
  const now = deps.now?.() ?? new Date();
  const from = deps.kindleFromEmail ?? KINDLE_FROM_EMAIL;
  const senderAddress = normalizeSender(from);

  try {
    if (action === "settings.get") {
      const profile = await loadProfile(deps.adminClient, userID);
      return json({
        kindle_email: profile?.kindle_email ?? null,
        sender_approved: Boolean(profile?.kindle_sender_approved_at),
        sender_email: senderAddress,
      });
    }

    if (action === "settings.save") {
      const kindleEmail = normalizeKindleEmail(body.kindle_email);
      if (!kindleEmail) return json({ error: "invalid_kindle_email" }, 400);
      const senderApproved = body.sender_approved === true;
      await saveSettings(
        deps.adminClient,
        userID,
        kindleEmail,
        senderApproved,
        now,
      );
      return json({
        configured: senderApproved,
        kindle_email: kindleEmail,
        sender_approved: senderApproved,
        sender_email: senderAddress,
      });
    }

    if (action === "settings.clear") {
      await clearSettings(deps.adminClient, userID);
      return json({ configured: false, sender_email: senderAddress });
    }

    if (action !== "send") return json({ error: "invalid_action" }, 400);

    const exportID = typeof body.export_metadata_id === "string"
      ? body.export_metadata_id.trim()
      : "";
    if (!exportID) return json({ error: "missing_export_metadata_id" }, 400);

    if (!deps.resendApiKey && !RESEND_API_KEY) {
      return json({ error: "email_provider_not_configured" }, 503);
    }
    if (!senderAddress) {
      return json({ error: "kindle_sender_not_configured" }, 503);
    }

    const profile = await loadProfile(deps.adminClient, userID);
    const kindleEmail = normalizeKindleEmail(profile?.kindle_email);
    if (!kindleEmail) return json({ error: "kindle_not_configured" }, 409);
    if (!profile?.kindle_sender_approved_at) {
      return json({ error: "kindle_sender_not_approved" }, 409);
    }

    const exportRow = await loadOwnedExport(deps.adminClient, exportID);
    if (!exportRow) return json({ error: "export_not_found" }, 404);
    if (exportRow.exported_by_user_id !== userID) {
      return json({ error: "forbidden" }, 403);
    }
    if (!exportRow.is_active || !exportRow.epub_storage_path) {
      return json({ error: "export_not_available" }, 409);
    }

    const windowStart = new Date(
      now.getTime() - SEND_WINDOW_MINUTES * 60 * 1000,
    );
    const sendCount = await recentSendCount(deps.adminClient, userID, windowStart);
    if (sendCount >= MAX_SENDS_PER_WINDOW) {
      return json({ error: "rate_limited" }, 429);
    }

    const { data: epubBlob, error: storageError } = await deps.adminClient.storage
      .from("exports")
      .download(exportRow.epub_storage_path);
    if (storageError || !epubBlob) {
      return json({ error: "epub_download_failed" }, 502);
    }
    const bytes = new Uint8Array(await epubBlob.arrayBuffer());
    if (bytes.byteLength > MAX_EPUB_BYTES) {
      return json({
        error: "epub_too_large_for_email",
        max_bytes: MAX_EPUB_BYTES,
      }, 413);
    }

    const provider = await sendViaResend(
      deps.fetchImpl ?? fetch,
      deps.resendApiKey ?? RESEND_API_KEY,
      from,
      kindleEmail,
      exportRow,
      bytes,
    );
    if (!provider.ok) {
      await recordEvent(deps.adminClient, {
        userID,
        exportID,
        status: "failed",
        errorCode: `resend_http_${provider.status}`,
      });
      return json({ error: "email_provider_failed" }, 502);
    }

    await recordEvent(deps.adminClient, {
      userID,
      exportID,
      status: "sent",
      providerMessageID: provider.id,
    });

    // Deliberately say sent_to_amazon, not delivered_to_kindle. Resend accepting
    // the message does not prove Amazon has converted or delivered the EPUB.
    return json({
      status: "sent_to_amazon",
      export_metadata_id: exportID,
      book_title: exportRow.book_title,
    });
  } catch (error) {
    console.error(
      "[send-to-kindle] request failed",
      error instanceof Error ? error.message : String(error),
    );
    return json({ error: "internal_error" }, 500);
  }
}

if (import.meta.main) {
  serve((req) => {
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      return json({ error: "backend_not_configured" }, 503);
    }
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: { persistSession: false },
    });
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false },
    });
    return handleRequest(req, { userClient, adminClient });
  });
}
