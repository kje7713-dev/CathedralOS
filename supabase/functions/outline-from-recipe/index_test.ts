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
  calculateRepairAllocation,
  ExpansionValidationError,
  NovelScalePlanningError,
  MAX_EXPANSION_ROUNDS,
  progressivelyExpandOutline,
  validateExpansionAdditions,
  mergeRepairedSuggestions,
  mergeExpansionAdditions,
  needsNovelExpansion,
  projectedExpectedTokens,
  projectedTokenRange,
  parseAndValidateAllocation,
  flattenSuggestionResponse,
  validateRequest,
  validateSuggestions,
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
  assertEquals(merged[0], firstPass[0]);
  assertEquals(merged[1], firstPass[1]);
  assertEquals(merged[2], firstPass[2]);
  assertEquals(merged[3], repaired[0]);
  assertEquals(merged[4], repaired[1]);
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
  assertEquals(source.includes("if (needsNovelExpansion(result.suggestions))"), true);
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
  assertEquals(source.includes("if (needsNovelExpansion(result.suggestions))"), true);
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

Deno.test("invalid expansion placement fails closed with diagnostics", async () => {
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
  assertEquals((failure as NovelScalePlanningError).message.includes("expansion placement crosses arc beats"), true);
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
