import type {
  ProjectOutline,
  Section,
} from "../export-epub/_section_walker.ts";
import { CURRENT_MEMORY_PIPELINE_VERSION } from "../_shared/memory-pipeline.ts";

export type SynopsisMemoryRow = {
  outline_section_id: string;
  generation_output_id: string | null;
  memory_pipeline_version: string | null;
  extracted_summary: string | null;
  character_deltas: unknown;
  plot_thread_deltas: unknown;
  continuity_facts: unknown;
  open_loops: unknown;
  scene_ending_state: unknown;
};

export class SynopsisMemoryError extends Error {
  constructor(
    public readonly code: "memory_missing" | "memory_stale",
    message: string = code,
  ) {
    super(message);
    this.name = "SynopsisMemoryError";
  }
}

const clean = (value: unknown, limit: number): string =>
  typeof value === "string"
    ? value.replace(/\s+/g, " ").trim().slice(0, limit)
    : "";

const record = (value: unknown): Record<string, unknown> =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};

function compactItems(
  value: unknown,
  limit: number,
  formatter: (item: Record<string, unknown>) => string,
): string[] {
  if (!Array.isArray(value)) return [];
  return value.map((item) => formatter(record(item))).filter(Boolean).map((
    item,
  ) => item.slice(0, limit));
}

function sectionMemory(section: Section, row: SynopsisMemoryRow): string {
  const characters = compactItems(row.character_deltas, 220, (item) => {
    const name = clean(item.character_name, 70);
    const changes = [
      item.knowledge_delta,
      item.relationship_delta,
      item.goals,
      item.injuries,
      item.emotional_stance,
    ]
      .map((value) => clean(value, 120)).filter(Boolean).join("; ");
    return name && changes ? `${name}: ${changes}` : name || changes;
  });
  const threads = compactItems(row.plot_thread_deltas, 260, (item) => {
    const name = clean(item.thread_name, 80);
    const status = clean(item.status, 20);
    const description = clean(item.description, 160);
    return [name, status ? `(${status})` : "", description].filter(Boolean)
      .join(" ");
  });
  const facts = compactItems(
    row.continuity_facts,
    220,
    (item) =>
      item.active === false ? "" : clean(item.fact ?? item.description, 210),
  );
  const loops = compactItems(
    row.open_loops,
    200,
    (item) => item.status === "resolved" ? "" : clean(item.description, 190),
  );
  const ending = record(row.scene_ending_state);
  const pressure = clean(ending.immediate_pressure, 200);
  const parts = [
    `Section ${section.title || section.id}: ${
      clean(row.extracted_summary, 520)
    }`,
    characters.length ? `Character changes: ${characters.join(" | ")}` : "",
    threads.length ? `Plot threads: ${threads.join(" | ")}` : "",
    facts.length ? `Consequences: ${facts.join(" | ")}` : "",
    loops.length ? `Open hooks: ${loops.join(" | ")}` : "",
    pressure ? `Ending pressure: ${pressure}` : "",
  ];
  return parts.filter(Boolean).join("\n");
}

export function buildSynopsisMemoryContext(
  outline: ProjectOutline,
  rows: SynopsisMemoryRow[],
): string {
  const byOutput = new Map(
    rows.map((row) => [String(row.generation_output_id).toLowerCase(), row]),
  );
  const sections = outline.chapters.flatMap((chapter) => chapter.sections);
  const selected = sections.filter((section) => section.body.trim());
  if (selected.some((section) => !section.generation_output_id)) {
    throw new SynopsisMemoryError(
      "memory_missing",
      "exported section has no generation lineage",
    );
  }
  const orderedRows = selected.map((section) => {
    const row = byOutput.get(
      String(section.generation_output_id).toLowerCase(),
    );
    if (!row) {
      throw new SynopsisMemoryError(
        "memory_missing",
        `memory missing for output ${section.generation_output_id}`,
      );
    }
    if (row.memory_pipeline_version !== CURRENT_MEMORY_PIPELINE_VERSION) {
      throw new SynopsisMemoryError(
        "memory_stale",
        `memory is stale for output ${section.generation_output_id}`,
      );
    }
    if (
      String(row.outline_section_id).toLowerCase() !==
        String(section.id).toLowerCase() &&
      String(section.id).toLowerCase() !==
        String(section.generation_output_id).toLowerCase()
    ) {
      throw new SynopsisMemoryError(
        "memory_missing",
        "memory section lineage mismatch",
      );
    }
    if (
      String(row.generation_output_id).toLowerCase() !==
        String(section.generation_output_id).toLowerCase()
    ) {
      throw new SynopsisMemoryError(
        "memory_missing",
        "memory lineage mismatch",
      );
    }
    return { section, row };
  });
  const brief = outline.storyBrief
    ? Object.entries(outline.storyBrief).map(([key, value]) =>
      `${key}: ${clean(value, 700)}`
    ).filter(Boolean).join("\n")
    : "";
  const narrative = orderedRows.map(({ section, row }) =>
    sectionMemory(section, row)
  ).join("\n\n");
  return [
    `Title: ${outline.title}`,
    brief ? `Story metadata (supporting context only):\n${brief}` : "",
    "Completed scene memory in canonical EPUB order:",
    narrative,
  ].filter(Boolean).join("\n\n");
}
