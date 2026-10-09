// Server-owned lifecycle reconciliation for structured scene memory.
// LLM output is semantic input only; IDs and lifecycle state are canonicalized here.

import { backfillPronounFacts, type SceneMemory } from "./scene-memory.ts";

export type MemoryRow = {
  character_deltas?: unknown;
  plot_thread_deltas?: unknown;
  continuity_facts?: unknown;
  open_loops?: unknown;
};

type AnyRecord = Record<string, unknown>;

const text = (value: unknown): string =>
  typeof value === "string" ? value.trim() : "";
const key = (value: string): string =>
  value.toLocaleLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const uuid = (): string => crypto.randomUUID();

function semanticReference(prefix: string, value: string): string {
  const normalized = key(value).replace(/\s+/g, "-");
  return `${prefix}:${normalized}`;
}

function identityFactReference(fact: string): string {
  const match = /^character:([^:]+):identity:([^:]+):/i.exec(fact);
  if (!match) return "";
  const character = key(match[1]).replace(/\s+/g, "-");
  const attribute = key(match[2]).replace(/\s+/g, "-");
  return character && attribute
    ? `character:${character}:identity:${attribute}`
    : "";
}

function factReference(item: AnyRecord): string {
  const fact = text(item.fact) || text(item.description);
  return identityFactReference(fact) ||
    text(item.reference) ||
    semanticReference("fact", fact);
}

function priorFactReference(
  existing: AnyRecord[],
  supplied: string,
  currentFact: string,
): string {
  if (!supplied) return "";
  if (existing.some((candidate) => factReference(candidate) === supplied)) {
    return supplied;
  }

  const currentIdentity = identityFactReference(currentFact);
  if (!currentIdentity) return supplied;
  const currentAttribute = currentIdentity.slice(
    currentIdentity.lastIndexOf(":") + 1,
  );

  const legacyMatches = existing.filter((candidate) => {
    if (text(candidate.reference) !== supplied) return false;
    const candidateIdentity = identityFactReference(
      text(candidate.fact) || text(candidate.description),
    );
    return candidateIdentity.endsWith(`:identity:${currentAttribute}`);
  });
  const canonical = new Set(legacyMatches.map(factReference));
  return canonical.size === 1 ? [...canonical][0] : supplied;
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

function mergeCharacterDeltas(_rows: MemoryRow[], current: unknown): unknown[] {
  // Persist only this scene's changes. Cumulative merging belongs to the
  // canonical Project State formatter, not section_embeddings rows.
  if (!Array.isArray(current)) return [];
  return current.filter((item) => item && typeof item === "object").map((
    item,
  ) => ({ ...item as AnyRecord }));
}

function reconcileThreads(
  rows: MemoryRow[],
  current: unknown[],
  source: string,
  now: string,
): AnyRecord[] {
  const existing = priorItems(rows, "plot_thread_deltas");
  return current.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const item = raw as AnyRecord;
    const name = text(item.thread_name);
    if (!name) return [];
    const reference = text(item.reference) || semanticReference("thread", name);
    const matches = existing.filter((candidate) =>
      (text(candidate.reference) ||
        semanticReference("thread", text(candidate.thread_name))) === reference
    );
    const distinctIds = new Set(
      matches.map((candidate) =>
        text(candidate.id) || JSON.stringify(candidate)
      ),
    );
    if (distinctIds.size > 1) {
      throw new Error(`ambiguous thread reference: ${reference}`);
    }
    const match = matches[matches.length - 1];
    const requestedStatus =
      ["introduced", "advanced", "resolved"].includes(text(item.status))
        ? text(item.status)
        : (match?.status === "resolved" ? "resolved" : "introduced");
    // Lifecycle/status values are extractor hints, not database commands. A
    // first appearance cannot advance or resolve an entity that has no prior
    // canonical identity; establish it safely instead of failing the scene.
    const status = match ? requestedStatus : "introduced";
    const id = text(match?.id) || uuid();
    return [{
      id,
      reference,
      source_section_id: source,
      thread_name: name,
      status,
      description: text(item.description) || text(match?.description),
      created_at: text(match?.created_at) || now,
      resolved_at: status === "resolved"
        ? (text(match?.resolved_at) || now)
        : null,
    }];
  });
}

function reconcileLoops(
  rows: MemoryRow[],
  current: unknown[],
  source: string,
  now: string,
): AnyRecord[] {
  const existing = priorItems(rows, "open_loops");
  return current.flatMap((raw) => {
    if (!raw || typeof raw !== "object") return [];
    const item = raw as AnyRecord;
    const description = text(item.description);
    if (!description) return [];
    const type = text(item.type) || "question";
    const status = text(item.status) === "resolved" ? "resolved" : "open";
    const suppliedReference = text(item.reference);
    const reference = suppliedReference ||
      semanticReference(`loop-${type}`, description);
    const matches = existing.filter((candidate) =>
      text(candidate.reference) === reference ||
      (!text(candidate.reference) &&
        semanticReference(
            `loop-${text(candidate.type) || "question"}`,
            text(candidate.description),
          ) === reference)
    );
    const distinctIds = new Set(
      matches.map((candidate) =>
        text(candidate.id) || JSON.stringify(candidate)
      ),
    );
    if (distinctIds.size > 1) {
      throw new Error(`ambiguous loop reference: ${reference}`);
    }
    const match = matches[matches.length - 1];
    // A resolved loop with no prior identity is a new loop-shaped hint, not a
    // valid resolution command. Keep it open until a later scene resolves the
    // canonical ID that this scene establishes.
    const normalizedStatus = match ? status : "open";
    const id = text(match?.id) || uuid();
    return [{
      id,
      reference,
      source_section_id: source,
      type,
      status: normalizedStatus,
      description,
      created_at: match ? (text(match.created_at) || now) : now,
      resolved_at: normalizedStatus === "resolved"
        ? (text(match?.resolved_at) || now)
        : null,
    }];
  });
}

function reconcileFacts(
  rows: MemoryRow[],
  current: unknown[],
  source: string,
  now: string,
): AnyRecord[] {
  const existing = priorItems(rows, "continuity_facts");
  const out: AnyRecord[] = [];
  for (const raw of current) {
    const item: AnyRecord = typeof raw === "string"
      ? { fact: raw }
      : (raw && typeof raw === "object" ? raw as AnyRecord : {});
    const fact = text(item.fact) || text(item.description);
    if (!fact) continue;
    const reference = factReference(item);
    const matches = existing.filter((candidate) =>
      factReference(candidate) === reference
    );
    const distinctIds = new Set(
      matches.map((candidate) =>
        text(candidate.id) || JSON.stringify(candidate)
      ),
    );
    if (distinctIds.size > 1) {
      throw new Error(`ambiguous fact reference: ${reference}`);
    }
    const match = matches[matches.length - 1];
    const replacement = priorFactReference(
      existing,
      text(item.prior_fact_reference),
      fact,
    );
    let supersedesPrior = false;
    if (text(item.operation) === "supersede") {
      const priorMatches = replacement
        ? existing.filter((candidate) =>
          factReference(candidate) === replacement &&
          candidate.active !== false
        )
        : [];
      const priorIds = new Set(
        priorMatches.map((candidate) =>
          text(candidate.id) || JSON.stringify(candidate)
        ),
      );
      // Missing history is recoverable: establish the new fact and let a
      // future scene supply a valid prior identity. Ambiguous history remains
      // fail-closed because choosing one canonical fact would corrupt state.
      if (priorIds.size > 1) {
        throw new Error(`ambiguous fact reference: ${replacement}`);
      }
      if (priorMatches.length > 0) {
        supersedesPrior = true;
        out.push({
          ...priorMatches[priorMatches.length - 1],
          active: false,
          superseded_by: reference,
        });
      }
    }
    const id = text(match?.id) || uuid();
    out.push({
      id,
      reference,
      source_section_id: source,
      operation: supersedesPrior
        ? "supersede"
        : (match ? "preserve" : "establish"),
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
): {
  character_deltas: unknown[];
  plot_thread_deltas: AnyRecord[];
  continuity_facts: AnyRecord[];
  open_loops: AnyRecord[];
} {
  const currentCharacterDeltas = Array.isArray(memory.character_deltas)
    ? memory.character_deltas
    : [];
  const currentContinuityFacts = Array.isArray(memory.continuity_facts)
    ? memory.continuity_facts
    : [];
  const protectedPronounReferences = new Set(
    [
      ...priorItems(rows, "continuity_facts").filter((item) =>
        item.active !== false
      ),
      ...currentContinuityFacts.filter((item) =>
        item && typeof item === "object"
      ).map((item) => item as AnyRecord),
    ]
      .map(factReference)
      .filter((reference) => /:identity:pronouns$/i.test(reference))
      .map((reference) => reference.trim().toLowerCase()),
  );
  const normalizedContinuityFacts = backfillPronounFacts(
    currentCharacterDeltas as SceneMemory["character_deltas"],
    currentContinuityFacts as SceneMemory["continuity_facts"],
    protectedPronounReferences,
  );

  return {
    character_deltas: mergeCharacterDeltas(rows, currentCharacterDeltas),
    plot_thread_deltas: reconcileThreads(
      rows,
      Array.isArray(memory.plot_thread_deltas) ? memory.plot_thread_deltas : [],
      sourceSectionId,
      now,
    ),
    continuity_facts: reconcileFacts(
      rows,
      normalizedContinuityFacts,
      sourceSectionId,
      now,
    ),
    open_loops: reconcileLoops(
      rows,
      Array.isArray(memory.open_loops) ? memory.open_loops : [],
      sourceSectionId,
      now,
    ),
  };
}

export async function loadPriorMemoryRows(
  adminClient: any,
  projectId: string,
  currentSectionId?: string,
): Promise<MemoryRow[]> {
  if (!projectId || !currentSectionId) return [];
  const { data: current, error: currentError } = await adminClient.from(
    "outline_sections",
  )
    .select("id, outline_id, position").eq("id", currentSectionId)
    .maybeSingle();
  if (currentError) {
    throw new Error(`current section query failed: ${currentError.message}`);
  }
  if (!current) throw new Error("current section not found");
  const { data: priorSections, error: sectionError } = await adminClient.from(
    "outline_sections",
  )
    .select("id, outline_id, position")
    .eq("outline_id", current.outline_id)
    .lt("position", Number(current.position));
  if (sectionError) {
    throw new Error(`prior section query failed: ${sectionError.message}`);
  }
  const ids = (priorSections ?? []).map((row: AnyRecord) => row.id).filter(
    Boolean,
  );
  if (!ids.length) return [];
  const { data: rows, error: rowError } = await adminClient.from(
    "section_embeddings",
  ).select(
    "outline_section_id, extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state",
  ).eq("project_id", projectId).in("outline_section_id", ids);
  if (rowError) {
    throw new Error(`prior memory query failed: ${rowError.message}`);
  }
  const meta = new Map<string, AnyRecord>(
    (priorSections ?? []).map((row: AnyRecord) => [String(row.id), row]),
  );
  return (rows ?? []).sort((a: AnyRecord, b: AnyRecord) =>
    Number(meta.get(String(a.outline_section_id))?.position ?? 0) -
    Number(meta.get(String(b.outline_section_id))?.position ?? 0)
  ) as MemoryRow[];
}
