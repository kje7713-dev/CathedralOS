import { assertEquals, assert } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildCompactPlanningView, compactMaterial, stableJSONStringify, promptMetrics, compactStorySparkForPlanning, compactAftertasteForPlanning } from "./_prompt_context.ts";

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

Deno.test("typed Story Spark and Aftertaste compaction preserves canonical semantics once", () => {
  const spark = compactStorySparkForPlanning({ id: "spark", title: "S", situation: "SITUATION_SENTINEL", stakes: "STAKES_SENTINEL", twist: "TWIST_SENTINEL", urgency: "URGENCY_SENTINEL", clock: "CLOCK_SENTINEL", triggerEvent: "TRIGGER_SENTINEL", reversalPotential: "REVERSAL_SENTINEL" });
  const aftertaste = compactAftertasteForPlanning({ id: "after", label: "A", emotionalResidue: "RESIDUE_SENTINEL", endingTexture: "TEXTURE_SENTINEL", desiredAmbiguityLevel: "AMBIGUITY_SENTINEL", readerQuestionLeftOpen: "QUESTION_SENTINEL", lastImageFeeling: "IMAGE_SENTINEL" });
  for (const value of ["SITUATION_SENTINEL", "STAKES_SENTINEL", "TWIST_SENTINEL", "URGENCY_SENTINEL", "CLOCK_SENTINEL", "TRIGGER_SENTINEL", "REVERSAL_SENTINEL"]) assert(JSON.stringify(spark).includes(value));
  for (const value of ["RESIDUE_SENTINEL", "TEXTURE_SENTINEL", "AMBIGUITY_SENTINEL", "QUESTION_SENTINEL", "IMAGE_SENTINEL"]) assert(JSON.stringify(aftertaste).includes(value));
});
