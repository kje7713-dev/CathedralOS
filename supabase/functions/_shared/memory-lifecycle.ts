// Server-owned lifecycle reconciliation for structured scene memory.
// LLM output is semantic input only; IDs and lifecycle state are canonicalized here.

export type MemoryRow = {
  character_deltas?: unknown;
  plot_thread_deltas?: unknown;
  continuity_facts?: unknown;
  open_loops?: unknown;
};

type AnyRecord = Record<string, unknown>;

const text = (value: unknown): string => typeof value === "string" ? value.trim() : "";
const key = (value: string): string => value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const uuid = (): string => crypto.randomUUID();

function words(value: string): Set<string> {
  return new Set(key(value).split(/\s+/).filter((word) => word.length > 2));
}
function similarity(a: string, b: string): number {
  const left = words(a);
  const right = words(b);
  if (!left.size || !right.size) return 0;
  let overlap = 0;
  for (const word of left) if (right.has(word)) overlap++;
  return overlap / Math.max(left.size, right.size);
}

function priorItems(rows: MemoryRow[], field: keyof MemoryRow): AnyRecord[] {
  const items: AnyRecord[] = [];
  for (const row of rows) {
    const value = row[field];
    if (!Array.isArray(value)) continue;
    for (const item of value) {
      if (item && typeof item === "object") items.push(item as AnyRecord);
    }
  }
  return items;
}

function mergeCharacterDeltas(rows: MemoryRow[], current: unknown): unknown[] {
  const merged = new Map<string, AnyRecord>();
  for (const item of priorItems(rows, "character_deltas")) {
    const name = text(item.character_name);
    if (name) merged.set(key(name), { ...item });
  }
  if (Array.isArray(current)) {
    for (const item of current) {
      if (!item || typeof item !== "object") continue;
      const next = item as AnyRecord;
      const name = text(next.character_name);
      if (!name) continue;
      const previous = merged.get(key(name)) ?? {};
      const combined = { ...previous };
      for (const [field, value] of Object.entries(next)) {
        if (value !== null && value !== undefined && text(String(value)) !== "") {
          combined[field] = value;
        }
      }
      merged.set(key(name), combined);
    }
  }
  return Array.from(merged.values());
}

function reconcileThreads(rows: MemoryRow[], current: unknown[], source: string, now: string): AnyRecord[] {
  const existing = priorItems(rows, "plot_thread_deltas");
  return current.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const item = raw as AnyRecord;
    const name = text(item.thread_name);
    if (!name) return [];
    const match = existing.find((candidate) => key(text(candidate.thread_name)) === key(name));
    const id = text(match?.id) || uuid();
    const status = ["introduced", "advanced", "resolved"].includes(text(item.status))
      ? text(item.status) : (match?.status === "resolved" ? "resolved" : "introduced");
    return [{
      id,
      source_section_id: source,
      thread_name: name,
      status,
      description: text(item.description) || text(match?.description),
      created_at: text(match?.created_at) || now,
      resolved_at: status === "resolved" ? (text(match?.resolved_at) || now) : null,
    }];
  });
}

function reconcileLoops(rows: MemoryRow[], current: unknown[], source: string, now: string): AnyRecord[] {
  const existing = priorItems(rows, "open_loops");
  return current.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const item = raw as AnyRecord;
    const description = text(item.description);
    if (!description) return [];
    const type = text(item.type) || "question";
    const match = existing
      .filter((candidate) => text(candidate.type) === type)
      .sort((a, b) => similarity(description, text(b.description)) - similarity(description, text(a.description)))[0];
    const same = match && similarity(description, text(match.description)) >= 0.45;
    const status = text(item.status) === "resolved" || text(item.status) === "closed" ? "resolved" : "open";
    const id = same && text(match?.id) ? text(match.id) : uuid();
    return [{
      id,
      source_section_id: source,
      type,
      description,
      status,
      created_at: same ? (text(match?.created_at) || now) : now,
      resolved_at: status === "resolved" ? (text(match?.resolved_at) || now) : null,
    }];
  });
}

function reconcileFacts(rows: MemoryRow[], current: unknown[], source: string, now: string): AnyRecord[] {
  const existing = priorItems(rows, "continuity_facts");
  const out: AnyRecord[] = [];
  for (const raw of current) {
    const item: AnyRecord = typeof raw === "string" ? { fact: raw } : (raw && typeof raw === "object" ? raw as AnyRecord : {});
    const fact = text(item.fact) || text(item.description);
    if (!fact) continue;
    const match = existing.find((candidate) => key(text(candidate.fact)) === key(fact));
    const id = text(match?.id) || uuid();
    const replacement = text(item.supersedes_id) || text(item.supersedes_fact);
    if (replacement) {
      const old = existing.find((candidate) => text(candidate.id) === replacement || key(text(candidate.fact)) === key(replacement));
      if (old?.id) out.push({ ...old, active: false, superseded_by: id });
    }
    out.push({
      id,
      source_section_id: source,
      fact,
      active: true,
      superseded_by: null,
      created_at: text(match?.created_at) || now,
    });
  }
  return out;
}

export function reconcileSceneMemory(
  rows: MemoryRow[],
  memory: AnyRecord,
  sourceSectionId: string,
  now = new Date().toISOString(),
): { character_deltas: unknown[]; plot_thread_deltas: AnyRecord[]; continuity_facts: AnyRecord[]; open_loops: AnyRecord[] } {
  return {
    character_deltas: mergeCharacterDeltas(rows, memory.character_deltas),
    plot_thread_deltas: reconcileThreads(rows, Array.isArray(memory.plot_thread_deltas) ? memory.plot_thread_deltas : [], sourceSectionId, now),
    continuity_facts: reconcileFacts(rows, Array.isArray(memory.continuity_facts) ? memory.continuity_facts : [], sourceSectionId, now),
    open_loops: reconcileLoops(rows, Array.isArray(memory.open_loops) ? memory.open_loops : [], sourceSectionId, now),
  };
}

export async function loadPriorMemoryRows(adminClient: any, projectId: string, currentSectionId?: string): Promise<MemoryRow[]> {
  if (!projectId) return [];
  const { data } = await adminClient.from("section_embeddings").select(
    "outline_section_id, character_deltas, plot_thread_deltas, continuity_facts, open_loops",
  ).eq("project_id", projectId);
  return (data ?? []).filter((row: AnyRecord) => row.outline_section_id !== currentSectionId) as MemoryRow[];
}
