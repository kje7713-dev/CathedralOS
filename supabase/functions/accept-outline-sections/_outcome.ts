export type AcceptRunTerminalOutcome = {
  status: "completed" | "failed";
  error: string | null;
};

/**
 * The snapshot commit is part of Accept All's durable completion contract.
 * Section work can be 6/6 while the final snapshot write fails, so section
 * counters alone must never determine success.
 */
export function acceptRunTerminalOutcome(
  sectionsFailed: number,
  snapshotError: string | null,
  sectionError: string | null,
): AcceptRunTerminalOutcome {
  if (snapshotError) {
    return { status: "failed", error: snapshotError.slice(0, 2000) };
  }
  if (sectionsFailed > 0) {
    return {
      status: "failed",
      error: sectionError?.slice(0, 2000) ??
        `${sectionsFailed} section(s) failed`,
    };
  }
  return { status: "completed", error: null };
}
