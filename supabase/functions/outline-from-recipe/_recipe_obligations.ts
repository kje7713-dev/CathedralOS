export type RecipeObligationClass =
  | "hard_premise"
  | "major_plot"
  | "character_arc"
  | "relationship"
  | "world_constraint"
  | "supporting_theme"
  | "supporting_motif"
  | "ending_intent";

export interface RecipeObligation {
  id: string;
  classification: RecipeObligationClass;
  statement: string;
  source: string;
  required: boolean;
}

function compact(value: unknown, maxLength = 900): string {
  if (typeof value === "string") return value.trim().slice(0, maxLength);
  if (value == null) return "";
  try {
    return JSON.stringify(value).slice(0, maxLength);
  } catch {
    return String(value).slice(0, maxLength);
  }
}

function meaningful(value: unknown): boolean {
  return compact(value).trim().length > 0 && compact(value).trim() !== "[]" && compact(value).trim() !== "{}";
}

export function deriveRecipeObligations(recipe: Record<string, unknown>): RecipeObligation[] {
  const obligations: RecipeObligation[] = [];
  const add = (
    classification: RecipeObligationClass,
    statement: string,
    source: string,
    required: boolean,
  ) => {
    if (!statement.trim()) return;
    obligations.push({ id: `R${obligations.length + 1}`, classification, statement: statement.trim().slice(0, 1200), source, required });
  };

  const project = (recipe.project ?? {}) as Record<string, unknown>;
  if (meaningful(project.summary)) add("hard_premise", `Preserve and materially realize the project premise: ${compact(project.summary)}`, "project.summary", true);

  if (meaningful(recipe.selectedStorySpark)) add("major_plot", `Materially develop the selected story spark: ${compact(recipe.selectedStorySpark)}`, "selectedStorySpark", true);

  const characters = Array.isArray(recipe.selectedCharacters) ? recipe.selectedCharacters : [];
  for (const character of characters) {
    if (!character || typeof character !== "object") continue;
    const c = character as Record<string, unknown>;
    const name = compact(c.name, 160) || compact(c.id, 160) || "selected character";
    const signals = ["description", "backstory", "goals", "fears", "roles", "traits", "wants", "needs"]
      .map((key) => meaningful(c[key]) ? `${key}: ${compact(c[key], 500)}` : "")
      .filter(Boolean).join("; ");
    if (signals) add("character_arc", `Give ${name} a materially relevant arc grounded in the supplied character facts (${signals}).`, `selectedCharacters.${name}`, true);
  }

  const relationships = Array.isArray(recipe.selectedRelationships) ? recipe.selectedRelationships : [];
  for (const relationship of relationships) {
    if (!meaningful(relationship)) continue;
    add("relationship", `Make this selected relationship materially affect the plot: ${compact(relationship)}`, "selectedRelationships", true);
  }

  if (recipe.setting && typeof recipe.setting === "object") {
    const setting = recipe.setting as Record<string, unknown>;
    const settingDetails = Object.entries(setting).filter(([key, value]) => key !== "included" && meaningful(value));
    if (setting.included === true && settingDetails.length > 0) {
      add("world_constraint", `Honor the included setting details as story constraints: ${compact(Object.fromEntries(settingDetails))}`, "setting", true);
    }
  }

  if (meaningful(recipe.selectedAftertaste)) add("ending_intent", `Resolve toward the selected aftertaste or ending residue: ${compact(recipe.selectedAftertaste)}`, "selectedAftertaste", true);

  const themes = Array.isArray(recipe.selectedThemeQuestions) ? recipe.selectedThemeQuestions : [];
  for (const theme of themes) if (meaningful(theme)) add("supporting_theme", `Keep this theme question alive as supporting guidance, without turning it into a mandatory event: ${compact(theme)}`, "selectedThemeQuestions", false);

  const motifs = Array.isArray(recipe.selectedMotifs) ? recipe.selectedMotifs : [];
  for (const motif of motifs) if (meaningful(motif)) add("supporting_motif", `Use this motif as supporting texture where natural, not as a substitute for plot: ${compact(motif)}`, "selectedMotifs", false);

  return obligations;
}

export function obligationCoverage(
  suggestions: Array<{ recipeRequirementIDs?: string[] }>,
  obligations: RecipeObligation[],
): { covered: Record<string, number>; missingRequired: RecipeObligation[] } {
  const covered: Record<string, number> = {};
  for (const suggestion of suggestions) {
    for (const id of suggestion.recipeRequirementIDs ?? []) covered[id] = (covered[id] ?? 0) + 1;
  }
  return { covered, missingRequired: obligations.filter((obligation) => obligation.required && !covered[obligation.id]) };
}

export function renderRecipeObligations(obligations: RecipeObligation[]): string {
  if (obligations.length === 0) return "No explicit recipe obligations were derived; preserve the supplied premise and use judgment without inventing mandatory requirements.";
  return obligations.map((obligation) => `- ${obligation.id} [${obligation.classification}]${obligation.required ? " REQUIRED" : " supporting"}: ${obligation.statement}`).join("\n");
}
