import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { deriveRecipeObligations, obligationCoverage } from "./_recipe_obligations.ts";

Deno.test("outline suggestion polling contract preserves structured failures and success", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/outline-from-recipe/index.ts",
  );
  assertEquals(source.includes("error_code: errorCode"), true);
  assertEquals(source.includes("errorCode: run.error_code"), true);
  assertEquals(source.includes('status: "completed"'), true);
  assertEquals(source.includes('status: "failed"'), true);
  assertEquals(source.includes('status: "running"'), true);
  assertEquals(source.includes("suggestions: run.suggestions"), true);
});

import {
  buildAllocationPrompt,
  buildExpansionPrompt,
  buildPrompt,
  buildSuggestionResponseSchema,
  STORY_MATERIAL_ENRICHMENT_SCHEMA,
  calculateRepairAllocation,
  adjustAllocationForExistingSections,
  ExpansionValidationError,
  NovelScalePlanningError,
  MAX_EXPANSION_ROUNDS,
  progressivelyExpandOutline,
  parseExpansionResponse,
  validateExpansionAdditions,
  mergeRepairedSuggestions,
  mergeExpansionAdditions,
  evaluateNovelScale,
  needsNovelExpansion,
  buildExpansionCheckpoint,
  expansionResumeState,
  projectedExpectedTokens,
  projectedTokenRange,
  parseAndValidateAllocation,
  flattenSuggestionResponse,
  validateRequest,
  logicalSuggestionIdentity,
  validateSuggestions,
  buildEnrichmentPrompt,
  countStoryMaterialItems,
  validateStoryMaterialEnrichment,
  storyMaterialSufficiency,
  recipeProvenance,
  attachRecipeProvenance,
  isCompatibleStoryMaterialEnrichment,
  findDramaticDistinctnessIssues,
  findCausalScaleIssues,
  validateOutlinePlanningQuality,
  plannedWordRangeForContainer,
  findUnusedStoryMaterial,
  validateStoryArcSemantics,
  validatePostRepairBeatCoverage,
  validateRequiredStoryArcFunctions,
  repairStoryArcMacroStructure,
  arcRoleContract,
  buildExpansionResponseSchema,
} from "./index.ts";

const sparseRequest = {
  recipe: {
    schema: "cathedralos.story_packet",
    version: 1,
    project: {
      id: "project-5",
      name: "Douche",
      summary: "Monsters kill humans",
    },
    setting: { included: false },
    selectedCharacters: [{
      id: "character-1",
      name: "Douche",
      roles: [],
      goals: [],
      fears: [],
    }],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
    promptPack: {
      id: "pack-1",
      name: "Sparse recipe",
      notes: "",
      instructionBias: "",
    },
  },
  arcTemplate: {
    id: "save-the-cat",
    name: "Save the Cat!",
    beats: [
      {
        id: "beat-1",
        role: "opening",
        label: "Opening Image",
        description: "Establish the world.",
      },
      {
        id: "beat-2",
        role: "break",
        label: "Break into Two",
        description: "Enter the unfamiliar situation.",
      },
    ],
  },
};

Deno.test("malformed selected recipe entities fail before any billable call", () => {
  assertEquals(
    validateRequest({ ...sparseRequest, recipe: { ...sparseRequest.recipe, selectedCharacters: [null] } }),
    "recipe.selectedCharacters contains a missing or invalid selected entity",
  );
  assertEquals(
    validateRequest({ ...sparseRequest, recipe: { ...sparseRequest.recipe, selectedMotifs: undefined } }),
    "recipe.selectedMotifs must be an array",
  );
});

Deno.test("logical suggestion identity is stable and changes with request material", async () => {
  const first = await logicalSuggestionIdentity({ ...sparseRequest, idempotencyKey: undefined });
  const same = await logicalSuggestionIdentity({ ...sparseRequest, idempotencyKey: undefined });
  const changed = await logicalSuggestionIdentity({
    ...sparseRequest,
    idempotencyKey: undefined,
    hint: "make the ending quieter",
  });
  assertEquals(first.key, same.key);
  assertEquals(first.fingerprint, same.fingerprint);
  assertEquals(first.key !== changed.key, true);
  assertEquals(first.fingerprint !== changed.fingerprint, true);
});

Deno.test("durable run source keeps lease and terminal ownership guards", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(source.includes('eq("lease_owner", workerToken)'), true);
  assertEquals(source.includes('attempt_count: priorAttemptCount + 1'), true);
  assertEquals(source.includes('status: "pending"'), true);
});

Deno.test("canonical recipe payload passes request validation", () => {
  assertEquals(validateRequest(sparseRequest), null);
  assertEquals(
    validateRequest({
      recipe: { id: "legacy", name: "old shape" },
      arcTemplate: sparseRequest.arcTemplate,
    }),
    "recipe.schema must be cathedralos.story_packet",
  );
  assertEquals(
    validateRequest({
      recipe: sparseRequest.recipe,
      arcTemplate: { ...sparseRequest.arcTemplate, beats: [] },
    }),
    "arcTemplate.id and non-empty arcTemplate.beats required",
  );
});

Deno.test("recipe obligations derive required plot signals and supporting-only texture", () => {
  const obligations = deriveRecipeObligations({
    ...sparseRequest.recipe,
    project: { ...sparseRequest.recipe.project, summary: "Monsters kill humans to save the world." },
    selectedStorySpark: { description: "Ted's rage is triggered at random." },
    selectedCharacters: [{ name: "Ted", goals: ["control the rage"], fears: ["hurting Betty"] }],
    selectedRelationships: [{ from: "Ted", to: "Betty", dynamic: "control" }],
    selectedAftertaste: "Can bad people do good things?",
    selectedThemeQuestions: [{ question: "Can bad people do good things?" }],
    selectedMotifs: [{ name: "skull" }],
  } as any);
  assertEquals(obligations.filter((item) => item.required).map((item) => item.classification), [
    "hard_premise", "major_plot", "character_arc", "relationship", "ending_intent",
  ]);
  assertEquals(obligations.filter((item) => !item.required).map((item) => item.classification), [
    "supporting_theme", "supporting_motif",
  ]);
  assertEquals(obligations.every((item) => item.id.startsWith("R")), true);
});

Deno.test("existing accepted sections satisfy obligation coverage and reduce repair allocation", () => {
  const obligations = deriveRecipeObligations({ ...sparseRequest.recipe, selectedStorySpark: { text: "R2" } } as any);
  const existing = [{ storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] }];
  const coverage = obligationCoverage([...existing, { recipeRequirementIDs: ["R2"] }], obligations);
  assertEquals(coverage.covered, { R1: 1, R2: 1 });
  assertEquals(coverage.missingRequired, []);
  const adjusted = adjustAllocationForExistingSections(new Map([
    ["beat-1", { minSections: 1, rationale: "covered" }],
    ["beat-2", { minSections: 2, rationale: "new" }],
  ]), existing);
  assertEquals(adjusted.get("beat-1")?.minSections, 0);
  assertEquals(adjusted.get("beat-2")?.minSections, 2);
});

Deno.test("missing existing obligation coverage remains repairable", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const coverage = obligationCoverage([{ recipeRequirementIDs: [] }], obligations);
  assertEquals(coverage.missingRequired.map((item) => item.id), ["R1"]);
});

Deno.test("character arc obligation includes canonical arc signals as one obligation", () => {
  const obligations = deriveRecipeObligations({
    ...sparseRequest.recipe,
    selectedCharacters: [{ name: "Ada", arcStart: "guarded", arcEnd: "trusting", coreLie: "love is weakness", coreTruth: "trust enables courage", wounds: ["war loss"], selfDeceptions: ["I need no one"], moralLines: ["never abandon a child"] }],
  } as any);
  const character = obligations.filter((item) => item.classification === "character_arc");
  assertEquals(character.length, 1);
  for (const signal of ["arcStart", "arcEnd", "coreLie", "coreTruth", "wounds", "selfDeceptions", "moralLines"]) assertEquals(character[0].statement.includes(signal), true);
});

Deno.test("recipe obligation coverage reports missing required items without promoting support", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const coverage = obligationCoverage([{ recipeRequirementIDs: [obligations[0].id] }], obligations);
  assertEquals(coverage.covered, { R1: 1 });
  assertEquals(coverage.missingRequired, []);
  const rich = deriveRecipeObligations({ ...sparseRequest.recipe, selectedStorySpark: { text: "A spark" }, selectedThemeQuestions: [{ text: "A theme" }] } as any);
  const richCoverage = obligationCoverage([{ recipeRequirementIDs: [rich[0].id] }], rich);
  assertEquals(richCoverage.missingRequired.map((item) => item.id), ["R2"]);
});

Deno.test("sparse recipe context is preserved for minimum-only allocation and outline prompts", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 1, rationale: "A concise setup." }],
    ["beat-2", { minSections: 1, rationale: "The conflict needs room to escalate." }],
  ]);
  const { system, user } = buildPrompt(sparseRequest as any, allocation);
  const plannerPrompt = buildAllocationPrompt(sparseRequest as any);
  const plannerInput = plannerPrompt.user;

  // Both planner and generator receive the same complete recipe object, not a
  // character-name-derived summary.
  assertEquals(plannerInput.includes("Monsters kill humans"), true);
  assertEquals(plannerInput.includes('"name": "Douche"'), true);
  assertEquals(user.includes("Monsters kill humans"), true);
  assertEquals(user.includes("Douche"), true);
  assertEquals(system.includes("30-60"), false);
  assertEquals(system.includes("Opening Image: minimum 1 section"), true);
  assertEquals(system.includes("Break into Two: minimum 1 section"), true);
  assertEquals(system.includes("targetSections"), false);
  assertEquals(system.includes("maxSections"), false);
});

Deno.test("allocation parser preserves minimums and rejects malformed plans", () => {
  const beats = sparseRequest.arcTemplate.beats;
  const result = parseAndValidateAllocation(
    JSON.stringify({
      allocations: [
        { beatID: "beat-1", minSections: 2, rationale: "setup" },
        { beatID: "beat-2", minSections: 0, rationale: "escalation" },
      ],
    }),
    beats,
  );
  assertEquals(result.get("beat-1")?.minSections, 2);
  assertEquals(result.get("beat-1")?.rationale, "setup");

  let error = "";
  try {
    parseAndValidateAllocation(JSON.stringify({ plan: [] }), beats);
  } catch (caught) {
    error = String(caught);
  }
  assertEquals(error.includes("missing allocations array"), true);

  let missingError = "";
  try {
    parseAndValidateAllocation(
      JSON.stringify({ allocations: [{ beatID: "beat-1", minSections: 1, rationale: "setup" }] }),
      beats,
    );
  } catch (caught) {
    missingError = String(caught);
  }
  assertEquals(missingError.includes("missing beat"), true);

  for (const invalid of [
    {
      allocations: [
        { beatID: "beat-1", minSections: 1, rationale: "setup" },
        { beatID: "beat-1", minSections: 1, rationale: "duplicate" },
        { beatID: "beat-2", minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatID: "unknown", minSections: 1, rationale: "unknown" },
        { beatID: "beat-1", minSections: 1, rationale: "setup" },
        { beatID: "beat-2", minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatID: "beat-1", minSections: 1.5, rationale: "not integer" },
        { beatID: "beat-2", minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatID: "beat-1", minSections: 1, targetSections: 2, rationale: "legacy target" },
        { beatID: "beat-2", minSections: 1, rationale: "break" },
      ],
    },
  ]) {
    let invalidError = "";
    try {
      parseAndValidateAllocation(JSON.stringify(invalid), beats);
    } catch (caught) {
      invalidError = String(caught);
    }
    assertEquals(invalidError.length > 0, true);
    assertEquals(invalidError.includes("default"), false);
  }

  // There is no allocation-total guard: the global response cap is separate.
  const largeMinimumPlan = parseAndValidateAllocation(
    JSON.stringify({ allocations: [
      { beatID: "beat-1", minSections: 10, rationale: "dense" },
      { beatID: "beat-2", minSections: 10, rationale: "dense" },
    ] }),
    beats,
  );
  assertEquals(largeMinimumPlan.get("beat-1")?.minSections, 10);
});

Deno.test("existing beat coverage allows zero allocation and emits no duplicate", () => {
  const requestWithExisting = {
    ...sparseRequest,
    existingSections: [{
      title: "Already accepted",
      summary: "The opening image is already established.",
      storyArcBeatID: "beat-1",
    }],
  };
  const plannerPrompt = buildAllocationPrompt(requestWithExisting as any);
  assertEquals(plannerPrompt.user.includes("Already accepted"), true);
  assertEquals(plannerPrompt.user.includes("existingSectionsByBeat"), true);

  const allocation = parseAndValidateAllocation(
    JSON.stringify({
      allocations: [
        { beatID: "beat-1", minSections: 0, rationale: "already covered" },
        { beatID: "beat-2", minSections: 1, rationale: "new escalation" },
      ],
    }),
    requestWithExisting.arcTemplate.beats,
  );
  const generated = {
    suggestions: [{
      title: "The Flight",
      summary: "Douche escapes as monsters hunt humans.",
      container: "scene",
      pov: "thirdPersonLimited",
      terminalBeat: "The shelter fails.",
      storyArcBeatID: "beat-2",
    }],
  };
  const result = validateSuggestions(
    generated,
    new Set(["beat-1", "beat-2"]),
    allocation,
  );
  assertEquals(result.suggestions.length, 1);
  assertEquals(
    result.suggestions.some((s) => s.storyArcBeatID === "beat-1"),
    false,
  );
});

Deno.test("zero allocation accepts an empty suggestion result", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 0, rationale: "already covered" }],
    ["beat-2", { minSections: 0, rationale: "already covered" }],
  ]);
  const result = validateSuggestions(
    { suggestions: [] },
    new Set(["beat-1", "beat-2"]),
    allocation,
  );
  assertEquals(result.suggestions, []);
});

const repairAllocation = new Map([
  ["beat-1", { minSections: 1, rationale: "setup" }],
  ["beat-2", { minSections: 2, rationale: "escalation" }],
  ["beat-3", { minSections: 2, rationale: "aftermath" }],
]);
const repairBeatOrder = ["beat-1", "beat-2", "beat-3"];
const repairBeatIds = new Set(repairBeatOrder);

function repairSuggestion(title: string, beatID: string): any {
  return {
    title,
    summary: `${title} changes the story.`,
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: `${title} ends with a consequential turn.`,
    storyArcBeatID: beatID,
  };
}

Deno.test("repair flow merges an earlier beat in canonical arc order", () => {
  const firstPass = [
    repairSuggestion("Beat 1 first", "beat-1"),
    repairSuggestion("Beat 2 first", "beat-2"),
    repairSuggestion("Beat 2 second", "beat-2"),
    repairSuggestion("Beat 3 first", "beat-3"),
    repairSuggestion("Beat 3 second", "beat-3"),
  ];
  const repaired = [
    repairSuggestion("Beat 2 repaired first", "beat-2"),
    repairSuggestion("Beat 2 repaired second", "beat-2"),
  ];
  const merged = mergeRepairedSuggestions(
    repairBeatOrder,
    repairBeatIds,
    repairAllocation,
    firstPass,
    repaired,
  );
  assertEquals(merged.map((suggestion) => suggestion.title), [
    "Beat 1 first",
    "Beat 2 first",
    "Beat 2 second",
    "Beat 2 repaired first",
    "Beat 2 repaired second",
    "Beat 3 first",
    "Beat 3 second",
  ]);
});

Deno.test("repair flow rejects a duplicate of a salvaged section", () => {
  let error = "";
  try {
    mergeRepairedSuggestions(
      ["beat-1", "beat-2"],
      new Set(["beat-1", "beat-2"]),
      new Map([
        ["beat-1", { minSections: 0, rationale: "covered" }],
        ["beat-2", { minSections: 2, rationale: "escalation" }],
      ]),
      [repairSuggestion("The First Escape", "beat-2")],
      [repairSuggestion("The First Escape", "beat-2")],
    );
  } catch (caught) {
    error = String(caught);
  }
  assertEquals(error.includes("duplicate section contract"), true);
});

Deno.test("repair flow rejects duplicates within the repair response", () => {
  let error = "";
  try {
    mergeRepairedSuggestions(
      ["beat-1", "beat-2"],
      new Set(["beat-1", "beat-2"]),
      new Map([
        ["beat-1", { minSections: 0, rationale: "covered" }],
        ["beat-2", { minSections: 2, rationale: "escalation" }],
      ]),
      [],
      [
        repairSuggestion("New section", "beat-2"),
        repairSuggestion("New section", "beat-2"),
      ],
    );
  } catch (caught) {
    error = String(caught);
  }
  assertEquals(error.includes("duplicate section contract"), true);
});

Deno.test("repair flow accepts additional distinct material without a per-beat maximum", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 0, rationale: "covered" }],
    ["beat-2", { minSections: 2, rationale: "escalation" }],
  ]);
  const repaired = Array.from({ length: 8 }, (_, index) =>
    repairSuggestion(`Repair ${index + 1}`, "beat-2")
  );
  const merged = mergeRepairedSuggestions(
    ["beat-1", "beat-2"],
    new Set(["beat-1", "beat-2"]),
    allocation,
    [],
    repaired,
  );
  assertEquals(merged.length, 8);
});

Deno.test("valid partial plus repair preserves content and canonical order", () => {
  const firstPass = [
    repairSuggestion("Beat 1 first", "beat-1"),
    repairSuggestion("Beat 2 first", "beat-2"),
    repairSuggestion("Beat 2 second", "beat-2"),
    repairSuggestion("Beat 3 first", "beat-3"),
    repairSuggestion("Beat 3 second", "beat-3"),
  ];
  const repaired = [
    repairSuggestion("Beat 2 repaired first", "beat-2"),
    repairSuggestion("Beat 2 repaired second", "beat-2"),
  ];
  const merged = mergeRepairedSuggestions(
    repairBeatOrder,
    repairBeatIds,
    repairAllocation,
    firstPass,
    repaired,
  );
  assertEquals(merged.length, 7);
  assertEquals(merged[0], { ...firstPass[0], plannedWordRange: { minWords: 615, maxWords: 1385 } });
  assertEquals(merged[1], { ...firstPass[1], plannedWordRange: { minWords: 615, maxWords: 1385 } });
  assertEquals(merged[2], { ...firstPass[2], plannedWordRange: { minWords: 615, maxWords: 1385 } });
  assertEquals(merged[3], { ...repaired[0], plannedWordRange: { minWords: 615, maxWords: 1385 } });
  assertEquals(merged[4], { ...repaired[1], plannedWordRange: { minWords: 615, maxWords: 1385 } });
});

Deno.test("minimum-only validation accepts 2, 3, and 8 sections but repairs 1", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 2, rationale: "coverage" }],
  ]);
  const make = (count: number) => ({
    suggestions: Array.from({ length: count }, (_, index) => ({
      title: `Section ${index + 1}`,
      summary: `Distinct event ${index + 1}.`,
      container: "scene",
      pov: "thirdPersonLimited",
      terminalBeat: `Turn ${index + 1}.`,
      storyArcBeatID: "beat-1",
    })),
  });
  for (const count of [2, 3, 8]) {
    const result = validateSuggestions(make(count), new Set(["beat-1"]), allocation);
    assertEquals(result.suggestions.length, count);
  }

  let belowMinimum = "";
  try {
    validateSuggestions(make(1), new Set(["beat-1"]), allocation);
  } catch (caught) {
    belowMinimum = String(caught);
  }
  assertEquals(belowMinimum.includes("returned 1 section; minimum is 2"), true);
});

Deno.test("repair allocation locks satisfied beats to zero and requests only shortages", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 2, rationale: "setup" }],
    ["beat-2", { minSections: 3, rationale: "escalation" }],
    ["beat-3", { minSections: 1, rationale: "aftermath" }],
  ]);
  const partial = [
    repairSuggestion("Beat A only", "beat-1"),
    repairSuggestion("Beat B first", "beat-2"),
    repairSuggestion("Beat B second", "beat-2"),
    repairSuggestion("Beat B third", "beat-2"),
    repairSuggestion("Beat B fourth", "beat-2"),
    repairSuggestion("Beat C only", "beat-3"),
  ];
  const repair = calculateRepairAllocation(allocation, partial);
  assertEquals(repair.get("beat-1")?.minSections, 1);
  assertEquals(repair.get("beat-2")?.minSections, 0);
  assertEquals(repair.get("beat-3")?.minSections, 0);
  assertEquals(repair.get("beat-2")?.rationale, "repair missing sections for beat-2");
  const accepted = mergeRepairedSuggestions(
    ["beat-1", "beat-2", "beat-3"],
    new Set(["beat-1", "beat-2", "beat-3"]),
    allocation,
    partial,
    [repairSuggestion("Beat A repaired", "beat-1")],
  );
  assertEquals(accepted.length, 7);
});

Deno.test("novel planning exposes container semantics and projected-size expansion", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const allocationPrompt = buildAllocationPrompt(sparseRequest as any).system;
  assertEquals(allocationPrompt.includes("70,000-90,000 word"), true);
  assertEquals(allocationPrompt.includes("minimum number of distinct dramatic sections"), true);
  assertEquals(allocationPrompt.includes("floor, not a target or maximum"), true);
  assertEquals(source.includes("targetSections"), false);
  assertEquals(source.includes("maxSections"), false);
  assertEquals(/\bsectionCount\b/.test(source), false);
  assertEquals(source.includes("const MAX_PLANNED_SECTIONS = 200;"), true);
  assertEquals(source.includes("maxItems: MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("merged.length > MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("needsNovelExpansion(result.suggestions, body.existingSections ?? [])"), true);
  assertEquals(source.includes("failed_under_target"), true);
  assertEquals(source.includes("failed_expansion"), true);
  assertEquals(source.includes("outline-expansion-"), true);
  const outlinePrompt = buildPrompt(sparseRequest as any, new Map([
    ["beat-1", { minSections: 1, rationale: "setup" }],
    ["beat-2", { minSections: 1, rationale: "escalation" }],
  ])).system;
  assertEquals(outlinePrompt.includes("expected 800-1,800 tokens"), true);
  assertEquals(outlinePrompt.includes("Novel-ready section titles"), true);
  assertEquals(outlinePrompt.includes("Do not restate or lightly rephrase"), true);
  assertEquals(outlinePrompt.includes("suitable for a novel outline or novel-ready table of contents"), true);
  assertEquals(projectedTokenRange([
    { container: "scene" }, { container: "developedScene" },
  ]), [2300, 4800]);
  assertEquals(projectedExpectedTokens([{ container: "scene" }]), 1300);
  assertEquals(evaluateNovelScale([{ container: "scene" }]).meetsMinimum, false);
  assertEquals(evaluateNovelScale([{ container: "scene" }]).minimumWords, 70000);
  assertEquals(projectedExpectedTokens([{ container: "sceneSequence" }]), 5000);
  assertEquals(projectedExpectedTokens([{ container: "scene" }, { container: "scene" }]), 2600);
  assertEquals(needsNovelExpansion([{ container: "sceneSequence" }]), true);
  assertEquals(needsNovelExpansion([{ container: "scene" }]), true);
  const expansion = buildExpansionPrompt(sparseRequest as any, [{
    title: "Setup", summary: "A setup", container: "scene", pov: "thirdPersonLimited",
    terminalBeat: "The choice is made", storyArcBeatID: "beat-1",
  }]);
  assertEquals(expansion.system.includes("Add distinct events, consequences"), true);
  assertEquals(expansion.system.includes("Do not inflate containers"), true);
  assertEquals(expansion.system.includes("ONLY ADDITIONAL"), true);
  const original = [{ title: "Setup", summary: "A setup", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Choice", storyArcBeatID: "beat-1" }];
  const additions = [{ title: "Consequence", summary: "The choice costs something", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Cost", storyArcBeatID: "beat-1", insertAfterTitle: "Setup" }];
  const merged = mergeExpansionAdditions(original as any, additions as any);
  assertEquals(merged.map((s) => s.title), ["Setup", "Consequence"]);
  assertEquals(merged[0], original[0]);
});


Deno.test("beat-local expansion visits canonical beats and isolates additions", async () => {
  const initial = sceneOutline(55).map((section, index) => ({
    ...section,
    storyArcBeatID: index < 28 ? "beat-1" : "beat-2",
  }));
  const calls: Array<{ beatID: string; currentSections: number }> = [];
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1", "beat-2"]),
    async (_current, _context, beat) => {
      if (!beat) throw new Error("beat context missing");
      calls.push({ beatID: beat.beatID, currentSections: beat.currentSections.length });
      return [
        expansionSection(`${beat.beatID} addition 1`, "chapter", beat.beatID),
        expansionSection(`${beat.beatID} addition 2`, "chapter", beat.beatID),
      ];
    },
    undefined,
    {
      beats: [
        { id: "beat-1", label: "Opening" },
        { id: "beat-2", label: "Escalation" },
      ],
    },
  );
  assertEquals(calls, [
    { beatID: "beat-1", currentSections: 28 },
    { beatID: "beat-2", currentSections: 27 },
  ]);
  assertEquals(result.suggestions.length, 59);
  assertEquals(result.suggestions.filter((section) => section.storyArcBeatID === "beat-1").length, 30);
  assertEquals(result.suggestions.filter((section) => section.storyArcBeatID === "beat-2").length, 29);
});

Deno.test("beat-local expansion rejects additions assigned to another beat", async () => {
  let failure: unknown;
  try {
    await progressivelyExpandOutline(
      sceneOutline(55) as any,
      new Set(["beat-1", "beat-2"]),
      async () => [expansionSection("Wrong beat", "chapter", "beat-2")],
      undefined,
      { beats: [{ id: "beat-1" }, { id: "beat-2" }] },
    );
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_expansion");
  assertEquals((failure as Error).message.includes("validation"), true);
});

Deno.test("beat-local expansion prompt carries the target beat contract", () => {
  const prompt = buildExpansionPrompt(sparseRequest as any, sceneOutline(2) as any, {
    round: 1,
    projectedTokens: 2600,
    projectedWords: 2000,
    desiredWords: [70000, 90000],
    remainingDeficitTokens: 88400,
    beat: {
      beatID: "beat-1",
      beatLabel: "Opening",
      beatDescription: "The ordinary world fractures.",
      currentSections: sceneOutline(2) as any,
      projectedTokens: 2600,
      projectedWords: 2000,
    },
  });
  assertEquals(prompt.system.includes("beat-local expansion"), true);
  assertEquals(prompt.system.includes("storyArcBeatID beat-1"), true);
  assertEquals(prompt.user.includes("beatLocalContext"), true);
});

Deno.test("novel scale evaluates existing accepted sections together with the generated delta", () => {
  const existing = sceneOutline(50);
  const generated = sceneOutline(21);
  const deltaOnly = evaluateNovelScale(generated);
  const complete = evaluateNovelScale(generated, existing);
  assertEquals(deltaOnly.meetsMinimum, false);
  assertEquals(complete.meetsMinimum, true);
  assertEquals(complete.projectedWords >= 70000, true);
});

Deno.test("existing accepted sections can prevent unnecessary expansion", async () => {
  const existing = sceneOutline(70);
  let calls = 0;
  const result = await progressivelyExpandOutline(
    [],
    new Set(["beat-1"]),
    async () => {
      calls++;
      return [expansionSection("Should not be generated")];
    },
    undefined,
    { existingSections: existing },
  );
  assertEquals(calls, 0);
  assertEquals(result.suggestions, []);
  assertEquals(needsNovelExpansion([], existing), false);
});

Deno.test("obligation-aware response schema requires auditable section assignments", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const allocation = new Map([["beat-1", { minSections: 1, rationale: "premise" }], ["beat-2", { minSections: 0, rationale: "transition" }]]);
  const schema = buildSuggestionResponseSchema(sparseRequest.arcTemplate.beats, allocation, obligations) as any;
  const item = schema.properties.beats.properties["beat-1"].items;
  assertEquals(item.required.includes("recipeRequirementIDs"), true);
  const flattened = flattenSuggestionResponse({ beats: { "beat-1": [{ title: "Premise", summary: "Monsters attack.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "The shelter falls.", recipeRequirementIDs: [obligations[0].id] }], "beat-2": [] } }, sparseRequest.arcTemplate.beats);
  assertEquals(flattened.suggestions[0].recipeRequirementIDs, [obligations[0].id]);
  assertEquals(validateSuggestions(flattened, new Set(["beat-1", "beat-2"]), allocation, obligations).suggestions.length, 1);
});

Deno.test("dynamic suggestion schema enforces every beat minimum and flattening owns order and IDs", () => {
  const beats = [{ id: "beat-b" }, { id: "beat-a" }, { id: "beat-c" }];
  const allocation = new Map([
    ["beat-b", { minSections: 1, rationale: "b" }],
    ["beat-a", { minSections: 3, rationale: "a" }],
    ["beat-c", { minSections: 0, rationale: "c" }],
  ]);
  const schema = buildSuggestionResponseSchema(beats, allocation) as any;
  assertEquals(schema.properties.beats.required, ["beat-b", "beat-a", "beat-c"]);
  assertEquals(schema.properties.beats.properties["beat-b"].minItems, 1);
  assertEquals(schema.properties.beats.properties["beat-a"].minItems, 3);
  assertEquals(schema.properties.beats.properties["beat-c"].minItems, 0);
  const section = (title: string) => ({ title, summary: title, container: "scene", pov: "thirdPersonLimited", terminalBeat: title });
  const flattened = flattenSuggestionResponse({ beats: { "beat-b": [section("B")], "beat-a": [section("A1"), section("A2"), section("A3")], "beat-c": [] } }, beats);
  assertEquals(flattened.suggestions.map((s) => s.title), ["B", "A1", "A2", "A3"]);
  assertEquals(flattened.suggestions.map((s) => s.storyArcBeatID), ["beat-b", "beat-a", "beat-a", "beat-a"]);
  let missing = false;
  try { flattenSuggestionResponse({ beats: { "beat-b": [], "beat-a": [], "beat-c": [] } }, beats); } catch { missing = true; }
  assertEquals(missing, false);
  let omitted = false;
  try { flattenSuggestionResponse({ beats: { "beat-b": [], "beat-a": [] } }, beats); } catch { omitted = true; }
  assertEquals(omitted, true);
  let duplicate = false;
  try {
    mergeRepairedSuggestions(["beat-b", "beat-a", "beat-c"], new Set(beats.map((b) => b.id)), new Map(), flattened.suggestions, [flattened.suggestions[0]]);
  } catch { duplicate = true; }
  assertEquals(duplicate, true);
});

Deno.test("dynamic response contract removes model-owned beat IDs and target/max allocation semantics", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const schema = buildSuggestionResponseSchema([{ id: "beat-1" }], new Map([["beat-1", { minSections: 2, rationale: "coverage" }]])) as any;
  assertEquals(schema.properties.beats.properties["beat-1"].items.properties.storyArcBeatID, undefined);
  assertEquals(source.includes("targetSections"), false);
  assertEquals(source.includes("maxSections"), false);
  assertEquals(/\bsectionCount\b/.test(source), false);
  assertEquals(source.includes("const MAX_PLANNED_SECTIONS = 200;"), true);
  assertEquals(source.includes("result.suggestions.length > MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("merged.length > MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("diagnostics:"), true);
  assertEquals(source.includes("plannerAllocationValidatedCountsByBeat"), true);
  assertEquals(source.includes("firstPassParsedCounts"), true);
  assertEquals(source.includes("firstPassValidatedCounts"), true);
  assertEquals(source.includes("if (validateResponse) await validateResponse"), true);
  assertEquals(source.includes("needsNovelExpansion(result.suggestions, body.existingSections ?? [])"), true);
});


function expansionSection(title: string, container = "scene", beat = "beat-1", insertAfterTitle: string | null = null): any {
  return { title, summary: `${title} summary`, container, pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, insertAfterTitle };
}

function sceneOutline(count: number): any[] {
  return Array.from({ length: count }, (_, index) => ({
    title: `Existing ${index + 1}`, summary: `Existing summary ${index + 1}`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `Existing ending ${index + 1}`, storyArcBeatID: "beat-1",
  }));
}

Deno.test("progressive expansion runs round 2 after a short round 1 and succeeds when scale is reached", async () => {
  const calls: any[] = [];
  const initial = sceneOutline(27);
  const result = await progressivelyExpandOutline(initial as any, new Set(["beat-1"]), async (current, context) => {
    calls.push({ current: current.length, context });
    return context.round === 1
      ? Array.from({ length: 10 }, (_, i) => expansionSection(`Round 1 ${i + 1}`, "scene"))
      : Array.from({ length: 10 }, (_, i) => expansionSection(`Round 2 ${i + 1}`, "chapter"));
  });
  assertEquals(calls.map((call) => call.context.round), [1, 2]);
  assertEquals(calls[0].current, 27);
  assertEquals(calls[1].current, 37);
  assertEquals(result.diagnostics.length, 2);
  assertEquals(result.diagnostics[0].sectionCountBefore, 27);
  assertEquals(result.diagnostics[0].sectionCountAfter, 37);
  assertEquals(result.diagnostics[1].sectionCountBefore, 37);
  assertEquals(result.diagnostics[1].sectionCountAfter, 47);
  assertEquals(result.warnings, []);
});

Deno.test("Test3-shaped undersized outline fails closed after bounded expansion", async () => {
  let calls = 0;
  const initial = sceneOutline(22);
  let failure: unknown;
  try {
    await progressivelyExpandOutline(initial as any, new Set(["beat-1"]), async () => {
      calls++;
      return [expansionSection(`Small addition ${calls}`)];
    });
  } catch (error) {
    failure = error;
  }
  assertEquals(calls, MAX_EXPANSION_ROUNDS);
  assertEquals((failure as NovelScalePlanningError).code, "failed_under_target");
  assertEquals((failure as NovelScalePlanningError).message.includes("70,000-word minimum"), true);
});

Deno.test("invalid expansion responses remain typed at the billable boundary", () => {
  const initial = sceneOutline(22);
  let failure: unknown;
  try {
    parseExpansionResponse(JSON.stringify({ suggestions: [{ title: "Bad", summary: "Bad", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Ends", storyArcBeatID: "unknown", insertAfterTitle: null }] }), new Set(["beat-1"]), initial as any);
  } catch (error) {
    failure = error;
  }
  assertEquals(failure instanceof ExpansionValidationError, true);
  assertEquals((failure as Error).message.includes("expansion returned an invalid addition"), true);
});

Deno.test("failed expansion retains the first-pass suggestions in its checkpoint", async () => {
  const firstPass = sceneOutline(22);
  let checkpointSuggestions: any[] | null = null;
  let failure: unknown;
  try {
    await progressivelyExpandOutline(
      firstPass as any,
      new Set(["beat-1"]),
      async () => { throw new ExpansionValidationError("round 1 failed"); },
      async (_diagnostic, rounds, current) => {
        checkpointSuggestions = current;
        assertEquals(buildExpansionCheckpoint(current, [], rounds).scale.meetsMinimum, false);
      },
    );
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_expansion");
  assertEquals(checkpointSuggestions, firstPass);
});

Deno.test("successful round 1 plus failed round 2 retains the round-1 checkpoint", async () => {
  const firstPass = sceneOutline(27);
  let checkpoint: any = null;
  let failure: unknown;
  try {
    await progressivelyExpandOutline(
      firstPass as any,
      new Set(["beat-1"]),
      async (_current, context) => {
        if (context.round === 1) return Array.from({ length: 10 }, (_, i) => expansionSection(`Round 1 checkpoint ${i + 1}`));
        throw new ExpansionValidationError("round 2 failed");
      },
      async (_diagnostic, rounds, current) => {
        checkpoint = buildExpansionCheckpoint(current, [], rounds);
      },
    );
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_expansion");
  assertEquals(checkpoint.nextRound, 2);
  assertEquals(checkpoint.expansionRounds.filter((round: any) => round.status === "completed").length, 1);
  assertEquals(checkpoint.scale.projectedWords, evaluateNovelScale(Array.from({ length: 37 }, () => ({ container: "scene" }))).projectedWords);
});

Deno.test("retry resumes from the persisted expansion checkpoint without repeating first-pass work", async () => {
  const checkpointSuggestions = sceneOutline(37);
  const completedRound = {
    round: 1,
    sectionCountBefore: 27,
    projectedTokensBefore: 35100,
    projectedWordsBefore: 27000,
    additionsReturned: 10,
    sectionCountAfter: 37,
    projectedTokensAfter: 48100,
    projectedWordsAfter: 37000,
    remainingEstimatedDeficitTokens: 42900,
    status: "completed",
  } as const;
  const resumed = expansionResumeState({
    suggestions: checkpointSuggestions,
    diagnostics: {
      expansionCheckpoint: {
        stage: "expansion",
        nextRound: 2,
        scale: evaluateNovelScale(checkpointSuggestions),
        expansionRounds: [completedRound],
      },
    },
  });
  assertEquals(resumed?.startRound, 2);
  assertEquals(resumed?.suggestions, checkpointSuggestions);
  assertEquals(resumed?.priorDiagnostics.length, 1);
  const calls: number[] = [];
  const result = await progressivelyExpandOutline(
    resumed!.suggestions,
    new Set(["beat-1"]),
    async (_current, context) => {
      calls.push(context.round);
      return Array.from({ length: 20 }, (_, i) => expansionSection(`Retry round ${i + 1}`, "chapter"));
    },
    undefined,
    { startRound: resumed!.startRound, priorDiagnostics: resumed!.priorDiagnostics },
  );
  assertEquals(calls, [2]);
  assertEquals(result.suggestions.length, 57);
});

Deno.test("a production-shaped ~49,230-word outline remains non-completable when expansion fails", async () => {
  const existing = [
    ...sceneOutline(49),
    ...sceneOutline(2).map((section) => ({ ...section, container: "beat" })),
  ];
  const scale = evaluateNovelScale([], existing);
  assertEquals(Math.round(scale.projectedWords), 49250);
  assertEquals(scale.meetsMinimum, false);
  let failure: unknown;
  try {
    await progressivelyExpandOutline(
      [],
      new Set(["beat-1"]),
      async () => { throw new ExpansionValidationError("required expansion failed"); },
      undefined,
      { existingSections: existing },
    );
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_expansion");
});

Deno.test("invalid expansion is a terminal failed_expansion, never a completed under-target outline", async () => {
  const initial = sceneOutline(22);
  const duplicate = expansionSection("New", "scene", "beat-1");
  let rejected = false;
  try {
    validateExpansionAdditions({ suggestions: [duplicate, duplicate] }, new Set(["beat-1"]), initial as any);
  } catch { rejected = true; }
  assertEquals(rejected, true);
  let failure: unknown;
  try {
    await progressivelyExpandOutline(initial as any, new Set(["beat-1"]), async () => {
      throw new ExpansionValidationError("expansion placement crosses arc beats");
    });
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_expansion");
  assertEquals((failure as Error).message.includes("round 1"), true);
});

Deno.test("existing sections survive progressive expansion and global cap fails closed below target", async () => {
  const initial = sceneOutline(199).map((section) => ({ ...section, container: "beat" }));
  let failure: unknown;
  try {
    await progressivelyExpandOutline(initial as any, new Set(["beat-1"]), async () => [expansionSection("At cap", "scene"), expansionSection("Over cap", "scene")]);
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as NovelScalePlanningError).code, "failed_under_target");
  assertEquals((failure as NovelScalePlanningError).message.includes("70,000-word minimum"), true);
});

Deno.test("expansion prompt includes round projection, broad range, and remaining deficit", () => {
  const prompt = buildExpansionPrompt(sparseRequest as any, sceneOutline(27) as any, { round: 2, projectedTokens: 35100, projectedWords: 27000, desiredWords: [70000, 90000], remainingDeficitTokens: 22700 });
  assertEquals(prompt.system.includes("progressive expansion round 2 of 3"), true);
  assertEquals(prompt.system.includes("remaining estimated deficit"), true);
  assertEquals(prompt.user.includes("remainingDeficitTokens"), true);
  assertEquals(prompt.system.includes("22,700"), true);
  assertEquals(prompt.system.includes("never return, rewrite, reorder, or omit existing sections"), true);
});


function enrichmentFixture(): any {
  return {
    schema: "cathedralos.story_material_enrichment",
    version: 2,
    format: "novel",
    sourceRecipeHash: "fixture-hash", sourceRecipeVersion: 1, sourcePromptPackID: "pack-1", sourcePromptPackName: "Sparse recipe",
    rationale: "The sparse premise needs concrete opposition and escalation.",
    characters: [{ id: "character-brody", source: "recipe", sourceReference: "character:character-1", label: "Brody", description: "The protagonist who uses bugs and lizards to pursue world domination." }],
    antagonisticForces: [{ id: "force-emergency-network", source: "planner", sourceReference: null, label: "Emergency network", description: "A coordinated response learns to sever Brody's creature routes." }],
    locations: [{ id: "location-terrarium", source: "recipe", sourceReference: "project.summary", label: "Terrarium room", description: "Brody's controlled starting environment." }],
    institutionsAndGroups: [], conflictSources: [], escalationLadder: [{ id: "escalation-town", source: "planner", sourceReference: null, label: "Townwide disruption", description: "A local experiment becomes visible to the town." }],
    reversals: [], consequences: [], relationships: [], discoveries: [], unresolvedQuestions: [], thematicPressures: [],
  };
}

Deno.test("story material enrichment validates provenance and remains inspectable for reuse", () => {
  const material = validateStoryMaterialEnrichment(enrichmentFixture());
  assertEquals(material.characters[0].source, "recipe");
  assertEquals(material.antagonisticForces[0].source, "planner");
  assertEquals(countStoryMaterialItems(material), 4);
  const reused = validateStoryMaterialEnrichment(JSON.parse(JSON.stringify(material)));
  assertEquals(reused, material);
  let duplicate = "";
  try {
    validateStoryMaterialEnrichment({ ...enrichmentFixture(), locations: [{ ...enrichmentFixture().locations[0], id: "character-brody" }] });
  } catch (error) { duplicate = String(error); }
  assertEquals(duplicate.includes("duplicate"), true);
});

Deno.test("enrichment prompt preserves sparse recipe facts and separates planner invention", () => {
  const prompt = buildEnrichmentPrompt(sparseRequest as any);
  assertEquals(prompt.system.includes("preserve, connect, and deepen supplied material"), true);
  assertEquals(prompt.system.includes("source=recipe"), true);
  assertEquals(prompt.system.includes("source=planner"), true);
  assertEquals(prompt.user.includes("Monsters kill humans"), true);
  assertEquals(prompt.user.includes("Douche"), true);
});

Deno.test("request validation accepts a previously persisted enrichment package", () => {
  assertEquals(validateRequest({ ...sparseRequest, storyMaterialEnrichment: enrichmentFixture() }), null);
});


function materialItem(id: string, source: "recipe" | "planner", sourceReference: string | null = null): any {
  return { id, source, sourceReference, label: id.replaceAll("-", " "), description: `${id} creates a concrete pressure, choice, and consequence.` };
}

function fixtureMaterial(recipe: any, sparse: boolean): any {
  const material: any = {
    schema: "cathedralos.story_material_enrichment", version: 2, format: "novel",
    sourceRecipeHash: "pending", sourceRecipeVersion: 1, sourcePromptPackID: "pack-1", sourcePromptPackName: "Sparse recipe",
    rationale: "Concrete material for novel-scale planning.",
  };
  for (const category of ["characters", "antagonisticForces", "locations", "institutionsAndGroups", "conflictSources", "escalationLadder", "reversals", "consequences", "relationships", "discoveries", "unresolvedQuestions", "thematicPressures"]) material[category] = [];
  material.characters.push(materialItem("brody", "recipe", "character:character-1"));
  material.characters.push(materialItem("bug-a-saur", "recipe", "character:character-2"));
  if (!sparse) {
    material.characters.push(materialItem("mentor", "recipe", "character:character-3"));
    material.relationships.push(materialItem("brody-bug", "recipe", "relationship:relationship-1"));
    material.thematicPressures.push(materialItem("moral-question", "recipe", "theme:theme-1"));
    material.locations.push(materialItem("city", "recipe", "location:location-1"));
    material.conflictSources.push(materialItem("rival", "recipe", "conflict:conflict-1"));
    material.escalationLadder.push(materialItem("public-crisis", "recipe", "event:event-1"));
  }
  const planner = {
    antagonisticForces: 2, locations: 3, institutionsAndGroups: 2, conflictSources: sparse ? 3 : 1,
    escalationLadder: sparse ? 4 : 2, reversals: 2, consequences: 2, relationships: sparse ? 2 : 1,
    discoveries: 2, unresolvedQuestions: 2, thematicPressures: 1,
  };
  for (const [category, count] of Object.entries(planner)) for (let i = 0; i < count; i++) material[category].push(materialItem(`${category}-${i + 1}`, "planner"));
  return material;
}

const brodyRecipe: any = {
  ...sparseRequest.recipe,
  project: { id: "brody", summary: "Brody takes over the world using bugs and lizards" },
  selectedCharacters: [{ id: "character-1", name: "Brody" }, { id: "character-2", name: "Bug a saur" }],
  selectedThemeQuestions: [{ id: "theme-1", question: "bugs are morally better than humans" }],
  promptPack: { id: "pack-1", name: "Sparse recipe" },
};

Deno.test("recipe provenance handles are server-verifiable and forged recipe claims fail", async () => {
  const material = fixtureMaterial(brodyRecipe, true);
  material.antagonisticForces[0] = materialItem("forged", "recipe", "character:does-not-exist");
  let error = "";
  try { validateStoryMaterialEnrichment(material, { recipe: brodyRecipe }); } catch (caught) { error = String(caught); }
  assertEquals(error.includes("unverified source reference"), true);
  material.antagonisticForces[0] = materialItem("valid", "recipe", "character:character-1");
  material.antagonisticForces[0].label = "character:character-1";
  error = "";
  try { validateStoryMaterialEnrichment(material, { recipe: brodyRecipe }); } catch (caught) { error = String(caught); }
  assertEquals(error.includes("no authored description"), true);
  material.antagonisticForces[0] = materialItem("unrelated", "recipe", "character:character-1");
  error = "";
  try { validateStoryMaterialEnrichment(material, { recipe: brodyRecipe }); } catch (caught) { error = String(caught); }
  assertEquals(error.includes("does not correspond"), true);
  material.antagonisticForces[0] = materialItem("planner", "planner", null);
  assertEquals(validateStoryMaterialEnrichment(material, { recipe: brodyRecipe }).antagonisticForces[0].source, "planner");
});

Deno.test("sparse Brody enrichment is sufficient and structurally rich", () => {
  const material = fixtureMaterial(brodyRecipe, true);
  const result = storyMaterialSufficiency(material, brodyRecipe, "novel");
  assertEquals(result.sufficient, true);
  assertEquals(result.counts.escalationLadder >= 3, true);
  assertEquals(result.counts.antagonisticForces >= 1, true);
  assertEquals(result.plannerInventedItemCount > result.recipeDerivedItemCount, true);
});

Deno.test("rich recipe preserves authored material and needs less planner invention", () => {
  const richRecipe = {
    ...brodyRecipe,
    promptPack: { id: "rich-pack", name: "Rich recipe" },
    selectedCharacters: [...brodyRecipe.selectedCharacters, { id: "character-3", name: "Mentor" }],
    selectedRelationships: [{ id: "relationship-1", from: "Brody", to: "Mentor" }],
    selectedThemeQuestions: [{ id: "theme-1", question: "Power has a cost" }],
  };
  const sparse = fixtureMaterial(brodyRecipe, true);
  const rich = fixtureMaterial(richRecipe, false);
  rich.sourcePromptPackID = "rich-pack"; rich.sourcePromptPackName = "Rich recipe";
  const sparseResult = storyMaterialSufficiency(sparse, brodyRecipe, "novel");
  const richResult = storyMaterialSufficiency(rich, richRecipe, "novel");
  assertEquals(richResult.sufficient, true);
  assertEquals(rich.characters.some((item: any) => item.source === "recipe" && item.sourceReference === "character:character-3"), true);
  assertEquals(rich.relationships.some((item: any) => item.source === "recipe" && item.sourceReference === "relationship:relationship-1"), true);
  assertEquals(richResult.plannerInventedItemCount < sparseResult.plannerInventedItemCount, true);
});

Deno.test("recipe hash mismatch and missing legacy provenance cannot reuse", async () => {
  const provenance = await recipeProvenance(brodyRecipe);
  const material = attachRecipeProvenance(fixtureMaterial(brodyRecipe, true), provenance);
  assertEquals(isCompatibleStoryMaterialEnrichment(material, provenance, "novel"), true);
  const changed = { ...brodyRecipe, project: { ...brodyRecipe.project, summary: "Brody becomes a local mayor" } };
  const changedProvenance = await recipeProvenance(changed);
  assertEquals(isCompatibleStoryMaterialEnrichment(material, changedProvenance, "novel"), false);
  const legacy = { ...material, sourceRecipeHash: undefined, sourceRecipeVersion: undefined, sourcePromptPackID: undefined, sourcePromptPackName: undefined };
  let error = "";
  try { validateStoryMaterialEnrichment(legacy, { recipe: brodyRecipe }); } catch (caught) { error = String(caught); }
  assertEquals(error.includes("missing server-owned recipe provenance"), true);
});

Deno.test("format is request-derived rather than hardcoded in enrichment prompt", () => {
  const prompt = buildEnrichmentPrompt({ ...sparseRequest, requestedFormat: "shortStory" } as any);
  assertEquals(prompt.user.includes('"requestedFormat": "shortStory"'), true);
  assertEquals(prompt.system.includes("shortStory"), true);
});


Deno.test("PR2 section schema exposes an additive generation-ready contract", () => {
  const allocation = new Map([[
    "beat-1",
    { minSections: 1, rationale: "opening movement" },
  ]]);
  const schema = buildSuggestionResponseSchema([{ id: "beat-1" }], allocation) as any;
  const required = schema.properties.beats.properties["beat-1"].items.required;
  for (const field of ["entryState", "dramaticEvent", "resultingChange", "terminalState"]) {
    assertEquals(required.includes(field), true);
  }
});

Deno.test("PR2 distinctness gate identifies repeated dramatic work without deleting sections", () => {
  const repeated: any[] = [
    { title: "Cut the route", summary: "Brody cuts the route through the town.", dramaticEvent: "Brody cuts the route through the town.", resultingChange: "The town loses access.", terminalState: "The town loses access.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Access is lost.", storyArcBeatID: "beat-1" },
    { title: "Cut the route again", summary: "Brody cuts the route through the town again.", dramaticEvent: "Brody cuts the route through the town.", resultingChange: "The town loses access.", terminalState: "The town loses access.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Access is lost again.", storyArcBeatID: "beat-1" },
  ];
  assertEquals(findDramaticDistinctnessIssues(repeated).length, 1);
  const distinct = [{ ...repeated[1], dramaticEvent: "An emergency coordinator cuts power to three neighborhoods.", resultingChange: "Brody abandons centralized control." }];
  assertEquals(findDramaticDistinctnessIssues([repeated[0], ...distinct]).length, 0);
});

Deno.test("PR3 causal-scale gate is general and records material-backed diagnostics", () => {
  const material = enrichmentFixture();
  material.escalationLadder = [
    { id: "e1", source: "planner", sourceReference: null, label: "local", description: "A local disruption." },
    { id: "e2", source: "planner", sourceReference: null, label: "regional", description: "A regional response." },
    { id: "e3", source: "planner", sourceReference: null, label: "global", description: "A global consequence." },
  ];
  const suggestions: any[] = [
    { title: "Local breach", summary: "A local route fails.", dramaticEvent: "A local route fails.", resultingChange: "The town mobilizes.", terminalState: "A regional response begins.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Response begins.", storyArcBeatID: "beat-1" },
    { title: "Regional response", summary: "A regional network counters the invasion.", dramaticEvent: "A regional network counters the invasion.", resultingChange: "The opposition learns the route.", terminalState: "Global attention follows.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Attention follows.", storyArcBeatID: "beat-1" },
    { title: "Global consequence", summary: "The global consequence changes the balance.", dramaticEvent: "The global consequence changes the balance.", resultingChange: "The world order shifts.", terminalState: "The new order must be negotiated.", container: "scene", pov: "thirdPersonLimited", terminalBeat: "The order shifts.", storyArcBeatID: "beat-1" },
  ];
  assertEquals(findCausalScaleIssues(suggestions, material, "novel"), []);
  const diagnostics = validateOutlinePlanningQuality(suggestions, material, "novel");
  assertEquals(diagnostics.distinctnessIssues, []);
  assertEquals(diagnostics.causalScaleIssues, []);
  assertEquals(diagnostics.unusedStoryMaterialItems >= 0, true);
});


Deno.test("PR3 expansion prioritizes unused enrichment and exposes soft word ranges", () => {
  const material = enrichmentFixture();
  const current: any[] = [{
    title: "Townwide disruption",
    summary: "The townwide disruption spreads.",
    dramaticEvent: "The townwide disruption spreads.",
    resultingChange: "The town responds.",
    terminalState: "The response escalates.",
    container: "scene", pov: "thirdPersonLimited", terminalBeat: "The response escalates.", storyArcBeatID: "beat-1",
  }];
  const unused = findUnusedStoryMaterial(current, material);
  assertEquals(unused.some((item) => item.id === "force-emergency-network"), true);
  assertEquals(plannedWordRangeForContainer("scene"), { minWords: 615, maxWords: 1385 });
  const prompt = buildExpansionPrompt({ ...sparseRequest, storyMaterialEnrichment: material } as any, current as any);
  assertEquals(prompt.user.includes("unusedStoryMaterial"), true);
  assertEquals(prompt.user.includes("force-emergency-network"), true);
  assertEquals(prompt.system.includes("unused or underdeveloped enrichment items"), true);
  assertEquals(prompt.system.includes("soft literary planning range"), false);
});


Deno.test("enrichment provider schema is strict-compatible and leaves server provenance to the server", () => {
  const schema = STORY_MATERIAL_ENRICHMENT_SCHEMA as any;
  const propertyNames = Object.keys(schema.properties).sort();
  const required = [...schema.required].sort();
  assertEquals(required, propertyNames);
  assertEquals(propertyNames.includes("sourceRecipeHash"), false);
  assertEquals(propertyNames.includes("sourcePromptPackID"), false);
  assertEquals(required.includes("rationale"), true);
});


Deno.test("sparse Brody fixture preserves the complete planning handoff contract", async () => {
  const provenance = await recipeProvenance(brodyRecipe);
  const material = attachRecipeProvenance(fixtureMaterial(brodyRecipe, true), provenance);
  const validated = validateStoryMaterialEnrichment(material, { recipe: brodyRecipe });
  assertEquals(storyMaterialSufficiency(validated, brodyRecipe, "novel").sufficient, true);
  const planned: any = {
    title: "Brody cuts the town escape route", summary: "The lizard swarm traps the response.",
    container: "scene", pov: "thirdPersonLimited", terminalBeat: "The route closes.",
    entryState: "The response is mobilizing.", dramaticEvent: "Brody redirects the swarm.",
    resultingChange: "The response loses its route.", terminalState: "The response escalates.",
    storyArcBeatID: "beat-1", recipeRequirementIDs: [],
  };
  const final = validateSuggestions({ suggestions: [planned] }, new Set(["beat-1"])).suggestions[0];
  assertEquals(final.plannedWordRange, { minWords: 615, maxWords: 1385 });
  const [acceptSource, runSource, generationSource] = await Promise.all([
    Deno.readTextFile("./supabase/functions/accept-outline-sections/index.ts"),
    Deno.readTextFile("./supabase/functions/run-outline/_generation_request.ts"),
    Deno.readTextFile("./supabase/functions/generate-story/index.ts"),
  ]);
  assertEquals(acceptSource.includes("entry_state: section.entryState"), true);
  assertEquals(acceptSource.includes("target_words_min"), true);
  assertEquals(runSource.includes("sectionEntryState"), true);
  assertEquals(runSource.includes("sectionTerminalState"), true);
  assertEquals(generationSource.includes("Entry state:"), true);
  assertEquals(generationSource.includes("Required terminal state:"), true);
});


const freytagFixture = {
  name: "Freytag's Pyramid",
  beats: [
    { id: "exp", role: "exposition", label: "Exposition" },
    { id: "rise", role: "rising_action", label: "Rising Action" },
    { id: "climax", role: "climax", label: "Climax" },
    { id: "fall", role: "falling_action", label: "Falling Action" },
    { id: "den", role: "denouement", label: "Denouement" },
  ],
};

const semanticSection = (beat: string, title: string, event: string, fn: any) => ({
  title, summary: event, dramaticEvent: event, resultingChange: "The state changes materially.",
  terminalState: "The consequences continue.", entryState: "The prior state holds.",
  container: "scene", pov: "thirdPersonLimited", terminalBeat: "The next state begins.", storyArcBeatID: beat, dramaticFunction: fn,
});

Deno.test("PR3 Freytag semantic contract rejects a decisive takeover in denouement", () => {
  const issues = validateStoryArcSemantics([
    semanticSection("climax", "The Pressure Breaks", "The coalition confronts Brody and the central conflict turns.", "climax"),
    semanticSection("den", "The Open Bid for Rule", "Brody launches a citywide takeover and seizes the government.", "resolution"),
  ] as any, freytagFixture);
  assertEquals(issues.length > 0, true);
  assertEquals(issues.some((issue) => issue.includes("primary conflict") || issue.includes("decisive")), true);
});

Deno.test("PR3 falling action allows consequences but not a new primary conflict", () => {
  const pass = validateStoryArcSemantics([
    semanticSection("climax", "The Turning Choice", "Brody makes the irreversible choice that ends the central confrontation.", "climax"),
    semanticSection("fall", "The Coalition Breaks", "The defeated coalition collapses and secondary alliances negotiate the consequences.", "consequence"),
    semanticSection("den", "A New Balance", "The new order settles and the surviving relationships find a changed normal.", "resolution"),
  ] as any, freytagFixture);
  assertEquals(pass, []);
  const fail = validateStoryArcSemantics([
    semanticSection("climax", "The Turning Choice", "The central confrontation turns.", "climax"),
    semanticSection("fall", "The Second Assault", "The antagonist launches a larger decisive assault on the city.", "consequence"),
  ] as any, freytagFixture);
  assertEquals(fail.length > 0, true);
});

Deno.test("PR3 Hero's Journey Resurrection remains a legal late climactic test", () => {
  const template = { name: "Hero's Journey", beats: [
    { id: "road", role: "road_back", label: "The Road Back" },
    { id: "res", role: "resurrection", label: "Resurrection" },
    { id: "return", role: "return_with_elixir", label: "Return with the Elixir" },
  ] };
  assertEquals(arcRoleContract(template.beats[1], template.name).allowedFunctions.includes("climax"), true);
  assertEquals(validateStoryArcSemantics([
    semanticSection("res", "The Final Test", "The hero faces the final climactic test and transforms.", "climax"),
    semanticSection("return", "The Changed World", "The hero returns with the elixir and a new normal settles.", "resolution"),
  ] as any, template), []);
});

Deno.test("PR3 server repair reassigns a locally misallocated decisive section", () => {
  const result = repairStoryArcMacroStructure([
    semanticSection("den", "The Open Bid for Rule", "Brody launches a citywide takeover and seizes the government.", "resolution"),
    semanticSection("den", "The Quiet Settlement", "The surviving relationships settle into a changed normal.", "resolution"),
  ] as any, freytagFixture);
  assertEquals(result.repaired.length, 1);
  assertEquals(result.suggestions.some((section) => section.storyArcBeatID === "climax"), true);
  assertEquals(result.unresolved, []);
});


Deno.test("PR3 repair cannot empty a required strong-closure beat", () => {
  const result = repairStoryArcMacroStructure([
    semanticSection("den", "The Only Settlement", "Brody launches a citywide takeover and seizes the government.", "resolution"),
  ] as any, freytagFixture);
  assertEquals(result.repaired, []);
  assertEquals(result.unresolved, ["The Only Settlement"]);
  assertEquals(validateStoryArcSemantics([] as any, freytagFixture).some((issue) => issue.includes("required strong closure")), true);
});

Deno.test("PR3 repair preserves allocation minima in the source beat", () => {
  const allocation = new Map([...["exp", "rise", "climax", "fall", "den"].map((id) => [id, { minSections: id === "den" ? 2 : 0, rationale: "test" } as any] as const)]);
  const result = repairStoryArcMacroStructure([
    semanticSection("den", "The Open Bid", "Brody launches a citywide takeover and seizes the government.", "resolution"),
    semanticSection("den", "The Quiet Settlement", "The surviving relationships settle into a changed normal.", "resolution"),
  ] as any, freytagFixture, allocation);
  assertEquals(result.repaired, []);
  assertEquals(result.unresolved, ["The Open Bid"]);
  assertEquals(result.diagnostics.some((item) => item.includes("minimum coverage")), true);
});

Deno.test("PR3 required dramatic functions are validated from final section functions", () => {
  const climaxOnly = { name: "Three-Act", beats: [{ id: "c", role: "climax", label: "Climax" }] };
  const missing = validateRequiredStoryArcFunctions([semanticSection("c", "Crisis", "The crisis turns.", "crisis")] as any, climaxOnly as any);
  assertEquals(missing.some((issue) => issue.includes("Climax") && issue.includes("climax") && issue.includes("crisis")), true);
  const resurrection = { name: "Hero's Journey", beats: [{ id: "r", role: "resurrection", label: "Resurrection" }] };
  assertEquals(validateStoryArcSemantics([semanticSection("r", "The Test", "The hero transforms.", "transformation")] as any, resurrection as any).some((issue) => issue.includes("required dramatic function climax")), true);
  assertEquals(validateStoryArcSemantics([semanticSection("r", "The Test", "The final confrontation turns.", "climax")] as any, resurrection as any), []);
});

Deno.test("PR3 expansion schema and parser enforce beat-local semantic functions", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const schema = buildExpansionResponseSchema(arcRoleContract(template.beats[0], template.name)) as any;
  assertEquals(schema.properties.suggestions.items.properties.dramaticFunction.enum.includes("climax"), false);
  const addition: any = semanticSection("fall", "Second Assault", "The antagonist launches a larger decisive assault on the city.", "consequence");
  addition.insertAfterTitle = null;
  let failed = false;
  try { parseExpansionResponse(JSON.stringify({ suggestions: [addition] }), new Set(["fall"]), [], [], template as any); } catch (error) { failed = String(error).includes("primary conflict"); }
  assertEquals(failed, true);
  const denouement = { name: "Freytag's Pyramid", beats: [{ id: "den", role: "denouement", label: "Denouement" }] };
  const denAddition: any = semanticSection("den", "Another Assault", "The antagonist launches another takeover.", "consequence");
  denAddition.insertAfterTitle = null;
  let denFailed = false;
  try { parseExpansionResponse(JSON.stringify({ suggestions: [denAddition] }), new Set(["den"]), [], [], denouement as any); } catch (error) { denFailed = String(error).includes("primary conflict"); }
  assertEquals(denFailed, true);
});

Deno.test("PR3 expansion prompt carries the complete target semantic contract", () => {
  const template = { ...sparseRequest, arcTemplate: { name: "Freytag's Pyramid", id: "f", beats: freytagFixture.beats } } as any;
  const prompt = buildExpansionPrompt(template, [], { round: 1, projectedTokens: 1, projectedWords: 1, desiredWords: [70000, 90000], remainingDeficitTokens: 100, beat: { beatID: "fall", beatLabel: "Falling Action", currentSections: [], projectedTokens: 0, projectedWords: 0 } } as any);
  assertEquals(prompt.system.includes("allowedFunctions="), true);
  assertEquals(prompt.system.includes("forbidsNewPrimaryConflict=true"), true);
  assertEquals(prompt.system.includes("phaseDirection=resolve"), true);
});

Deno.test("PR3 repair chooses the nearest compatible beat and refuses unsafe long-distance movement", () => {
  const localTemplate = { name: "Three-Act", beats: [
    { id: "setup", role: "setup", label: "Setup" }, { id: "rise", role: "rising_action", label: "Rising" },
    { id: "climax", role: "climax", label: "Climax" }, { id: "den", role: "resolution", label: "Resolution" },
  ] };
  const local = repairStoryArcMacroStructure([
    semanticSection("den", "Bad Late Assault", "The antagonist launches a citywide takeover.", "resolution"),
    semanticSection("den", "Quiet End", "The world settles into a new normal.", "resolution"),
  ] as any, localTemplate as any);
  assertEquals(local.suggestions.some((section) => section.storyArcBeatID === "climax"), true);
  assertEquals(validateRequiredStoryArcFunctions(local.suggestions as any, localTemplate as any), []);
  const farTemplate = { name: "Three-Act", beats: [
    { id: "den", role: "resolution", label: "Resolution" }, { id: "one", role: "setup", label: "One" },
    { id: "two", role: "rising_action", label: "Two" }, { id: "three", role: "rising_action", label: "Three" },
    { id: "climax", role: "climax", label: "Climax" },
  ] };
  const far = repairStoryArcMacroStructure([
    semanticSection("den", "Bad Late Assault", "The antagonist launches a citywide takeover.", "resolution"),
    semanticSection("den", "Quiet End", "The world settles into a new normal.", "resolution"),
  ] as any, farTemplate as any);
  assertEquals(far.repaired, []);
  assertEquals(far.unresolved, ["Bad Late Assault"]);
});

Deno.test("PR3 all seven built-in template families use explicit canonical role contracts", () => {
  const cases: Array<[string, string, string]> = [
    ["Three-Act", "first_plot_point", "commitment"], ["Hero's Journey", "meeting_mentor", "transformation"],
    ["Mystery", "false_solution", "reversal"], ["Save the Cat!", "b_story", "transformation"],
    ["Story Circle", "take", "crisis"], ["Freytag's Pyramid", "falling_action", "consequence"],
    ["Kishōtenketsu", "sho", "complication"],
  ];
  for (const [name, role, fn] of cases) assertEquals(arcRoleContract({ role, label: role }, name).allowedFunctions.includes(fn as any), true);
  const sho = arcRoleContract({ role: "sho", label: "Shō" }, "Kishōtenketsu");
  assertEquals(sho.allowedFunctions.includes("reversal"), false);
  assertEquals(arcRoleContract({ role: "ten", label: "Ten" }, "Kishōtenketsu").allowedFunctions.includes("reversal"), true);
  const ketsu = { name: "Kishōtenketsu", beats: [{ id: "k", role: "ketsu", label: "Ketsu" }] };
  assertEquals(validateStoryArcSemantics([semanticSection("k", "Unfinished", "The event continues.", "transformation")] as any, ketsu as any).some((issue) => issue.includes("required dramatic function resolution")), true);
});
