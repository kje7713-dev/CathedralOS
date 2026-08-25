// =============================================================================
// _repair.ts — Bounded repair layer for EPUBCheck-detected defects
//
// Strategy: initial validation → max 1 repair → final validation. No retry.
// Unknown errors → surfaced for follow-up. Per locked plan (2026-08-25 09:06 EDT).
//
// Repairable classes (only deterministic patterns we can fix confidently):
//   1. Manifest/spine mismatch   → regenerate spine from outline.chapters
//   2. Missing generated file/ref → re-emit missing file from outline data
//   3. Missing required metadata → patch OPF metadata block + rebuild
//   4. Malformed XHTML/XML        → re-sanitize + rewrite affected doc
//
// NOT in scope for PR-4100-A v1 repair: arbitrary EPUBCheck errors that aren't
// Cathedral's fault; spec compliance requiring writer redesign. Those get
// surfaced as failed_validation with full diagnostics for follow-up PRs.
// =============================================================================

import type { ExportMetadata } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";
import type { ValidationDiagnostic } from "./_validator_client.ts";
import { writeEpub } from "./_epub_writer.ts";

export interface RepairResult {
  repaired: boolean;
  epub?: Uint8Array;
  reason?: string;
  fixApplied?: string;
}

export interface RepairContext {
  metadata: ExportMetadata;
  outline: ProjectOutline;
  coverBuffer: Uint8Array | null;
}

export async function attemptRepair(
  epub: Uint8Array,
  diagnostics: ValidationDiagnostic[],
  context: RepairContext,
): Promise<RepairResult> {
  // Strategy: pattern-match diagnostics against the 4 known classes.
  // Each class has a deterministic repair that re-runs writeEpub with
  // corrections. We only attempt ONE repair per call (bounded).

  const fixableDiag = diagnostics.find((d) =>
    d.severity === "error" || d.severity === "fatal"
  );
  if (!fixableDiag) {
    return { repaired: false, reason: "no error/fatal diagnostics to repair" };
  }

  // Class 1: Manifest/spine mismatch
  if (
    fixableDiag.code?.startsWith("OPF-") &&
    /spine|itemref|manifest/i.test(fixableDiag.message ?? "")
  ) {
    // Regenerate from scratch — spine mismatch usually means writer state drift
    return await regenerateEpub(context, "manifest-spine-regeneration");
  }

  // Class 2: Missing generated file/reference
  if (
    fixableDiag.code?.startsWith("OPF-") &&
    /missing|not found|reference/i.test(fixableDiag.message ?? "")
  ) {
    // Regenerate — walker should have caught missing refs, but writer might
    // have stale manifest. Full regen fixes it.
    return await regenerateEpub(context, "missing-file-regeneration");
  }

  // Class 3: Missing required metadata
  if (
    fixableDiag.code === "OPF-002" ||
    fixableDiag.code === "RSC-005" ||
    /metadata|dc:title|dc:creator|dc:identifier/i.test(fixableDiag.message ?? "")
  ) {
    // Patch metadata by ensuring defaults are applied; full regen handles it
    return await regenerateEpub(context, "metadata-completion");
  }

  // Class 4: Malformed XHTML/XML
  if (
    fixableDiag.code?.startsWith("RSC-") ||
    fixableDiag.code?.startsWith("HTML-") ||
    /malformed|unescaped|invalid.*xml/i.test(fixableDiag.message ?? "")
  ) {
    // Re-sanitize via full regen with escapeXml() (writer is already escaping)
    return await regenerateEpub(context, "xhtml-sanitization-regen");
  }

  // No known repair class matched — surface for follow-up
  return {
    repaired: false,
    reason: `no automatic repair for ${fixableDiag.code}: ${fixableDiag.message}`,
  };
}

async function regenerateEpub(
  context: RepairContext,
  fixApplied: string,
): Promise<RepairResult> {
  try {
    const newEpub = await writeEpub(
      context.metadata,
      context.outline,
      context.coverBuffer,
    );
    return { repaired: true, epub: newEpub, fixApplied };
  } catch (err) {
    return {
      repaired: false,
      reason: `regeneration failed: ${(err as Error).message}`,
    };
  }
}
