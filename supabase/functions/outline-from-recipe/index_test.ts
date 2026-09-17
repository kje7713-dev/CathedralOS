import { assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { deriveRecipeObligations, obligationCoverage } from "./_recipe_obligations.ts";
import { compactMaterial } from "./_prompt_context.ts";

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
  outlineLogicalStageFamily,
  buildPrompt,
  buildSuggestionResponseSchema,
  STORY_MATERIAL_ENRICHMENT_SCHEMA,
  calculateRepairAllocation,
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
  repairStoryMaterialFromRecipe,
  mergeCanonicalRecipeMaterial,
  resumeOrRepairStoryMaterial,
  normalizeProviderStoryMaterialItemIDs,
  downgradeUnverifiedProviderRecipeReferences,
  validateStoryMaterialEnrichment,
  storyMaterialSufficiency,
  recipeProvenance,
  attachRecipeProvenance,
  isCompatibleStoryMaterialEnrichment,
  findDramaticDistinctnessIssues,
  findCausalScaleIssues,
  validateOutlinePlanningQuality,
  collectAdvisoryOutlineQuality,
  plannedWordRangeForContainer,
  findUnusedStoryMaterial,
  validateStoryArcSemantics,
  validatePostRepairBeatCoverage,
  validateRequiredStoryArcFunctions,
  repairRequiredStoryArcFunctions,
  repairStoryArcMacroStructure,
  arcRoleContract,
  buildExpansionResponseSchema,
  planSectionAllocation,
  checkRateLimit,
  logRequest,
  isRetryableStoryMaterialFailure,
  StoryMaterialSufficiencyError,
  StoryMaterialValidationError,
  SuggestionWorkerYield,
  SuggestionWorkerSlice,
  assertWorkerSliceCanDispatch,
  reclaimExpiredSuggestionRun,
  returnSuggestionRunToPending,
  recoverPendingSuggestionRun,
  runSuggestionJob,
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
  assertEquals(source.includes('workerSliceCount'), true);
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
Deno.test("POST production path validates local_project_id and lineage before billing", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(source.includes("local_project_id"), true);
  assertEquals(source.includes("outlineRow.lineage_id"), true);
  assertEquals(source.includes('select("id, user_id, local_project_id, lineage_id, source_recipe_hash")'), true);
  assertEquals(source.includes('.select("id, user_id, project_id, lineage_id")'), false);
  const ownership = source.indexOf("const { data: outlineRow");
  const insert = source.indexOf("const insert = await db");
  assertEquals(ownership >= 0 && insert > ownership, true);
});

Deno.test("PR4 validateRequest accepts outline_id + project_lineage_id + requestedFormat", () => {
  assertEquals(
    validateRequest({
      ...sparseRequest,
      outline_id: "11111111-1111-4111-8111-111111111111",
      project_lineage_id: "22222222-2222-4222-8222-222222222222",
      requestedFormat: "novel",
    }),
    null,
    "Full PR 4 wire shape (outline_id + project_lineage_id + requestedFormat) must pass validation; the POST handler does the DB-backed ownership check pre-billable",
  );
});

Deno.test("PR4 validateRequest rejects malformed outline_id", () => {
  assertEquals(
    validateRequest({ ...sparseRequest, outline_id: "not-a-uuid" }),
    "outline_id must be a UUID string when present",
  );
  assertEquals(
    validateRequest({ ...sparseRequest, outline_id: 12345 }),
    "outline_id must be a UUID string when present",
  );
});

Deno.test("PR4 validateRequest rejects malformed project_lineage_id", () => {
  assertEquals(
    validateRequest({ ...sparseRequest, project_lineage_id: "nope" }),
    "project_lineage_id must be a UUID string when present",
  );
  assertEquals(
    validateRequest({ ...sparseRequest, project_lineage_id: null }),
    "project_lineage_id must be a UUID string when present",
  );
});

Deno.test("PR4 validateRequest accepts missing outline_id for legacy callers", () => {
  // Legacy callers that have not yet been migrated to the new contract
  // omit outline_id entirely. The server treats this as 'skip enrichment
  // provenance + skip ownership check' (backward compatibility).
  assertEquals(validateRequest(sparseRequest), null);
  assertEquals(
    validateRequest({ ...sparseRequest, outline_id: undefined }),
    null,
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

Deno.test("existing accepted sections satisfy obligation coverage", () => {
  const obligations = deriveRecipeObligations({ ...sparseRequest.recipe, selectedStorySpark: { text: "R2" } } as any);
  const existing = [{ storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] }];
  const coverage = obligationCoverage([...existing, { recipeRequirementIDs: ["R2"] }], obligations);
  assertEquals(coverage.covered, { R1: 1, R2: 1 });
  assertEquals(coverage.missingRequired, []);
});

// PR 5 — "count existing section coverage once" regression suite.
//
// The bug: buildAllocationPrompt instructed the planner to return minSections as
// the number of NEW sections still required after considering existingSections,
// but the production planning path then called adjustAllocationForExistingSections
// and subtracted existing-section counts AGAIN. Existing coverage was therefore
// counted twice.
//
// The fix: delete adjustAllocationForExistingSections, use plannedAllocation
// directly, and tighten the planner prompt so the residual contract is
// unambiguous. These tests prove the new contract at the prompt level and at the
// production-prompt level (which consumes the planner's residual output
// unchanged).

Deno.test("planner prompt passes empty existingSectionsByBeat when no existing sections", () => {
  const { system, user } = buildAllocationPrompt({ ...sparseRequest, existingSections: [] } as any);
  assertEquals(
    system.includes("minSections represents the number of additional sections still required beyond existingSections"),
    true,
    "planner prompt must explicitly state the residual-count contract",
  );
  const parsed = JSON.parse(user);
  for (const [beatIndex, beat] of parsed.planningContext.arc.beats.entries()) {
    assertEquals(beat.beatIndex, beatIndex);
    assertEquals(parsed.existingSectionsByBeat[sparseRequest.arcTemplate.beats[beatIndex].id], []);
  }
  assertEquals(parsed.existingUnlinkedSections, []);
});

Deno.test("planner prompt groups one existing section onto its linked beat", () => {
  const section = { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] };
  const { system, user } = buildAllocationPrompt({ ...sparseRequest, existingSections: [section] } as any);
  assertEquals(
    system.includes("existing coverage is already accounted for; do not include it in minSections"),
    true,
    "planner prompt must instruct planner NOT to count existing coverage in minSections",
  );
  const parsed: any = JSON.parse(user);
  assertEquals(parsed.existingSectionsByBeat["beat-1"], [{ id: null, title: null, summary: null, terminalState: null, recipeRequirementIDs: section.recipeRequirementIDs }]);
  assertEquals(parsed.existingSectionsByBeat["beat-2"], []);
  assertEquals(parsed.existingUnlinkedSections, []);
});

Deno.test("planner prompt groups two existing sections onto the same beat", () => {
  const s1 = { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] };
  const s2 = { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R2"] };
  const { system, user } = buildAllocationPrompt({ ...sparseRequest, existingSections: [s1, s2] } as any);
  assertEquals(
    system.includes("minSections represents the number of additional sections still required beyond existingSections"),
    true,
  );
  const parsed: any = JSON.parse(user);
  assertEquals(parsed.existingSectionsByBeat["beat-1"].map((s: any) => s.recipeRequirementIDs), [s1.recipeRequirementIDs, s2.recipeRequirementIDs]);
  assertEquals(parsed.existingSectionsByBeat["beat-2"], []);
  assertEquals(parsed.existingUnlinkedSections, []);
});

Deno.test("planner prompt groups mixed beats with different existing coverage plus unlinked", () => {
  const s1 = { storyArcBeatID: "beat-1" };
  const s2 = { storyArcBeatID: "beat-1" };
  const s3 = { storyArcBeatID: "beat-2" };
  const s4 = { storyArcBeatID: "beat-unknown" }; // unlinked to the arc template
  const { system, user } = buildAllocationPrompt({ ...sparseRequest, existingSections: [s1, s2, s3, s4] } as any);
  assertEquals(
    system.includes("minSections represents the number of additional sections still required beyond existingSections"),
    true,
  );
  const parsed: any = JSON.parse(user);
  assertEquals(parsed.existingSectionsByBeat["beat-1"].map((s: any) => s.title), [null, null]);
  assertEquals(parsed.existingSectionsByBeat["beat-2"], [{ id: null, title: null, summary: null, terminalState: null, recipeRequirementIDs: [] }]);
  // beat-unknown is not in the arc template, so per-beat bucket is absent and
  // the section falls into existingUnlinkedSections.
  assertEquals(parsed.existingSectionsByBeat["beat-unknown"], undefined);
  assertEquals(parsed.existingUnlinkedSections, [{ title: null, summary: null }]);
});

Deno.test("production prompt uses planner residual allocation unchanged (no double subtraction)", () => {
  // Simulate the planner's residual output:
  //   - 2 existing on beat-1, planner returned 3 additional new sections
  //   - 1 existing on beat-2, planner returned 0 (already covered)
  //   - 0 existing on beat-3, planner returned 2
  // Pre-PR-5, adjustAllocationForExistingSections would have subtracted again:
  //   beat-1: 3 - 2 = 1  (BUG: undergenerates by 2 sections)
  //   beat-2: 0 - 1 = -1 -> clamped to 0 (silently wrong)
  // Post-PR-5, buildPrompt must reflect the planner's residual counts directly.
  const sparseWithThirdBeat = {
    ...sparseRequest,
    arcTemplate: {
      ...sparseRequest.arcTemplate,
      beats: [
        ...sparseRequest.arcTemplate.beats,
        { id: "beat-3", role: "midpoint", label: "Midpoint", description: "Reversal." },
      ],
    },
  } as any;
  const residual = new Map([
    ["beat-1", { minSections: 3, rationale: "needs 3 new beyond existing 2" }],
    ["beat-2", { minSections: 0, rationale: "fully covered by existing 1" }],
    ["beat-3", { minSections: 2, rationale: "needs 2 new" }],
  ]);
  const { system } = buildPrompt(sparseWithThirdBeat, residual as any);
  assertEquals(system.includes("Opening Image: minimum 3 sections"), true,
    "beat-1 residual 3 must reach buildPrompt unchanged (pre-fix would have produced 1)");
  assertEquals(system.includes("Break into Two: minimum 0 sections"), true,
    "beat-2 residual 0 must reach buildPrompt unchanged (pre-fix would have clamped -1 to 0)");
  assertEquals(system.includes("Midpoint: minimum 2 sections"), true,
    "beat-3 residual 2 must reach buildPrompt unchanged");
});

// PR 5 — planner→generation handoff behavioral coverage.
//
// The pre-existing regression tests above prove two things in isolation:
//   (a) buildAllocationPrompt tells the planner to return RESIDUAL counts
//       (NEW sections beyond existingSections), and
//   (b) buildPrompt renders whatever allocation map it is given.
// Neither test exercises the actual production code path in runSuggestionJob
// where planSectionAllocation runs the planner and its output is then handed
// off to buildPrompt. If a future change reintroduced a second subtraction
// step between those two calls (e.g. resurrecting adjustAllocationForExistingSections
// at the handoff site), tests (a) and (b) would still pass while production
// silently double-subtracts existing-section coverage again.
//
// These two tests close that gap by driving planSectionAllocation with a
// mocked billableCall, taking the planner's actual return value, and feeding
// it into buildPrompt exactly as runSuggestionJob does. If double-subtraction
// is reintroduced at the handoff, planSectionAllocation will not catch it
// (the planner already returned residual counts) — but buildPrompt will see
// the wrong numbers and these assertions will fail.
//
// The third test is a source-level structural guard: it pins the exact code
// shape of the handoff in runSuggestionJob so a future editor cannot
// accidentally re-introduce a subtraction step between the planner call
// and the buildPrompt call without a deliberate, reviewable change.

Deno.test("planner→generation handoff: 2 existing + planner returns 3 → generation receives 3 (not 1)", async () => {
  // 2 existing sections already cover beat-1; planner correctly returns
  // minSections=3 for the NEW sections still required on beat-1.
  const plannerResponse = JSON.stringify({
    allocations: [
      { beatIndex: 0, minSections: 3, rationale: "needs 3 new beyond existing 2" },
      { beatIndex: 1, minSections: 2, rationale: "needs 2 new" },
    ],
  });
  const calls: Array<{ action: string }> = [];
  const billableCall: any = async (
    _system: string,
    _user: string,
    _maxOutputTokens: number,
    _responseFormat: unknown,
    action: string,
  ) => {
    calls.push({ action });
    return { content: plannerResponse, creditCostCharged: 0, remainingCredits: 0 };
  };
  const reqWithExisting = {
    ...sparseRequest,
    existingSections: [
      { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] },
      { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] },
    ],
  } as any;

  const plannedAllocation = await planSectionAllocation(reqWithExisting, "fake-key", billableCall);

  // Planner contract: residual counts come back unchanged.
  assertEquals(plannedAllocation.get("beat-1")?.minSections, 3,
    "planner must return 3 for beat-1 (residual after existing 2)");
  assertEquals(plannedAllocation.get("beat-2")?.minSections, 2,
    "planner must return 2 for beat-2");

  // Production handoff: buildPrompt receives the planner's residual counts unchanged.
  const { system } = buildPrompt(reqWithExisting, plannedAllocation);
  assertEquals(system.includes("Opening Image: minimum 3 sections"), true,
    "beat-1 residual 3 must reach buildPrompt unchanged (pre-fix would have produced 1)");
  assertEquals(system.includes("Break into Two: minimum 2 sections"), true,
    "beat-2 residual 2 must reach buildPrompt unchanged");

  // The planner was called exactly once (no retry triggered).
  assertEquals(calls.length, 1);
  assertEquals(calls[0].action, "outline-plan");
});

Deno.test("planner→generation handoff: planner returns 0 → generation receives 0", async () => {
  // Planner determines every beat is fully covered by existing sections and
  // returns minSections=0 for both.
  const plannerResponse = JSON.stringify({
    allocations: [
      { beatIndex: 0, minSections: 0, rationale: "fully covered by existing 1" },
      { beatIndex: 1, minSections: 0, rationale: "fully covered by existing 1" },
    ],
  });
  const billableCall: any = async () => ({
    content: plannerResponse,
    creditCostCharged: 0,
    remainingCredits: 0,
  });
  const reqWithExisting = {
    ...sparseRequest,
    existingSections: [
      { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] },
      { storyArcBeatID: "beat-2", recipeRequirementIDs: ["R1"] },
    ],
  } as any;

  const plannedAllocation = await planSectionAllocation(reqWithExisting, "fake-key", billableCall);

  assertEquals(plannedAllocation.get("beat-1")?.minSections, 0,
    "planner must return 0 for beat-1 (fully covered)");
  assertEquals(plannedAllocation.get("beat-2")?.minSections, 0,
    "planner must return 0 for beat-2 (fully covered)");

  const { system } = buildPrompt(reqWithExisting, plannedAllocation);
  assertEquals(system.includes("Opening Image: minimum 0 sections"), true,
    "beat-1 residual 0 must reach buildPrompt unchanged (pre-fix would have clamped -1 to 0)");
  assertEquals(system.includes("Break into Two: minimum 0 sections"), true,
    "beat-2 residual 0 must reach buildPrompt unchanged (pre-fix would have clamped -1 to 0)");
});

Deno.test("runSuggestionJob handoff does not subtract existing sections a second time", async () => {
  // Structural guard: pin the exact shape of the planner→buildPrompt handoff
  // in runSuggestionJob so a future change cannot silently re-introduce
  // double-subtraction (e.g. by calling adjustAllocationForExistingSections
  // between planSectionAllocation and buildPrompt).
  const source = await Deno.readTextFile(
    "./supabase/functions/outline-from-recipe/index.ts",
  );

  // 1. The old double-subtraction helper must not be called anywhere — if it
  //    is, this test fails loudly.
  assertEquals(
    source.includes("adjustAllocationForExistingSections("),
    false,
    "adjustAllocationForExistingSections must not be called anywhere; it caused double-subtraction before PR 5",
  );

  // 2. The handoff must bind plannedAllocation to a local allocation and pass
  //    that allocation (not plannedAllocation under a different name) into
  //    buildPrompt. Allow either pattern: `const allocation = plannedAllocation`
  //    followed by `buildPrompt(body, allocation, ...)`, or a direct
  //    `buildPrompt(body, plannedAllocation, ...)` call. Both are correct;
  //    anything else (a wrapper that subtracts existing sections again) is not.
  const buildPromptCalls = source.match(/buildPrompt\([^)]*\)/g) ?? [];
  const handoffCall = buildPromptCalls.find((call) =>
    call.includes("plannedAllocation") || /\ballocation\b/.test(call)
  );
  if (typeof handoffCall !== "string") {
    throw new Error(
      "buildPrompt must be called with plannedAllocation or an alias bound to it; found calls: " +
        JSON.stringify(buildPromptCalls),
    );
  }
  // The call must reference allocation/plannedAllocation exactly — no
  // adjustAllocationForExistingSections or any other wrapper in between.
  assertEquals(
    /buildPrompt\([^)]*\b(plannedAllocation|allocation)\b[^)]*\)/.test(handoffCall),
    true,
    `buildPrompt handoff must reference plannedAllocation or allocation directly, got: ${handoffCall}`,
  );

  // 3. The PR 5 comment must remain in place so future readers understand why
  //    plannedAllocation is used directly.
  assertEquals(source.includes("const persistedAllocation = Array.isArray(planningState.allocationEntries)"), true);
  assertEquals(source.includes("buildPrompt(body, allocation"), true);
  assertEquals(source.includes("planSectionAllocation"), true);
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

Deno.test("sparse recipe context is preserved for the single comprehensive outline prompt", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 1, rationale: "A concise setup." }],
    ["beat-2", { minSections: 1, rationale: "The conflict needs room to escalate." }],
  ]);
  const { system, user } = buildPrompt(sparseRequest as any, allocation);
  const plannerPrompt = buildAllocationPrompt(sparseRequest as any);
  const plannerInput = plannerPrompt.user;

  // Allocation receives the compact semantic planning view, including authored recipe context.
  assertEquals(plannerInput.includes("Monsters kill humans"), true);
  assertEquals(plannerInput.includes('"name": "Douche"'), true);
  assertEquals(user.includes("Monsters kill humans"), true);
  assertEquals(user.includes("Douche"), true);
  assertEquals(system.includes("30-60"), false);
  assertEquals(system.includes("5-15"), false);
  assertEquals(system.includes("minimum is a floor for dramatic coverage, not a target or maximum"), true);
  assertEquals(system.includes("targetSections"), false);
  assertEquals(system.includes("maxSections"), false);
});


Deno.test("global outline prompt keeps recipe prose once while retaining material provenance", async () => {
  const material = enrichmentFixture();
  material.characters.push({
    id: "planner-character",
    label: "Planner candidate",
    description: "A planner-created candidate.",
    source: "planner",
  });
  material.characters[0] = {
    ...material.characters[0],
    source: "recipe",
    sourceReference: "character:authored-character",
  };
  const request = { ...sparseRequest, storyMaterialEnrichment: material } as any;
  const { user } = buildPrompt(request, new Map(), [], material);
  const planningContext = JSON.parse(user).planningContext;
  const recipeEntry = planningContext.materialIndex.find((item: any) => item.source === "recipe");
  const plannerEntry = planningContext.materialIndex.find((item: any) => item.source === "planner");
  assertEquals("label" in recipeEntry, false);
  assertEquals("description" in recipeEntry, false);
  assertEquals(recipeEntry.sourceReference, "character:authored-character");
  assertEquals(plannerEntry.label, "Planner candidate");
  assertEquals(plannerEntry.description, "A planner-created candidate.");
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(source.includes("115_000"), true);
});

Deno.test("single-pass prompt accepts rich recipes beyond the former 20K stage budget", async () => {
  const richRecipe = {
    ...sparseRequest.recipe,
    project: {
      ...sparseRequest.recipe.project,
      summary: "ALLOCATION_UNIQUE_PREMISE " + "x".repeat(36_000),
    },
    selectedCharacters: Array.from({ length: 40 }, (_, index) => ({
      id: `character-${index}`,
      name: `Character ${index}`,
      summary: `ALLOCATION_UNIQUE_CHARACTER_${index} ` + "y".repeat(1_000),
    })),
    selectedStorySpark: { id: "spark-rich", text: "The authored spark", title: "The authored spark", situation: "The premise begins under pressure.", stakes: "Everything important is at risk." },
    selectedThemeQuestions: [{ id: "theme-rich", text: "What does survival cost?", question: "What does survival cost?" }],
  };
  const request = { ...sparseRequest, recipe: richRecipe } as any;
  const allocation = new Map<string, any>(request.arcTemplate.beats.map((beat: any) => [
    beat.id,
    { minSections: 0, rationale: "single-pass outline generation" },
  ]));
  const primary = buildPrompt(request, allocation);
  const richMaterial = enrichmentFixture();
  richMaterial.characters = Array.from({ length: 40 }, (_, index) => ({
    id: `character-${index}`,
    source: index % 2 === 0 ? "recipe" : "planner",
    sourceReference: index % 2 === 0 ? `character:character-${index}` : null,
    label: `Character ${index}`,
    description: `Character material ${index} ` + "z".repeat(900),
  }));
  const richPrimary = buildPrompt({ ...request, storyMaterialEnrichment: richMaterial } as any, allocation, [], richMaterial);
  const duplicatedPayload = JSON.parse(richPrimary.user);
  duplicatedPayload.planningContext.materialIndex = compactMaterial(richMaterial);
  const duplicatedChars = JSON.stringify(duplicatedPayload, null, 2).length;
  const deduplicatedChars = richPrimary.user.length;
  console.log(`global outline prompt rich fixture: ${duplicatedChars} chars before, ${deduplicatedChars} after, ${duplicatedChars - deduplicatedChars} removed`);
  assertEquals(deduplicatedChars < duplicatedChars, true);
  const allocationPrompt = buildAllocationPrompt(request, deriveRecipeObligations(request.recipe));
  const parsedAllocation = JSON.parse(allocationPrompt.user);
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(allocationPrompt.user.length > 20_000, true);
  assertEquals(primary.user.includes("ALLOCATION_UNIQUE_PREMISE"), true);
  assertEquals(allocationPrompt.user.includes("ALLOCATION_UNIQUE_CHARACTER_39"), true);
  assertEquals(allocationPrompt.user.split('"planningContext"').length - 1, 1);
  assertEquals(parsedAllocation.planningView, undefined);
  assertEquals(typeof parsedAllocation.planningContext.project.summary, "string");
  assertEquals(parsedAllocation.planningContext.obligations.length > 0, true);
  assertEquals(Array.isArray(parsedAllocation.planningContext.materialIndex), true);
  assertEquals("existingSectionsByBeat" in parsedAllocation, true);
  assertEquals("existingUnlinkedSections" in parsedAllocation, true);
  assertEquals(source.includes("assertPromptWithinBudget"), false);
  assertEquals(source.includes("const promptLimit"), false);
});

Deno.test("primary outline prompt has no arbitrary section-count instruction", () => {
  const prompt = buildPrompt(sparseRequest as any, new Map([
    ["beat-1", { minSections: 0, rationale: "covered" }],
    ["beat-2", { minSections: 1, rationale: "closure" }],
  ])).system;
  assertEquals(/\b\d+[-–]\d+\s+distinct sections\b/i.test(prompt), false);
  assertEquals(prompt.includes("minimum is a floor for dramatic coverage, not a target or maximum"), true);
  assertEquals(prompt.includes("MAX_PLANNED_SECTIONS"), false);
});

Deno.test("all outline physical actions share explicit logical stage families", () => {
  assertEquals(outlineLogicalStageFamily("story-material-enrichment-001"), "enrichment");
  assertEquals(outlineLogicalStageFamily("outline-plan-001"), "allocation");
  assertEquals(outlineLogicalStageFamily("outline-suggestions"), "suggestions");
  assertEquals(outlineLogicalStageFamily("outline-expansion-round-002"), "expansion");
});

Deno.test("allocation planner propagates worker yield instead of converting it to validation failure", async () => {
  const billable = async () => {
    throw new SuggestionWorkerYield();
  };
  await assertRejects(
    () => planSectionAllocation(sparseRequest as any, "test-key", billable as any),
    SuggestionWorkerYield,
  );
});

Deno.test("global buildPrompt includes the requested concrete-event guardrails", () => {
  const { system } = buildPrompt(sparseRequest as any, new Map());
  assertEquals(system.includes("Every section must commit to one canonical event."), true);
  assertEquals(system.includes("Each section must produce a materially new resulting state."), true);
  assertEquals(system.includes("The Resurrection must not replay the Ordeal at greater scale."), true);
  assertEquals(system.includes("When the planning context supplies a concrete location, clue, institution, object, threat mechanism, or consequence"), true);
});

Deno.test("allocation parser preserves minimums and rejects malformed plans", () => {
  const beats = sparseRequest.arcTemplate.beats;
  const result = parseAndValidateAllocation(
    JSON.stringify({
      allocations: [
        { beatIndex: 0, minSections: 2, rationale: "setup" },
        { beatIndex: 1, minSections: 0, rationale: "escalation" },
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
      JSON.stringify({ allocations: [{ beatIndex: 0, minSections: 1, rationale: "setup" }] }),
      beats,
    );
  } catch (caught) {
    missingError = String(caught);
  }
  assertEquals(missingError.includes("missing beat"), true);

  for (const invalid of [
    {
      allocations: [
        { beatIndex: 0, minSections: 1, rationale: "setup" },
        { beatIndex: 0, minSections: 1, rationale: "duplicate" },
        { beatIndex: 1, minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatIndex: 99, minSections: 1, rationale: "unknown" },
        { beatIndex: 0, minSections: 1, rationale: "setup" },
        { beatIndex: 1, minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatIndex: 0, minSections: 1.5, rationale: "not integer" },
        { beatIndex: 1, minSections: 1, rationale: "break" },
      ],
    },
    {
      allocations: [
        { beatIndex: 0, minSections: 1, targetSections: 2, rationale: "legacy target" },
        { beatIndex: 1, minSections: 1, rationale: "break" },
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
      { beatIndex: 0, minSections: 10, rationale: "dense" },
      { beatIndex: 1, minSections: 10, rationale: "dense" },
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
  const parsedPlanning = JSON.parse(plannerPrompt.user);
  assertEquals(typeof parsedPlanning.planningContext.recipe, "object");
  assertEquals(parsedPlanning.planningContext.arc.beats[0].id, "beat-1");
  assertEquals(Array.isArray(parsedPlanning.planningContext.materialIndex), true);
  assertEquals(Array.isArray(parsedPlanning.planningContext.obligations), true);
  assertEquals(parsedPlanning.existingSectionsByBeat["beat-1"][0].title, "Already accepted");
  assertEquals(parsedPlanning.existingUnlinkedSections, []);

  const allocation = parseAndValidateAllocation(
    JSON.stringify({
      allocations: [
        { beatIndex: 0, minSections: 0, rationale: "already covered" },
        { beatIndex: 1, minSections: 1, rationale: "new escalation" },
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


Deno.test("allocation never accepts a stitched or model-authored beat UUID", () => {
  const beats = [
    { id: "80A38EE5-8187-4AE1-A82F-335959781679" },
    { id: "10A90555-20C7-4D73-A17D-EA7967604AB0" },
  ];
  let error = "";
  try {
    parseAndValidateAllocation(JSON.stringify({ allocations: [
      { beatID: "10A90555-8187-4AE1-A82F-335959781679", minSections: 1, rationale: "hallucinated" },
      { beatIndex: 1, minSections: 1, rationale: "valid" },
    ] }), beats);
  } catch (caught) {
    error = String(caught);
  }
  assertEquals(error.includes("unexpected field"), true);
  const mapped = parseAndValidateAllocation(JSON.stringify({ allocations: [
    { beatIndex: 0, minSections: 1, rationale: "midpoint" },
    { beatIndex: 1, minSections: 1, rationale: "close in" },
  ] }), beats);
  assertEquals([...mapped.keys()], beats.map((beat) => beat.id));
});

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

Deno.test("outline section contract assigns canonical plot decisions to the planner", () => {
  const prompt = buildPrompt(sparseRequest as any, new Map([
    ["beat-1", { minSections: 1, rationale: "setup" }],
  ])).system;
  assertEquals(prompt.includes("one canonical dramatic realization"), true);
  assertEquals(prompt.includes("The outline planner owns plot decisions; the later prose generator owns execution"), true);
  assertEquals(prompt.includes("choose the concrete location, participating characters, triggering action"), true);
  assertEquals(prompt.includes("Do not leave those decisions as interchangeable possibilities"), true);
  assertEquals(prompt.includes("Do not mechanically ban words such as"), true);
  assertEquals(prompt.includes("two prose generators following the same section contract"), true);
  assertEquals(prompt.includes("Make entryState, resultingChange, and terminalState similarly concrete"), true);
});

Deno.test("novel planning exposes container semantics and projected-size expansion", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const allocationPrompt = buildAllocationPrompt(sparseRequest as any).system;
  assertEquals(allocationPrompt.includes("70,000-90,000 word"), true);
  assertEquals(allocationPrompt.includes("minimum number of NEW dramatic sections still required"), true);
  assertEquals(allocationPrompt.includes("floor, not a target or maximum"), true);
  assertEquals(source.includes("targetSections"), false);
  assertEquals(source.includes("maxSections"), false);
  assertEquals(source.includes("promptLimit"), false);
  assertEquals(source.includes("assertPromptWithinBudget"), false);
  assertEquals(source.includes("const MAX_PLANNED_SECTIONS = 200;"), true);
  assertEquals(source.includes("maxItems: MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("merged.length > MAX_PLANNED_SECTIONS"), true);
  assertEquals(source.includes("collectAdvisoryOutlineQuality"), true);
  assertEquals(source.includes("outline failed Story Arc semantic validation"), false);
  assertEquals(source.includes("dramatic distinctness validation"), false);
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


Deno.test("semantic disagreement is advisory: a late apparent conflict still completes", () => {
  const suggestions = [
    semanticSection("climax", "The Decisive Battle", "The central confrontation ends the primary conflict.", "climax"),
    semanticSection("fall", "The Freeze Order", "The leaders freeze the front and contain the remaining danger.", "consequence"),
    semanticSection("den", "Wei Jian and Volkov Stand Down", "The rivals stand down and accept the new order.", "resolution"),
  ];
  const advisory = collectAdvisoryOutlineQuality(suggestions as any, undefined, "novel", {
    name: "fixture",
    beats: [
      { id: "climax", label: "Climax" },
      { id: "fall", label: "Falling Action" },
      { id: "den", label: "Denouement" },
    ],
  } as any);
  assertEquals(advisory.semanticArcIssues.length > 0, true);
  assertEquals(suggestions.map((section) => section.title), [
    "The Decisive Battle",
    "The Freeze Order",
    "Wei Jian and Volkov Stand Down",
  ]);
});

Deno.test("malformed outline output remains a structural failure", () => {
  let failure: unknown;
  try {
    validateSuggestions({}, new Set(["beat-1"]));
  } catch (error) {
    failure = error;
  }
  assertEquals((failure as Error).message, "response missing suggestions array");
});

Deno.test("optional repair failure keeps the original structurally valid outline", () => {
  const original = [semanticSection("beat-1", "Original", "A usable section.", "consequence")];
  const advisory = collectAdvisoryOutlineQuality(original as any, undefined, "novel", {
    name: "fixture",
    beats: [{ id: "beat-1", label: "Opening" }],
  } as any);
  assertEquals(advisory.advisoryValidationError ?? null, null);
  assertEquals(original[0].title, "Original");
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
  assertEquals(prompt.user.includes("targetBeat"), true);
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
  assertEquals(source.includes("const MAX_PLANNED_SECTIONS = 200;"), true);
  assertEquals(source.includes("diagnostics:"), true);
  assertEquals(source.includes("generateEnrichment"), true);
  assertEquals(source.includes("planSectionAllocation"), true);
  assertEquals(source.includes('"outline-suggestions"'), true);
  assertEquals(source.includes("expandNovel"), true);
  assertEquals(source.includes("outline-suggestions-single-pass"), false);
  assertEquals(source.includes("if (validateResponse) await validateResponse"), true);
  assertEquals(source.includes("outline failed Story Arc semantic validation"), false);
});


function expansionSection(title: string, container = "scene", beat = "beat-1", insertAfterTitle: string | null = null): any {
  return { title, summary: `${title} summary`, container, pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: [], insertAfterTitle };
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

Deno.test("a ~34K projected novel cannot terminate as completed below the 70K minimum", async () => {
  const underweight = sceneOutline(34) as any;
  assertEquals(Math.round(evaluateNovelScale(underweight).projectedWords), 34000);
  await assertRejects(
    () => progressivelyExpandOutline(
      underweight,
      new Set(["beat-1"]),
      async () => [],
      undefined,
      { existingSections: [], beats: [{ id: "beat-1", label: "Opening" }] },
    ),
    NovelScalePlanningError,
  );
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

// PR6 (Fix the Shit cycle 6): the recovery path must produce a valid
// StoryMaterialEnrichment from any canonical recipe. These tests guard
// the contract that lets the 41 legacy persisted runs be resumed
// without regeneration or re-billing.
// PR8: the recovery path must produce a structurally-valid StoryMaterialEnrichment
// from any canonical PromptPackExportPayload, using CANONICAL sourceReferences
// from recipeMaterialHandles(). Previously these tests pinned the broken
// references (selectedCharacters[<id>] etc.) — those references never existed as
// canonical handles, so the repaired material failed validateStoryMaterialEnrichment
// when anyone tried to re-validate it. PR8 replaces them with recipe:* / project:*
// / character:* / relationship:* / theme:* / motif:* / storySpark / aftertaste.
Deno.test("PR8 repairStoryMaterialFromRecipe: produces a structurally-valid enrichment from a canonical PromptPackExportPayload", () => {
  const provenance = {
    sourceRecipeHash: "deadbeef",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-1",
    sourcePromptPackName: "Test Pack",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-1", summary: "A brooding thriller" },
    setting: { included: false },
    promptPack: { id: "pack-1", name: "Test Pack" },
    selectedCharacters: [
      { id: "c-1", name: "Mara", summary: "Disgraced detective" },
      { id: "c-2", name: "Vik", summary: "Rival fixer" },
    ],
    selectedStorySpark: { id: "s-1", title: "Cold case reopen", description: "An old murder returns" },
    selectedAftertaste: { title: "Quiet dread", description: "The reader should feel watched" },
    selectedRelationships: [
      { id: "r-1", summary: "Mara + Vik", description: "Ex-partners turned enemies" },
    ],
    selectedThemeQuestions: [
      { question: "Can the past be trusted?", description: "Memory vs record" },
      { question: "Is revenge justice?", description: "Cycle of violence" },
    ],
    selectedMotifs: [
      { label: "Mirrors", description: "Reflections of identity" },
      { label: "Smoke", description: "Obscured truth" },
    ],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  // Schema + provenance fields
  assertEquals(repaired.schema, "cathedralos.story_material_enrichment");
  assertEquals(repaired.version, 2);
  assertEquals(repaired.format, "novel");
  assertEquals(repaired.sourceRecipeHash, "deadbeef");
  assertEquals(repaired.sourceRecipeVersion, 1);
  assertEquals(repaired.sourcePromptPackID, "pack-1");
  assertEquals(repaired.sourcePromptPackName, "Test Pack");
  // PR8: sourceReferences are canonical handles from recipeMaterialHandles —
  // never the legacy "selectedCharacters[<id>]" / "selectedStorySpark[<id>]" etc.
  assertEquals(repaired.characters.length, 2);
  assertEquals(repaired.characters[0].sourceReference, "character:c-1");
  assertEquals(repaired.characters[1].sourceReference, "character:c-2");
  // PR8: storySpark is consumed as a single object → exactly one antagonisticForce
  assertEquals(repaired.antagonisticForces.length, 1);
  assertEquals(repaired.antagonisticForces[0].sourceReference, "storySpark");
  assertEquals(repaired.relationships.length, 1);
  assertEquals(repaired.relationships[0].sourceReference, "relationship:r-1");
  // PR8: themes + motifs both go into thematicPressures; aftertaste lands in
  // unresolvedQuestions (not thematicPressures — that was a pre-fix mixing bug).
  assertEquals(repaired.thematicPressures.length, 4); // 2 themes + 2 motifs
  assertEquals(repaired.unresolvedQuestions.length, 1);
  assertEquals(repaired.unresolvedQuestions[0].sourceReference, "aftertaste");
  // PR8: project.summary is preserved as a discovery item (per spec).
  assertEquals(repaired.discoveries.length, 1);
  assertEquals(repaired.discoveries[0].sourceReference, "project.summary");
  // PR8: every recipe item has label + description distinct from sourceReference
  // (validateStoryMaterialEnrichment requires both). Labels/descriptions come
  // from real canonical recipe fields — never the handle itself.
  const allItems = [
    ...repaired.characters,
    ...repaired.antagonisticForces,
    ...repaired.relationships,
    ...repaired.thematicPressures,
    ...repaired.unresolvedQuestions,
    ...repaired.discoveries,
  ];
  for (const item of allItems) {
    assertEquals(item.source, "recipe");
    assertEquals(typeof item.sourceReference, "string");
    assertEquals(item.sourceReference !== "", true, `${item.id}: sourceReference required`);
    assertEquals(item.label !== "", true, `${item.id}: label required`);
    assertEquals(item.description !== "", true, `${item.id}: description required`);
    assertEquals(item.label !== item.sourceReference, true, `${item.id}: label must differ from sourceReference`);
    assertEquals(item.description !== item.sourceReference, true, `${item.id}: description must differ from sourceReference`);
  }
  // PR8: self-validate must pass — the repair function calls
  // validateStoryMaterialEnrichment internally before returning, so any
  // structural contract violation would have already thrown.
  const validated = validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
  assertEquals(validated, repaired);
  // Empty categories stay empty.
  assertEquals(repaired.locations.length, 0);
  assertEquals(repaired.escalationLadder.length, 0);
});

Deno.test("PR8 repairStoryMaterialFromRecipe: consumes selectedStorySpark and selectedAftertaste as single objects (object-or-null, not array)", () => {
  const provenance = {
    sourceRecipeHash: "single-object",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-so",
    sourcePromptPackName: "SingleObject",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-so", summary: "Single spark, single aftertaste" },
    setting: { included: false },
    promptPack: { id: "pack-so", name: "SingleObject" },
    selectedCharacters: [{ id: "c-so", name: "Solo", roles: ["traveler"], notes: "Lone traveler" }],
    selectedStorySpark: { id: "s-so", title: "Letter arrives", situation: "A stranger writes from the past" },
    selectedAftertaste: { id: "at-so", label: "Quiet grief", note: "Reader carries the weight" },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  // PR8: exactly one antagonisticForce and one unresolvedQuestion — the
  // canonical handles storySpark and aftertaste are single, not arrays.
  assertEquals(repaired.antagonisticForces.length, 1);
  assertEquals(repaired.antagonisticForces[0].sourceReference, "storySpark");
  assertEquals(repaired.antagonisticForces[0].label, "Letter arrives");
  assertEquals(repaired.unresolvedQuestions.length, 1);
  assertEquals(repaired.unresolvedQuestions[0].sourceReference, "aftertaste");
  assertEquals(repaired.unresolvedQuestions[0].label, "Quiet grief");
});

Deno.test("PR8 repairStoryMaterialFromRecipe: null selectedStorySpark and selectedAftertaste produce no antagonisticForce or unresolvedQuestion", () => {
  const provenance = {
    sourceRecipeHash: "null-spark",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-ns",
    sourcePromptPackName: "NullSpark",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-ns", summary: "Quiet story" },
    setting: { included: false },
    promptPack: { id: "pack-ns", name: "NullSpark" },
    selectedCharacters: [{ id: "c-ns", name: "Solo", summary: "Lone traveler" }],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  // PR8: null spark/aftertaste → handle is absent → no item produced.
  assertEquals(repaired.antagonisticForces.length, 0);
  assertEquals(repaired.unresolvedQuestions.length, 0);
  // characters and project.summary still preserved.
  assertEquals(repaired.characters.length, 1);
  assertEquals(repaired.characters[0].sourceReference, "character:c-ns");
  assertEquals(repaired.discoveries.length, 1);
  assertEquals(repaired.discoveries[0].sourceReference, "project.summary");
  // Self-validate passes (empty categories are valid).
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR8 repairStoryMaterialFromRecipe: themes and motifs both map to thematicPressures (no dedicated motif category)", () => {
  const provenance = {
    sourceRecipeHash: "tm",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-tm",
    sourcePromptPackName: "TM",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-tm", summary: "Themes and motifs" },
    setting: { included: false },
    promptPack: { id: "pack-tm", name: "TM" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [
      { question: "Can the past be trusted?", description: "Memory vs record" },
      { question: "What does justice cost?", description: "Personal cost of vengeance" },
    ],
    selectedMotifs: [
      { label: "Mirrors", description: "Reflections of identity" },
      { label: "Smoke", description: "Obscured truth" },
      { label: "Rain", description: "Grief and cleansing" },
    ],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  assertEquals(repaired.thematicPressures.length, 5); // 2 themes + 3 motifs
  const refs = repaired.thematicPressures.map((item) => item.sourceReference).sort();
  assertEquals(refs.includes("theme:theme-1"), true);
  assertEquals(refs.includes("theme:theme-2"), true);
  assertEquals(refs.includes("motif:motif-1"), true);
  assertEquals(refs.includes("motif:motif-2"), true);
  assertEquals(refs.includes("motif:motif-3"), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR8 repairStoryMaterialFromRecipe: a sufficient canonical recipe yields a sufficiency-passing material", () => {
  const provenance = {
    sourceRecipeHash: "sufficient",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-sf",
    sourcePromptPackName: "Sufficient",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-sf", summary: "A complex investigation with a deep cast" },
    setting: { included: false },
    promptPack: { id: "pack-sf", name: "Sufficient" },
    selectedCharacters: [
      { id: "c-a", name: "Mara", summary: "Detective" },
      { id: "c-b", name: "Vik", summary: "Rival" },
      { id: "c-c", name: "Yara", summary: "Witness" },
    ],
    selectedStorySpark: { title: "Cold case reopen", description: "Old murder returns" },
    selectedAftertaste: { title: "Quiet dread", description: "Reader feels watched" },
    selectedRelationships: [
      { id: "r-1", summary: "Mara + Vik", description: "Ex-partners" },
      { id: "r-2", summary: "Mara + Yara", description: "Mentor" },
      { id: "r-3", summary: "Vik + Yara", description: "Ally" },
    ],
    selectedThemeQuestions: [
      { question: "Can the past be trusted?", description: "Memory vs record" },
      { question: "What does justice cost?", description: "Personal cost of vengeance" },
      { question: "Who gets to tell the story?", description: "Narrator reliability" },
    ],
    selectedMotifs: [
      { label: "Mirrors", description: "Reflections of identity" },
      { label: "Smoke", description: "Obscured truth" },
      { label: "Rain", description: "Grief and cleansing" },
      { label: "Keys", description: "Access and confinement" },
    ],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  // PR8: shortStory sufficiency only requires characters + conflictSources +
  // escalationLadder > 0 — achievable from canonical recipe. Novel requires
  // escalationLadder ≥ 3 and reversals + consequences ≥ 2 which the canonical
  // recipe cannot supply; that scenario is covered by the sparse/novel test
  // below (the call site must fail closed via StoryMaterialSufficiencyError).
  const sufficiency = storyMaterialSufficiency(repaired, recipe as any, "shortStory");
  assertEquals(
    sufficiency.sufficient,
    true,
    `recipe-derived repair should be sufficient for shortStory scale; reasons=${JSON.stringify(sufficiency.reasons)}`,
  );
  assertEquals(sufficiency.recipeDerivedItemCount > 0, true, "sufficiency should count at least one recipe-derived item");
});

Deno.test("PR8 repairStoryMaterialFromRecipe: a sparse canonical recipe yields insufficient material (call site must fail closed via StoryMaterialSufficiencyError)", () => {
  const provenance = {
    sourceRecipeHash: "sparse",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-sp",
    sourcePromptPackName: "Sparse",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-sp", summary: "A whisper" },
    setting: { included: false },
    promptPack: { id: "pack-sp", name: "Sparse" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);
  // PR8: structural validation passes even with empty categories.
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
  // PR8: but semantic sufficiency fails — the resume call site must throw
  // StoryMaterialSufficiencyError in this case (fail closed).
  const sufficiency = storyMaterialSufficiency(repaired, recipe as any, "novel");
  assertEquals(sufficiency.sufficient, false, "sparse recipe must NOT pass sufficiency");
  assertEquals(sufficiency.reasons.length > 0, true);
});

Deno.test("PR8 (revised) repairStoryMaterialFromRecipe: preserves authored character summaries, motif descriptions, relationship descriptions, theme descriptions, spark descriptions, aftertaste descriptions", () => {
  const provenance = {
    sourceRecipeHash: "preserve",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-pr",
    sourcePromptPackName: "Preserve",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-pr", summary: "A brooding thriller" },
    setting: { included: false },
    promptPack: { id: "pack-pr", name: "Preserve" },
    selectedCharacters: [
      { id: "c-1", name: "Mara", roles: ["detective"], notes: "Disgraced detective returning to a cold case" },
      { id: "c-2", name: "Vik", roles: ["fixer"], notes: "Rival fixer with a long memory" },
    ],
    selectedStorySpark: { id: "s-1", title: "Cold case reopen", situation: "An old murder returns with new evidence", stakes: "The case implicates the victim's family" },
    selectedAftertaste: { id: "at-1", label: "Quiet dread", note: "The reader should feel watched in the final scene", endingTexture: "Unresolved" },
    selectedRelationships: [
      { id: "r-1", name: "Mara + Vik", relationshipType: "former partners turned enemies", tension: "Ex-partners turned enemies by a shared failure" },
    ],
    selectedThemeQuestions: [
      { id: "tq-1", question: "Can the past be trusted?", coreTension: "Memory versus official record" },
    ],
    selectedMotifs: [
      { id: "m-1", label: "Mirrors", category: "identity", meaning: "Reflections of a fractured identity" },
      { id: "m-2", label: "Smoke", category: "obscuration" },
    ],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe, provenance);

  // PR8 (revised): label/description come from the actual recipe objects,
  // NOT from the recipeMaterialHandles map value (which would discard
  // summary/description in favor of just `name`).
  const c1 = repaired.characters.find((item) => item.sourceReference === "character:c-1" as string);
  assertEquals(c1?.label, "Mara");
  assertEquals(c1?.description, "Roles: detective. Notes: Disgraced detective returning to a cold case.");
  const c2 = repaired.characters.find((item) => item.sourceReference === "character:c-2" as string);
  assertEquals(c2?.label, "Vik");
  assertEquals(c2?.description, "Roles: fixer. Notes: Rival fixer with a long memory.");

  const r1 = repaired.relationships.find((item) => item.sourceReference === "relationship:r-1" as string);
  assertEquals(r1?.label, "Mara + Vik");
  assertEquals(r1?.description, "Type: former partners turned enemies. Tension: Ex-partners turned enemies by a shared failure.");

  const spark = repaired.antagonisticForces.find((item) => item.sourceReference === "storySpark" as string);
  assertEquals(spark?.label, "Cold case reopen");
  assertEquals(spark?.description, "Situation: An old murder returns with new evidence. Stakes: The case implicates the victim's family.");

  const after = repaired.unresolvedQuestions.find((item) => item.sourceReference === "aftertaste" as string);
  assertEquals(after?.label, "Quiet dread");
  assertEquals(after?.description, "The reader should feel watched in the final scene. Ending texture: Unresolved.");

  const themeItem = repaired.thematicPressures.find((item) => typeof item.sourceReference === "string" && item.sourceReference.startsWith("theme:"));
  assertEquals(themeItem?.description, "Core tension: Memory versus official record.");

  const mirror = repaired.thematicPressures.find((item) => item.sourceReference === "motif:m-1" as string);
  assertEquals(mirror?.label, "Mirrors");
  assertEquals(mirror?.description, "Category: identity. Meaning: Reflections of a fractured identity.");

  // Smoke motif has only category — description combines the canonical
  // Category field deterministically rather than collapsing to the handle.
  const smoke = repaired.thematicPressures.find((item) => item.sourceReference === "motif:m-2" as string);
  assertEquals(smoke?.label, "Smoke");
  assertEquals(smoke?.description, "Category: obscuration.");

  // Self-validate still passes — the validator checks label/description
  // structure; reading from actual recipe objects produces richer text
  // without breaking the sourceReference contract.
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("itemFromHandle: authored prose empty for `aftertaste` still produces label/description distinct from the handle", () => {
  // Regression: handles without a category prefix (`aftertaste`,
  // `storySpark`) share their id portion with the handle. The previous
  // `idPortion || handle` fallback collapsed authored prose to the
  // handle itself, tripping
  // validateStoryMaterialEnrichment's `description === sourceReference`
  // check with `recipe story material item recipe-aftertaste has no
  // authored description`.
  const provenance = {
    sourceRecipeHash: "aftertaste-bare",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-aftertaste",
    sourcePromptPackName: "Aftertaste Bare",
  };
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-at", summary: "Bare aftertaste" },
    setting: { included: false },
    promptPack: { id: "pack-aftertaste", name: "Aftertaste Bare" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: { id: "at-bare", label: "Quiet dread" },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, provenance);

  const after = repaired.unresolvedQuestions.find((item) => item.sourceReference === "aftertaste");
  assertEquals(after !== undefined, true);
  // The validator's strict check is `label === sourceReference || description === sourceReference`.
  // Both must differ from `aftertaste`; whether they differ from each other
  // is irrelevant when only the title was authored.
  assertEquals(after!.label !== "aftertaste", true);
  assertEquals(after!.description !== "aftertaste", true);

  // Critical: validation must now succeed (no `no authored description`
  // rejection) on a bare aftertaste that previously caused HTTP 500.
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR8 (revised) resumeOrRepairStoryMaterial: persists story_material + diagnostics.storyMaterialRepair BEFORE returning when a repair is required", async () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-r", summary: "Repair-then-persist test" },
    setting: { included: false },
    promptPack: { id: "pack-r", name: "RepairPersist" },
    selectedCharacters: [{ id: "c-1", name: "Solo", summary: "Lone traveler" }],
    selectedStorySpark: { title: "Spark", description: "Spark desc" },
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const provenance = await recipeProvenance(recipe as any);
  // Persisted material is a stale legacy shape — fails structural validation,
  // forcing the repair branch.
  const claimedMaterial = { schema: "wrong", version: 1 } as any;
  const calls: Array<Record<string, unknown>> = [];
  const updateRun = async (patch: Record<string, unknown>) => {
    calls.push(patch);
  };
  const result = await resumeOrRepairStoryMaterial({
    claimedMaterial,
    recipe: recipe as any,
    provenance,
    // shortStory sufficiency is achievable from this canonical recipe
    // (characters > 0 with format=shortStory). Use shortStory so the
    // repair output passes sufficiency and the helper persists BEFORE
    // returning. The sparse/novel sufficiency-fail test below exercises
    // the opposite branch with format="novel".
    format: "shortStory",
    updateRun,
  });
  // Audit must be populated (a repair happened).
  assertEquals(result.audit !== null, true);
  // updateRun must be called exactly once with the repaired material +
  // repair audit BEFORE the helper returned.
  assertEquals(calls.length, 1);
  assertEquals(
    calls[0].story_material !== undefined,
    true,
    "story_material must be persisted BEFORE the helper returns",
  );
  const persistedDiagnostics = calls[0].diagnostics as Record<string, unknown>;
  assertEquals(persistedDiagnostics.stage, "story_material_repaired");
  assertEquals(persistedDiagnostics.storyMaterialRepair !== undefined, true);
  // Returned material equals persisted material — no second repair will be
  // attempted on the next resume.
  assertEquals(calls[0].story_material, result.material);
});

Deno.test("PR8 (revised) resumeOrRepairStoryMaterial: retries do NOT re-repair or re-persist when the first repair already landed", async () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-rt", summary: "Retry path test" },
    setting: { included: false },
    promptPack: { id: "pack-rt", name: "Retry" },
    selectedCharacters: [{ id: "c-1", name: "Solo", summary: "Lone traveler" }],
    selectedStorySpark: { title: "Spark", description: "Spark desc" },
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const provenance = await recipeProvenance(recipe as any);
  // First call: legacy shape forces a repair.
  let firstCalls = 0;
  const firstUpdateRun = async () => {
    firstCalls++;
  };
  const first = await resumeOrRepairStoryMaterial({
    claimedMaterial: { schema: "wrong", version: 1 } as any,
    recipe: recipe as any,
    provenance,
    // shortStory sufficiency is met by this canonical recipe (characters > 0).
    // repairStoryMaterialFromRecipe now accepts a format parameter, so the
    // repair output is also shortStory-formatted and compatible on retry.
    format: "shortStory",
    updateRun: firstUpdateRun,
  });
  assertEquals(firstCalls, 1);
  assertEquals(first.audit !== null, true);
  const repairedMaterial = first.material;

  // Second call (retry / next resume): persisted material is the
  // already-repaired material. It must validate cleanly, NOT trigger a
  // second repair, and NOT call updateRun.
  let secondCalls = 0;
  const secondUpdateRun = async () => {
    secondCalls++;
  };
  const second = await resumeOrRepairStoryMaterial({
    claimedMaterial: repairedMaterial,
    recipe: recipe as any,
    provenance,
    format: "shortStory",
    updateRun: secondUpdateRun,
  });
  assertEquals(secondCalls, 0, "retry with persisted material must NOT re-persist");
  assertEquals(second.audit, null, "retry with persisted material must NOT re-repair");
  assertEquals(second.material, repairedMaterial);
});

Deno.test("PR8 (revised) resumeOrRepairStoryMaterial: a sparse recipe that cannot satisfy sufficiency throws StoryMaterialSufficiencyError and does NOT partially persist", async () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-sparse", summary: "Sparse" },
    setting: { included: false },
    promptPack: { id: "pack-sparse", name: "Sparse" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const provenance = await recipeProvenance(recipe as any);
  const claimedMaterial = { schema: "wrong", version: 1 } as any;
  let calls = 0;
  const updateRun = async () => {
    calls++;
  };
  let threw = false;
  try {
    await resumeOrRepairStoryMaterial({
      claimedMaterial,
      recipe: recipe as any,
      provenance,
      format: "novel",
      updateRun,
    });
  } catch (error) {
    threw = true;
    assertEquals(String(error).includes("story material enrichment is insufficient"), true);
  }
  assertEquals(threw, true, "sparse recipe must fail closed via StoryMaterialSufficiencyError");
  assertEquals(calls, 0, "must NOT persist a partial repair when sufficiency fails");
});

Deno.test("PR8 (revised) resumeOrRepairStoryMaterial: a healthy persisted material returns without persisting or repairing", async () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-ok", summary: "Healthy" },
    setting: { included: false },
    promptPack: { id: "pack-ok", name: "OK" },
    selectedCharacters: [{ id: "c-1", name: "Healthy", summary: "Already validated" }],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const provenance = await recipeProvenance(recipe as any);
  // PR8 (revised): pass the same format the helper will receive so the
  // pre-built material is format-compatible and isCompatibleStoryMaterialEnrichment
  // does not return false on a format mismatch (which would re-trigger the
  // repair branch).
  const healthyMaterial = repairStoryMaterialFromRecipe(recipe as any, provenance, "shortStory");
  let calls = 0;
  const updateRun = async () => {
    calls++;
  };
  const result = await resumeOrRepairStoryMaterial({
    claimedMaterial: healthyMaterial,
    recipe: recipe as any,
    provenance,
    format: "shortStory",
    updateRun,
  });
  assertEquals(calls, 0, "healthy persisted material must not trigger a repair-side updateRun");
  assertEquals(result.audit, null);
  assertEquals(result.material, healthyMaterial);
});


Deno.test("repairStoryMaterialFromRecipe: handles an empty canonical recipe without throwing", () => {
  const provenance = {
    sourceRecipeHash: "empty",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-empty",
    sourcePromptPackName: "Empty",
  };
  const repaired = repairStoryMaterialFromRecipe({}, provenance);
  assertEquals(repaired.schema, "cathedralos.story_material_enrichment");
  assertEquals(repaired.characters.length, 0);
  assertEquals(repaired.thematicPressures.length, 0);
  assertEquals(repaired.sourceRecipeHash, "empty");
});

Deno.test("provider enrichment cannot erase canonical recipe material", async () => {
  const recipe = brodyRecipe as any;
  const provenance = await recipeProvenance(recipe);
  const providerOnly = fixtureMaterial(recipe, false);
  for (const category of ["characters", "antagonisticForces", "locations", "institutionsAndGroups", "conflictSources", "escalationLadder", "reversals", "consequences", "relationships", "discoveries", "unresolvedQuestions", "thematicPressures"]) {
    providerOnly[category] = providerOnly[category].filter((item: any) => item.source === "planner");
  }
  const merged = mergeCanonicalRecipeMaterial(providerOnly, recipe, provenance, "novel");
  const recipeItems = Object.values(merged)
    .flatMap((value: any) => Array.isArray(value) ? value : [])
    .filter((item: any) => item?.source === "recipe");
  assertEquals(recipeItems.length > 0, true);
  assertEquals(recipeItems.some((item: any) => item.sourceReference === "character:character-1"), true);
  assertEquals(recipeItems.some((item: any) => item.sourceReference === "theme:theme-1"), true);
  assertEquals(storyMaterialSufficiency(merged, recipe, "novel").recipeDerivedItemCount > 0, true);
});

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
  assertEquals(prompt.system.includes("source=recipe"), false);
  assertEquals(prompt.system.includes("source=planner"), true);
  assertEquals(prompt.user.includes("Monsters kill humans"), true);
  assertEquals(prompt.user.includes("Douche"), true);
});

Deno.test("request validation accepts a previously persisted enrichment package", () => {
  assertEquals(validateRequest({ ...sparseRequest, storyMaterialEnrichment: enrichmentFixture() }), null);
});

Deno.test("request validation repairs duplicate or blank IDs in a reused enrichment package", () => {
  const malformed = enrichmentFixture();
  malformed.characters[0].id = "";
  malformed.locations[0].id = malformed.antagonisticForces[0].id;
  assertEquals(validateRequest({ ...sparseRequest, storyMaterialEnrichment: malformed }), null);
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
  // Exact canonical handles establish provenance; generated prose may explain
  // the material through consequences or relationships without repeating its
  // display-name tokens. Do not apply a brittle lexical correspondence test.
  assertEquals(validateStoryMaterialEnrichment(material, { recipe: brodyRecipe }).antagonisticForces[0].source, "recipe");
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

Deno.test("PR3 Final Image aftermath-only content is repaired into an actual resolution", async () => {
  const template = {
    name: "Save the Cat!",
    beats: [{ id: "final", role: "final_image", label: "Final Image" }],
  };
  const aftermathOnly: any = semanticSection(
    "final",
    "The Aftermath",
    "The survivors mourn and remember what was lost.",
    "aftermath",
  );
  aftermathOnly.resultingChange = "The aftermath continues.";
  aftermathOnly.terminalState = "The aftermath remains unresolved.";
  const before = validateStoryArcSemantics([aftermathOnly], template as any);
  assertEquals(before.some((issue) => issue.includes("missing required dramatic function resolution")), true);
  const mislabeledAftermath = { ...aftermathOnly, dramaticFunction: "resolution" };
  assertEquals(validateStoryArcSemantics([mislabeledAftermath], template as any).some((issue) => issue.includes("does not materially resolve")), true);

  const repaired = await repairRequiredStoryArcFunctions(
    [aftermathOnly],
    template as any,
    async (
      _system: string,
      _user: string,
      _maxOutputTokens: number,
      _responseFormat: unknown,
      _action: string,
      validateResponse?: (content: string) => unknown | Promise<unknown>,
    ) => {
      const content = JSON.stringify({ section: {
        ...aftermathOnly,
        title: "The Conflict Is Settled",
        summary: "The central conflict is finally settled and the survivors choose what comes next.",
        dramaticEvent: "The survivors answer the central question by confronting the final consequence and making the binding choice that ends the conflict.",
        resultingChange: "The central conflict is resolved; the survivors accept the settled cost and choose a new shared direction.",
        terminalState: "The question is answered and the new normal holds without the former conflict continuing.",
        dramaticFunction: "resolution",
      } });
      if (validateResponse) await validateResponse(content);
      return { content, creditCostCharged: 0, remainingCredits: 10 };
    },
  );

  assertEquals(repaired.unresolved, []);
  assertEquals(repaired.repaired, ["The Aftermath: resolution"]);
  assertEquals(validateStoryArcSemantics(repaired.suggestions, template as any), []);
  assertEquals(repaired.suggestions[0].dramaticFunction, "resolution");
  assertEquals(repaired.suggestions[0].terminalState?.includes("question is answered"), true);
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


// MARK: - PR 7: idempotency-safe planning rate limits

Deno.test("zero-charge story-material structural failures are retryable, paid and unrelated failures are terminal", () => {
  assertEquals(isRetryableStoryMaterialFailure({
    status: "failed",
    credit_cost_charged: 0,
    error: "story material enrichment contains a duplicate or missing item id",
  }), true);
  assertEquals(isRetryableStoryMaterialFailure({
    status: "failed",
    credit_cost_charged: 0,
    error: "recipe story material item recipe-character-x has an unverified source reference",
  }), true);
  assertEquals(isRetryableStoryMaterialFailure({
    status: "failed",
    credit_cost_charged: 1,
    error: "story material enrichment contains a duplicate or missing item id",
  }), false);
  assertEquals(isRetryableStoryMaterialFailure({
    status: "failed",
    credit_cost_charged: 0,
    error: "provider timeout",
  }), false);
});


Deno.test("legacy recipe-local source references are downgraded before reuse", () => {
  const material = {
    schema: "cathedralos.story_material_enrichment", version: 2, format: "novel",
    sourceRecipeHash: "pending", sourceRecipeVersion: 1, sourcePromptPackID: "pack-1", sourcePromptPackName: "Sparse recipe",
    rationale: "legacy persisted material",
    characters: [{ id: "brody", source: "recipe", sourceReference: "loc-hawkins-high-school", label: "Brody", description: "A concrete protagonist." }],
    antagonisticForces: [], locations: [], institutionsAndGroups: [], conflictSources: [],
    escalationLadder: [], reversals: [], consequences: [], relationships: [], discoveries: [],
    unresolvedQuestions: [], thematicPressures: [],
  };
  const downgraded = downgradeUnverifiedProviderRecipeReferences(material, brodyRecipe) as any;
  assertEquals(downgraded.characters[0].source, "planner");
  assertEquals(downgraded.characters[0].sourceReference, null);
  assertEquals(downgraded.characters[0].description, material.characters[0].description);
});

Deno.test("provider story material IDs are repaired when blank or duplicated across categories", () => {
  const material = {
    schema: "cathedralos.story_material_enrichment",
    version: 2,
    format: "novel",
    rationale: "provider output",
    characters: [{ id: "same", source: "planner", sourceReference: null, label: "A", description: "A." }],
    antagonisticForces: [{ id: "same", source: "planner", sourceReference: null, label: "B", description: "B." }],
    locations: [{ id: "", source: "planner", sourceReference: null, label: "C", description: "C." }],
    institutionsAndGroups: [], conflictSources: [], escalationLadder: [], reversals: [], consequences: [],
    relationships: [], discoveries: [], unresolvedQuestions: [], thematicPressures: [],
  };
  const normalized = normalizeProviderStoryMaterialItemIDs(material) as Record<string, any>;
  assertEquals(normalized.characters[0].id, "same");
  assertEquals(normalized.antagonisticForces[0].id, "provider-antagonisticForces-1");
  assertEquals(normalized.locations[0].id, "provider-locations-1");
  const validated = validateStoryMaterialEnrichment(normalized, { allowMissingProvenance: true, recipe: sparseRequest.recipe as any });
  assertEquals(new Set([
    ...validated.characters,
    ...validated.antagonisticForces,
    ...validated.locations,
  ].map((item) => item.id)).size, 3);
});

Deno.test("PR7 checkRateLimit returns allowed=true when no prior entries exist", async () => {
  const calls: string[] = [];
  const mockSupabase = {
    from(table: string) {
      calls.push(`from:${table}`);
      return {
        select() {
          return {
            eq() {
              return {
                eq() {
                  return {
                    gte: async () => ({ count: 0, error: null }),
                  };
                },
              };
            },
          };
        },
      };
    },
  };
  const result = await checkRateLimit(mockSupabase as any, "user-x");
  assertEquals(result.allowed, true, "No entries in either window must allow the request");
  assertEquals(result.retryAfterSeconds, undefined);
  assertEquals(calls.includes("from:generation_request_logs"), true,
    "checkRateLimit must query generation_request_logs (per-minute and per-hour counts)");
});

Deno.test("PR7 checkRateLimit blocks when per-minute count hits RATE_LIMIT_PER_MINUTE (5)", async () => {
  const mockSupabase = {
    from(_table: string) {
      return {
        select() {
          return {
            eq() {
              return {
                eq() {
                  return {
                    gte: async () => ({ count: 5, error: null }),
                  };
                },
              };
            },
          };
        },
      };
    },
  };
  const result = await checkRateLimit(mockSupabase as any, "user-x");
  assertEquals(result.allowed, false);
  assertEquals(result.retryAfterSeconds, 60,
    "Per-minute hit must return retryAfterSeconds=60 so the client backs off for one minute");
});

Deno.test("PR7 checkRateLimit blocks when per-hour count hits RATE_LIMIT_PER_HOUR (30)", async () => {
  let callIndex = 0;
  const mockSupabase = {
    from(_table: string) {
      return {
        select() {
          return {
            eq() {
              return {
                eq() {
                  return {
                    gte: async () => {
                      callIndex++;
                      return { count: callIndex === 1 ? 0 : 30, error: null };
                    },
                  };
                },
              };
            },
          };
        },
      };
    },
  };
  const result = await checkRateLimit(mockSupabase as any, "user-x");
  assertEquals(result.allowed, false);
  assertEquals(result.retryAfterSeconds, 3600,
    "Per-hour hit must return retryAfterSeconds=3600 so the client backs off for one hour");
});

Deno.test("PR7 logRequest inserts one outline-from-recipe log entry with the right shape", async () => {
  let inserted: any = null;
  const mockSupabase = {
    from(table: string) {
      if (table !== "generation_request_logs") throw new Error(`unexpected table: ${table}`);
      return {
        insert(data: any) {
          inserted = data;
          return Promise.resolve({ error: null });
        },
      };
    },
  };
  await logRequest(mockSupabase as any, "user-x", "queued");
  assertEquals(inserted !== null, true, "logRequest must insert into generation_request_logs");
  assertEquals(inserted.action, "outline-from-recipe",
    "Log action must be 'outline-from-recipe' so checkRateLimit counts this entry");
  assertEquals(inserted.user_id, "user-x");
  assertEquals(inserted.status, "queued");
  assertEquals(inserted.error_code, null);
  assertEquals(typeof inserted.request_id, "string", "Each log entry must have a unique request_id");
  assertEquals(typeof inserted.created_at, "string", "Log entry must carry a created_at timestamp");
});

Deno.test("PR7 logRequest passes through errorCode when supplied", async () => {
  let inserted: any = null;
  const mockSupabase = {
    from(_table: string) {
      return {
        insert(data: any) {
          inserted = data;
          return Promise.resolve({ error: null });
        },
      };
    },
  };
  await logRequest(mockSupabase as any, "user-y", "failed", "rate_limited");
  assertEquals(inserted.status, "failed");
  assertEquals(inserted.error_code, "rate_limited",
    "When the request fails the log entry must record the failure code so audit queries can attribute the slot consumption");
});

Deno.test("PR7 POST handler reorders: resolve-existing BEFORE checkRateLimit", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const resolveExistingIdx = source.indexOf("PR 7: resolve an existing matching idempotent run first");
  const checkRateLimitIdx = source.indexOf("await checkRateLimit(userClient, user.id);");
  assertEquals(resolveExistingIdx > 0, true, "POST handler must contain the upfront resolve-existing block");
  assertEquals(checkRateLimitIdx > 0, true, "POST handler must call checkRateLimit");
  assertEquals(resolveExistingIdx < checkRateLimitIdx, true,
    "resolve-existing must be ordered BEFORE checkRateLimit so reconnects do NOT consume a rate-limit slot");
});

Deno.test("PR7 POST handler gates logRequest on isFreshInsert (reconnects skip logRequest)", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const isFreshInsertDecl = source.indexOf("const isFreshInsert = !insert.error && !!insert.data;");
  const logRequestCall = source.indexOf("await logRequest(db, user.id, \"queued\");");
  const logRequestGuard = source.indexOf("if (isFreshInsert) {");
  assertEquals(isFreshInsertDecl > 0, true, "POST handler must declare isFreshInsert");
  assertEquals(logRequestCall > 0, true, "POST handler must call logRequest");
  assertEquals(logRequestGuard > 0, true,
    "logRequest call must be guarded by isFreshInsert so reconnects (upfront resolve hit) and 23505 race-fallbacks do NOT log");
  assertEquals(logRequestGuard < logRequestCall, true,
    "isFreshInsert guard must precede the logRequest call");
  // PR 7 follow-up: generation_request_logs is service-role INSERT-only.
  // Using userClient (authenticated JWT) for logRequest would silently
  // 42501 in production, breaking the rate-limit counter. The call site
  // must use the admin client (db) so the insert actually lands.
  assertEquals(source.indexOf("await logRequest(userClient, user.id") === -1, true,
    "logRequest must be called through the admin/service-role client (db), not userClient — generation_request_logs is service-role INSERT-only");
});
Deno.test("PR7-fix logRequest throws visibly when Supabase insert returns error (regression for service-role-only table)", async () => {
  let inserted: any = null;
  const mockSupabase = {
    from(_table: string) {
      return {
        insert(data: any) {
          inserted = data;
          // Simulate the production failure mode that motivated this fix:
          // generation_request_logs is service-role INSERT-only, so an
          // insert attempted via an authenticated client returns a 42501
          // row-level security violation rather than throwing. Supabase
          // returns errors via the resolved value, so logRequest must
          // explicitly throw to make the failure visible to callers.
          return Promise.resolve({
            error: {
              message:
                'new row violates row-level security policy for table "generation_request_logs"',
              code: "42501",
              details: null,
              hint: null,
            },
            data: null,
          });
        },
      };
    },
  };
  let caught: Error | null = null;
  try {
    await logRequest(mockSupabase as any, "user-z", "queued");
  } catch (err) {
    caught = err as Error;
  }
  assertEquals(inserted !== null, true,
    "logRequest must still attempt the insert before reporting failure (so the failure is real, not skipped)");
  assertEquals(inserted.user_id, "user-z", "insert payload must still be built before throw");
  assertEquals(caught !== null, true,
    "logRequest must throw when Supabase returns an error so the failure is not silently swallowed by `await`");
  assertEquals(
    typeof caught?.message === "string" &&
      caught.message.includes("row-level security policy"),
    true,
    "Thrown error must surface the underlying Supabase error message so production RLS rejections are visible in logs",
  );
});

Deno.test("PR7-fix logRequest throws with non-empty message even when Supabase error has no message field", async () => {
  const mockSupabase = {
    from(_table: string) {
      return {
        insert(_data: any) {
          return Promise.resolve({ error: { code: "PGRST000" }, data: null });
        },
      };
    },
  };
  let caught: Error | null = null;
  try {
    await logRequest(mockSupabase as any, "user-w", "queued");
  } catch (err) {
    caught = err as Error;
  }
  assertEquals(caught !== null, true,
    "logRequest must throw on any Supabase error, even one missing the message field");
  assertEquals(typeof caught?.message === "string" && caught.message.length > 0, true,
    "Thrown error must carry a non-empty message so log scrapers / on-call see something actionable");
});


// ============================================================================
// PR #573 (revised): canonical recipe-field repair coverage.
//
// Every test below uses a payload shape that matches the actual
// PromptPackExportPayload schema (CathedralOSApp/Models/PromptPackExportPayload.swift),
// not a fabricated "title/description" object. The previous PR's fixture
// (`selectedAftertaste: { title: "Quiet dread" }`) exercised a non-canonical
// field and only proved that the placeholder fallback prevented the validator
// from rejecting the handle; it did not prove that authored recipe content
// reached Story Material.
//
// These tests assert the real contract: each canonical payload type populates
// label and description from the fields the iOS export actually emits, and
// only falls back to a synthesized structural note when every canonical field
// is empty.
// ============================================================================

Deno.test("PR #573 canonical repair: Aftertaste with only basic fields (label + note)", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-at-basic", summary: "A short story about loss" },
    setting: { included: false },
    promptPack: { id: "pack-at-basic", name: "Aftertaste Basic" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: {
      id: "at-basic",
      label: "Quiet dread",
      note: "The dread lingers long after the case closes",
    },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "at-basic", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-at-basic", sourcePromptPackName: "Aftertaste Basic",
  });
  const after = repaired.unresolvedQuestions.find((item) => item.sourceReference === "aftertaste");
  assertEquals(after?.label, "Quiet dread");
  assertEquals(after?.description, "The dread lingers long after the case closes.");
  assertEquals(after?.source, "recipe");
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: rich Aftertaste combines note + emotionalResidue + endingTexture + desiredAmbiguityLevel + readerQuestionLeftOpen + lastImageFeeling", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-at-rich", summary: "A novel about aftermath" },
    setting: { included: false },
    promptPack: { id: "pack-at-rich", name: "Aftertaste Rich" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: {
      id: "at-rich",
      label: "Quiet dread",
      note: "The dread lingers long after the case closes",
      emotionalResidue: "Uneasy vigilance",
      endingTexture: "Unresolved",
      desiredAmbiguityLevel: "High",
      readerQuestionLeftOpen: "Who else knew?",
      lastImageFeeling: "Empty courtroom",
    },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "at-rich", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-at-rich", sourcePromptPackName: "Aftertaste Rich",
  });
  const after = repaired.unresolvedQuestions.find((item) => item.sourceReference === "aftertaste");
  assertEquals(after?.label, "Quiet dread");
  assertEquals(
    after?.description,
    "The dread lingers long after the case closes. Emotional residue: Uneasy vigilance. Ending texture: Unresolved. Desired ambiguity: High. Reader question left open: Who else knew? Last image feeling: Empty courtroom.",
  );
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: StorySpark combines title + situation + stakes + twist + urgency + threat + opportunity + complication + clock + triggerEvent + initialImbalance + falseResolution + reversalPotential", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-spark", summary: "An old case returns" },
    setting: { included: false },
    promptPack: { id: "pack-spark", name: "Spark Canonical" },
    selectedCharacters: [],
    selectedStorySpark: {
      id: "s-canonical",
      title: "Cold case reopen",
      situation: "A detective is assigned to a decades-old murder",
      stakes: "The killer is still active",
      twist: "The victim's family is complicit",
      urgency: "A second body appears",
      threat: "Evidence is being destroyed",
      opportunity: "A surviving witness steps forward",
      complication: "The witness is unreliable",
      clock: "48 hours until the next murder",
      triggerEvent: "New DNA evidence surfaces",
      initialImbalance: "A powerful family with impunity",
      falseResolution: "An obvious suspect is arrested",
      reversalPotential: "The obvious suspect is innocent",
    },
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "spark-canonical", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-spark", sourcePromptPackName: "Spark Canonical",
  });
  const spark = repaired.antagonisticForces.find((item) => item.sourceReference === "storySpark");
  assertEquals(spark?.label, "Cold case reopen");
  assertEquals(spark?.description?.startsWith("Situation: A detective is assigned to a decades-old murder."), true);
  assertEquals(spark?.description?.includes("Stakes: The killer is still active."), true);
  assertEquals(spark?.description?.includes("Twist: The victim's family is complicit."), true);
  assertEquals(spark?.description?.includes("Urgency: A second body appears."), true);
  assertEquals(spark?.description?.includes("Threat: Evidence is being destroyed."), true);
  assertEquals(spark?.description?.includes("Opportunity: A surviving witness steps forward."), true);
  assertEquals(spark?.description?.includes("Complication: The witness is unreliable."), true);
  assertEquals(spark?.description?.includes("Clock: 48 hours until the next murder."), true);
  assertEquals(spark?.description?.includes("Trigger event: New DNA evidence surfaces."), true);
  assertEquals(spark?.description?.includes("Initial imbalance: A powerful family with impunity."), true);
  assertEquals(spark?.description?.includes("False resolution: An obvious suspect is arrested."), true);
  assertEquals(spark?.description?.includes("Reversal potential: The obvious suspect is innocent."), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: Character combines name + roles + goals + fears + flaws + secrets + wounds + contradictions + notes", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-char", summary: "A brooding protagonist" },
    setting: { included: false },
    promptPack: { id: "pack-char", name: "Character Canonical" },
    selectedCharacters: [
      {
        id: "c-mara",
        name: "Mara",
        roles: ["detective", "protagonist"],
        goals: ["solve the cold case", "restore her reputation"],
        fears: ["losing control", "hurting an innocent"],
        flaws: ["obsessive", "trusts no one"],
        secrets: ["buried evidence from her first case"],
        wounds: ["disbarred for planting evidence"],
        contradictions: ["wants justice but bends rules"],
        notes: "Disgraced detective returning to a cold case",
      },
    ],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "char-canonical", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-char", sourcePromptPackName: "Character Canonical",
  });
  const c = repaired.characters.find((item) => item.sourceReference === "character:c-mara");
  assertEquals(c?.label, "Mara");
  assertEquals(c?.description?.startsWith("Roles: detective, protagonist."), true);
  assertEquals(c?.description?.includes("Goals: solve the cold case, restore her reputation."), true);
  assertEquals(c?.description?.includes("Fears: losing control, hurting an innocent."), true);
  assertEquals(c?.description?.includes("Flaws: obsessive, trusts no one."), true);
  assertEquals(c?.description?.includes("Secrets: buried evidence from her first case."), true);
  assertEquals(c?.description?.includes("Wounds: disbarred for planting evidence."), true);
  assertEquals(c?.description?.includes("Contradictions: wants justice but bends rules."), true);
  assertEquals(c?.description?.includes("Notes: Disgraced detective returning to a cold case."), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: Relationship combines name + relationshipType + tension + loyalty + fear + desire + dependency + history + powerBalance + resentment + misunderstanding + unspokenTruth + whatEachWantsFromTheOther + whatWouldBreakIt + whatWouldTransformIt + notes", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-rel", summary: "A former partnership gone wrong" },
    setting: { included: false },
    promptPack: { id: "pack-rel", name: "Relationship Canonical" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [
      {
        id: "r-mara-vik",
        name: "Mara + Vik",
        relationshipType: "former partners turned enemies",
        tension: "Mutual suspicion and unresolved betrayal",
        loyalty: "None remaining",
        fear: "Mara fears Vik's retaliation; Vik fears Mara's pursuit",
        desire: "Mara wants closure; Vik wants silence",
        dependency: "Vik depends on Mara's silence",
        history: "Worked together on the original case",
        powerBalance: "Vik has institutional power; Mara has the truth",
        resentment: "Vik resents Mara's integrity",
        misunderstanding: "Both believe the other betrayed them first",
        unspokenTruth: "Vik planted the evidence that disbarred Mara",
        whatEachWantsFromTheOther: "Mara wants an admission; Vik wants Mara to leave town",
        whatWouldBreakIt: "Public disclosure of the planted evidence",
        whatWouldTransformIt: "Vik admitting what he did before the case closes",
        notes: "Their scenes should mirror the original partnership's warmth",
      },
    ],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "rel-canonical", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-rel", sourcePromptPackName: "Relationship Canonical",
  });
  const rel = repaired.relationships.find((item) => item.sourceReference === "relationship:r-mara-vik");
  assertEquals(rel?.label, "Mara + Vik");
  assertEquals(rel?.description?.startsWith("Type: former partners turned enemies."), true);
  assertEquals(rel?.description?.includes("Tension: Mutual suspicion and unresolved betrayal."), true);
  assertEquals(rel?.description?.includes("Fear: Mara fears Vik's retaliation; Vik fears Mara's pursuit."), true);
  assertEquals(rel?.description?.includes("Desire: Mara wants closure; Vik wants silence."), true);
  assertEquals(rel?.description?.includes("Dependency: Vik depends on Mara's silence."), true);
  assertEquals(rel?.description?.includes("History: Worked together on the original case."), true);
  assertEquals(rel?.description?.includes("Power balance: Vik has institutional power; Mara has the truth."), true);
  assertEquals(rel?.description?.includes("Resentment: Vik resents Mara's integrity."), true);
  assertEquals(rel?.description?.includes("Misunderstanding: Both believe the other betrayed them first."), true);
  assertEquals(rel?.description?.includes("Unspoken truth: Vik planted the evidence that disbarred Mara."), true);
  assertEquals(rel?.description?.includes("What each wants from the other: Mara wants an admission; Vik wants Mara to leave town."), true);
  assertEquals(rel?.description?.includes("What would break it: Public disclosure of the planted evidence."), true);
  assertEquals(rel?.description?.includes("What would transform it: Vik admitting what he did before the case closes."), true);
  assertEquals(rel?.description?.includes("Their scenes should mirror the original partnership's warmth."), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: ThemeQuestion combines question + coreTension + valueConflict + moralFaultLine + endingTruth + notes", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-theme", summary: "Memory and justice" },
    setting: { included: false },
    promptPack: { id: "pack-theme", name: "Theme Canonical" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [
      {
        id: "tq-past",
        question: "Can the past be trusted?",
        coreTension: "Memory versus official record",
        valueConflict: "Truth versus peace",
        moralFaultLine: "Justice requires disturbing settled narratives",
        endingTruth: "Memory is fallible but worth defending",
        notes: "Surface the question in the courtroom scene",
      },
    ],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "theme-canonical", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-theme", sourcePromptPackName: "Theme Canonical",
  });
  const t = repaired.thematicPressures.find((item) => item.sourceReference === "theme:tq-past");
  assertEquals(t?.label, "Can the past be trusted?");
  assertEquals(t?.description?.startsWith("Core tension: Memory versus official record."), true);
  assertEquals(t?.description?.includes("Value conflict: Truth versus peace."), true);
  assertEquals(t?.description?.includes("Moral fault line: Justice requires disturbing settled narratives."), true);
  assertEquals(t?.description?.includes("Ending truth: Memory is fallible but worth defending."), true);
  assertEquals(t?.description?.includes("Surface the question in the courtroom scene."), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: Motif combines label + category + meaning + examples + notes", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-motif", summary: "Symbols of identity" },
    setting: { included: false },
    promptPack: { id: "pack-motif", name: "Motif Canonical" },
    selectedCharacters: [],
    selectedStorySpark: null,
    selectedAftertaste: null,
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [
      {
        id: "m-mirror",
        label: "Mirrors",
        category: "Identity",
        meaning: "Reflections of a fractured identity",
        examples: ["Smashed mirror at crime scene", "Vik's sunglasses never off", "Mara's bathroom mirror has a crack"],
        notes: "Each mirror moment reveals a character hiding from themselves",
      },
    ],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "motif-canonical", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-motif", sourcePromptPackName: "Motif Canonical",
  });
  const m = repaired.thematicPressures.find((item) => item.sourceReference === "motif:m-mirror");
  assertEquals(m?.label, "Mirrors");
  assertEquals(m?.description?.startsWith("Category: Identity."), true);
  assertEquals(m?.description?.includes("Meaning: Reflections of a fractured identity."), true);
  assertEquals(m?.description?.includes("Examples: Smashed mirror at crime scene, Vik's sunglasses never off, Mara's bathroom mirror has a crack."), true);
  assertEquals(m?.description?.includes("Notes: Each mirror moment reveals a character hiding from themselves."), true);
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: sparse-but-valid payload — every canonical row has only its required identifier + label; deterministic fallback for description", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-sparse", summary: "Minimal viable story" },
    setting: { included: false },
    promptPack: { id: "pack-sparse", name: "Sparse" },
    selectedCharacters: [{ id: "c-sparse", name: "Mara" }],
    selectedStorySpark: { id: "s-sparse", title: "A letter arrives" },
    selectedAftertaste: { id: "at-sparse", label: "Quiet reflection" },
    selectedRelationships: [{ id: "r-sparse", name: "Mara + the sender" }],
    selectedThemeQuestions: [{ id: "tq-sparse", question: "What does the letter mean?" }],
    selectedMotifs: [{ id: "m-sparse", label: "Letters" }],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "sparse", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-sparse", sourcePromptPackName: "Sparse",
  });
  assertEquals(repaired.characters.length, 1);
  assertEquals(repaired.antagonisticForces.length, 1);
  assertEquals(repaired.unresolvedQuestions.length, 1);
  assertEquals(repaired.relationships.length, 1);
  assertEquals(repaired.thematicPressures.length, 2);
  assertEquals(repaired.discoveries.length, 1);
  const allItems = [
    ...repaired.characters,
    ...repaired.antagonisticForces,
    ...repaired.relationships,
    ...repaired.thematicPressures,
    ...repaired.unresolvedQuestions,
    ...repaired.discoveries,
  ];
  for (const item of allItems) {
    assertEquals(item.label !== item.sourceReference, true, `${item.id} label must differ from sourceReference`);
    assertEquals(item.description !== item.sourceReference, true, `${item.id} description must differ from sourceReference`);
    assertEquals(item.label.length > 0, true, `${item.id} label must be non-empty`);
    assertEquals(item.description.length > 0, true, `${item.id} description must be non-empty`);
  }
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: truly empty authored fields produce deterministic category-specific fallback description", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-empty", summary: "Untold story" },
    setting: { included: false },
    promptPack: { id: "pack-empty", name: "Empty" },
    selectedCharacters: [{ id: "c-empty", name: "" }],
    selectedStorySpark: { id: "s-empty", title: "" },
    selectedAftertaste: { id: "at-empty", label: "" },
    selectedRelationships: [{ id: "r-empty", name: "" }],
    selectedThemeQuestions: [{ id: "tq-empty", question: "" }],
    selectedMotifs: [{ id: "m-empty", label: "" }],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "empty", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-empty", sourcePromptPackName: "Empty",
  });
  // Even with truly empty authored fields, repair must produce structurally
  // valid material — the fallback is a deterministic category-specific
  // diagnostic, NOT a handle-derived placeholder that re-trips the validator.
  const c = repaired.characters[0];
  assertEquals(c.label, "Character");
  assertEquals(c.description, "Character with no authored content supplied");
  const spark = repaired.antagonisticForces[0];
  assertEquals(spark.label, "Story Spark");
  assertEquals(spark.description, "Story spark with no authored content supplied");
  const after = repaired.unresolvedQuestions[0];
  assertEquals(after.label, "Aftertaste");
  assertEquals(after.description, "Aftertaste with no authored content supplied");
  const rel = repaired.relationships[0];
  assertEquals(rel.label, "Relationship");
  assertEquals(rel.description, "Relationship with no authored content supplied");
  const t = repaired.thematicPressures.find((it) => it.sourceReference === "theme:tq-empty");
  assertEquals(t?.label, "Theme Question");
  assertEquals(t?.description, "Theme question with no authored content supplied");
  const m = repaired.thematicPressures.find((it) => it.sourceReference === "motif:m-empty");
  assertEquals(m?.label, "Motif");
  assertEquals(m?.description, "Motif with no authored content supplied");
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
});

Deno.test("PR #573 canonical repair: validateStoryMaterialEnrichment succeeds for a fully-populated canonical recipe", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-full", summary: "A fully-authored recipe" },
    setting: { included: false },
    promptPack: { id: "pack-full", name: "Full" },
    selectedCharacters: [
      { id: "c-mara", name: "Mara", roles: ["detective"], flaws: ["obsessive"], notes: "Returning to a cold case" },
      { id: "c-vik", name: "Vik", roles: ["fixer"], notes: "Rival with a long memory" },
    ],
    selectedStorySpark: { id: "s-1", title: "Cold case reopen", situation: "An old murder returns", stakes: "The killer is still active" },
    selectedAftertaste: { id: "at-1", label: "Quiet dread", note: "The dread lingers", endingTexture: "Unresolved" },
    selectedRelationships: [{ id: "r-1", name: "Mara + Vik", relationshipType: "enemies", tension: "Mutual suspicion" }],
    selectedThemeQuestions: [{ id: "tq-1", question: "Can the past be trusted?", coreTension: "Memory vs record" }],
    selectedMotifs: [{ id: "m-1", label: "Mirrors", category: "Identity", meaning: "Reflections of self" }],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "full", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-full", sourcePromptPackName: "Full",
  });
  // Must not throw — proves the canonical repair output passes the same
  // structural contract the validator enforces on planner output.
  const validated = validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
  assertEquals(validated, repaired);
});

Deno.test("PR #573 canonical repair: every produced sourceReference is verified by recipeMaterialHandles", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-refs", summary: "Reference authority check" },
    setting: { included: false },
    promptPack: { id: "pack-refs", name: "Refs" },
    selectedCharacters: [{ id: "c-1", name: "Mara", roles: ["detective"] }],
    selectedStorySpark: { id: "s-1", title: "A letter arrives" },
    selectedAftertaste: { id: "at-1", label: "Quiet dread" },
    selectedRelationships: [{ id: "r-1", name: "Mara + Sender" }],
    selectedThemeQuestions: [{ id: "tq-1", question: "What does the letter mean?" }],
    selectedMotifs: [{ id: "m-1", label: "Letters" }],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "refs", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-refs", sourcePromptPackName: "Refs",
  });
  // recipeMaterialHandles is internal to index.ts, so verify the canonical
  // handle shape directly via the prefix rules the validator relies on.
  const allowedHandle = (ref: string): boolean =>
    ref === "project.summary" || ref === "storySpark" || ref === "aftertaste" ||
    ref.startsWith("character:") || ref.startsWith("relationship:") ||
    ref.startsWith("theme:") || ref.startsWith("motif:");
  const allItems = [
    ...repaired.characters,
    ...repaired.antagonisticForces,
    ...repaired.relationships,
    ...repaired.thematicPressures,
    ...repaired.unresolvedQuestions,
    ...repaired.discoveries,
  ];
  for (const item of allItems) {
    assertEquals(typeof item.sourceReference, "string");
    assertEquals(item.sourceReference !== null, true, `${item.id} sourceReference must not be null for recipe-sourced items`);
    assertEquals((item.sourceReference as string).length > 0, true);
    assertEquals(allowedHandle(item.sourceReference as string), true, `${item.id} (${item.sourceReference}) must be a canonical handle`);
  }
});

Deno.test("PR #573 canonical repair: output is deterministic across repeated calls on the same input", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-det", summary: "Determinism check" },
    setting: { included: false },
    promptPack: { id: "pack-det", name: "Det" },
    selectedCharacters: [{ id: "c-1", name: "Mara", roles: ["detective"], flaws: ["obsessive"] }],
    selectedStorySpark: { id: "s-1", title: "Cold case reopen", situation: "An old murder returns" },
    selectedAftertaste: { id: "at-1", label: "Quiet dread", note: "The dread lingers" },
    selectedRelationships: [{ id: "r-1", name: "Mara + Vik", relationshipType: "enemies" }],
    selectedThemeQuestions: [{ id: "tq-1", question: "Can the past be trusted?", coreTension: "Memory vs record" }],
    selectedMotifs: [{ id: "m-1", label: "Mirrors", category: "Identity", meaning: "Reflections of self" }],
  };
  const provenance = {
    sourceRecipeHash: "det", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-det", sourcePromptPackName: "Det",
  };
  const a = repairStoryMaterialFromRecipe(recipe as any, provenance);
  const b = repairStoryMaterialFromRecipe(recipe as any, provenance);
  assertEquals(a, b);
  for (let i = 0; i < a.characters.length; i++) {
    assertEquals(a.characters[i].description, b.characters[i].description);
  }
  for (let i = 0; i < a.thematicPressures.length; i++) {
    assertEquals(a.thematicPressures[i].description, b.thematicPressures[i].description);
  }
});

Deno.test("PR #573 canonical repair: re-running repair does not progressively mutate or degrade authored content", () => {
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-replay", summary: "Replay stability check" },
    setting: { included: false },
    promptPack: { id: "pack-replay", name: "Replay" },
    selectedCharacters: [{ id: "c-mara", name: "Mara", roles: ["detective", "protagonist"], flaws: ["obsessive"], notes: "Disgraced detective returning to a cold case" }],
    selectedStorySpark: { id: "s-1", title: "Cold case reopen", situation: "An old murder returns" },
    selectedAftertaste: { id: "at-1", label: "Quiet dread", note: "The dread lingers" },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const provenance = {
    sourceRecipeHash: "replay", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-replay", sourcePromptPackName: "Replay",
  };
  let current = repairStoryMaterialFromRecipe(recipe as any, provenance);
  for (let i = 0; i < 5; i++) {
    const next = repairStoryMaterialFromRecipe(recipe as any, provenance);
    assertEquals(next, current, `repair iteration ${i + 1} must match prior output byte-for-byte`);
    current = next;
  }
  // Authored content survives every replay.
  const c = current.characters.find((it) => it.sourceReference === "character:c-mara");
  assertEquals(c?.description?.includes("Roles: detective, protagonist."), true);
  assertEquals(c?.description?.includes("Flaws: obsessive."), true);
  assertEquals(c?.description?.includes("Notes: Disgraced detective returning to a cold case."), true);
});

Deno.test("PR #573 canonical repair: sufficiency fails closed when canonical recipe is too sparse to support novel-scale development", () => {
  // Sparse-but-valid: every category produced an item (so the structural
  // validator passes), but the recipe lacks breadth for novel-scale
  // sufficiency. The repair function must still fail closed at the
  // sufficiency layer (which runs at call sites).
  const recipe = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: { id: "proj-ss", summary: "Minimal viable story" },
    setting: { included: false },
    promptPack: { id: "pack-ss", name: "Sparse" },
    selectedCharacters: [{ id: "c-ss", name: "Mara" }],
    selectedStorySpark: { id: "s-ss", title: "A letter arrives" },
    selectedAftertaste: { id: "at-ss", label: "Quiet reflection" },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
  const repaired = repairStoryMaterialFromRecipe(recipe as any, {
    sourceRecipeHash: "sparse-sufficient", sourceRecipeVersion: 1,
    sourcePromptPackID: "pack-ss", sourcePromptPackName: "Sparse",
  });
  validateStoryMaterialEnrichment(repaired, { recipe: recipe as any });
  const sufficiency = storyMaterialSufficiency(repaired, recipe as any, "novel");
  assertEquals(sufficiency.sufficient, false, "sparse recipe must NOT pass novel sufficiency");
  assertEquals(sufficiency.reasons.length > 0, true);
  // No recipe-derived item was lost during repair.
  assertEquals(repaired.characters.length, 1);
  assertEquals(repaired.unresolvedQuestions.length, 1);
});

Deno.test("expansion prompt stays bounded as global outline grows", () => {
  const target = { beatID: "beat-1", beatLabel: "Opening", beatDescription: "Begin", projectedWords: 1200, currentSections: [{ id: "target", title: "Target", summary: "Current target", storyArcBeatID: "beat-1", container: "scene" }] };
  const sizes = [10, 50, 100].map((count) => {
    const current = Array.from({ length: count }, (_, i) => ({ id: `s-${i}`, title: `Section ${i}`, summary: `Summary ${i}`, storyArcBeatID: "beat-1", container: "scene" }));
    const prompt = buildExpansionPrompt(sparseRequest as any, current as any, { round: 1, projectedTokens: 1200, projectedWords: 300, desiredWords: [70000, 90000], remainingDeficitTokens: 1000, beat: target as any }, []);
    return JSON.stringify(prompt).length;
  });
  assertEquals(sizes[2] <= sizes[0] * 1.5, true);
});

Deno.test("restored planning topology removes packet routing and keeps bounded stages", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(source.includes("generateEnrichment"), true);
  assertEquals(source.includes("story-material-enrichment-repair"), true);
  assertEquals(source.includes("planSectionAllocation"), true);
  assertEquals(source.includes('"outline-suggestions"'), true);
  assertEquals(source.includes("expandNovel"), true);
  assertEquals(source.includes("outline-route-"), false);
  assertEquals(source.includes("outline-suggestions-beat-"), false);
  assertEquals(source.includes("packetizeAtoms"), false);
  assertEquals(source.includes("assertPromptWithinBudget"), false);
  assertEquals(source.includes("const promptLimit"), false);
});


class ExecutableRunDb {
  row: any;
  attempts: any[] = [];
  cleanupCalls = 0;
  claims = 0;
  singleClaimOnly = false;
  constructor(row: any, options: { singleClaimOnly?: boolean } = {}) {
    this.row = structuredClone(row);
    this.singleClaimOnly = options.singleClaimOnly ?? false;
  }
  from(table: string) {
    const self = this;
    let patch: Record<string, unknown> | null = null;
    const filters: Array<[string, unknown]> = [];
    const ranges: Array<[string, unknown]> = [];
    let selected = false;
    const query: any = {
      update(value: Record<string, unknown>) { patch = value; return query; },
      eq(column: string, value: unknown) { filters.push([column, value]); return query; },
      lte(column: string, value: unknown) { ranges.push([column, value]); return query; },
      select(_columns?: string) { selected = true; return query; },
      maybeSingle() { return Promise.resolve(self.execute(table, patch, filters, ranges, selected)); },
      then(resolve: (value: unknown) => unknown, reject: (error: unknown) => unknown) {
        return Promise.resolve(self.execute(table, patch, filters, ranges, selected)).then(resolve, reject);
      },
    };
    return query;
  }
  private matches(value: any, filters: Array<[string, unknown]>, ranges: Array<[string, unknown]>) {
    return filters.every(([column, expected]) => value?.[column] === expected) &&
      ranges.every(([column, expected]) => String(value?.[column] ?? "") <= String(expected));
  }
  private execute(table: string, patch: Record<string, unknown> | null, filters: Array<[string, unknown]>, ranges: Array<[string, unknown]>, selected: boolean) {
    if (table === "outline_suggestion_runs") {
      if (!this.matches(this.row, filters, ranges)) return { data: null, error: null };
      if (patch?.status === "running" && this.singleClaimOnly && this.claims > 0) return { data: null, error: null };
      if (patch?.status === "running") this.claims++;
      if (patch) Object.assign(this.row, patch);
      if (!selected) return { data: [this.row], error: null };
      return { data: selected && filters.some(([column]) => column === "lease_expires_at") ? { id: this.row.id } : { ...this.row }, error: null };
    }
    if (table === "generation_provider_attempts") {
      for (const attempt of this.attempts) {
        if (this.matches(attempt, filters, ranges)) {
          if (patch) Object.assign(attempt, patch);
          this.cleanupCalls++;
        }
      }
      return { data: null, error: null };
    }
    return { data: null, error: null };
  }
}

function executableWorkerRecipe() {
  return {
    ...sparseRequest.recipe,
    project: { ...sparseRequest.recipe.project, id: "worker-project", summary: "A durable worker fixture" },
    promptPack: { ...sparseRequest.recipe.promptPack, id: "worker-pack" },
    selectedCharacters: Array.from({ length: 60 }, (_, index) => ({
      id: `character-${index + 1}`,
      name: `Character ${index + 1}`,
      roles: ["survivor"],
      goals: [`Goal ${index} with a long durable evidence description ${"x".repeat(700)}`],
      fears: [`Fear ${index} with a long durable evidence description ${"y".repeat(700)}`],
    })),
    selectedStorySpark: {
      id: "spark-1",
      title: "The route closes",
      situation: `A route closes under pressure ${"z".repeat(700)}`,
      stakes: "The survivors must choose who can cross.",
    },
    selectedAftertaste: { id: "aftertaste-1", label: "Uneasy survival", note: "The cost remains visible." },
    selectedRelationships: [],
    selectedThemeQuestions: [],
    selectedMotifs: [],
  };
}

async function executableWorkerBody() {
  const recipe = executableWorkerRecipe();
  const material = attachRecipeProvenance(
    repairStoryMaterialFromRecipe(recipe as any, {
      sourceRecipeHash: "worker-fixture",
      sourceRecipeVersion: 1,
      sourcePromptPackID: "worker-pack",
      sourcePromptPackName: "Worker fixture",
    }, "shortStory"),
    await recipeProvenance(recipe as any),
  );
  return {
    ...sparseRequest,
    recipe,
    requestedFormat: "shortStory" as const,
    storyMaterialEnrichment: material,
    arcTemplate: {
      id: "worker-arc",
      name: "Worker Arc",
      beats: [
        { id: "beat-1", role: "setup", label: "Setup", description: "Establish the route." },
        { id: "beat-2", role: "resolution", label: "Resolution", description: "Show the cost." },
      ],
    },
  };
}

function checkpointedWorkerRow(body: any) {
  return {
    id: "run-worker-fixture",
    status: "pending",
    credit_cost_charged: 0,
    remaining_credits: 100,
    story_material: body.storyMaterialEnrichment,
    suggestions: [],
    diagnostics: {},
    planning_context: null,
    planning_context_hash: null,
    planning_context_version: null,
    planning_state: {
      version: 2,
      phase: "allocation_complete",
      allocationEntries: [
        ["beat-1", { minSections: 1, rationale: "fixture" }],
        ["beat-2", { minSections: 1, rationale: "fixture" }],
      ],
    },
    planning_state_version: 2,
    attempt_count: 0,
    request_json: body,
  };
}

function fakeWorkerBilling(requestedActions: string[], providerCalls = requestedActions) {
  return async (request: any) => {
    requestedActions.push(request.action);
    if (providerCalls !== requestedActions) providerCalls.push(request.action);
    if (request.action === "outline-suggestions") {
      const section = (beat: string, title: string) => ({ title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: [], entryState: "The prior state holds.", dramaticEvent: `${title} happens.`, resultingChange: `${title} changes the pressure.`, terminalState: `${title} hands forward a new pressure.` });
      return { featureResult: JSON.stringify({ beats: { "beat-1": [section("beat-1", "Opening route")], "beat-2": [section("beat-2", "Cost of the route")] } }), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
    }
    if (request.action === "outline-plan") {
      return { featureResult: JSON.stringify({ allocations: [
        { beatIndex: 0, minSections: 1, rationale: "fixture" },
        { beatIndex: 1, minSections: 1, rationale: "fixture" },
      ] }), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
    }
    return { featureResult: JSON.stringify({ suggestions: [] }), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
  };
}

function validatedWorkerBilling(actions: string[], responseFor: (action: string) => string | unknown) {
  return async (request: any) => {
    actions.push(request.action);
    const content = responseFor(request.action);
    if (request.onProviderSuccess) {
      await request.onProviderSuccess({ content: typeof content === "string" ? content : JSON.stringify(content) });
    }
    return { featureResult: typeof content === "string" ? content : JSON.stringify(content), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
  };
}

Deno.test("enrichment semantic failure checkpoints one repair without repeating the first call", async () => {
  const fullBody = await executableWorkerBody();
  const body = { ...fullBody, storyMaterialEnrichment: undefined } as any;
  const row: any = {
    ...checkpointedWorkerRow(body),
    story_material: null,
    planning_state: { version: 2, phase: "start" },
    request_json: body,
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (action) => action === "story-material-enrichment" ? {} : fullBody.storyMaterialEnrichment);
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["story-material-enrichment"]);
  assertEquals(db.row.planning_state.nextAction, "story-material-enrichment-repair");
  await run();
  assertEquals(actions, ["story-material-enrichment", "story-material-enrichment-repair"]);
  assertEquals(db.row.planning_state.phase, "enrichment_complete");
  assertEquals(db.row.attempt_count, 0);
});

Deno.test("allocation semantic failure checkpoints one retry without repeating the first plan", async () => {
  const body = await executableWorkerBody();
  const row: any = {
    ...checkpointedWorkerRow(body),
    planning_state: { version: 2, phase: "enrichment_complete", nextAction: "outline-plan" },
    request_json: body,
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const valid = { allocations: [
    { beatIndex: 0, minSections: 1, rationale: "setup" },
    { beatIndex: 1, minSections: 1, rationale: "closure" },
  ] };
  const billable = validatedWorkerBilling(actions, (action) => action === "outline-plan" ? { allocations: [] } : valid);
  const run = () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["outline-plan"]);
  assertEquals(db.row.planning_state.nextAction, "outline-plan-retry");
  await run();
  assertEquals(actions, ["outline-plan", "outline-plan-retry"]);
  assertEquals(db.row.planning_state.phase, "allocation_complete");
  assertEquals(db.row.attempt_count, 0);
});

Deno.test("multi-beat expansion checkpoints beat one before the one-dispatch yield", async () => {
  const fullBody = await executableWorkerBody();
  const recipe = fullBody.recipe;
  const plannerItem = (id: string, label: string) => ({ id, label, description: `${label} description`, source: "planner", sourceReference: null });
  const material = {
    ...fullBody.storyMaterialEnrichment,
    format: "novel",
    escalationLadder: [
      ...fullBody.storyMaterialEnrichment.escalationLadder,
      plannerItem("worker-escalation-1", "First escalation"),
      plannerItem("worker-escalation-2", "Second escalation"),
      plannerItem("worker-escalation-3", "Third escalation"),
    ],
    reversals: [plannerItem("worker-reversal-1", "First reversal"), plannerItem("worker-reversal-2", "Second reversal")],
    consequences: [plannerItem("worker-consequence-1", "First consequence")],
  } as any;
  const body = { ...fullBody, requestedFormat: "novel", storyMaterialEnrichment: material } as any;
  const row: any = checkpointedWorkerRow(body);
  row.story_material = material;
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const baseSection = (beat: string, title: string) => ({ title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: [], entryState: "Prior state", dramaticEvent: `${title} happens`, resultingChange: `${title} changes the pressure`, terminalState: `${title} hands forward pressure` });
  const billable = validatedWorkerBilling(actions, (action) => {
    if (action === "outline-suggestions") return { beats: { "beat-1": [baseSection("beat-1", "Opening")], "beat-2": [baseSection("beat-2", "Closing")] } };
    const beat = action.endsWith("beat-1") ? "beat-1" : "beat-2";
    const count = beat === "beat-1" ? 7 : 2;
    return { suggestions: Array.from({ length: count }, (_, index) => expansionSection(`${action}-${index}`, "episode", beat)) };
  });
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.planning_state.phase, "expansion");
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-expansion-1-beat-1"]);
  assertEquals(db.row.planning_state.expansionCheckpoint.nextRound, 1);
  assertEquals(db.row.planning_state.expansionCheckpoint.nextBeatIndex, 1);
  assertEquals(db.row.suggestions.some((section: any) => section.title.includes("beat-1-0")), true);
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-expansion-1-beat-1", "outline-expansion-1-beat-2"]);
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.attempt_count, 0);
});

Deno.test("fresh novel worker sequence is enrichment then allocation then one global outline call", async () => {
  const fullBody = await executableWorkerBody();
  const body = { ...fullBody, storyMaterialEnrichment: undefined } as any;
  const row = {
    ...checkpointedWorkerRow(body),
    story_material: null,
    suggestions: [],
    diagnostics: {},
    planning_state: { version: 2, phase: "start" },
    request_json: body,
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const materialJSON = JSON.stringify(fullBody.storyMaterialEnrichment);
  const billable = async (request: any) => {
    actions.push(request.action);
    if (request.action === "story-material-enrichment") {
      return { featureResult: materialJSON, charged: true, actualCharge: 1, remainingCredits: 99 } as any;
    }
    return fakeWorkerBilling([])(request);
  };
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  await run();
  await run();
  assertEquals(actions, ["story-material-enrichment", "outline-plan", "outline-suggestions"]);
  assertEquals(db.row.attempt_count, 0);
  assertEquals(actions.some((action) => action.startsWith("outline-route-")), false);
  assertEquals(actions.some((action) => action.startsWith("outline-suggestions-beat-")), false);
  assertEquals(db.row.status, "completed");
});

Deno.test("reclaimed worker trusts an intact persisted planning checkpoint after JSON normalization", async () => {
  const fullBody = await executableWorkerBody();
  const body = { ...fullBody, storyMaterialEnrichment: undefined } as any;
  const row = {
    ...checkpointedWorkerRow(body),
    story_material: null,
    suggestions: [],
    diagnostics: {},
    planning_state: { version: 2, phase: "start" },
    request_json: body,
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const materialJSON = JSON.stringify(fullBody.storyMaterialEnrichment);
  const billable = async (request: any) => {
    actions.push(request.action);
    if (request.action === "story-material-enrichment") {
      return { featureResult: materialJSON, charged: true, actualCharge: 1, remainingCredits: 99 } as any;
    }
    return fakeWorkerBilling([])(request);
  };
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["story-material-enrichment"]);
  const persistedPlanningContext = { ...db.row.planning_context, reclaimedAfterJSONRoundTrip: true };
  db.row.planning_context = persistedPlanningContext;
  db.row.planning_context_hash = await (async (value) => {
    const stable = (candidate: any): any => Array.isArray(candidate)
      ? candidate.map(stable)
      : candidate && typeof candidate === "object"
      ? Object.fromEntries(Object.keys(candidate).sort().map((key) => [key, stable(candidate[key])]))
      : candidate;
    const bytes = new TextEncoder().encode(JSON.stringify(stable(value)));
    const digest = await crypto.subtle.digest("SHA-256", bytes);
    return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  })(persistedPlanningContext);
  await run();
  await run();
  assertEquals(actions, ["story-material-enrichment", "outline-plan", "outline-suggestions"]);
  assertEquals(db.row.status, "completed");
});

Deno.test("production checkpoint resume executes the single global outline call once", async () => {
  const body = await executableWorkerBody();
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const billableActions: string[] = [];
  const providerCalls: string[] = [];
  const scheduled: Array<{ body: any; auth: string }> = [];
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: fakeWorkerBilling(billableActions, providerCalls) as any,
    scheduleContinuation: async (continuationBody, auth) => { scheduled.push({ body: continuationBody, auth }); },
  });
  assertEquals(providerCalls.length, 1);
  assertEquals(providerCalls[0], "outline-suggestions");
  assertEquals(billableActions.length, 1);
  assertEquals(billableActions[0], "outline-suggestions");
  assertEquals(db.row.status, "completed");
  assertEquals(scheduled.length, 0);
});

Deno.test("global outline completion preserves advisory quality and obligation audit diagnostics", async () => {
  const body = await executableWorkerBody();
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const actions: string[] = [];
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: fakeWorkerBilling(actions) as any,
    scheduleContinuation: async () => {},
  });
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.status, "completed");
  const diagnostics = db.row.diagnostics;
  assertEquals(Array.isArray(diagnostics.dramaticDistinctnessIssues), true);
  assertEquals(Array.isArray(diagnostics.semanticArcIssues), true);
  assertEquals(Array.isArray(diagnostics.causalScaleIssues), true);
  assertEquals(typeof diagnostics.unusedStoryMaterialItems, "number");
  assertEquals("advisoryValidationError" in diagnostics, false);
  assertEquals(typeof diagnostics.recipeObligationCoverage, "object");
  assertEquals(Array.isArray(diagnostics.missingRequiredRecipeObligations), true);
});

Deno.test("one physical provider call stops the second dispatch before provider execution", async () => {
  const slice = new SuggestionWorkerSlice();
  const providerCalls: string[] = [];
  const billable = async (action: string) => {
    slice.beginDispatch();
    providerCalls.push(action);
    return action;
  };
  await billable("outline-plan");
  await assertRejects(() => billable("outline-suggestions"), SuggestionWorkerYield);
  assertEquals(providerCalls, ["outline-plan"]);
  assertEquals(slice.dispatchCount, 1);
});

Deno.test("voluntary yield transitions running to pending and schedules the same authenticated request once", async () => {
  const body = { idempotencyKey: "same-key", recipe: { project: { id: "p" } } } as any;
  const row: any = { status: "running", lease_owner: "worker-token", lease_expires_at: "future", completed_at: null, error_code: null, error: null };
  const patches: any[] = [];
  let scheduleCount = 0;
  let scheduledBody: any;
  let scheduledAuth = "";
  await returnSuggestionRunToPending(
    async (patch) => { patches.push(patch); Object.assign(row, patch); },
    async (nextBody, auth) => { scheduleCount++; scheduledBody = nextBody; scheduledAuth = auth; },
    body,
    "Bearer original",
    { stage: "routing", worker: { lastYieldReason: "provider_dispatch_boundary" } },
  );
  assertEquals(row.status, "pending");
  assertEquals(row.lease_owner, null);
  assertEquals(row.lease_expires_at, null);
  assertEquals(row.completed_at, null);
  assertEquals(row.error_code, null);
  assertEquals(row.error, null);
  assertEquals(scheduleCount, 1);
  assertEquals(scheduledBody, body);
  assertEquals(scheduledBody.idempotencyKey, "same-key");
  assertEquals(scheduledAuth, "Bearer original");
  assertEquals(patches.length, 1);
});

Deno.test("two continuation workers race on one pending claim and produce one provider call", async () => {
  const body = await executableWorkerBody();
  const db = new ExecutableRunDb(checkpointedWorkerRow(body), { singleClaimOnly: true });
  const providerCalls: string[] = [];
  const schedules: any[] = [];
  await Promise.all([
    runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
      db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
      billableLLM: fakeWorkerBilling(providerCalls) as any,
      scheduleContinuation: async (nextBody, auth) => { schedules.push({ nextBody, auth }); },
    }),
    runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
      db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
      billableLLM: fakeWorkerBilling(providerCalls) as any,
      scheduleContinuation: async (nextBody, auth) => { schedules.push({ nextBody, auth }); },
    }),
  ]);
  assertEquals(providerCalls.length, 1);
  assertEquals(providerCalls[0], "outline-suggestions");
  assertEquals(schedules.length, 0);
  assertEquals(db.row.status, "completed");
});

Deno.test("stale reclaim is a compare-and-set race and only the winner cleans orphan attempts", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb({ id: "run-stale", status: "running", lease_expires_at: expired, attempt_count: 4 });
  db.attempts = [{ feature_run_id: "run-stale", status: "started", started_at: new Date(Date.now() - 2000).toISOString() }];
  const run = { id: "run-stale", status: "running", lease_expires_at: expired, attempt_count: 4 };
  const results = await Promise.all([reclaimExpiredSuggestionRun(db, run), reclaimExpiredSuggestionRun(db, run)]);
  assertEquals(results, [true, false]);
  assertEquals(db.row.status, "pending");
  assertEquals(db.row.attempt_count, 5);
  assertEquals(db.cleanupCalls, 1);
  assertEquals(db.attempts[0].status, "provider_failed");
  assertEquals(db.attempts[0].provider_error_code, "worker_interrupted");
  assertEquals(db.attempts[0].completed_at !== null, true);
});

Deno.test("active lease recovery is a no-op", async () => {
  const future = new Date(Date.now() + 60_000).toISOString();
  const db = new ExecutableRunDb({ id: "run-active", status: "running", lease_expires_at: future, attempt_count: 2 });
  const result = await reclaimExpiredSuggestionRun(db, { id: "run-active", status: "running", lease_expires_at: future, attempt_count: 2 });
  assertEquals(result, false);
  assertEquals(db.row.status, "running");
  assertEquals(db.row.lease_expires_at, future);
  assertEquals(db.cleanupCalls, 0);
});

Deno.test("GET recovery starts the next pending slice after self-scheduling failure", async () => {
  const body = { idempotencyKey: "same-key", recipe: { project: { id: "p" } } } as any;
  const started: any[] = [];
  const startedRecovery = await recoverPendingSuggestionRun(
    { id: "run-recovery", status: "pending", request_json: body, attempt_count: 2 },
    "user-recovery",
    "openai-key",
    "Bearer recovery",
    async (...args) => { started.push(args); },
  );
  assertEquals(startedRecovery, true);
  assertEquals(started.length, 1);
  assertEquals(started[0][0], "run-recovery");
  assertEquals(started[0][1], body);
  assertEquals(started[0][5], "Bearer recovery");
});

Deno.test("self-scheduling failure leaves pending checkpoint recoverable", async () => {
  const body = { idempotencyKey: "same-key", recipe: { project: { id: "p" } } } as any;
  const row: any = { status: "running", lease_owner: "worker-token", lease_expires_at: "future", completed_at: null, error_code: null, error: null, checkpoint: "route-001" };
  await returnSuggestionRunToPending(
    async (patch) => Object.assign(row, patch),
    async () => { throw new Error("scheduler unavailable"); },
    body,
    "Bearer original",
    { stage: "routing", checkpoint: row.checkpoint },
  );
  assertEquals(row.status, "pending");
  assertEquals(row.error_code, null);
  assertEquals(row.error, null);
  assertEquals(row.checkpoint, "route-001");
});

Deno.test("final global provider call completes without an extra continuation", async () => {
  const body = await executableWorkerBody();
  const row: any = checkpointedWorkerRow(body);
  row.planning_state = {
    version: 2,
    phase: "allocation_complete",
    allocationEntries: [
      ["beat-1", { minSections: 1, rationale: "final CPU-only fixture" }],
      ["beat-2", { minSections: 1, rationale: "final CPU-only fixture" }],
    ],
  };
  const db = new ExecutableRunDb(row);
  const providerCalls: string[] = [];
  let scheduleCount = 0;
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: fakeWorkerBilling(providerCalls) as any,
    scheduleContinuation: async () => { scheduleCount++; },
  });
  assertEquals(providerCalls.length, 1, JSON.stringify({ providerCalls, planningState: db.row.planning_state, diagnostics: db.row.diagnostics }));
  assertEquals(providerCalls[0], "outline-suggestions");
  assertEquals(db.row.status, "completed", JSON.stringify({ providerCalls, planningState: db.row.planning_state, diagnostics: db.row.diagnostics }));
  assertEquals(scheduleCount, 0);
});
