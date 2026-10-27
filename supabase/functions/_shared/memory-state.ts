// Canonical semantic fold used by both generate-story and run-outline.
// It deliberately treats IDs as authoritative and falls back to semantic keys
// only for legacy rows that predate server-owned lifecycle IDs.
export type ProjectStateRelevance = {
  query?: string | null;
};

export type ProjectStateMeasurement = {
  rawChars: number;
  renderedChars: number;
  maxChars: number;
  truncated: boolean;
};

const RELEVANCE_STOP_WORDS = new Set([
  "about",
  "after",
  "already",
  "among",
  "because",
  "before",
  "being",
  "could",
  "current",
  "discovering",
  "during",
  "from",
  "into",
  "must",
  "only",
  "that",
  "their",
  "there",
  "these",
  "they",
  "this",
  "through",
  "under",
  "what",
  "when",
  "where",
  "which",
  "while",
  "with",
]);

function relevanceTokens(value: unknown): string[] {
  return String(value ?? "")
    .toLocaleLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((token) => token.length >= 4 && !RELEVANCE_STOP_WORDS.has(token));
}

function relevantRecord(
  record: Record<string, unknown>,
  queryTokens: Set<string>,
  forcedNames: Set<string>,
): boolean {
  const characterName = String(record.character_name ?? "").toLocaleLowerCase();
  if (characterName && forcedNames.has(characterName)) return true;
  const reference = String(record.reference ?? "").toLocaleLowerCase();
  const searchable = relevanceTokens([
    record.character_name,
    record.thread_name,
    record.reference,
    record.fact,
    record.description,
    record.location,
    record.possessions,
    record.goals,
    record.knowledge_delta,
    record.relationship_delta,
    record.injuries,
    record.emotional_stance,
    record.status,
    record.type,
  ].join(" "));
  const matches = searchable.filter((token) => queryTokens.has(token));
  if (reference && matches.some((token) => reference.includes(token))) {
    return true;
  }
  return new Set(matches).size >= 2;
}

export function formatCanonicalProjectState(
  scenes: Array<Record<string, unknown>>,
  previousScene?: Record<string, unknown>,
  maxChars = 50_000,
  relevance?: ProjectStateRelevance,
  measurement?: ProjectStateMeasurement,
): string {
  const characters = new Map<string, Record<string, unknown>>();
  const threads = new Map<string, Record<string, unknown>>();
  const facts = new Map<string, Record<string, unknown>>();
  const loops = new Map<string, Record<string, unknown>>();
  const key = (value: unknown) =>
    String(value ?? "").toLocaleLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const lines = ["## Project State", ""];
  if (previousScene) {
    lines.push("## Previous Canonical Section", "");
    if (
      typeof previousScene.extracted_summary === "string" &&
      previousScene.extracted_summary
    ) lines.push(`Summary: ${previousScene.extracted_summary}`, "");
    if (
      previousScene.scene_ending_state &&
      typeof previousScene.scene_ending_state === "object"
    ) {
      lines.push(
        "Ending state:",
        "```json",
        JSON.stringify(previousScene.scene_ending_state, null, 2),
        "```",
        "",
      );
    }
  }
  for (const scene of scenes) {
    for (
      const item of Array.isArray(scene.character_deltas)
        ? scene.character_deltas
        : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const name = key(record.character_name);
      if (!name) continue;
      const prior = characters.get(name) ?? {};
      for (const [field, value] of Object.entries(record)) {
        if (value !== null && value !== undefined && value !== "") {
          prior[field] = value;
        }
      }
      characters.set(name, prior);
    }
    for (
      const item of Array.isArray(scene.plot_thread_deltas)
        ? scene.plot_thread_deltas
        : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = key(record.reference) || key(record.thread_name);
      if (!id) continue;
      threads.set(id, record);
    }
    for (
      const item of Array.isArray(scene.continuity_facts)
        ? scene.continuity_facts
        : []
    ) {
      const record = typeof item === "string"
        ? { fact: item }
        : item && typeof item === "object"
        ? item as Record<string, unknown>
        : null;
      if (!record) continue;
      const id = key(record.reference) || key(record.fact);
      if (!id) continue;
      if (record.active === false || record.superseded_by) facts.delete(id);
      else facts.set(id, record);
    }
    for (
      const item of Array.isArray(scene.open_loops) ? scene.open_loops : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = key(record.reference) || key(record.description);
      if (!id) continue;
      if (record.status === "resolved" || record.status === "closed") {
        loops.delete(id);
      } else loops.set(id, record);
    }
  }
  const stableIdentityCategories = new Set([
    "pronoun",
    "pronouns",
    "gender",
    "identity",
    "kinship",
    "species",
    "name",
    "physical",
  ]);
  const isStableIdentityFact = (item: Record<string, unknown>) => {
    const parts = key(item.reference).split(" ").filter(Boolean);
    const identityIndex = parts.indexOf("identity");
    if (parts[0] !== "character" || identityIndex < 1) return false;
    const category = parts[identityIndex + 1];
    return stableIdentityCategories.has(category);
  };
  const stableIdentityFacts = Array.from(facts.values()).filter(
    isStableIdentityFact,
  );
  const remainingFacts = Array.from(facts.values()).filter(
    (item) => !isStableIdentityFact(item),
  );

  // The database remains the complete canon ledger. Generation receives a
  // deterministic scene-specific projection when a query is supplied. Hard
  // facts are selected by their stable references/entities, not by an LLM.
  let selectedCharacters = Array.from(characters.values());
  let selectedThreads = Array.from(threads.values()).filter((item) =>
    item.status !== "resolved"
  );
  let selectedIdentityFacts = stableIdentityFacts;
  let selectedFacts = remainingFacts;
  let selectedLoops = Array.from(loops.values());
  if (relevance?.query) {
    const queryTokens = new Set(relevanceTokens(relevance.query));
    const forcedNames = new Set(
      (Array.isArray(previousScene?.character_deltas)
        ? previousScene.character_deltas
        : [])
        .filter((item) => item && typeof item === "object")
        .map((item) =>
          String((item as Record<string, unknown>).character_name ?? "")
            .toLocaleLowerCase()
        )
        .filter(Boolean),
    );
    selectedCharacters = selectedCharacters.filter((item) =>
      relevantRecord(item, queryTokens, forcedNames)
    );
    const selectedNames = new Set(
      selectedCharacters.map((item) =>
        String(item.character_name ?? "").toLocaleLowerCase()
      ),
    );
    const relatedQueryTokens = new Set(queryTokens);
    for (const name of selectedNames) {
      for (const token of relevanceTokens(name)) relatedQueryTokens.add(token);
    }
    const selectRelated = (item: Record<string, unknown>) =>
      relevantRecord(item, relatedQueryTokens, selectedNames);
    selectedThreads = selectedThreads.filter(selectRelated);
    // Active continuity facts are durable canon. Keep them all even when the
    // current scene uses different terminology; only volatile context is
    // relevance-filtered. Inactive/superseded facts were removed above.
    selectedLoops = selectedLoops.filter(selectRelated);
  }

  if (selectedIdentityFacts.length) {
    lines.push(
      "## Stable Identity Facts",
      "",
      ...selectedIdentityFacts.map((item) =>
        `- ${String(item.reference ?? "no-reference")}: ${
          String(item.fact ?? "")
        }`
      ),
      "",
    );
  }

  lines.push("## Cumulative Story State", "");
  if (selectedCharacters.length) {
    const selectedCharacterLines = selectedCharacters.map((item) => {
      if (!relevance?.query) {
        return `- **${item.character_name}**: ${JSON.stringify(item)}`;
      }
      const compact = Object.fromEntries(
        [
          "character_name",
          "location",
          "knowledge_delta",
          "possessions",
          "goals",
          "injuries",
          "relationship_delta",
          "emotional_stance",
        ].filter((field) =>
          item[field] !== null && item[field] !== undefined &&
          item[field] !== ""
        )
          .map((field) => [field, item[field]]),
      );
      return `- **${item.character_name}**: ${JSON.stringify(compact)}`;
    });
    lines.push("Characters:", ...selectedCharacterLines, "");
  }
  const activeThreads = selectedThreads;
  if (activeThreads.length) {
    lines.push(
      "Plot threads:",
      ...activeThreads.map((item) =>
        `- **${item.thread_name}** (${item.reference ?? "no-reference"}) [${
          item.status ?? "unknown"
        }]: ${item.description ?? ""}`
      ),
      "",
    );
  }
  if (selectedFacts.length) {
    lines.push(
      "Continuity Facts:",
      ...selectedFacts.map((item) =>
        `- ${String(item.reference ?? "no-reference")}: ${
          String(item.fact ?? "")
        }`
      ),
      "",
    );
  }
  if (selectedLoops.length) {
    lines.push(
      "Open loops:",
      ...selectedLoops.map((item) =>
        `- [${item.type ?? "unknown"}] (${item.reference ?? "no-reference"}) ${
          item.description ?? ""
        }`
      ),
      "",
    );
  }
  const rawState = lines.join("\n");
  const effectiveMaxChars = Math.max(1_000, maxChars);
  const renderedState = rawState.slice(0, effectiveMaxChars);
  if (measurement) {
    measurement.rawChars = rawState.length;
    measurement.renderedChars = renderedState.length;
    measurement.maxChars = effectiveMaxChars;
    measurement.truncated = renderedState.length < rawState.length;
  }
  return renderedState;
}
