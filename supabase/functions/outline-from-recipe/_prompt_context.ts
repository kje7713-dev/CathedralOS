// Deterministic, bounded prompt context helpers for outline generation.
export function compactText(value: unknown, max = 500): string {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);
}

// Story Arc beat descriptions are authored narrative contracts, not expendable
// prompt decoration. Preserve the complete text when carrying them between
// the request, planning view, and provider prompts; truncating these strings
// turns a specific beat requirement back into a generic structural role.
export function compactArcNarrativeText(value: unknown): string {
  return String(value ?? "").replace(/\s+/g, " ").trim();
}

export const RECIPE_CREATIVE_AUTHORITY_DIRECTIVE = `## Creative authority and Story Arc precedence
1. The canonical authored recipe and author instructions define the story's identity: premise, genre, tone, characters, relationships, world rules, intended reader experience, and ending direction.
2. Author-customized Story Arc beat content is structural guidance interpreted consistently with that recipe.
3. Generic Story Arc contracts supply progression, escalation, reversal, crisis, climax, and consequence only.
4. Planner-invented enrichment is provisional support material; it must not displace, soften, contradict, or redirect the authored premise.
5. Generic narrative conventions and defaults have the lowest authority.

Interpret every Story Arc beat through the recipe. Never change the recipe's creative identity to fit conventional genre expectations associated with the arc. Character transformation does not imply moral improvement; sacrifice does not require nobility; resolution does not require justice, institutional reform, reconciliation, or heroic victory. Tragic, absurd, morally compromised, ambiguous, or destructive outcomes are valid when they satisfy the recipe and establish a concrete consequence. If an arc requirement has multiple valid realizations, choose the one most faithful to the recipe. Preserve structural integrity, continuity, required output schema, and safety constraints.`;

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, sorted(v)]));
}

export function stableJSONStringify(value: unknown): string {
  return JSON.stringify(sorted(value));
}

export function compactMaterial(material: any): unknown[] {
  if (!material || typeof material !== "object") return [];
  return Object.entries(material).flatMap(([category, values]) => Array.isArray(values)
    ? values.map((item: any) => ({ id: item?.id ?? null, category, label: compactText(item?.label ?? item?.name, 180), description: compactText(item?.description ?? item?.summary, 650), source: item?.source === "recipe" ? "recipe" : "planner", sourceReference: item?.sourceReference ?? null, sourceRefs: Array.isArray(item?.sourceRefs) ? item.sourceRefs.slice(0, 12) : Array.isArray(item?.sourceReferenceIDs) ? item.sourceReferenceIDs.slice(0, 12) : [], priority: item?.priority ?? null }))
    : []);
}

/**
 * The final outline prompt already carries authored recipe prose in
 * `planningContext.recipe`. Keep the material index for provenance and
 * planner-created candidates, but do not repeat label/description for
 * canonical recipe entries.
 */
export function compactMaterialForOutline(material: any): unknown[] {
  return compactMaterial(material).map((item) => {
    const entry = item as Record<string, unknown>;
    if (entry.source !== "recipe") return entry;
    const { label: _label, description: _description, ...provenance } = entry;
    return provenance;
  });
}

export function compactObligations(obligations: any[]): unknown[] {
  return (obligations ?? []).map((o) => ({ id: o.id, source: compactText(o.source, 180), classification: compactText(o.classification, 100), required: Boolean(o.required), label: compactText(o.label, 180), directive: compactText(o.directive ?? o.statement, 500), sourceRefIDs: o.sourceRefIDs ?? o.sourceReferenceIDs ?? [] }));
}

export function compactExistingSections(sections: any[]): unknown[] {
  return (sections ?? []).map((s) => ({
    id: s.id ?? null,
    title: compactText(s.title, 200),
    summary: compactText(s.summary, 2000),
    storyArcBeatID: s.storyArcBeatID ?? null,
    container: s.container ?? null,
    terminalBeat: compactText(s.terminalBeat, 500),
    dramaticFunction: s.dramaticFunction ?? null,
    entryState: compactText(s.entryState, 1200),
    dramaticEvent: compactText(s.dramaticEvent, 2000),
    resultingChange: compactText(s.resultingChange, 1200),
    terminalState: compactText(s.terminalState, 1200),
    recipeRequirementIDs: s.recipeRequirementIDs ?? [],
  }));
}

export function buildCompactPlanningView(req: any, obligations: any[] = [], material = req?.storyMaterialEnrichment): Record<string, unknown> {
  return {
    schema: "cathedralos.outline_planning_context",
    version: 1,
    project: req?.recipe?.project ? {
      id: req.recipe.project.id ?? null,
      name: compactText(req.recipe.project.name, 200),
      summary: compactText(req.recipe.project.summary, 1200),
      readingLevel: compactText(req.recipe.project.readingLevel, 80),
      contentRating: compactText(req.recipe.project.contentRating, 40),
      intimacyRating: compactText(req.recipe.project.intimacyRating || "unspecified", 40),
      audienceNotes: compactText(req.recipe.project.audienceNotes, 1200),
    } : null,
    recipe: req?.recipe ?? null,
    obligations: compactObligations(obligations),
    mustDos: compactObligations(obligations.filter((o: any) => o.classification === "story_non_negotiable")),
    materialIndex: compactMaterial(material),
    arc: {
      id: req?.arcTemplate?.id,
      name: req?.arcTemplate?.name,
      description: compactArcNarrativeText(req?.arcTemplate?.description),
      beats: (req?.arcTemplate?.beats ?? []).map((b: any, beatIndex: number) => ({
        beatIndex,
        id: b.id,
        role: b.role,
        label: compactText(b.label, 180),
        description: compactArcNarrativeText(b.description),
      })),
    },
    existingOutline: compactExistingSections(req?.existingSections ?? []),
  };
}

export function promptMetrics(messages: Array<{ role: string; content: unknown }>, extra: Record<string, unknown> = {}) {
  const serialized = messages.map((m) => `${m.role}:${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}`).join("\n");
  return { promptBytes: new TextEncoder().encode(serialized).byteLength, promptChars: serialized.length, estimatedInputTokens: Math.ceil(serialized.length / 4), ...extra };
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
