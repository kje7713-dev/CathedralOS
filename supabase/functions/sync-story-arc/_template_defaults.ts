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

export function canonicalizeLegacyArcTemplate<T extends {
  name: string;
  description: string;
  beats: Array<{ role: string; label: string; description: string }>;
}>(
  incoming: T,
  catalog: { name?: string; description?: string; beats?: TemplateBeatDefault[] },
): T {
  if (catalog.name !== incoming.name || !Array.isArray(catalog.beats)) {
    return incoming;
  }
  return {
    ...incoming,
    // For a matching built-in catalog identity the description is fixed
    // template metadata, not an editable, project-specific Story Arc beat.
    description: catalog.description ?? incoming.description,
    beats: incoming.beats.map((beat) => ({
      ...beat,
      description: canonicalizeUnmodifiedBeatDetails({
        role: beat.role,
        label: beat.label,
        details: beat.description,
      }, catalog.beats!),
    })),
  };
}
