export interface WatchdogRun {
  id: string;
  status?: string | null;
  lease_expires_at?: string | null;
}

export function isRecoverableRun(run: WatchdogRun, now = Date.now()): boolean {
  if (run.status === "pending") return true;
  return run.status === "running" && !!run.lease_expires_at &&
    new Date(run.lease_expires_at).getTime() < now;
}

export function watchdogDispatchBody(runID: string): { watchdog_run_id: string } {
  return { watchdog_run_id: runID };
}
