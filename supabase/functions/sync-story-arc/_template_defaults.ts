// Preserve new built-in Story Arc instructions when a previously installed
// client syncs an unchanged local copy of an older template default.
// Author-edited descriptions, renamed beats, custom roles, and missing beats
// remain entirely under the author's control.
export interface TemplateBeatDefault {
  role?: string;
  label?: string;
  description?: string;
}

export interface IncomingArcBeat {
  role?: string;
  label?: string;
  details?: string;
}

const PROGRESSION_MARKER = " Creative progression: ";

export function canonicalizeUnmodifiedBeatDetails(
  incoming: IncomingArcBeat,
  defaults: TemplateBeatDefault[],
): string {
  const current = incoming.details ?? "";
  if (!incoming.role || !incoming.label) return current;
  const original = defaults.find((b) =>
    b.role === incoming.role && b.label === incoming.label
  );
  const description = original?.description;
  if (typeof description !== "string") return current;
  const marker = description.indexOf(PROGRESSION_MARKER);
  if (marker < 1) return current;
  // The prefix is the old canonical default; only upgrade EXACT matches.
  // An arbitrary value must never become an excuse to overwrite an author edit.
  const earlierDefault = description.slice(0, marker);
  return current === earlierDefault ? description : current;
}
