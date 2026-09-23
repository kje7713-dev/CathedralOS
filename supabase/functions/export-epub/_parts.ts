import type { Chapter, Section } from "./_section_walker.ts";

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

export interface BookPart {
  id: string;
  position: number;
  default_title: string;
  chapter_ids: string[];
  beat_roles: string[];
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

const EXPLICIT_PARTS: Record<string, { roles: string[]; titles: string[] }> = {
  [TEMPLATE_IDS.freytagsPyramid]: {
    roles: [
      "exposition",
      "rising_action",
      "climax",
      "falling_action",
      "denouement",
    ],
    titles: [
      "Part I — Exposition",
      "Part II — Rising Action",
      "Part III — Climax",
      "Part IV — Falling Action",
      "Part V — Denouement",
    ],
  },
  [TEMPLATE_IDS.kishotenketsu]: {
    roles: ["ki", "sho", "ten", "ketsu"],
    titles: [
      "Part I — Ki",
      "Part II — Shō",
      "Part III — Ten",
      "Part IV — Ketsu",
    ],
  },
};

export function deriveBookParts(
  chapters: Chapter[],
  arc: StoryArcInfo | null,
): BookPart[] {
  if (!arc || arc.beats.length === 0 || chapters.length === 0) return [];

  const orderedBeats = [...arc.beats].sort((a, b) => a.position - b.position);
  const templateID = arc.template_id?.toLowerCase() ?? "";
  const explicit = EXPLICIT_PARTS[templateID];
  const threePartRoles = THREE_PART_ROLES[templateID];
  const roles = explicit?.roles ?? threePartRoles ??
    orderedBeats.map((b) => b.role);
  if (roles.length === 0) return [];

  const partCount = explicit?.roles.length ??
    (threePartRoles ? 3 : Math.min(3, roles.length));
  const roleToPart = new Map<string, number>();
  if (explicit) {
    explicit.roles.forEach((role, index) => roleToPart.set(role, index));
  } else if (threePartRoles) {
    const boundaries = THREE_PART_BOUNDARIES[templateID];
    threePartRoles.forEach((role, index) => {
      roleToPart.set(
        role,
        index < boundaries[0] ? 0 : index < boundaries[1] ? 1 : 2,
      );
    });
  } else {
    // Custom arcs use contiguous thirds of the ordered beats. This is stable,
    // preserves order, and never invents a fourth hierarchy level.
    const base = Math.ceil(roles.length / partCount);
    roles.forEach((role, index) =>
      roleToPart.set(role, Math.min(partCount - 1, Math.floor(index / base)))
    );
  }

  const chapterParts = new Map<string, number>();
  let previousPart = 0;
  const taggedChapterParts: Array<{ chapterIndex: number; part: number }> = [];
  for (let index = 0; index < chapters.length; index++) {
    const role = chapterRole(chapters[index].sections);
    const part = role ? roleToPart.get(role) : undefined;
    if (part !== undefined) {
      previousPart = part;
      taggedChapterParts.push({ chapterIndex: index, part });
      chapterParts.set(chapters[index].id, part);
    } else if (taggedChapterParts.length > 0) {
      chapterParts.set(chapters[index].id, previousPart);
    } else {
      chapterParts.set(chapters[index].id, 0);
    }
  }

  // If a malformed/custom arc skips a group, compact the result so no empty
  // Part is emitted and all generated chapters remain assigned exactly once.
  const used = new Set(chapterParts.values());
  const remap = new Map<number, number>();
  [...used].sort((a, b) => a - b).forEach((part, index) =>
    remap.set(part, index)
  );
  const compacted = new Map<string, number>();
  for (const [chapterID, part] of chapterParts) {
    compacted.set(chapterID, remap.get(part) ?? 0);
  }

  const titles = explicit?.titles ??
    Array.from({ length: partCount }, (_, i) => `Part ${roman(i + 1)}`);
  return [...remap.entries()].sort((a, b) => a[1] - b[1]).map(
    ([sourcePart, position]) => {
      const chapterIDs = chapters.filter((chapter) =>
        compacted.get(chapter.id) === position
      ).map((chapter) => chapter.id);
      const beatRoles = roles.filter((role) =>
        (roleToPart.get(role) ?? 0) === sourcePart
      );
      return {
        id: `part-${position + 1}`,
        position,
        default_title: titles[sourcePart] ?? `Part ${roman(position + 1)}`,
        chapter_ids: chapterIDs,
        beat_roles: beatRoles,
      };
    },
  ).filter((part) => part.chapter_ids.length > 0);
}

function chapterRole(sections: Section[]): string | null {
  return sections.find((section) => section.story_arc_beat_id)
    ?.story_arc_role ?? null;
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
