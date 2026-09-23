// List previously generated EPUB exports for the authenticated owner of a project.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export interface ExportHistoryItem {
  id: string;
  book_title: string;
  author_name: string;
  is_current: boolean;
  is_active: boolean;
  created_at: string;
  shared_output_id?: string | null;
  is_publicly_shared?: boolean;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

export async function handleListRequest(
  req: Request,
  client: SupabaseClient,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "missing_authorization" }, 401);
  }
  const { data: { user }, error: authError } = await client.auth.getUser(
    authHeader.slice("Bearer ".length).trim(),
  );
  if (authError || !user) return json({ error: "invalid_token" }, 401);

  let body: { project_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  if (!body.project_id || typeof body.project_id !== "string") {
    return json({ error: "missing_project_id" }, 400);
  }

  const { data: snapshot, error: snapshotError } = await client
    .from("project_snapshots")
    .select("id")
    .eq("user_id", user.id)
    .eq("local_project_id", body.project_id)
    .maybeSingle();
  if (snapshotError) return json({ error: "lookup_failed" }, 500);
  if (!snapshot) return json({ exports: [] });

  const { data: exports, error: exportError } = await client
    .from("export_metadata")
    .select("id, book_title, author_name, is_current, is_active, created_at")
    .eq("project_id", snapshot.id)
    .eq("exported_by_user_id", user.id)
    .eq("is_active", true)
    .order("created_at", { ascending: false });
  if (exportError) return json({ error: "lookup_failed" }, 500);
  const exportRows = (exports ?? []) as Array<Record<string, unknown>>;
  const ids = exportRows.map((row) => String(row.id));
  let publications: Array<Record<string, unknown>> = [];
  if (ids.length > 0) {
    const { data, error } = await client
      .from("shared_outputs")
      .select("id, export_metadata_id, visibility, unpublished_at")
      .eq("content_type", "epub");
    if (error) return json({ error: "lookup_failed" }, 500);
    publications = ((data ?? []) as Array<Record<string, unknown>>)
      .filter((row) => ids.includes(String(row.export_metadata_id)));
  }
  const publicationByExport = new Map(
    publications.map((row) => [String(row.export_metadata_id), row]),
  );
  return json({
    exports: exportRows.map((row) => {
      const publication = publicationByExport.get(String(row.id));
      const visible = publication &&
        ["shared", "unlisted"].includes(String(publication.visibility)) &&
        !publication.unpublished_at;
      return {
        ...row,
        shared_output_id: visible ? String(publication.id) : null,
        is_publicly_shared: Boolean(visible),
      };
    }) as ExportHistoryItem[],
  });
}

serve((req) => {
  const client = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  return handleListRequest(req, client);
});
