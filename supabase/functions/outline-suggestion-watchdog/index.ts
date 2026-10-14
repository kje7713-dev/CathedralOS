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

export type WatchdogDispatch = (runID: string) => Promise<number>;

/** One bounded scheduler pass; the cron handler and deterministic tests share this path. */
export async function runWatchdogOnce(
  db: any,
  dispatch: WatchdogDispatch,
  now = new Date(),
): Promise<{ scanned: number; statuses: Array<Record<string, unknown>> }> {
  const { data: runs, error } = await db.from("outline_suggestion_runs")
    .select("id")
    .or(`status.eq.pending,and(status.eq.running,lease_expires_at.lt.${now.toISOString()})`)
    .order("updated_at", { ascending: true })
    .limit(MAX_BATCH);
  if (error) throw new Error("could not list recoverable runs");

  const statuses: Array<Record<string, unknown>> = [];
  for (const run of runs ?? []) {
    try {
      statuses.push({ run_id: run.id, status: await dispatch(run.id) });
    } catch (err) {
      statuses.push({ run_id: run.id, error: err instanceof Error ? err.message : String(err) });
    }
  }
  return { scanned: runs?.length ?? 0, statuses };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return response({ error: "POST required" }, 405);
  if (!authorized(req)) return response({ error: "not authorized" }, 401);
  if (!adminKey || !supabaseUrl) return response({ error: "not configured" }, 500);

  const db = createClient(supabaseUrl, adminKey, { auth: { persistSession: false } });
  const target = `${supabaseUrl.replace(/\/$/, "")}/functions/v1/outline-from-recipe`;
  try {
    const result = await runWatchdogOnce(db, async (runID) => {
      const continuation = await fetch(target, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": serviceKey,
          "Authorization": `Bearer ${serviceKey}`,
        },
        body: JSON.stringify(watchdogDispatchBody(runID)),
      });
      return continuation.status;
    });
    return response({ scanned: result.scanned, dispatched: result.statuses });
  } catch (err) {
    return response({ error: err instanceof Error ? err.message : String(err) }, 500);
  }
});
