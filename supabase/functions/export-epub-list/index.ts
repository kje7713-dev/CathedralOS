// List previously generated EPUB exports for the authenticated owner of a project.
// The client supplies the iOS/local project UUID; export_metadata.project_id stores
// the server-generated project_snapshots row UUID, so resolve that boundary here.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "missing_authorization" }, 401);
  }
  const { data: { user }, error: authError } = await supabase.auth.getUser(
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

  const { data: snapshot, error: snapshotError } = await supabase
    .from("project_snapshots")
    .select("id")
    .eq("user_id", user.id)
    .eq("local_project_id", body.project_id)
    .maybeSingle();
  if (snapshotError) return json({ error: "lookup_failed" }, 500);
  if (!snapshot) return json({ exports: [] });

  const { data: exports, error: exportError } = await supabase
    .from("export_metadata")
    .select("id, book_title, author_name, is_current, is_active, created_at")
    .eq("project_id", snapshot.id)
    .eq("exported_by_user_id", user.id)
    .eq("is_active", true)
    .order("created_at", { ascending: false });
  if (exportError) return json({ error: "lookup_failed" }, 500);

  return json({ exports: exports ?? [] });
});
