import { assertEquals } from "jsr:@std/assert@1";
import { isRecoverableRun, watchdogDispatchBody } from "./_logic.ts";

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
