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

function retryDelaySeconds(failures: number): number {
  return Math.min(15 * 60, 2 ** Math.min(Math.max(failures, 0), 8) * 15);
}

export type WatchdogFailureKind = "none" | "transient" | "configuration";

export function classifyDispatchStatus(status: number): {
  failed: boolean;
  failureKind: WatchdogFailureKind;
} {
  if (status >= 200 && status < 300) {
    return { failed: false, failureKind: "none" };
  }
  // Transport failures and provider throttling/outages are retryable. Any
  // HTTP error is still a failed dispatch; 4xx configuration/auth/contract
  // errors must not be mistaken for a successful reset of watchdog state.
  if (status === 0 || status === 408 || status === 425 || status === 429 || status >= 500) {
    return { failed: true, failureKind: "transient" };
  }
  return { failed: true, failureKind: "configuration" };
}

/** One bounded scheduler pass; the cron handler and deterministic tests share this path. */
export async function runWatchdogOnce(
  db: any,
  dispatch: WatchdogDispatch,
  now = new Date(),
): Promise<{ scanned: number; statuses: Array<Record<string, unknown>> }> {
  const nowISO = now.toISOString();
  const { data: runs, error } = await db.from("outline_suggestion_runs")
    .select("id, watchdog_failures")
    .or(`and(status.eq.pending,watchdog_next_attempt_at.lte.${nowISO}),and(status.eq.running,lease_expires_at.lt.${nowISO},watchdog_next_attempt_at.lte.${nowISO})`)
    .order("watchdog_next_attempt_at", { ascending: true })
    .order("updated_at", { ascending: true })
    .limit(MAX_BATCH);
  if (error) throw new Error("could not list recoverable runs");

  const statuses: Array<Record<string, unknown>> = [];
  for (const run of runs ?? []) {
    try {
      const status = await dispatch(run.id);
      const classification = classifyDispatchStatus(status);
      const failed = classification.failed;
      const failures = Number(run.watchdog_failures ?? 0) + (failed ? 1 : 0);
      const backoff = failed ? retryDelaySeconds(failures) : 0;
      const nextAttemptAt = failed
        ? new Date(now.getTime() + backoff * 1000).toISOString()
        : nowISO;
      await db.from("outline_suggestion_runs").update({
        watchdog_failures: failed ? failures : 0,
        watchdog_next_attempt_at: nextAttemptAt,
      }).eq("id", run.id);
      statuses.push({ run_id: run.id, status, failureKind: classification.failureKind, backoff });
    } catch (err) {
      const failures = Number(run.watchdog_failures ?? 0) + 1;
      const nextAttemptAt = new Date(now.getTime() + retryDelaySeconds(failures) * 1000).toISOString();
      await db.from("outline_suggestion_runs").update({
        watchdog_failures: failures,
        watchdog_next_attempt_at: nextAttemptAt,
      }).eq("id", run.id);
      statuses.push({ run_id: run.id, error: err instanceof Error ? err.message : String(err), failureKind: "transient", backoff: retryDelaySeconds(failures) });
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
