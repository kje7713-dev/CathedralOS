// =============================================================================
// _repair.ts — Bounded repair layer for EPUBCheck-detected defects
//
// Strategy: initial validation → max 1 repair → final validation.
// No retry loop. Unknown errors → surfaced for follow-up.
//
// Repairable classes (per locked plan):
//   1. Manifest/spine mismatches
//   2. Missing generated files/references
//   3. Missing required metadata when Cathedral already has the value
//   4. Malformed generated XHTML/XML from escaping/sanitization
//
// NOT repaired in PR-4100-A:
//   - EPUBCheck errors that aren't Cathedral's fault
//   - Spec compliance requiring writer redesign (track in repair_backlog)
// =============================================================================

import type { ExportMetadata } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";
import type { ValidationDiagnostic } from "./_validator_client.ts";

export interface RepairResult {
  repaired: boolean;
  epub?: Uint8Array;
  reason?: string;        // if !repaired, why we couldn't fix
  fixApplied?: string;    // if repaired, what fix we applied (for telemetry)
}

export interface RepairContext {
  metadata: ExportMetadata;
  outline: ProjectOutline;
  coverBuffer: Uint8Array | null;
}

export async function attemptRepair(
  _epub: Uint8Array,
  _diagnostics: ValidationDiagnostic[],
  _context: RepairContext,
): Promise<RepairResult> {
  // TODO: PR-4100-A follow-up
  // Pattern-match diagnostics against the 4 known classes:
  //   1. Manifest/spine mismatch:
  //      - Detect: spine references non-existent section
  //      - Fix: rebuild spine from outline.chapters (regenerate OPF spine)
  //   2. Missing generated files/refs:
  //      - Detect: OPF href to non-existent xhtml
  //      - Fix: re-emit missing file from outline data
  //   3. Missing required metadata:
  //      - Detect: dc:title empty when metadata.book_title is non-empty
  //      - Fix: patch OPF metadata block + rebuild
  //   4. Malformed XHTML/XML:
  //      - Detect: unescaped & in content docs
  //      - Fix: re-sanitize + rewrite affected doc
  //
  // Unknown errors: return { repaired: false, reason: "unrepairable" }
  // Deterministic match → return { repaired: true, epub: newBytes, fixApplied: "..." }
  throw new Error("_repair.attemptRepair: not yet implemented");
}
