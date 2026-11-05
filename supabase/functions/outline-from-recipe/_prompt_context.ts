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
4. Planner-invented enrichment is provisional support material; it must not displace, soften, contradict, or redirect the authored premise. It may be used, adapted, replaced, or discarded before acceptance.
5. Generic narrative conventions and defaults have the lowest authority.

## Preserve the author's character identity across the whole story
Treat the recipe's populated character traits, motivations, recurring behaviors, appetites, flaws, relationships, contradictions, and tonal intensity as ongoing CREATIVE CAUSES, not introductory facts that vanish once the plot starts. At the beginning, middle, climax, and aftermath, decisions should remain recognizable as choices these particular people would make under their NEW circumstances. A defining pattern may intensify, mutate, retreat, or end when the author's intended arc or earned events make that change plausible; show the cause and its lasting consequences. Neither simply repeat the same behavior in every scene nor silently replace an established character with a more convenient, generically sensible version. Keep changed circumstances distinct from changed identity.

Do not preselect ANY moral trajectory. Improvement, decline, moral ambiguity, unchanged vice, reconciliation, estrangement, self-sacrifice, exploitation, and contradictory combinations are all possibilities, not mandatory plot destinations. The author's actual recipe, explicit instructions, accepted events, and the selected arc's compatible dramatic promise decide the trajectory. If the author intentionally leaves it open, discover it through specific character-driven consequences rather than automatically rewarding or punishing the characters. Do not treat resolution, survival, love, growth, or a satisfying ending as automatic evidence of virtue, rehabilitation, healthy boundaries, consent negotiations, or their opposites. Never override a specifically authored transformation or a selected arc's explicit compatible requirement in the name of preserving an initial flaw.

## Emotional and interpersonal causality is the dramatic foundation
Build the story around emotionally consequential dynamics between the authored people: what they desire, fear, need, conceal, resent, depend on, and are willing to do to or for one another. Their relationships, incompatible desires, loyalties, betrayals, attachments, and power struggles must cause the major decisions, reversals, and climax, not merely decorate an independently operating external plot. External problems can create pressure and genre-specific events, but their dramatic importance comes from how they alter relationships and compel irreversible personal choices. The reader must experience the people driving and being changed by events, not simply the completion of a mechanism.
This applies across all genres without imposing romance, redemption, reconciliation, morality, or a particular kind of ending. Relationships may be intimate, hostile, destructive, estranged, or irreparably broken. Preserve explicit authored plots, world rules, and the selected arc's defining experiences while making the story's emotional and interpersonal causality substantive.

Interpret every Story Arc beat through the recipe. Incidental mechanism words in a built-in arc beat (such as investigation, evidence, rescue, transfer, or operation) describe possible contexts, NOT an independent requirement to invent that machinery. Respect an explicitly authored or arc-defining investigation, crime, conspiracy, legal process, or other procedural experience when it is actually promised; do not promote a merely illustrative plot device into the genre's defining story. Never change the recipe's creative identity to fit conventional genre expectations associated with the arc. Author-created names and facts, plus events already accepted into the story, are binding; generated candidates are not. Character transformation does not imply moral improvement; sacrifice does not require nobility; resolution does not require justice, institutional reform, reconciliation, or heroic victory. Tragic, absurd, morally compromised, ambiguous, or destructive outcomes are valid when they satisfy the recipe and establish a concrete consequence. If an arc requirement has multiple valid realizations, choose the one most faithful to the recipe. Preserve structural integrity, continuity, required output schema, and safety constraints.`;

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
  return Object.entries(material).flatMap(([category, values]) => category !== "premiseComponents" && Array.isArray(values)
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
    // Author-grounded, atomic premise commitments are a separate input, never
    // optional planner material. Preserve the source quote and current meaning.
    premiseComponents: (material?.premiseComponents ?? []).map((component: any, index: number) => ({
      id: `premise_component_${index}`,
      sourceQuote: compactText(component.sourceQuote, 600),
      requirement: compactText(component.requirement, 750),
    })),
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

/**
 * Canonical author facts are always available through planningContext.recipe.
 * Optional enrichment is a bank of ideas, not a second story brief. Only
 * independent people/relationships and thematic context may influence the
 * causal architecture or later outline; otherwise a prebuilt procedural plot
 * leaks back into generation after the architecture has already been chosen.
 *
 * Keep the FULL enrichment persisted for provenance/QA, not as mandatory
 * model input. This selection policy applies to the initial plan, outline,
 * and optional length expansion. Never use a source=planner category as canon.
 */
export function authorFirstMaterialIndex(material: any): Array<Record<string, unknown>> {
  const characterLedCategories = new Set([
    "characters", "relationships", "thematicPressures",
  ]);
  return (compactMaterial(material) as Array<Record<string, unknown>>).filter((item) =>
    item.source === "recipe" || characterLedCategories.has(String(item.category))
  );
}

export function buildArchitecturePlanningView(
  req: any,
  obligations: any[] = [],
  material = req?.storyMaterialEnrichment,
): Record<string, unknown> {
  const context = buildCompactPlanningView(req, obligations, material);
  return { ...context, materialIndex: authorFirstMaterialIndex(material) };
}

export function promptMetrics(messages: Array<{ role: string; content: unknown }>, extra: Record<string, unknown> = {}) {
  const serialized = messages.map((m) => `${m.role}:${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}`).join("\n");
  return { promptBytes: new TextEncoder().encode(serialized).byteLength, promptChars: serialized.length, estimatedInputTokens: Math.ceil(serialized.length / 4), ...extra };
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
