import { createClient } from "jsr:@supabase/supabase-js@2";
import { watchdogDispatchBody } from "./_logic.ts";
import { isAuthorized, readSecretKey } from "./_auth.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = readSecretKey(Deno.env.get("SUPABASE_SECRET_KEYS"));
const adminKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? serviceKey;
const MAX_BATCH = 20;

function authorized(req: Request): boolean {
  const supplied = req.headers.get("apikey");
  return isAuthorized(supplied, serviceKey);
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return response({ error: "POST required" }, 405);
  if (!authorized(req)) return response({ error: "not authorized" }, 401);
  if (!adminKey || !supabaseUrl) return response({ error: "not configured" }, 500);

  const db = createClient(supabaseUrl, adminKey, { auth: { persistSession: false } });
  const now = new Date().toISOString();
  const { data: runs, error } = await db.from("outline_suggestion_runs")
    .select("id")
    .or(`status.eq.pending,and(status.eq.running,lease_expires_at.lt.${now})`)
    .order("updated_at", { ascending: true })
    .limit(MAX_BATCH);
  if (error) return response({ error: "could not list recoverable runs" }, 500);

  const results: Array<Record<string, unknown>> = [];
  for (const run of runs ?? []) {
    try {
      const target = `${supabaseUrl.replace(/\/$/, "")}/functions/v1/outline-from-recipe`;
      const result = await fetch(target, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": serviceKey,
          "Authorization": `Bearer ${serviceKey}`,
        },
        body: JSON.stringify(watchdogDispatchBody(run.id)),
      });
      results.push({ run_id: run.id, status: result.status });
    } catch (err) {
      results.push({ run_id: run.id, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return response({ scanned: runs?.length ?? 0, dispatched: results });
});
