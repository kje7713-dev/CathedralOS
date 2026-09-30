import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

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
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function isStoragePath(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 &&
    !value.startsWith("http://") && !value.startsWith("https://") &&
    !value.includes("..") && !value.startsWith("/");
}

async function removeObjects(
  adminClient: SupabaseClient,
  bucket: string,
  paths: string[],
): Promise<void> {
  const uniquePaths = [...new Set(paths.filter(isStoragePath))];
  if (uniquePaths.length === 0) return;
  for (let offset = 0; offset < uniquePaths.length; offset += 100) {
    const { error } = await adminClient.storage.from(bucket).remove(
      uniquePaths.slice(offset, offset + 100),
    );
    if (error) throw new Error(`storage_cleanup_failed:${bucket}`);
  }
}

async function collectOwnedArtifacts(
  adminClient: SupabaseClient,
  userId: string,
 ): Promise<{ exports: string[]; covers: string[]; sharedImages: string[] }> {
  const { data: exportRows, error: exportError } = await adminClient
    .from("export_metadata")
    .select("epub_storage_path, cover_image_url")
    .eq("exported_by_user_id", userId);
  if (exportError) throw new Error("export_metadata_lookup_failed");

  const { data: sharedRows, error: sharedError } = await adminClient
    .from("shared_outputs")
    .select("cover_image_path")
    .eq("owner_user_id", userId);
  if (sharedError) throw new Error("shared_outputs_lookup_failed");

  // Cover uploads historically used exports/<project-id>/... before export
  // metadata existed. Enumerate every owned project prefix so failed or
  // abandoned exports cannot leave user-owned objects behind.
  const { data: projectRows, error: projectError } = await adminClient
    .from("project_snapshots")
    .select("local_project_id")
    .eq("user_id", userId);
  if (projectError) throw new Error("project_snapshots_lookup_failed");

  const orphanedExports: string[] = [];
  const orphanedCovers: string[] = [];
  for (const row of projectRows ?? []) {
    if (typeof row.local_project_id !== "string" || !row.local_project_id) continue;
    const prefix = `exports/${row.local_project_id}`;
    for (const [bucket, destination] of [["exports", orphanedExports], ["covers", orphanedCovers]] as const) {
      const { data, error } = await adminClient.storage.from(bucket).list(prefix, {
        limit: 1000,
        offset: 0,
      });
      if (error) throw new Error(`storage_list_failed:${bucket}`);
      for (const object of data ?? []) {
        if (typeof object.name === "string" && object.name) {
          destination.push(`${prefix}/${object.name}`);
        }
      }
    }
  }

  return {
    exports: [
      ...(exportRows ?? []).map((row) => row.epub_storage_path).filter(isStoragePath),
      ...orphanedExports,
    ],
    covers: [
      ...(exportRows ?? []).map((row) => row.cover_image_url).filter(isStoragePath),
      ...orphanedCovers,
    ],
    sharedImages: (sharedRows ?? []).map((row) => row.cover_image_path).filter(isStoragePath),
  };
}

export async function deleteOwnedAccount(
  adminClient: SupabaseClient,
  userId: string,
): Promise<void> {
  const artifacts = await collectOwnedArtifacts(adminClient, userId);
  await removeObjects(adminClient, "exports", artifacts.exports);
  await removeObjects(adminClient, "covers", artifacts.covers);
  await removeObjects(adminClient, "shared-output-images", artifacts.sharedImages);

  // These two tables have historical foreign keys without ON DELETE CASCADE;
  // remove them explicitly before deleting the auth user. All other user-owned
  // rows are deleted by their auth.users FK cascades or intentionally retained
  // with a nullable user reference.
  const { error: jobsError } = await adminClient
    .from("export_jobs")
    .delete()
    .eq("user_id", userId);
  if (jobsError) throw new Error("export_jobs_delete_failed");

  const { error: metadataError } = await adminClient
    .from("export_metadata")
    .delete()
    .eq("exported_by_user_id", userId);
  if (metadataError) throw new Error("export_metadata_delete_failed");

  const { error: authError } = await adminClient.auth.admin.deleteUser(userId);
  if (authError) throw new Error("auth_user_delete_failed");
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json({ error: "server_configuration_error" }, 500);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "unauthorized" }, 401);

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authorization } },
  });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) return json({ error: "unauthorized" }, 401);

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  try {
    await deleteOwnedAccount(adminClient, data.user.id);
    return json({ deleted: true, user_id: data.user.id });
  } catch (error) {
    console.error("[delete-account] deletion failed", error);
    return json({ error: "account_deletion_failed" }, 500);
  }
}

if (import.meta.main) serve(handler);
