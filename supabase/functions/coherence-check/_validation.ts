// =============================================================================
// coherence-check/_validation.ts
//
// Request + response validation for the coherence-check edge function. Pulled
// out of index.ts so index_test.ts can import the real implementation
// instead of mirroring it (kevbot-brain: mirror tests hide regressions).
// =============================================================================

export interface CurrentSection {
  id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  beat_label: string | null;
}

export interface CanonSection {
  section_id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  created_at: string;
  extracted_summary: string | null;
  character_deltas: unknown[];
  plot_thread_deltas: unknown[];
  continuity_facts: unknown[];
  open_loops: unknown[];
  scene_ending_state: unknown;
}

export interface PriorCanon {
  sections: CanonSection[];
}

export interface CoherenceCheckRequest {
  /** estimate performs preflight only; check performs the billable call. */
  action?: "estimate" | "check";
  /** Backend generation_models.id; never a provider model string from the client. */
  selected_model_id?: string;
  output_text: string;
  current_section: CurrentSection | null;
  prior_canon: PriorCanon;
  project_id?: string;
}

export interface CoherenceWarning {
  reason: string;
  severity: "warn" | "high";
}

export type ValidationResult =
  | { ok: true; request: CoherenceCheckRequest }
  | { ok: false; error: string };

export function validateRequest(body: unknown): ValidationResult {
  // deno-lint-ignore no-explicit-any
  const b = body as any;
  if (
    b?.action !== undefined && b.action !== "estimate" && b.action !== "check"
  ) {
    return { ok: false, error: "action must be estimate or check" };
  }
  if (
    b?.selected_model_id !== undefined &&
    typeof b.selected_model_id !== "string"
  ) {
    return { ok: false, error: "selected_model_id must be a string" };
  }
  if (typeof b?.output_text !== "string" || b.output_text.length === 0) {
    return { ok: false, error: "output_text required (non-empty string)" };
  }
  if (!b.prior_canon || typeof b.prior_canon !== "object") {
    return { ok: false, error: "prior_canon required (object)" };
  }
  if (!Array.isArray(b.prior_canon.sections)) {
    return { ok: false, error: "prior_canon.sections required (array)" };
  }
  if (b.current_section !== null && b.current_section !== undefined) {
    const cs = b.current_section;
    if (
      typeof cs.id !== "string" ||
      typeof cs.title !== "string" ||
      typeof cs.summary !== "string"
    ) {
      return {
        ok: false,
        error: "current_section requires id, title, summary (strings)",
      };
    }
  }
  return { ok: true, request: b as CoherenceCheckRequest };
}

export interface FilterResult {
  warnings: CoherenceWarning[];
  preFilterCount: number;
  postFilterCount: number;
}

export function validateAndFilterWarnings(raw: unknown): FilterResult {
  if (!raw || typeof raw !== "object") {
    return { warnings: [], preFilterCount: 0, postFilterCount: 0 };
  }
  // deno-lint-ignore no-explicit-any
  const r = raw as any;
  const list = Array.isArray(r.warnings) ? r.warnings : [];
  const preFilterCount = list.length;
  const warnings: CoherenceWarning[] = list
    // deno-lint-ignore no-explicit-any
    .filter((w: any) =>
      typeof w === "object" &&
      w !== null &&
      typeof w.reason === "string" &&
      w.reason.length > 0 &&
      (w.severity === "warn" || w.severity === "high")
    )
    // deno-lint-ignore no-explicit-any
    .map((w: any) => ({
      reason: w.reason as string,
      severity: w.severity === "high" ? "high" : "warn",
    }));
  return { warnings, preFilterCount, postFilterCount: warnings.length };
}
