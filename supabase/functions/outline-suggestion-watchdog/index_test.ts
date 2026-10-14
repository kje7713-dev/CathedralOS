import { assertEquals } from "jsr:@std/assert@1";
import { isRecoverableRun, watchdogDispatchBody } from "./_logic.ts";
import { runWatchdogOnce } from "./index.ts";

Deno.test("watchdog recovers pending runs and expired leases only", () => {
  const now = Date.parse("2026-10-14T17:00:00.000Z");
  assertEquals(isRecoverableRun({ id: "pending", status: "pending" }, now), true);
  assertEquals(isRecoverableRun({ id: "expired", status: "running", lease_expires_at: "2026-10-14T16:59:59.000Z" }, now), true);
  assertEquals(isRecoverableRun({ id: "active", status: "running", lease_expires_at: "2026-10-14T17:01:00.000Z" }, now), false);
  assertEquals(isRecoverableRun({ id: "done", status: "completed" }, now), false);
});

Deno.test("watchdog dispatch is bound to one durable run identity", () => {
  assertEquals(watchdogDispatchBody("run-123"), { watchdog_run_id: "run-123" });
});


Deno.test("watchdog backs off failed dispatches so newer jobs can become due", async () => {
  const row: any = { id: "run-stuck", status: "pending", watchdog_failures: 0, watchdog_next_attempt_at: "2026-10-14T17:00:00.000Z" };
  const db = {
    from(_table: string) {
      const query: any = {
        patch: null as Record<string, unknown> | null,
        select() { return query; }, update(value: Record<string, unknown>) { query.patch = value; return query; },
        eq() { return query; }, or() { return query; }, order() { return query; }, limit() { return query; },
        then(resolve: (value: unknown) => unknown) {
          if (query.patch) { Object.assign(row, query.patch); return Promise.resolve(resolve({ data: null, error: null })); }
          const due = new Date(row.watchdog_next_attempt_at).getTime() <= Date.parse("2026-10-14T17:00:00.000Z");
          return Promise.resolve(resolve({ data: due ? [{ id: row.id, watchdog_failures: row.watchdog_failures }] : [], error: null }));
        },
      };
      return query;
    },
  };
  const result = await runWatchdogOnce(db, async () => 503, new Date("2026-10-14T17:00:00.000Z"));
  assertEquals(result.statuses[0].backoff, 30);
  assertEquals(row.watchdog_failures, 1);
  assertEquals(row.watchdog_next_attempt_at, "2026-10-14T17:00:30.000Z");
});

Deno.test("scheduled watchdog resumes one abandoned checkpoint without replaying settled stages", async () => {
  const row: any = {
    id: "run-abandoned",
    status: "pending",
    lease_expires_at: null,
    checkpoint: "outline_generation",
    settledStages: ["enrichment", "allocation"],
    providerCalls: 0,
    workerClaims: 0,
  };
  const db = {
    from(_table: string) {
      const query: any = {
        patch: null as Record<string, unknown> | null,
        select() { return query; },
        update(value: Record<string, unknown>) { query.patch = value; return query; },
        eq() { return query; },
        or() { return query; },
        order() { return query; },
        limit() { return query; },
        then(resolve: (value: unknown) => unknown) {
          if (query.patch) {
            Object.assign(row, query.patch);
            return Promise.resolve(resolve({ data: null, error: null }));
          }
          const due = (row.status === "pending" || row.status === "running") &&
            (!row.watchdog_next_attempt_at || new Date(row.watchdog_next_attempt_at).getTime() <= Date.now());
          return Promise.resolve(resolve({ data: due ? [{ id: row.id, watchdog_failures: row.watchdog_failures ?? 0 }] : [], error: null }));
        },
      };
      return query;
    },
  };
  let dispatches = 0;
  const dispatch = async (runID: string): Promise<number> => {
    dispatches += 1;
    const request = new Request("https://project.supabase.co/functions/v1/outline-from-recipe", {
      method: "POST",
      headers: {
        "apikey": "operator-secret",
        "Authorization": "Bearer operator-secret",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ watchdog_run_id: runID }),
    });
    if (request.headers.get("apikey") !== "operator-secret") throw new Error("operator auth missing");
    const body = await request.json() as { watchdog_run_id?: string };
    if (body.watchdog_run_id !== row.id) throw new Error("wrong durable run identity");
    // This is the privileged continuation endpoint's atomic worker claim.
    if (row.status !== "pending") return 200;
    row.status = "running";
    row.workerClaims += 1;
    // Resume from the persisted outline checkpoint. Settled enrichment and
    // allocation stages are intentionally not dispatched again or charged.
    if (row.checkpoint === "outline_generation") row.providerCalls += 1;
    row.status = "completed";
    return 202;
  };

  const first = await runWatchdogOnce(db, dispatch, new Date("2026-10-14T17:00:00Z"));
  const second = await runWatchdogOnce(db, dispatch, new Date("2026-10-14T17:01:00Z"));
  assertEquals(first.scanned, 1);
  assertEquals(first.statuses, [{ run_id: row.id, status: 202, backoff: 0 }]);
  assertEquals(second.scanned, 0);
  assertEquals(dispatches, 1);
  assertEquals(row.workerClaims, 1);
  assertEquals(row.providerCalls, 1);
  assertEquals(row.settledStages, ["enrichment", "allocation"]);
  assertEquals(row.status, "completed");
});
