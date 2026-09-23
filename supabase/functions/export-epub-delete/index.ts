// =============================================================================
// export-epub-delete — transactional metadata deletion + best-effort Storage
// cleanup for persistent EPUB history (PR 2).
// =============================================================================
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export interface ExportMetadataRow {
  id: string;
  project_id: string;
  book_title: string;
  author_name: string;
  epub_storage_path: string | null;
  is_current: boolean;
  is_active: boolean;
  exported_by_user_id: string;
}

export interface TransactionalDeleteResult {
  deleted_export_metadata_id: string;
  project_id: string;
  was_current: boolean;
  promoted_to: string | null;
  epub_storage_path: string | null;
}

export interface DeleteResponse {
  deleted: true;
  export_metadata_id: string;
  project_id: string;
  was_current: boolean;
  promoted_to: string | null;
  storage_object_deleted: boolean;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function log(...args: unknown[]) {
  console.log("[export-epub-delete]", ...args);
}

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

export async function lookupExportMetadata(
  adminClient: SupabaseClient,
  id: string,
): Promise<ExportMetadataRow | null> {
  const { data, error } = await adminClient
    .from("export_metadata")
    .select(
      "id, project_id, book_title, author_name, epub_storage_path, is_current, is_active, exported_by_user_id",
    )
    .eq("id", id)
    .maybeSingle();
  if (error) {
    log("export_metadata lookup error:", error.message);
    return null;
  }
  return data as ExportMetadataRow | null;
}

export function ownershipError(
  row: ExportMetadataRow,
  userId: string,
): string | null {
  return row.exported_by_user_id === userId ? null : "forbidden";
}

export async function deleteMetadataAndPromote(
  adminClient: SupabaseClient,
  exportMetadataId: string,
  expectedUserId: string,
): Promise<
  {
    data: TransactionalDeleteResult | null;
    error: { code?: string; message: string } | null;
  }
> {
  const { data, error } = await adminClient.rpc(
    "delete_export_metadata_and_promote",
    {
      p_export_metadata_id: exportMetadataId,
      p_expected_user_id: expectedUserId,
    },
  );
  return {
    data: data as TransactionalDeleteResult | null,
    error: error ? { code: error.code, message: error.message } : null,
  };
}

export async function deleteStorageObject(
  adminClient: SupabaseClient,
  storagePath: string,
): Promise<boolean> {
  const { error } = await adminClient.storage.from("exports").remove([
    storagePath,
  ]);
  if (error) {
    log("storage cleanup failed; orphaned path:", storagePath, error.message);
    return false;
  }
  return true;
}

export async function handleDeleteRequest(
  req: Request,
  userClient: SupabaseClient,
  adminClient: SupabaseClient,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders, status: 204 });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "missing_authorization" }, 401);
  }
  const userId = await verifyUserJwt(
    userClient,
    authHeader.slice("Bearer ".length).trim(),
  );
  if (!userId) return json({ error: "invalid_token" }, 401);

  let body: { export_metadata_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (!body.export_metadata_id || typeof body.export_metadata_id !== "string") {
    return json({ error: "missing_export_metadata_id" }, 400);
  }

  // Defense in depth: the endpoint verifies ownership before invoking the
  // service-role RPC, and the RPC verifies p_expected_user_id again.
  const row = await lookupExportMetadata(adminClient, body.export_metadata_id);
  if (!row) return json({ error: "export_not_found" }, 404);
  if (ownershipError(row, userId)) return json({ error: "forbidden" }, 403);

  const { data: deleted, error: deleteError } = await deleteMetadataAndPromote(
    adminClient,
    row.id,
    userId,
  );
  if (deleteError || !deleted) {
    if (deleteError?.code === "P0002") {
      return json({ error: "export_not_found" }, 404);
    }
    if (deleteError?.code === "P0003") return json({ error: "forbidden" }, 403);
    log(
      "transactional metadata delete failed:",
      deleteError?.message ?? "empty result",
    );
    return json({ error: "metadata_update_failed" }, 500);
  }

  let storageObjectDeleted = true;
  if (deleted.epub_storage_path) {
    storageObjectDeleted = await deleteStorageObject(
      adminClient,
      deleted.epub_storage_path,
    );
  }

  const response: DeleteResponse = {
    deleted: true,
    export_metadata_id: deleted.deleted_export_metadata_id,
    project_id: deleted.project_id,
    was_current: deleted.was_current,
    promoted_to: deleted.promoted_to,
    storage_object_deleted: storageObjectDeleted,
  };
  return json(response, 200);
}

serve((req) => {
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
  });
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  return handleDeleteRequest(req, userClient, adminClient);
});
