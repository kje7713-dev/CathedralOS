import { assertEquals, assert } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildCompactPlanningView, compactMaterial, stableJSONStringify, promptMetrics } from "./_prompt_context.ts";

const req = { recipe: { project: { id: "p", name: "A", summary: "A story" }, selectedCharacters: [{ id: "c", name: "Hero", summary: "A sentinel" }] }, arcTemplate: { id: "a", name: "Arc", beats: [{ id: "b", label: "Beat", description: "Turn" }] }, existingSections: [] };
Deno.test("compact planning context is deterministic and carries provenance", () => {
  const a = stableJSONStringify(buildCompactPlanningView(req, [{ id: "R1", source: "selectedCharacters.c", directive: "Use Hero", required: true }], { characters: [{ id: "m1", label: "SENTINEL", description: "A compact fact", source: "recipe" }] }));
  const b = stableJSONStringify(buildCompactPlanningView(req, [{ required: true, directive: "Use Hero", source: "selectedCharacters.c", id: "R1" }], { characters: [{ source: "recipe", description: "A compact fact", label: "SENTINEL", id: "m1" }] }));
  assertEquals(a, b);
  assert(a.includes("SENTINEL"));
});
Deno.test("material compaction does not duplicate an item across prompt representations", () => {
  const compact = JSON.stringify(compactMaterial({ characters: [{ id: "m1", label: "SENTINEL", description: "fact" }] }));
  assertEquals((compact.match(/SENTINEL/g) ?? []).length, 1);
});
Deno.test("prompt metrics estimate serialized input without retaining prompt text", () => {
  const metrics = promptMetrics([{ role: "system", content: "x".repeat(400) }], { stage: "allocation" });
  assertEquals(metrics.estimatedInputTokens > 100, true);
  assertEquals("system" in metrics, false);
});

Deno.test("planning context preserves the complete canonical recipe exactly", () => {
  const recipe: any = {
    project: { id: "p", name: "Frozen", summary: "Summary", audienceNotes: "AUDIENCE", nested: { deep: { sentinel: "DEEP_SENTINEL" } } },
    setting: { included: true, worldRules: ["RULE_" + "x".repeat(1000)], hiddenTruths: ["HIDDEN"], nested: { level: { value: "NESTED_SETTING" } } },
    selectedCharacters: Array.from({ length: 25 }, (_, index) => ({ id: `c-${index}`, name: `Character ${index}`, instructionBias: `CHARACTER_${index}`, deeplyNested: { level: { value: `NESTED_CHARACTER_${index}` } } })),
    selectedRelationships: [{ id: "r", relationshipType: "RELATIONSHIP" }],
    selectedThemeQuestions: [{ id: "t", question: "THEME_QUESTION", coreTension: "THEME_TENSION", valueConflict: "THEME_VALUE", moralFaultLine: "THEME_FAULT" }],
    selectedMotifs: [{ id: "m", meaning: "MOTIF" }],
    selectedStorySpark: { id: "spark", situation: "SPARK" },
    selectedAftertaste: { id: "after", endingTexture: "AFTERTASTE" },
    storyNonNegotiables: ["NON_NEGOTIABLE"],
    promptPack: { id: "pack", name: "Pack", notes: "PACK_NOTES", instructionBias: "PACK_BIAS" },
  };
  const view = buildCompactPlanningView({ recipe, arcTemplate: { id: "a", name: "Arc", beats: [] }, existingSections: [] });
  assertEquals(view.recipe, recipe);
  assertEquals(JSON.stringify(view.recipe).includes("DEEP_SENTINEL"), true);
  assertEquals((view.recipe as any).selectedCharacters.length, 25);
});
