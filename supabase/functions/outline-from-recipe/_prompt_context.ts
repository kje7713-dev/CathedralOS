// Deterministic, bounded prompt context helpers for outline generation.
export function compactText(value: unknown, max = 500): string {
  return String(value ?? "").replace(/\s+/g, " ").trim().slice(0, max);
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, sorted(v)]));
}

export function stableJSONStringify(value: unknown): string {
  return JSON.stringify(sorted(value));
}

function compactEntity(item: any): Record<string, unknown> {
  const out: Record<string, unknown> = {
    id: item?.id ?? null,
    name: compactText(item?.name ?? item?.label, 160),
    role: compactText(item?.role ?? item?.classification, 160),
    summary: compactText(item?.summary ?? item?.description ?? item?.notes, 600),
  };
  // Preserve authored narrative semantics without embedding arbitrary raw JSON.
  const fields = [
    "roles", "goals", "needs", "fears", "wounds", "secrets", "contradictions",
    "selfDeceptions", "identityConflicts", "moralLines", "breakingPoints",
    "wants", "traits", "flaws", "obsessions", "attachments", "virtues",
    "participants", "history", "powerBalance", "resentment", "misunderstanding",
    "unspokenTruth", "whatEachWantsFromTheOther", "whatWouldBreakIt", "whatWouldTransformIt",
    "arcStart", "arcEnd", "coreLie", "coreTruth", "publicMask", "privateLogic", "reputation", "status",
    "relationshipType", "tension", "loyalty", "fear", "desire", "dependency", "meaning", "examples",
  ];
  for (const field of fields) {
    const value = item?.[field];
    if (Array.isArray(value)) {
      const values = value.map((x: unknown) => compactText(x, 220)).filter(Boolean).slice(0, 12);
      if (values.length) out[field] = values;
    } else if (value != null && compactText(value, 700)) {
      out[field] = compactText(value, 700);
    }
  }
  return out;
}

export function compactRecipe(recipe: any): Record<string, unknown> {
  return {
    schema: recipe?.schema,
    version: recipe?.version,
    project: recipe?.project ? { id: recipe.project.id ?? null, name: compactText(recipe.project.name, 200), summary: compactText(recipe.project.summary, 1200) } : null,
    setting: recipe?.setting ? { included: recipe.setting.included ?? true, name: compactText(recipe.setting.name, 160), description: compactText(recipe.setting.description ?? recipe.setting.summary, 900) } : null,
    selectedCharacters: Array.isArray(recipe?.selectedCharacters) ? recipe.selectedCharacters.map(compactEntity) : [],
    selectedRelationships: Array.isArray(recipe?.selectedRelationships) ? recipe.selectedRelationships.map(compactEntity) : [],
    selectedThemeQuestions: Array.isArray(recipe?.selectedThemeQuestions) ? recipe.selectedThemeQuestions.map(compactEntity) : [],
    selectedMotifs: Array.isArray(recipe?.selectedMotifs) ? recipe.selectedMotifs.map(compactEntity) : [],
    selectedStorySpark: recipe?.selectedStorySpark ? compactEntity(recipe.selectedStorySpark) : null,
    selectedAftertaste: recipe?.selectedAftertaste ? compactEntity(recipe.selectedAftertaste) : null,
    promptPack: recipe?.promptPack ? { id: recipe.promptPack.id ?? null, name: compactText(recipe.promptPack.name, 200), instructionBias: compactText(recipe.promptPack.instructionBias, 900) } : null,
  };
}

export function compactMaterial(material: any): unknown[] {
  if (!material || typeof material !== "object") return [];
  return Object.entries(material).flatMap(([category, values]) => Array.isArray(values)
    ? values.map((item: any) => ({ id: item?.id ?? null, category, label: compactText(item?.label ?? item?.name, 180), description: compactText(item?.description ?? item?.summary, 650), source: item?.source === "recipe" ? "recipe" : "planner", sourceReference: item?.sourceReference ?? null, sourceRefs: Array.isArray(item?.sourceRefs) ? item.sourceRefs.slice(0, 12) : Array.isArray(item?.sourceReferenceIDs) ? item.sourceReferenceIDs.slice(0, 12) : [], priority: item?.priority ?? null }))
    : []);
}

export function compactObligations(obligations: any[]): unknown[] {
  return (obligations ?? []).map((o) => ({ id: o.id, source: compactText(o.source, 180), classification: compactText(o.classification, 100), required: Boolean(o.required), label: compactText(o.label, 180), directive: compactText(o.directive ?? o.statement, 500), sourceRefIDs: o.sourceRefIDs ?? o.sourceReferenceIDs ?? [] }));
}

export function compactExistingSections(sections: any[]): unknown[] {
  return (sections ?? []).map((s) => ({ id: s.id ?? null, title: compactText(s.title, 160), summary: compactText(s.summary, 500), storyArcBeatID: s.storyArcBeatID ?? null, container: s.container ?? null, terminalBeat: compactText(s.terminalBeat, 180), recipeRequirementIDs: s.recipeRequirementIDs ?? [] }));
}

export function buildCompactPlanningView(req: any, obligations: any[] = [], material = req?.storyMaterialEnrichment): Record<string, unknown> {
  return {
    schema: "cathedralos.outline_planning_context",
    version: 1,
    project: req?.recipe?.project ? { id: req.recipe.project.id ?? null, name: compactText(req.recipe.project.name, 200), summary: compactText(req.recipe.project.summary, 1200) } : null,
    recipe: compactRecipe(req?.recipe),
    obligations: compactObligations(obligations),
    materialIndex: compactMaterial(material),
    arc: { id: req?.arcTemplate?.id, name: req?.arcTemplate?.name, beats: (req?.arcTemplate?.beats ?? []).map((b: any, beatIndex: number) => ({ beatIndex, id: b.id, role: b.role, label: compactText(b.label, 180), description: compactText(b.description, 650) })) },
    existingOutline: compactExistingSections(req?.existingSections ?? []),
  };
}

export function promptMetrics(messages: Array<{ role: string; content: unknown }>, extra: Record<string, unknown> = {}) {
  const serialized = messages.map((m) => `${m.role}:${typeof m.content === "string" ? m.content : JSON.stringify(m.content)}`).join("\n");
  return { promptBytes: new TextEncoder().encode(serialized).byteLength, promptChars: serialized.length, estimatedInputTokens: Math.ceil(serialized.length / 4), ...extra };
}

export function assertPromptWithinBudget(stage: string, messages: Array<{ role: string; content: unknown }>, maxEstimatedTokens: number, extra: Record<string, unknown> = {}) {
  const metrics = promptMetrics(messages, { stage, ...extra });
  if (metrics.estimatedInputTokens > maxEstimatedTokens) throw new Error(`${stage} prompt exceeds safety budget (${metrics.estimatedInputTokens} estimated input tokens; limit ${maxEstimatedTokens})`);
  return metrics;
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
