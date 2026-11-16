import type {
  ProjectOutline,
  Section,
} from "../export-epub/_section_walker.ts";
import { CURRENT_MEMORY_PIPELINE_VERSION } from "../_shared/memory-pipeline.ts";

export const MAX_SYNOPSIS_CONTEXT_CHARS = 48_000;

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

function sectionMemory(
  section: Section,
  row: SynopsisMemoryRow,
  summaryLimit: number,
  includeDetails = true,
): string {
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
      clean(row.extracted_summary, summaryLimit)
    }`,
    includeDetails && characters.length
      ? `Changes: ${characters.map((item) => item.slice(0, 100)).join(" | ")}`
      : "",
    includeDetails && threads.length
      ? `Threads: ${threads.map((item) => item.slice(0, 110)).join(" | ")}`
      : "",
    includeDetails && facts.length
      ? `Consequences: ${facts.map((item) => item.slice(0, 100)).join(" | ")}`
      : "",
    includeDetails && pressure ? `Pressure: ${pressure}` : "",
  ];
  return parts.filter(Boolean).join("\n");
}

type Aggregate = {
  characters: Map<string, Record<string, string>>;
  threads: Map<string, Record<string, string>>;
  facts: Map<string, Record<string, string | boolean>>;
  loops: Map<string, Record<string, string>>;
};

function itemText(item: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = clean(item[key], 300);
    if (value) return value;
  }
  return "";
}

function itemKey(item: Record<string, unknown>, fallback: string): string {
  return (itemText(
    item,
    "reference",
    "id",
    "thread_name",
    "description",
    "fact",
  ) || fallback)
    .toLocaleLowerCase();
}

function aggregateMemory(rows: SynopsisMemoryRow[]): Aggregate {
  const aggregate: Aggregate = {
    characters: new Map(),
    threads: new Map(),
    facts: new Map(),
    loops: new Map(),
  };
  for (const row of rows) {
    for (
      const raw of Array.isArray(row.character_deltas)
        ? row.character_deltas
        : []
    ) {
      const item = record(raw);
      const name = itemText(item, "character_name");
      if (!name) continue;
      const key = name.toLocaleLowerCase();
      const prior = aggregate.characters.get(key) ?? { name };
      for (
        const field of [
          "location",
          "knowledge_delta",
          "relationship_delta",
          "injuries",
          "goals",
          "possessions",
          "emotional_stance",
        ]
      ) {
        const value = clean(item[field], 220);
        if (value) prior[field] = value;
      }
      aggregate.characters.set(key, prior);
    }
    for (
      const raw of Array.isArray(row.plot_thread_deltas)
        ? row.plot_thread_deltas
        : []
    ) {
      const item = record(raw);
      const key = itemKey(item, "thread");
      const prior = aggregate.threads.get(key) ?? {};
      for (const field of ["thread_name", "status", "description"]) {
        const value = clean(item[field], 260);
        if (value) prior[field] = value;
      }
      aggregate.threads.set(key, prior);
    }
    for (
      const raw of Array.isArray(row.continuity_facts)
        ? row.continuity_facts
        : []
    ) {
      const item = record(raw);
      const key = itemKey(item, "fact");
      const prior = aggregate.facts.get(key) ?? {};
      const fact = itemText(item, "fact", "description");
      if (fact) prior.fact = fact;
      prior.active = item.active !== false;
      aggregate.facts.set(key, prior);
    }
    for (const raw of Array.isArray(row.open_loops) ? row.open_loops : []) {
      const item = record(raw);
      const key = itemKey(item, "loop");
      const prior = aggregate.loops.get(key) ?? {};
      const description = itemText(item, "description");
      if (description) prior.description = description;
      prior.status = clean(item.status, 20) || "open";
      aggregate.loops.set(key, prior);
    }
  }
  return aggregate;
}

function aggregateContext(rows: SynopsisMemoryRow[]): string {
  const aggregate = aggregateMemory(rows);
  const characters = [...aggregate.characters.values()].map((item) =>
    `${item.name}: ${
      [
        item.relationship_delta,
        item.knowledge_delta,
        item.goals,
        item.location,
        item.emotional_stance,
      ].filter(Boolean).join("; ")
    }`
  );
  const threads = [...aggregate.threads.values()].map((item) =>
    `${item.thread_name ?? "Thread"} (${item.status ?? "unknown"}): ${
      item.description ?? ""
    }`
  );
  const facts = [...aggregate.facts.values()].filter((item) =>
    item.active !== false
  ).map((item) => String(item.fact ?? ""));
  const loops = [...aggregate.loops.values()].filter((item) =>
    item.status !== "resolved"
  ).map((item) => String(item.description ?? ""));
  return [
    "Current reconciled story state:",
    characters.length ? `Characters: ${characters.join(" | ")}` : "",
    threads.length ? `Plot threads: ${threads.join(" | ")}` : "",
    facts.length ? `Active consequential facts: ${facts.join(" | ")}` : "",
    loops.length ? `Open narrative loops: ${loops.join(" | ")}` : "",
  ].filter(Boolean).join("\n").slice(0, 12_000);
}

function fitNarrative(
  orderedRows: Array<{ section: Section; row: SynopsisMemoryRow }>,
  budget: number,
): string {
  if (!orderedRows.length || budget <= 0) return "";
  const contentBudget = Math.max(0, budget - (orderedRows.length - 1) * 2);
  const anchorIndexes = new Set([
    0,
    Math.floor(orderedRows.length / 2),
    Math.floor(orderedRows.length * 0.75),
    orderedRows.length - 1,
  ]);
  const anchorBudget = Math.min(
    160,
    Math.floor(contentBudget / Math.max(1, anchorIndexes.size)),
  );
  const regularBudget = Math.max(
    0,
    Math.floor(
      (contentBudget - anchorBudget * anchorIndexes.size) /
        Math.max(1, orderedRows.length - anchorIndexes.size),
    ),
  );
  return orderedRows.map(({ section, row }, index) => {
    const limit = anchorIndexes.has(index) ? anchorBudget : regularBudget;
    return limit > 0
      ? sectionMemory(section, row, Math.max(1, limit - 40), false).slice(
        0,
        limit,
      )
      : "";
  }).filter(Boolean).join("\n\n");
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
  const aggregate = aggregateContext(orderedRows.map(({ row }) => row));
  const titleContext = `Title: ${outline.title}`;
  const fixedBudget = Math.max(
    0,
    MAX_SYNOPSIS_CONTEXT_CHARS - aggregate.length - 4,
  );
  const briefBudget = Math.max(0, fixedBudget - titleContext.length - 2);
  const boundedBrief = brief.slice(0, briefBudget);
  const fixed = [
    titleContext,
    boundedBrief
      ? `Story metadata (supporting context only):\n${boundedBrief}`
      : "",
    "Completed scene memory in canonical EPUB order:",
  ].filter(Boolean).join("\n\n");
  const available = Math.max(
    0,
    MAX_SYNOPSIS_CONTEXT_CHARS - fixed.length - aggregate.length - 4,
  );
  const summaryLimit = Math.max(
    120,
    Math.floor(available / Math.max(1, orderedRows.length)),
  );
  const narrative = available > 0
    ? orderedRows.map(({ section, row }) =>
      sectionMemory(section, row, Math.min(420, summaryLimit))
    ).join("\n\n")
    : "";
  const boundedNarrative = narrative.length <= available
    ? narrative
    : fitNarrative(orderedRows, available);
  const prefix = [fixed, boundedNarrative].filter(Boolean).join("\n\n");
  const aggregateBudget = Math.max(
    0,
    MAX_SYNOPSIS_CONTEXT_CHARS - prefix.length - 2,
  );
  return aggregateBudget > 0
    ? `${prefix}\n\n${aggregate.slice(0, aggregateBudget)}`
    : prefix;
}
