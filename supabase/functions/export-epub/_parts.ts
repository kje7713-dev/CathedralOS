import type { Chapter } from "./_section_walker.ts";

export interface StoryArcBeat {
  id: string;
  position: number;
  role: string;
  label: string;
}

export interface StoryArcInfo {
  template_id: string | null;
  beats: StoryArcBeat[];
}

/** A source Part keeps semantic identity; position is never the rendered ordinal. */
export interface BookPart {
  id: string;
  position: number;
  source_semantic_part_index: number;
  label: string;
  default_subtitle: string | null;
  default_title: string;
  chapter_ids: string[];
  beat_ids: string[];
  beat_roles: string[];
}

export interface DerivedPartAssignments {
  /** Values are source semantic Part indexes, not compact rendered ordinals. */
  chapterPartById: Map<string, number>;
  parts: BookPart[];
}

const TEMPLATE_IDS = {
  threeAct: "a0000001-0000-0000-0000-000000000001",
  herosJourney: "a0000001-0000-0000-0000-000000000002",
  mystery: "a0000001-0000-0000-0000-000000000003",
  saveTheCat: "a0000001-0000-0000-0000-000000000004",
  storyCircle: "a0000001-0000-0000-0000-000000000005",
  freytagsPyramid: "a0000001-0000-0000-0000-000000000006",
  kishotenketsu: "a0000001-0000-0000-0000-000000000007",
} as const;

const THREE_PART_ROLES: Record<string, string[]> = {
  [TEMPLATE_IDS.threeAct]: [
    "setup",
    "inciting_incident",
    "first_plot_point",
    "rising_action",
    "midpoint",
    "crisis",
    "climax",
    "resolution",
  ],
  [TEMPLATE_IDS.herosJourney]: [
    "ordinary_world",
    "call_to_adventure",
    "refusal_of_call",
    "meeting_mentor",
    "crossing_threshold",
    "tests_allies_enemies",
    "approach_inmost_cave",
    "ordeal",
    "reward",
    "road_back",
    "resurrection",
    "return_with_elixir",
  ],
  [TEMPLATE_IDS.mystery]: [
    "the_crime",
    "investigation_begins",
    "first_suspect",
    "rising_tension",
    "key_revelation",
    "false_solution",
    "real_clue",
    "confrontation",
    "resolution",
  ],
  [TEMPLATE_IDS.saveTheCat]: [
    "opening_image",
    "theme_stated",
    "setup",
    "catalyst",
    "debate",
    "break_into_two",
    "b_story",
    "fun_and_games",
    "midpoint",
    "bad_guys_close_in",
    "all_is_lost",
    "dark_night_of_the_soul",
    "break_into_three",
    "finale",
    "final_image",
  ],
  [TEMPLATE_IDS.storyCircle]: [
    "you",
    "need",
    "go",
    "search",
    "find",
    "take",
    "return",
    "change",
  ],
};

const THREE_PART_BOUNDARIES: Record<string, number[]> = {
  [TEMPLATE_IDS.threeAct]: [3, 6, 8],
  [TEMPLATE_IDS.herosJourney]: [5, 9, 12],
  [TEMPLATE_IDS.mystery]: [3, 7, 9],
  [TEMPLATE_IDS.saveTheCat]: [5, 12, 15],
  [TEMPLATE_IDS.storyCircle]: [3, 6, 8],
};

const EXPLICIT_PARTS: Record<string, { roles: string[]; subtitles: string[] }> =
  {
    [TEMPLATE_IDS.freytagsPyramid]: {
      roles: [
        "exposition",
        "rising_action",
        "climax",
        "falling_action",
        "denouement",
      ],
      subtitles: [
        "Exposition",
        "Rising Action",
        "Climax",
        "Falling Action",
        "Denouement",
      ],
    },
    [TEMPLATE_IDS.kishotenketsu]: {
      roles: ["ki", "sho", "ten", "ketsu"],
      subtitles: ["Ki", "Shō", "Ten", "Ketsu"],
    },
  };

/** Derive source Parts, then normalize assignments without ever reordering chapters. */
export function derivePartAssignments(
  chapters: Chapter[],
  arc: StoryArcInfo | null,
): DerivedPartAssignments {
  const empty = {
    chapterPartById: new Map<string, number>(),
    parts: [] as BookPart[],
  };
  if (!arc || arc.beats.length === 0 || chapters.length === 0) return empty;

  const beats = [...arc.beats].sort((a, b) =>
    a.position - b.position || a.id.localeCompare(b.id)
  );
  const templateID = arc.template_id?.toLowerCase() ?? "";
  const explicit = EXPLICIT_PARTS[templateID];
  const semanticRoles = explicit?.roles ?? THREE_PART_ROLES[templateID] ?? [];
  const semanticPartCount = explicit?.roles.length ??
    (semanticRoles.length > 0 ? 3 : Math.min(3, beats.length));
  const desiredByBeat = new Map<string, number>();
  const desiredByRole = new Map<string, number>();

  if (explicit) {
    explicit.roles.forEach((role, index) => desiredByRole.set(role, index));
  } else if (semanticRoles.length > 0) {
    const boundaries = THREE_PART_BOUNDARIES[templateID];
    semanticRoles.forEach((role, index) =>
      desiredByRole.set(
        role,
        index < boundaries[0] ? 0 : index < boundaries[1] ? 1 : 2,
      )
    );
  }

  if (semanticRoles.length === 0) {
    for (const [index, beat] of beats.entries()) {
      desiredByBeat.set(
        beat.id.toLowerCase(),
        Math.floor(index * semanticPartCount / beats.length),
      );
    }
  } else {
    // Resolve role-bearing beats first, then make empty/unknown roles deterministic
    // by neighboring semantic identity. The beat ID remains authoritative.
    const desired = beats.map((beat) =>
      desiredByRole.get(beat.role.trim().toLowerCase())
    );
    let nextKnown = semanticPartCount - 1;
    for (let index = desired.length - 1; index >= 0; index--) {
      if (desired[index] !== undefined) nextKnown = desired[index]!;
      else desired[index] = nextKnown;
    }
    let previous = desired[0] ?? 0;
    for (const [index, beat] of beats.entries()) {
      const rolePart = desiredByRole.get(beat.role.trim().toLowerCase());
      if (rolePart !== undefined) previous = rolePart;
      else desired[index] = index === 0 ? desired[index] ?? 0 : previous;
      desiredByBeat.set(
        beat.id.toLowerCase(),
        Math.max(0, desired[index] ?? previous),
      );
    }
  }

  const rawChapterParts = chapters.map((chapter) => {
    for (const section of chapter.sections) {
      const beatID = section.story_arc_beat_id?.toLowerCase();
      if (beatID && desiredByBeat.has(beatID)) return desiredByBeat.get(beatID);
    }
    return undefined;
  });
  const taggedIndexes = rawChapterParts.flatMap((value, index) =>
    value === undefined ? [] : [index]
  );
  const firstTagged = taggedIndexes[0];
  const lastTagged = taggedIndexes.at(-1);
  const normalized: number[] = [];
  let current = 0;
  for (const [index, raw] of rawChapterParts.entries()) {
    let target: number;
    if (raw !== undefined) {
      target = raw;
    } else if (firstTagged === undefined || index < firstTagged) {
      target = 0;
    } else if (lastTagged !== undefined && index > lastTagged) {
      // A trailing untagged chapter belongs to the final semantic Part, even if
      // no chapter is tagged with that Part. This is still a source Part, not a
      // new Part invented for the untagged chapter.
      target = semanticPartCount - 1;
    } else {
      target = current;
    }
    // Keep the existing safety invariant for non-monotonic semantic tags: Part
    // membership can never force prose into a different manuscript order.
    current = Math.max(current, target);
    normalized.push(current);
  }

  const used = [...new Set(normalized)].sort((a, b) => a - b);
  const chapterPartById = new Map<string, number>();
  chapters.forEach((chapter, index) =>
    chapterPartById.set(chapter.id, normalized[index])
  );
  const subtitleFor = (source: number): string | null =>
    explicit?.subtitles[source] ?? null;
  const labelFor = (source: number): string => `Part ${roman(source + 1)}`;
  const parts = used.map((source) => {
    const chapterIDs = chapters.filter((chapter) =>
      chapterPartById.get(chapter.id) === source
    ).map((chapter) => chapter.id);
    const partBeatEntries = beats.filter((beat) =>
      desiredByBeat.get(beat.id.toLowerCase()) === source
    );
    const label = labelFor(source);
    const subtitle = subtitleFor(source);
    return {
      id: `part-${source + 1}`,
      position: source,
      source_semantic_part_index: source,
      label,
      default_subtitle: subtitle,
      default_title: subtitle ? `${label} — ${subtitle}` : label,
      chapter_ids: chapterIDs,
      beat_ids: partBeatEntries.map((beat) => beat.id),
      beat_roles: partBeatEntries.map((beat) => beat.role).filter(Boolean),
    } satisfies BookPart;
  });
  return { chapterPartById, parts };
}

export function deriveBookParts(
  chapters: Chapter[],
  arc: StoryArcInfo | null,
): BookPart[] {
  return derivePartAssignments(chapters, arc).parts;
}

function roman(value: number): string {
  return [
    "I",
    "II",
    "III",
    "IV",
    "V",
    "VI",
    "VII",
    "VIII",
    "IX",
    "X",
  ][value - 1] ?? String(value);
}
