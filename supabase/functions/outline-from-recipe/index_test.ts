import { assertEquals, assertRejects, assertThrows, assertStringIncludes } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { deriveRecipeObligations, obligationCoverage, renderStoryNonNegotiableMustDos } from "./_recipe_obligations.ts";
import { buildCompactPlanningView, buildArchitecturePlanningView, compactArcNarrativeText, compactMaterial, RECIPE_CREATIVE_AUTHORITY_DIRECTIVE } from "./_prompt_context.ts";

Deno.test("continuation auth keeps user JWT out of apikey and authenticates watchdog explicitly", () => {
  assertEquals(continuationHeaders("Bearer user-access-jwt", "operator-secret"), {
    Authorization: "Bearer user-access-jwt",
    "Content-Type": "application/json",
  });
  assertEquals(continuationHeaders("Bearer operator-secret", "operator-secret"), {
    Authorization: "Bearer operator-secret",
    apikey: "operator-secret",
    "Content-Type": "application/json",
  });
});

Deno.test("Suggest Sections defaults missing model selection to GPT-6 Luna", () => {
  assertEquals(LEGACY_PLANNING_MODEL_ID, "gpt-6-luna");
  assertEquals(canonicalizeNewPlanningRequest({} as any).modelID, "gpt-6-luna");
  assertEquals(canonicalizeNewPlanningRequest({ modelID: "gpt-5.4-mini" } as any).modelID, "gpt-6-luna");
  assertEquals(canonicalizeNewPlanningRequest({ modelID: "gpt-6-luna" } as any).modelID, "gpt-6-luna");
});

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
  assertEquals(source.includes("diagnostics, planning_state, story_material"), true);
});

import {
  buildAllocationPrompt,
  buildExpansionPrompt,
  isRetryableInsufficientCreditFailure,
  fitAllocationToNovelBudget,
  maximumBudgetedNewSections,
  maximumContainerPlannedNewSections,
  NOVEL_MIXED_SECTION_ESTIMATE_TOKENS,
  NOVEL_ACCEPTED_MAX_WORDS,
  NOVEL_MAX_GRACE_WORDS,
  allocationDeficits,
  allocationShortfalls,
  allocationRepairExhausted,
  AllocationBudgetConstraintError,
  assertAllocationCoverage,
  AllocationCoverageValidationError,
  outlineLogicalStageFamily,
  buildPrompt,
  assertDistinctOutlineTitles,
  buildSuggestionResponseSchema,
  plannedNovelContainerSlots,
  buildObligationRepairPrompt,
  mergeObligationRepairOperations,
  buildObligationRepairResponseSchema,
  repairRequiredRecipeObligations,
  STORY_MATERIAL_ENRICHMENT_SCHEMA,
  calculateRepairAllocation,
  ExpansionValidationError,
  fitExpansionAdditionsToBudget,
  NovelScalePlanningError,
  MAX_EXPANSION_ROUNDS,
  progressivelyExpandOutline,
  parseExpansionResponse,
  validateExpansionAdditions,
  mergeRepairedSuggestions,
  mergeExpansionAdditions,
  evaluateNovelScale,
  needsNovelExpansion,
  NOVEL_EXPANSION_MIN_WORDS,
  buildExpansionCheckpoint,
  expansionResumeState,
  isRetryableExpansionFailure,
  projectedExpectedTokens,
  projectedTokenRange,
  parseAndValidateAllocation,
  flattenSuggestionResponse,
  validateRequest,
  logicalSuggestionIdentity,
  validateSuggestions,
  normalizeTerminalBeat,
  buildEnrichmentPrompt,
  countStoryMaterialItems,
  repairStoryMaterialFromRecipe,
  mergeCanonicalRecipeMaterial,
  resumeOrRepairStoryMaterial,
  normalizeProviderStoryMaterialItemIDs,
  downgradeUnverifiedProviderRecipeReferences,
  validateStoryMaterialEnrichment,
  validatePremiseComponents,
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
  analyzePlannerCharacterIntegration,
  validateStoryArcSemantics,
  validateArcSemanticObligations,
  validateGroundedArcEvidence,
  normalizeEvidenceText,
  findGroundedSemanticField,
  resolveSemanticEvidenceCitation,
  isSemanticEvidenceGroundingFailure,
  validatePostRepairBeatCoverage,
  validateRequiredStoryArcFunctions,
  repairStoryArcMacroStructure,
  arcRoleContract,
  buildExpansionResponseSchema,
  validateNovelLeafContainers,
  NOVEL_LEAF_CONTAINERS,
  intimacyRequirement,
  intimacyPlanningDirective,
  semanticVerificationInput,
  removeDuplicateOutlineSections,
  verifyStoryArcSemantics,
  repairStoryArcSemanticObligations,
  SELECTED_INTIMACY_LEVEL_OBLIGATION,
  CREATIVE_FIDELITY_OBLIGATION,
  chooseBestSemanticOutline,
  REQUIRED_RESOLUTION_OUTCOME_OBLIGATION,
  verificationObligationsForBeat,
  planSectionAllocation,
  checkRateLimit,
  logRequest,
  isRetryableStoryMaterialFailure,
  isRetryableSemanticRepairFailure,
  isRetryableSemanticVerificationFailure,
  isSettledSemanticRepairCheckpoint,
  StoryMaterialSufficiencyError,
  StoryMaterialValidationError,
  RecipeObligationValidationError,
  SuggestionWorkerYield,
  SuggestionWorkerSlice,
  assertWorkerSliceCanDispatch,
  reclaimExpiredSuggestionRun,
  loadAuthoritativeSuggestionRun,
  suggestionRunResponse,
  markMeaningfulProgress,
  assertDurableUpdateSucceeded,
  suggestionLifecycleFailure,
  parseOutlineJSON,
  OutlineOutputExhaustedError,
  OUTLINE_PROVIDER_TIMEOUT_MS,
  OUTLINE_OUTPUT_TOKEN_BUDGET,
  SUPABASE_FREE_WALL_CLOCK_MS,
  MAX_SUGGESTION_NO_PROGRESS_MS,
  returnSuggestionRunToPending,
  continuationHeaders,
  canonicalizeNewPlanningRequest,
  LEGACY_PLANNING_MODEL_ID,
  recoverPendingSuggestionRun,
  runSuggestionJob,
  recoverWatchdogRun,
} from "./index.ts";
import { ProviderBillingUnavailableError } from "../generate-story/_provider.ts";

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

Deno.test("provider-facing prompts preserve the complete canonical recipe exactly", () => {
  const recipe: any = {
    ...sparseRequest.recipe,
    project: { ...sparseRequest.recipe.project, audienceNotes: "TED_AUDIENCE", nested: { deep: { value: "DEEP_PROJECT" } } },
    setting: { included: true, worldRules: ["RULE_" + "x".repeat(1200)], hiddenTruths: ["HIDDEN_TRUTH"], nested: { level: { value: "DEEP_SETTING" } } },
    selectedCharacters: Array.from({ length: 25 }, (_, index) => ({ id: `character-${index}`, name: `Character ${index}`, instructionBias: `CHARACTER_${index}`, speechStyle: `STYLE_${index}`, nested: { deep: { value: `DEEP_CHARACTER_${index}` } } })),
    selectedRelationships: [{ id: "relationship-1", relationshipType: "RELATIONSHIP" }],
    selectedThemeQuestions: [{ id: "theme-1", question: "Can people who are incapable of governing themselves save everyone else?", coreTension: "Private ruin versus public salvation", valueConflict: "Survival versus responsibility", moralFaultLine: "The difference between consequential action and moral worth" }],
    selectedMotifs: [{ id: "motif-1", meaning: "MOTIF" }],
    selectedStorySpark: { id: "spark-1", situation: "SPARK" },
    selectedAftertaste: { id: "aftertaste-1", endingTexture: "AFTERTASTE" },
    storyNonNegotiables: ["NON_NEGOTIABLE"],
    promptPack: { ...sparseRequest.recipe.promptPack, notes: "PACK_NOTES", instructionBias: "PACK_BIAS" },
  };
  const request: any = { ...sparseRequest, recipe };
  assertEquals(buildCompactPlanningView(request).recipe, recipe);
  assertEquals(JSON.parse(buildEnrichmentPrompt(request).user).recipe, recipe);
  assertEquals(JSON.parse(buildPrompt(request, new Map()).user).planningContext.recipe, recipe);
  assertEquals(JSON.parse(buildExpansionPrompt(request, []).user).global.recipe, recipe);
  assertEquals(JSON.parse(buildObligationRepairPrompt(request, [], [], []).user).recipe, recipe);
  assertEquals(semanticVerificationInput([], request.arcTemplate, recipe).recipe, recipe);
});

Deno.test("recipe authority governs enrichment, allocation, outline, and expansion prompts", () => {
  const request: any = {
    ...sparseRequest,
    recipe: {
      ...sparseRequest.recipe,
      project: { ...sparseRequest.recipe.project, audienceNotes: "Do not make the protagonist heroic." },
      setting: { included: true, worldRules: ["The dead can alter one living memory."], hiddenTruths: ["The supposed prophecy is a fraud."] },
      selectedCharacters: [{ id: "mara", name: "Mara", instructionBias: "Never reward Mara with moral redemption." }],
    },
  };
  const allocation = buildAllocationPrompt(request).system;
  const outline = buildPrompt(request, new Map()).system;
  const expansion = buildExpansionPrompt(request, []).system;
  const enrichment = buildEnrichmentPrompt(request).system;
  for (const prompt of [allocation, outline, expansion, enrichment]) {
    assertEquals(prompt.includes(RECIPE_CREATIVE_AUTHORITY_DIRECTIVE), true);
    assertEquals(prompt.includes("Never change the recipe's creative identity"), true);
  }
  assertEquals(outline.includes("Planner-generated material may be rejected or replaced"), true);
  assertEquals(expansion.includes("Planner-generated enrichment is provisional"), true);
  assertStringIncludes(enrichment, "A planner-invented mechanism is an optional candidate");
  assertEquals(JSON.parse(buildExpansionPrompt(request, []).user).global.recipe.setting.worldRules[0].includes("dead"), true);
});

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

Deno.test("reasoningEffort accepts supported Sol levels and rejects invalid/non-Sol values", () => {
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6.1-sol", reasoningEffort: "low" }), null);
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6.1-sol", reasoningEffort: "medium" }), null);
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6.1-sol", reasoningEffort: "high" }), null);
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6-luna", reasoningEffort: "medium" }), null);
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6-astra", reasoningEffort: "low" }), null);
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-6.1-sol", reasoningEffort: "xhigh" }), "reasoningEffort must be low, medium, or high");
  assertEquals(validateRequest({ ...sparseRequest, modelID: "gpt-5.6-luna", reasoningEffort: "low" }), "reasoningEffort is only supported for GPT-6 Luna, GPT-6.1 Sol, or GPT-6 Astra");
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

Deno.test("story non-negotiables derive as required obligations", () => {
  const obligations = deriveRecipeObligations({
    ...sparseRequest.recipe,
    storyNonNegotiables: ["The protagonists must choose intimacy after accountability."],
  } as any);
  const nonNegotiable = obligations.find((item) => item.classification === "story_non_negotiable");
  assertEquals(nonNegotiable?.required, true);
  assertStringIncludes(nonNegotiable?.statement ?? "", "must choose intimacy after accountability");
});

Deno.test("story non-negotiables are rendered as explicit must-do acceptance criteria", () => {
  const obligations = deriveRecipeObligations({
    ...sparseRequest.recipe,
    storyNonNegotiables: ["There must be 10 hard core long sex scenes built in."],
  } as any);
  const mustDos = renderStoryNonNegotiableMustDos(obligations);
  assertStringIncludes(mustDos, "R2 MUST DO:");
  assertStringIncludes(mustDos, "There must be 10 hard core long sex scenes built in.");
  const request = { ...sparseRequest, storyNonNegotiables: ["There must be 10 hard core long sex scenes built in."] } as any;
  const prompt = buildPrompt(request, new Map(), obligations);
  assertStringIncludes(prompt.system, "STORY NON-NEGOTIABLE MUST-DOS (acceptance criteria)");
  assertStringIncludes(prompt.system, "treat that number as the minimum count of distinct realized events");
  const planningContext = JSON.parse(prompt.user).planningContext;
  assertEquals(planningContext.mustDos[0].directive.includes("There must be 10 hard core long sex scenes built in."), true);
});

Deno.test("outline prompts distinguish substantial dramatic developments from fragments", () => {
  const request = { ...sparseRequest, requestedFormat: "novel" } as any;
  const outlinePrompt = buildPrompt(request, new Map()).system;
  assertStringIncludes(outlinePrompt, "Before assigning separate sections to related events, determine whether each creates a genuinely new causal development.");
  assertStringIncludes(outlinePrompt, "A separate section must introduce a consequential new action, discovery, reversal, cost, commitment, or changed relationship");
  assertStringIncludes(outlinePrompt, "Preserve legitimate slow-burn storytelling, character reflection, suspense, callbacks, and multi-stage confrontations");
  assertStringIncludes(outlinePrompt, "Do not impose an arbitrary requirement that every section contain action or spectacle.");
  assertStringIncludes(outlinePrompt, "115,000-word minimum");
  assertStringIncludes(outlinePrompt, "125,000-word hard cap");
  assertStringIncludes(outlinePrompt, "Story Arc");
  assertStringIncludes(outlinePrompt, "recipe obligations");

  const allocationPrompt = buildAllocationPrompt(request).system;
  assertStringIncludes(allocationPrompt, "Allocate sections according to distinct dramatic developments, not the number of steps, conversations, or locations involved in one development.");
  assertStringIncludes(allocationPrompt, "Consecutive preparations for the same confrontation");
  assertStringIncludes(allocationPrompt, "Prefer appropriately substantial containers over fragmenting a single causal unit");
  assertStringIncludes(allocationPrompt, "115,000 projected words");
  assertStringIncludes(allocationPrompt, "125,000-word maximum");
  assertStringIncludes(allocationPrompt, "container");
  assertStringIncludes(allocationPrompt, "Story Arc");
  assertStringIncludes(allocationPrompt, "Recipe obligations");
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
    system.includes("minSections is only the additional sections still required"),
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

Deno.test("charged insufficient-credit runs with a planning checkpoint are resumable", () => {
  assertEquals(isRetryableInsufficientCreditFailure({
    status: "failed",
    error_code: "insufficient_credits",
    credit_cost_charged: 3.67,
    planning_state: { phase: "allocation_complete", nextAction: "outline-suggestions" },
  }), true);
  assertEquals(isRetryableInsufficientCreditFailure({
    status: "failed",
    error_code: "insufficient_credits",
    credit_cost_charged: 0,
    planning_state: { phase: "allocation_complete", nextAction: "outline-suggestions" },
  }), false);
});

Deno.test("allocator floors are normalized into bounded container slots", () => {
  const req = {
    ...sparseRequest,
    arcTemplate: {
      ...sparseRequest.arcTemplate,
      beats: Array.from({ length: 11 }, (_, index) => ({
        id: `beat-${index + 1}`,
        role: index === 0 ? "ordinaryWorld" : "risingAction",
        label: `Beat ${index + 1}`,
        description: "Distinct movement.",
      })),
    },
  } as any;
  const allocation = new Map<string, any>(req.arcTemplate.beats.map((beat: any) => [beat.id, {
    minSections: 20,
    rationale: "material-rich movement",
  }]));
  const fitted = fitAllocationToNovelBudget(allocation, req);
  const total = Array.from(fitted.values()).reduce((sum, plan) => sum + plan.minSections, 0);
  assertEquals(total, 121);
  assertEquals(Array.from(fitted.values()).every((plan) => plan.minSections > 0), true);
  assertEquals(maximumBudgetedNewSections(req), 46);
});

Deno.test("container completion uses the remaining accepted capacity", () => {
  const existingSections = [
    ...Array.from({ length: 9 }, () => ({ container: "chapter" })),
    ...Array.from({ length: 2 }, () => ({ container: "sceneSequence" })),
    ...Array.from({ length: 5 }, () => ({ container: "setPiece" })),
    ...Array.from({ length: 8 }, () => ({ container: "developedScene" })),
    ...Array.from({ length: 5 }, () => ({ container: "scene" })),
  ];
  const req = { ...sparseRequest, requestedFormat: "novel", existingSections } as any;
  assertEquals(existingSections.length, 29);
  assertEquals(existingSections.filter((section) => section.container === "chapter").length, 9);
  assertEquals(Math.round(projectedExpectedTokens(existingSections) / 1.3), 78077);
  assertEquals(maximumBudgetedNewSections(req), 17);
  assertEquals(maximumContainerPlannedNewSections(req), 17);
  const fitted = fitAllocationToNovelBudget(new Map([["beat-1", { minSections: 20, rationale: "calibration fallback" }]]), req);
  assertEquals(fitted.get("beat-1")?.minSections, 20);
});

Deno.test("unknown novel allocation uses the mixed-section estimate", () => {
  const req = { ...sparseRequest, requestedFormat: "novel" } as any;
  const chapterTokens = projectedExpectedTokens([{ container: "chapter" }]);
  assertEquals(chapterTokens, 5500);
  assertEquals(NOVEL_MIXED_SECTION_ESTIMATE_TOKENS, 3500);
  assertEquals(maximumBudgetedNewSections(req), Math.floor(125000 * 1.3 / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS));
  assertEquals(maximumContainerPlannedNewSections(req), 46);
  assertEquals(Math.round(115000 * 1.3 / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS), 43);
  const scale = evaluateNovelScale(
    Array.from({ length: 28 }, () => ({ container: "chapter" })),
  );
  assertEquals(Math.round(scale.projectedWords), 118462);
  assertEquals(scale.meetsPreferredMinimum, true);
  assertEquals(scale.exceedsMaximum, false);
});

Deno.test("container-aware planner can allocate a mixed 120k-word first pass beyond 29 slots", () => {
  const beats = [{ id: "beat-1" }, { id: "beat-2" }];
  const counts = { scene: 0, developedScene: 6, setPiece: 5, sceneSequence: 4, chapter: 5 };
  const parsed = parseAndValidateAllocation(JSON.stringify({
    allocations: [
      { beatIndex: 0, minSections: 20, containerCounts: counts, rationale: "opening and development" },
      { beatIndex: 1, minSections: 20, containerCounts: counts, rationale: "turns and resolution" },
    ],
  }), beats);
  const req = { ...sparseRequest, requestedFormat: "novel", arcTemplate: { ...sparseRequest.arcTemplate, beats } } as any;
  assertEquals(maximumBudgetedNewSections(req), 46, "unknown-mix fallback uses the mixed-section estimate");
  const fitted = fitAllocationToNovelBudget(parsed, req);
  assertEquals(Array.from(fitted.values()).reduce((sum, plan) => sum + plan.minSections, 0), 40);
  const plannedContainers = Array.from({ length: 2 }).flatMap(() =>
    Object.entries(counts).flatMap(([container, count]) =>
      Array.from({ length: count }, () => ({ container }))));
  assertEquals(projectedExpectedTokens(plannedContainers), 157000);
  const scale = evaluateNovelScale(plannedContainers);
  assertEquals(scale.meetsPreferredMinimum, true);
  assertEquals(scale.exceedsMaximum, false);
  assertEquals(Math.round(scale.projectedWords), 120769);
  const schema: any = buildSuggestionResponseSchema(beats, fitted, [], "", "novel");
  const beatSchema = schema.properties.beats.properties["beat-1"];
  assertEquals(beatSchema.type, "object");
  assertEquals(Object.keys(beatSchema.properties).length, 20);
  assertEquals(beatSchema.required.length, 20);
  assertOpenAIStrictSchema(schema);
  const slots = plannedNovelContainerSlots(counts);
  for (let index = 0; index < slots.length; index++) {
    const key = `section_${String(index + 1).padStart(3, "0")}`;
    assertEquals(beatSchema.properties[key].properties.container.enum, [slots[index]]);
  }
  assertEquals(slots.filter((type) => type === "scene").length, 0);
  assertEquals(slots.filter((type) => type === "chapter").length, 5);
  // This exact mix projects >115k without depending on expansion. No new provider call.
  const typedResponse = { beats: Object.fromEntries(beats.map((beat, beatIndex) => [
    beat.id, Object.fromEntries(slots.map((container, index) => [
      `section_${String(index + 1).padStart(3, "0")}`,
      { title: `Section ${beatIndex * 20 + index + 1}`, summary: "Distinct event.", container, pov: "thirdPersonLimited", terminalBeat: "Mara shuts the door." },
    ])),
  ])) };
  const flattened = flattenSuggestionResponse(typedResponse, beats);
  assertEquals(flattened.suggestions.length, 40);
  assertEquals(evaluateNovelScale(flattened.suggestions).meetsPreferredMinimum, true);
  assertEquals(evaluateNovelScale(flattened.suggestions).exceedsMaximum, false);
  assertEquals(flattened.suggestions[20].storyArcBeatID, "beat-2");
  const { system } = buildPrompt(req, fitted);
  assertEquals(system.includes("planned containers: developedScene=6, setPiece=5, sceneSequence=4, chapter=5"), true);
  assertEquals(buildAllocationPrompt(req).system.includes("containerCounts"), true);
});

Deno.test("novel planning provider receives strict typed budget and carries 40 section mix without scaling", async () => {
  const beats = [{ id: "beat-1" }, { id: "beat-2" }];
  const request = { ...sparseRequest, requestedFormat: "novel", arcTemplate: { ...sparseRequest.arcTemplate, beats } } as any;
  const counts = { scene: 0, developedScene: 6, setPiece: 5, sceneSequence: 4, chapter: 5 };
  let providerCalls = 0;
  const allocation = await planSectionAllocation(request, "unused", async (
    system: string, user: string, _max: number, format: any, action: string,
  ) => {
    providerCalls++;
    assertEquals(action, "outline-plan");
    assertEquals(system.includes("Return containerCounts on each beat"), true);
    assertEquals(user.includes("containerMidpointTokens"), true);
    const schema = format.json_schema.schema;
    const item = schema.properties.allocations.items;
    assertEquals(item.required.includes("containerCounts"), true);
    assertEquals(item.properties.containerCounts.required.length, 5);
    return { content: JSON.stringify({ allocations: [
      { beatIndex: 0, minSections: 20, containerCounts: counts, rationale: "opening" },
      { beatIndex: 1, minSections: 20, containerCounts: counts, rationale: "resolution" },
    ] }), creditCostCharged: 0, remainingCredits: 0 };
  });
  assertEquals(providerCalls, 1);
  assertEquals(Array.from(allocation.values()).reduce((count, entry) => count + entry.minSections, 0), 40);
  assertEquals(allocation.get("beat-1")?.containerCounts, counts);
});


Deno.test("arc-first architecture derives plot from every authored beat before committing to an outcome", () => {
  const beats = [
    { id: "opening", role: "normal_with_crack", label: "Unsettling Opening", description: "Establish the particular wrongness of the ordinary world." },
    { id: "manifest", role: "full_manifestation", label: "The Threat Arrives", description: "Make the principal danger immediate and unavoidable." },
    { id: "ending", role: "final_image", label: "Final Image", description: "Show the irreversible consequence and emotional residue." },
  ];
  for (const arcName of ["Horror / Escalating Dread", "Romance / HEA", "Three-Act", "Custom Experimental Arc"]) {
    const request: any = { ...sparseRequest, arcTemplate: { ...sparseRequest.arcTemplate, name: arcName, beats } };
    const { system, user } = buildAllocationPrompt(request);
    const arcFirst = system.indexOf("Interpret the recipe AND selected Story Arc BEFORE choosing the story");
    const chooseOutcome = system.indexOf("After reconciling the recipe with the ordered arc movements");
    const persistBeatPlans = system.indexOf("THEN write the already-selected beat-by-beat movements into allocation rationale");
    const sizeChapters = system.indexOf("Only AFTER those story and arc decisions");
    assertEquals(arcFirst >= 0 && arcFirst < chooseOutcome && chooseOutcome < persistBeatPlans && persistBeatPlans < sizeChapters, true, arcName);
    assertStringIncludes(system, "Each rationale must explain BOTH the specific effect required by that beat's authored description");
    const payload = JSON.parse(user);
    assertEquals(payload.planningContext.arc.name, arcName);
    assertEquals(payload.planningContext.arc.beats.map((beat: any) => beat.description), beats.map((beat) => beat.description));
    const outline = buildPrompt(request, new Map(), [], undefined, {
      centralQuestion: "Which value will the protagonist betray?",
      characterCausality: "The protagonist makes decisions that compound the cost.",
      decisiveClimax: "A decisive act permanently changes the relationship.",
      endingConsequence: "The new relationship cannot revert.",
      deliberatelyOpenThreads: "The wider mystery continues.",
    });
    assertStringIncludes(outline.system, "Each beat's rationale must realize that beat's authored dramatic requirement");
    assertStringIncludes(outline.system, "Reconcile the authored Story Arc's dramatic progression with the recipe BEFORE committing to the plot");
  }
});

Deno.test("exceptional payoff changes with the selected arc, not just beat labels", () => {
  // The recipe is deliberately IDENTICAL. Only the selected Story Arc varies.
  const sameRecipe: any = {
    ...sparseRequest.recipe,
    project: {
      ...sparseRequest.recipe.project,
      summary: "Two compromised companions share a secret and face a corrupt institution whose larger purpose remains unknown.",
      audienceNotes: "Adult fiction with psychologically complex, morally compromised characters.",
    },
  };
  const arcs = [
    {
      name: "Horror / Escalating Dread",
      beats: [
        { id: "h-a", role: "full_manifestation", label: "Full Manifestation", description: "Make the horror unavoidable and genuinely terrifying." },
        { id: "h-b", role: "final_image", label: "Final Image", description: "Leave disturbing emotional residue after the decisive encounter." },
      ],
    },
    {
      name: "Romance / HEA",
      beats: [
        { id: "r-a", role: "grand_choice", label: "Grand Choice", description: "Force the lovers to risk something deeply personal for one another." },
        { id: "r-b", role: "hea_hfn", label: "HEA", description: "Deliver an emotionally earned happy relationship outcome." },
      ],
    },
    {
      name: "Mystery",
      beats: [
        { id: "m-a", role: "key_revelation", label: "Key Revelation", description: "Change the meaning of all previous clues." },
        { id: "m-b", role: "resolution", label: "Resolution", description: "Deliver the earned answer and its irreversible cost." },
      ],
    },
    {
      name: "Custom Experimental Arc",
      beats: [
        { id: "c-a", role: "rupture", label: "Rupture", description: "An irreversible relationship fracture." },
        { id: "c-b", role: "aftermath", label: "Aftermath", description: "A quiet but devastating moral consequence." },
      ],
    },
  ];
  let baselineSystem: string | undefined;
  for (const arc of arcs) {
    const request: any = { ...sparseRequest, recipe: sameRecipe, requestedFormat: "novel", arcTemplate: { ...sparseRequest.arcTemplate, ...arc } };
    const architecture = buildAllocationPrompt(request);
    const outline = buildPrompt(request, new Map(), [], undefined, {
      centralQuestion: "Which truth must the protagonists confront?",
      characterCausality: "The companions' conflicting decisions cause an irreversible confrontation.",
      decisiveClimax: "One protagonist makes a decisive and costly choice.",
      endingConsequence: "Their lives can never return to their earlier state.",
      deliberatelyOpenThreads: "The larger institution remains unresolved.",
    });
    const payload = JSON.parse(architecture.user);
    assertEquals(payload.planningContext.recipe.project.summary, sameRecipe.project.summary);
    assertEquals(payload.planningContext.arc.name, arc.name);
    assertEquals(payload.planningContext.arc.beats.map((b: any) => b.description), arc.beats.map((b) => b.description));
    assertStringIncludes(architecture.system, "Choose an exceptional, arc-specific ending before building the central plot");
    assertStringIncludes(architecture.system, "Survival, escape, staying together, a disrupted operation");
    assertStringIncludes(architecture.system, "a DIFFERENT primary dramatic question, conflict trajectory, decisive event, and outcome");
    assertStringIncludes(architecture.system, "Merely changing labels, tone");
    assertStringIncludes(architecture.system, "impose a tragic ending on a happy-ending contract");
    assertStringIncludes(architecture.system, "Personal stakes can be as devastating as national stakes");
    assertStringIncludes(architecture.system, "THEN work backward from that chosen payoff");
    assertStringIncludes(architecture.system, "Preserve wider series promises at their authored scope");
    assertStringIncludes(outline.system, "Preserve the architecture's specifically selected, extraordinary arc-driven payoff");
    assertStringIncludes(outline.system, "do not displace it with a report, explanation");
    assertStringIncludes(outline.system, "procedural storytelling are entirely valid");
    assertStringIncludes(outline.system, "a mere narrow escape, surviving together, stopping a routine operation");
    // The same rules apply to every genre, while each distinct authored arc
    // is actually passed to the planner to shape its generated ending.
    if (baselineSystem === undefined) baselineSystem = architecture.system;
    else assertEquals(architecture.system, baselineSystem);
  }
});

Deno.test("high-impact endings preserve existing architecture schema and one-call planning", async () => {
  const req = { ...sparseRequest, requestedFormat: "novel" } as any;
  let calls = 0;
  const result = await planSectionAllocation(req, "unused", async (system: string, _user: string, _maxTokens: number, format: any, action: string) => {
    calls += 1;
    assertEquals(action, "outline-plan");
    assertStringIncludes(system, "Choose an exceptional, arc-specific ending before building the central plot");
    assertEquals(Object.keys(format.json_schema.schema.properties.storyArchitecture.properties).sort(),
      ["centralQuestion", "characterCausality", "decisiveClimax", "deliberatelyOpenThreads", "endingConsequence"].sort());
    return {
      content: JSON.stringify({
        storyArchitecture: {
          centralQuestion: "Will Mara tell the truth despite the irreversible consequences?",
          characterCausality: "Her betrayal sets off the final reckoning.",
          decisiveClimax: "Mara exposes her part in the betrayal and loses the person she most wanted to protect.",
          endingConsequence: "The family knows the truth and is permanently changed.",
          deliberatelyOpenThreads: "The wider political conspiracy remains.",
        },
        allocations: [
          { beatIndex: 0, minSections: 2, containerCounts: { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 2 }, rationale: "Mara's fatal mistake begins the betrayal." },
          { beatIndex: 1, minSections: 2, containerCounts: { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 2 }, rationale: "The irrevocable loss and resulting changed family fulfill this arc." },
        ],
      }),
      creditCostCharged: 1,
      remainingCredits: 99,
    } as any;
  });
  assertEquals(calls, 1);
  assertEquals(result.size, 2);
});

Deno.test("novel first-pass slot schema reserves required functions across arc templates", () => {
  const cases = [
    { name: "Horror / Escalating Dread", climaxRole: "survival_confrontation", resolutionRole: "final_image", requiresResolution: true },
    { name: "Romance / HEA", climaxRole: "grand_choice", resolutionRole: "hea_hfn", requiresResolution: true },
    { name: "Mystery", climaxRole: "confrontation", resolutionRole: "resolution", requiresResolution: true },
    { name: "Three-Act", climaxRole: "climax", resolutionRole: "resolution", requiresResolution: false },
    { name: "Custom Experimental Arc", climaxRole: "confrontation", resolutionRole: "final_image", requiresResolution: false },
  ];
  for (const sample of cases) {
    const beats = [
      { id: "decisive", role: sample.climaxRole, label: "Decisive", description: "Achieve the beat's distinct dramatic change." },
      { id: "last", role: sample.resolutionRole, label: "Last", description: "Carry that change into the final image." },
    ];
    const allocation = new Map(beats.map((beat) => [beat.id, {
      minSections: 3,
      rationale: "A distinct authored dramatic development.",
      containerCounts: { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 3 },
    }]));
    const schema: any = buildSuggestionResponseSchema(beats, allocation, [], sample.name, "novel");
    assertOpenAIStrictSchema(schema);
    const climax = schema.properties.beats.properties.decisive.properties;
    const resolution = schema.properties.beats.properties.last.properties;
    assertEquals(climax.section_003.properties.dramaticFunction.enum, ["climax"], sample.name);
    if (sample.requiresResolution) {
      assertEquals(resolution.section_003.properties.dramaticFunction.enum, ["resolution"], sample.name);
    } else {
      // Don't invent requirements that the template's own contract lacks.
      assertEquals(resolution.section_003.properties.dramaticFunction.enum.includes("aftermath"), true);
    }
    assertEquals(climax.section_001.properties.dramaticFunction.enum.includes("climax"), true);
    assertEquals(resolution.section_001.properties.dramaticFunction.enum.includes("resolution"), true);
    assertEquals(climax.section_003.properties.container.enum, ["chapter"]);
    assertEquals(schema.properties.beats.properties.decisive.required.length, 3);
    assertEquals(schema.properties.beats.properties.last.required.length, 3);
    const withAccepted = buildSuggestionResponseSchema(beats, allocation, [], sample.name, "novel", [
      { storyArcBeatID: "decisive", dramaticFunction: "climax" },
      { storyArcBeatID: "last", dramaticFunction: "resolution" },
    ]) as any;
    assertEquals(withAccepted.properties.beats.properties.decisive.properties.section_003.properties.dramaticFunction.enum.includes("crisis"), true);
    assertEquals(withAccepted.properties.beats.properties.last.properties.section_003.properties.dramaticFunction.enum.includes("aftermath"), true);
    // No extra required field or rerun is introduced for non-novels and older array allocations.
    const legacy = buildSuggestionResponseSchema(beats, new Map(beats.map((beat) => [beat.id, { minSections: 2, rationale: "legacy" }])), [], sample.name, "novel") as any;
    assertEquals(legacy.properties.beats.properties.decisive.type, "array");
  }
});

Deno.test("architecture + allocation share one provider response, with recipe authority and optional enrichment", async () => {
  const req = { ...sparseRequest, requestedFormat: "novel" } as any;
  const architecture = {
    centralQuestion: "Can Mara rescue the family she betrayed?",
    characterCausality: "Mara's deception drives her brother to protect the wrong person, forcing a personal reckoning.",
    decisiveClimax: "Mara confronts the threat and saves her family at an irreversible personal cost.",
    endingConsequence: "The family survives, but their trust cannot return to its prior state.",
    deliberatelyOpenThreads: "The identity of the anonymous witness remains unknown.",
  };
  let calls = 0;
  let saved: any;
  const planned = await planSectionAllocation(req, "unused", async (_system: string, _user: string, maxTokens: number, format: any, action: string) => {
    calls++;
    assertEquals(action, "outline-plan");
    assertEquals(maxTokens >= 3500, true);
    const schema = format.json_schema.schema;
    assertEquals(schema.required.includes("storyArchitecture"), true);
    assertEquals(schema.properties.storyArchitecture.required.length, 5);
    return {
      content: JSON.stringify({
        storyArchitecture: architecture,
        allocations: [
          { beatIndex: 0, minSections: 2, containerCounts: { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 2 }, rationale: "Mara's lie launches the family conflict." },
          { beatIndex: 1, minSections: 2, containerCounts: { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 2 }, rationale: "Mara confronts the threat, pays the cost, and the family survives." },
        ],
      }),
      creditCostCharged: 1, remainingCredits: 99,
    } as any;
  }, [], { onArchitecture: (a) => { saved = a; } });
  assertEquals(calls, 1);
  assertEquals(saved, architecture);
  assertEquals(planned.size, 2);
  const { system, user } = buildPrompt(req, planned, [], undefined, saved);
  assertStringIncludes(system, "## Selected causal architecture from the allocation call");
  assertStringIncludes(system, architecture.decisiveClimax);
  assertStringIncludes(system, architecture.endingConsequence);
  assertStringIncludes(system, "Mara confronts the threat, pays the cost");
  assertStringIncludes(system, "resolution may only dramatize its consequences");
  const payload = JSON.parse(user);
  assertEquals(payload.allocation[0][1].minSections, planned.get("beat-1")?.minSections);
  assertEquals(payload.allocation[1][1].minSections, planned.get("beat-2")?.minSections);
  assertEquals(payload.planningContext.recipe, req.recipe);
});

Deno.test("allocation rejects malformed architecture instead of passing it to prose generation", () => {
  const good = {
    centralQuestion: "Who survives?",
    characterCausality: "Mara's betrayal forces her brother to fight.",
    decisiveClimax: "The siblings stop the threat together.",
    endingConsequence: "They survive estranged.",
    deliberatelyOpenThreads: "The witness's employer remains unknown.",
  };
  const allocations = [
    { beatIndex: 0, minSections: 1, rationale: "Cause" },
    { beatIndex: 1, minSections: 1, rationale: "Outcome" },
  ];
  const beats = sparseRequest.arcTemplate.beats;
  const parsed = parseAndValidateAllocation(JSON.stringify({ storyArchitecture: good, allocations }), beats);
  assertEquals(parsed.size, 2);
  for (const bad of [{ ...good, decisiveClimax: "" }, { ...good, unapprovedCanon: "A new authorial mandate" }, { ...good, endingConsequence: 5 }, []]) {
    assertThrows(() => parseAndValidateAllocation(JSON.stringify({ storyArchitecture: bad, allocations }), beats), Error);
  }
  // A persisted pre-upgrade allocation can still be replayed without a new
  // provider call; absence of architecture must not corrupt old checkpoints.
  assertEquals(parseAndValidateAllocation(JSON.stringify({ allocations }), beats).size, 2);
  assertStringIncludes(buildPrompt(sparseRequest as any, parsed).system, "Legacy checkpoint");
});

Deno.test("reader-experience-first architecture applies equally across genres without a hardcoded genre solution", () => {
  const recipes = [
    {
      name: "Horror / Escalating Dread",
      summary: "Three ruined drifters encounter an unknowable conspiracy whose ultimate danger may unfold over several books.",
      audienceNotes: "Grotesque psychological dread and surreal uncertainty.",
    },
    {
      name: "Comedy / Escalating Chaos",
      summary: "A vain grifter makes ridiculous promises that turn his failing town against him.",
      audienceNotes: "Absurd comedy driven by humiliation and escalating mistakes.",
    },
    {
      name: "Romance",
      summary: "Two estranged friends must choose whether to risk their friendship to become lovers.",
      audienceNotes: "Intimate, tender romantic tension and an earned emotional choice.",
    },
    {
      name: "Thriller",
      summary: "A whistleblower must expose the conspiracy and stop its planned raid before the book ends.",
      audienceNotes: "A high-stakes investigation that culminates in stopping the raid.",
    },
    {
      name: "Literary Drama",
      summary: "Siblings struggle after their mother's death, and one finally admits the truth without earning forgiveness.",
      audienceNotes: "Quiet moral ambiguity and painful family relationships.",
    },
  ];
  let genreNeutralSystem: string | undefined;
  for (const genre of recipes) {
    const request: any = {
      ...sparseRequest,
      requestedFormat: "novel",
      recipe: {
        ...sparseRequest.recipe,
        project: { ...sparseRequest.recipe.project, summary: genre.summary, audienceNotes: genre.audienceNotes },
      },
      arcTemplate: { ...sparseRequest.arcTemplate, name: genre.name },
    };
    const architecturePrompt = buildAllocationPrompt(request);
    const outlinePrompt = buildPrompt(request, new Map());
    assertStringIncludes(architecturePrompt.system, "Author-promised reader experience BEFORE plot machinery");
    assertStringIncludes(architecturePrompt.system, "The Story Arc governs dramatic progression, not a default set of plot devices");
    assertStringIncludes(architecturePrompt.system, "A premise fact does not itself create an objective");
    assertStringIncludes(architecturePrompt.system, "This rule applies to ALL genres");
    assertStringIncludes(architecturePrompt.system, "if the author explicitly requires a particular resolution in this volume, honor it");
    assertStringIncludes(outlinePrompt.system, "identify the intended reader experience from this recipe's specific genre, tone");
    assertStringIncludes(outlinePrompt.system, "Do not convert the authored reader experience into a generic mission");
    assertStringIncludes(outlinePrompt.system, "relationship milestone is authored and dramatically appropriate");
    assertEquals(JSON.parse(architecturePrompt.user).planningContext.recipe.project.summary, genre.summary);
    assertEquals(JSON.parse(architecturePrompt.user).planningContext.arc.name, genre.name);
    // The rule itself is shared: no code-level special treatment for the example horror recipe.
    if (genreNeutralSystem === undefined) genreNeutralSystem = architecturePrompt.system;
    else assertEquals(architecturePrompt.system, genreNeutralSystem);
  }
});

Deno.test("selected book-level climax persists into outline without forcing the wider threat to be defeated", () => {
  const request: any = {
    ...sparseRequest,
    recipe: {
      ...sparseRequest.recipe,
      project: { ...sparseRequest.recipe.project, summary: "Their accidental notoriety exposes a mystery whose stakes may reach other books." },
    },
  };
  const savedArchitecture = {
    centralQuestion: "Will Mara betray the people she promised to protect?",
    characterCausality: "Her lies and her friend's reckless choices force a costly decision.",
    decisiveClimax: "She chooses her friends and permanently loses the only safe home she knows.",
    endingConsequence: "The group survives, but their relationships cannot return to what they were.",
    deliberatelyOpenThreads: "The larger organization remains hidden and active.",
  };
  const outlinePrompt = buildPrompt(request, new Map(), [], undefined, savedArchitecture);
  assertStringIncludes(outlinePrompt.system, savedArchitecture.centralQuestion);
  assertStringIncludes(outlinePrompt.system, savedArchitecture.decisiveClimax);
  assertStringIncludes(outlinePrompt.system, savedArchitecture.deliberatelyOpenThreads);
  assertStringIncludes(outlinePrompt.system, "not necessarily resolve every external threat");
  assertStringIncludes(outlinePrompt.system, "the decisive BOOK-level outcome must be achieved in the climax role");
});

Deno.test("explicitly authored external victory and relationship resolution remain permitted in all genres", () => {
  for (const summary of [
    "An investigator must expose the named conspiracy and stop its planned raid before the book ends.",
    "Two lovers must reunite and confess their feelings before the end of this book.",
  ]) {
    const request: any = {
      ...sparseRequest,
      recipe: { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, summary } },
    };
    const architecturePrompt = buildAllocationPrompt(request);
    const outlinePrompt = buildPrompt(request, new Map());
    assertStringIncludes(architecturePrompt.system, "if the author explicitly requires a particular resolution in this volume, honor it");
    assertStringIncludes(outlinePrompt.system, "if a procedural solution, external victory, or relationship milestone is authored and dramatically appropriate, deliver it");
    assertEquals(JSON.parse(architecturePrompt.user).planningContext.recipe.project.summary, summary);
  }
});

Deno.test("allocation prompt selects causal outcome before sizing chapters without canonizing contractors", () => {
  const material: any = {
    characters: [{ id: "p1", label: "Inez", source: "planner", sourceReference: null, description: "Sells out a friend to gain control." }],
    antagonisticForces: [{ id: "p2", label: "Government contractor screen", source: "planner", sourceReference: null, description: "Generic audit program." }],
  };
  const req = { ...sparseRequest, requestedFormat: "novel", storyMaterialEnrichment: material } as any;
  const allocationPrompt = buildAllocationPrompt(req, deriveRecipeObligations(req.recipe));
  assertStringIncludes(allocationPrompt.system, "## Interpret the recipe AND selected Story Arc BEFORE choosing the story");
  assertStringIncludes(allocationPrompt.system, "The recipe governs premise, genre, intended experience");
  assertStringIncludes(allocationPrompt.system, "THEN write the already-selected beat-by-beat movements into allocation rationale");
  assertStringIncludes(allocationPrompt.system, "Only AFTER those story and arc decisions, budget and assign containerCounts");
  assertStringIncludes(allocationPrompt.system, "An invented institution, operation, investigation, or technical solution is not implied");
  const payload = JSON.parse(allocationPrompt.user);
  assertEquals(payload.planningContext.recipe, req.recipe);
  assertEquals(payload.planningContext.materialIndex.find((item: any) => item.id === "p2"), undefined);
  assertEquals(payload.planningContext.materialIndex.find((item: any) => item.id === "p1").source, "planner");
  assertStringIncludes(buildEnrichmentPrompt(req).system, "avoid defaulting to a government contractor");
  const original = buildPrompt(req, new Map(), [], material);
  assertStringIncludes(original.system, "Legacy checkpoint");
});

Deno.test("non-novel allocation keeps its legacy strict planner schema and prompt", async () => {
  let schema: any;
  const req = { ...sparseRequest, requestedFormat: "shortStory" } as any;
  const allocation = await planSectionAllocation(req, "unused", async (
    system: string, _user: string, _tokens: number, responseFormat: any,
  ) => {
    assertEquals(system.includes("Return containerCounts on each beat"), false);
    schema = responseFormat.json_schema.schema;
    return { content: JSON.stringify({ allocations: [
      { beatIndex: 0, minSections: 1, rationale: "opening" },
      { beatIndex: 1, minSections: 1, rationale: "ending" },
    ] }), creditCostCharged: 0, remainingCredits: 0 };
  });
  assertEquals("containerCounts" in schema.properties.allocations.items.properties, false);
  assertEquals(schema.properties.allocations.items.required, ["beatIndex", "minSections", "rationale"]);
  assertEquals(allocation.get("beat-1")?.minSections, 1);
  assertEquals(allocation.get("beat-2")?.minSections, 1);
});

Deno.test("container-aware allocation preserves typed slots inside the grace ceiling", () => {
  const beats = [{ id: "beat-1" }, { id: "beat-2" }];
  const counts = { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 15 };
  const allocation = parseAndValidateAllocation(JSON.stringify({
    allocations: beats.map((_, beatIndex) => ({
      beatIndex,
      minSections: 15,
      containerCounts: counts,
      rationale: "substantial novel development",
    })),
  }), beats);
  const req = { ...sparseRequest, requestedFormat: "novel", arcTemplate: { ...sparseRequest.arcTemplate, beats } } as any;
  const projectedWords = (30 * projectedExpectedTokens([{ container: "chapter" }])) / 1.3;
  assertEquals(Math.round(projectedWords), 126923);
  assertEquals(projectedWords > 125000, true);
  assertEquals(projectedWords < NOVEL_ACCEPTED_MAX_WORDS, true);
  const fitted = fitAllocationToNovelBudget(allocation, req);
  assertEquals(fitted.get("beat-1")?.containerCounts, counts);
  assertEquals(Array.from(fitted.values()).reduce((sum, plan) => sum + plan.minSections, 0), 30);
});

Deno.test("container-aware allocation completes and trims incomplete or oversized mixes", () => {
  const beats = [{ id: "beat-1" }, { id: "beat-2" }];
  const counts = { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 20 };
  const inconsistent = parseAndValidateAllocation(JSON.stringify({
    allocations: [
      { beatIndex: 0, minSections: 19, containerCounts: counts, rationale: "bad" },
      { beatIndex: 1, minSections: 20, containerCounts: counts, rationale: "bad" },
    ],
  }), beats);
  const normalizedIncomplete = fitAllocationToNovelBudget(inconsistent, { ...sparseRequest, requestedFormat: "novel" } as any);
  assertEquals(Array.from(normalizedIncomplete.values()).every((plan) => plan.containerCounts !== undefined), true);
  assertEquals(Array.from(normalizedIncomplete.values()).reduce((sum, plan) => sum + plan.minSections, 0) < 40, true);
  const allocation = parseAndValidateAllocation(JSON.stringify({
    allocations: [
      { beatIndex: 0, minSections: 20, containerCounts: counts, rationale: "large" },
      { beatIndex: 1, minSections: 20, containerCounts: counts, rationale: "large" },
    ],
  }), beats);
  const req = { ...sparseRequest, requestedFormat: "novel", arcTemplate: { ...sparseRequest.arcTemplate, beats } } as any;
  const normalized = fitAllocationToNovelBudget(allocation, req);
  assertEquals(Array.from(normalized.values()).every((plan) => plan.containerCounts !== undefined), true);
  assertEquals(Array.from(normalized.values()).reduce((sum, plan) => sum + plan.minSections, 0) < 40, true);
});

Deno.test("existing accepted sections reduce unknown-mix planning capacity", () => {
  const req = { ...sparseRequest, requestedFormat: "novel", existingSections: [{ container: "chapter" }, { container: "scene" }] } as any;
  const expected = Math.floor((125000 * 1.3 - 5500 - 1300) / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS);
  assertEquals(maximumBudgetedNewSections(req), expected);
  assertEquals(maximumContainerPlannedNewSections(req), expected);
});

Deno.test("novel length tolerances separate under-target expansion from overshoot grace", async () => {
  assertEquals(NOVEL_EXPANSION_MIN_WORDS, 112700);
  const nearTarget = Array.from({ length: 27 }, () => ({ container: "chapter" }));
  const belowTolerance = Array.from({ length: 26 }, () => ({ container: "chapter" }));
  assertEquals(Math.round(evaluateNovelScale(nearTarget).projectedWords), 114231);
  assertEquals(evaluateNovelScale(nearTarget).meetsMinimum, false, "115k remains the preferred planning goal");
  assertEquals(needsNovelExpansion(nearTarget), false, "114,231 words is within the 2% tolerance");
  assertEquals(needsNovelExpansion(belowTolerance), true, "110k words still needs development");
  assertEquals(needsNovelExpansion(belowTolerance, [{ container: "chapter" }]), false, "existing accepted work counts once");
  assertEquals(NOVEL_MAX_GRACE_WORDS, 5000);
  assertEquals(evaluateNovelScale(Array.from({ length: 30 }, () => ({ container: "chapter" }))).exceedsMaximum, false, "5,000-word grace remains accepted");
  assertEquals(evaluateNovelScale(Array.from({ length: 31 }, () => ({ container: "chapter" }))).exceedsMaximum, true, "accepted grace ceiling is still bounded");

  let expansionCalls = 0;
  const result = await progressivelyExpandOutline(
    nearTarget as any,
    new Set(["beat-1"]),
    async () => {
      expansionCalls++;
      return [];
    },
  );
  assertEquals(expansionCalls, 0, "no optional provider expansion for a negligible deficit");
  assertEquals(result.suggestions.length, 27);
  assertEquals(result.diagnostics.length, 0);
});

Deno.test("budget normalization preserves one-section coverage per uncovered beat", () => {
  const req = {
    ...sparseRequest,
    arcTemplate: {
      ...sparseRequest.arcTemplate,
      beats: Array.from({ length: 3 }, (_, index) => ({ id: `beat-${index + 1}`, label: `Beat ${index + 1}` })),
    },
  } as any;
  const allocation = new Map<string, any>(req.arcTemplate.beats.map((beat: any) => [beat.id, {
    minSections: 20,
    rationale: "material-rich movement",
  }]));
  const fitted = fitAllocationToNovelBudget(allocation, req);
  assertEquals(Array.from(fitted.values()).every((plan) => plan.minSections > 0), true);
  assertEquals(Array.from(fitted.values()).every((plan) => plan.coverageMinimum === 1), true);
  assertEquals(allocationShortfalls([], fitted).every((entry) => entry.intended === 20 && entry.shortfall === 20), true);
  assertEquals(
    allocationDeficits([], fitted).map(({ beatID, required, actual, missing }) => ({ beatID, required, actual, missing })),
    Array.from(fitted.entries()).map(([beatID, plan]) => ({
      beatID, required: plan.minSections, actual: 0, missing: plan.minSections,
    })),
  );
});

Deno.test("budget normalization preserves uncovered beats when the existing draft is large", () => {
  const req = { ...sparseRequest, existingSections: Array.from({ length: 30 }, () => ({ container: "chapter" })) } as any;
  const allocation = new Map([
    ["beat-1", { minSections: 1, rationale: "opening" }],
    ["beat-2", { minSections: 1, rationale: "ending" }],
  ]);
  const fitted = fitAllocationToNovelBudget(allocation, req);
  assertEquals(Array.from(fitted.values()).every((plan) => plan.minSections === 1), true);
  assertEquals(Array.from(fitted.values()).every((plan) => plan.containerCounts !== undefined), true);
});

Deno.test("allocation repair is terminal when a resumed checkpoint starts after round three", () => {
  const deficits = [{ beatID: "beat-2", required: 1, actual: 0, missing: 1 }];
  assertEquals(allocationRepairExhausted(deficits, [{ round: MAX_EXPANSION_ROUNDS, status: "completed" } as any]), true);
  assertEquals(allocationRepairExhausted(deficits, [{ round: MAX_EXPANSION_ROUNDS - 1, status: "completed" } as any]), false);
});

Deno.test("final allocation coverage enforces the budget-normalized allocation floor", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 5, allocationMinimum: 5, coverageMinimum: 1, rationale: "opening" }],
  ]);
  const suggestions = [{ storyArcBeatID: "beat-1" }] as any;
  assertEquals(allocationDeficits(suggestions, allocation), [{
    beatID: "beat-1", required: 5, actual: 1, missing: 4,
  }]);
});

Deno.test("final allocation coverage reports a repair deficit when a beat is omitted", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 1, rationale: "opening" }],
    ["beat-2", { minSections: 1, rationale: "ending" }],
  ]);
  const suggestions = [{ storyArcBeatID: "beat-1" }] as any;
  assertEquals(allocationDeficits(suggestions, allocation), [{
    beatID: "beat-2", required: 1, actual: 0, missing: 1,
  }]);
  assertThrows(
    () => assertAllocationCoverage(suggestions, allocation, "final outline"),
    AllocationCoverageValidationError,
    "final outline: beat beat-2 returned 0 sections; minimum is 1",
  );
});

Deno.test("planner prompt groups one existing section onto its linked beat", () => {
  const section = { storyArcBeatID: "beat-1", recipeRequirementIDs: ["R1"] };
  const { system, user } = buildAllocationPrompt({ ...sparseRequest, existingSections: [section] } as any);
  assertEquals(
    system.includes("when accepted sections already contribute to a beat, minSections is only the additional sections still required"),
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
    system.includes("minSections is only the additional sections still required"),
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
    system.includes("minSections is only the additional sections still required"),
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
  assertEquals(system.includes("Opening Image: complete first-pass allocation: 3 sections"), true,
    "beat-1 residual 3 must reach buildPrompt unchanged (pre-fix would have produced 1)");
  assertEquals(system.includes("Break into Two: complete first-pass allocation: 0 sections"), true,
    "beat-2 residual 0 must reach buildPrompt unchanged (pre-fix would have clamped -1 to 0)");
  assertEquals(system.includes("Midpoint: complete first-pass allocation: 2 sections"), true,
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
  assertEquals(system.includes("Opening Image: complete first-pass allocation: 3 sections"), true,
    "beat-1 residual 3 must reach buildPrompt unchanged (pre-fix would have produced 1)");
  assertEquals(system.includes("Break into Two: complete first-pass allocation: 2 sections"), true,
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
  assertEquals(system.includes("Opening Image: complete first-pass allocation: 0 sections"), true,
    "beat-1 residual 0 must reach buildPrompt unchanged (pre-fix would have clamped -1 to 0)");
  assertEquals(system.includes("Break into Two: complete first-pass allocation: 0 sections"), true,
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

Deno.test("allocation handoff preserves section budgets without importing plot rationales", () => {
  const sentinel = "ALLOCATOR_ONLY_GOVERNMENT_RELAY_RESCUE_CLIMAX";
  for (const format of ["novel", "shortStory"]) {
    const novel = format === "novel";
    const firstCounts = { scene: 0, developedScene: 1, setPiece: 0, sceneSequence: 0, chapter: 1 };
    const finalCounts = { scene: 0, developedScene: 0, setPiece: 0, sceneSequence: 0, chapter: 1 };
    const first = {
      minSections: novel ? 2 : 3,
      ...(novel ? { containerCounts: firstCounts } : {}),
      rationale: sentinel,
    };
    const last = {
      minSections: 1,
      ...(novel ? { containerCounts: finalCounts } : {}),
      rationale: "ALLOCATOR_ONLY_REPEAT_THE_SAME_FINALE",
    };
    const allocation = new Map<string, any>([["beat-1", first], ["beat-2", last]]);
    const request = { ...sparseRequest, requestedFormat: format } as any;
    const prompt = buildPrompt(request, allocation);
    const renamedRationale = new Map<string, any>([
      ["beat-1", { ...first, rationale: "Allocate room for whatever the author requires." }],
      ["beat-2", { ...last, rationale: "No specific plot prescribed." }],
    ]);
    // Changing only the allocator's speculative plot must not change either
    // model-facing prompt, for novels or other formats.
    assertEquals(buildPrompt(request, renamedRationale), prompt, format);
    assertEquals(prompt.system.includes(sentinel), false, format);
    assertEquals(prompt.user.includes(sentinel), false, format);
    assertEquals(prompt.system.includes(last.rationale), false, format);
    assertEquals(prompt.system.includes(`complete first-pass allocation: 2 sections`), novel, format);
    assertEquals(prompt.system.includes(`minimum 3 sections`), !novel, format);
    if (novel) {
      assertStringIncludes(prompt.system, "planned containers: developedScene=1, chapter=1");
      assertStringIncludes(prompt.system, "ordered slots: section_001=developedScene, section_002=chapter");
      assertStringIncludes(prompt.system, "section counts, ordered container types, and Story Arc beat placement");
    }
    // This experiment removes only the creative instructions, not the stored
    // allocation values or the behavioral effect of count/container choices.
    assertEquals(allocation.get("beat-1")?.rationale, sentinel);
    const changedCount = new Map<string, any>([
      ["beat-1", { ...first, minSections: first.minSections + 1 }],
      ["beat-2", last],
    ]);
    assertEquals(buildPrompt(request, changedCount).system === prompt.system, false, format);
  }
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
  assertEquals(plannerPrompt.system.includes("minSections is only the additional sections still required"), true);
  assertEquals(system.includes("minimum is a floor for dramatic coverage, not a target or maximum"), false);
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
  assertEquals(prompt.includes("Allocate the available word budget across the Story Arc beats before choosing sections."), true);
  assertEquals(prompt.includes("Selected motifs are supporting material, not a quota"), true);
  assertEquals(prompt.includes("do not repeat a motif merely to prove that the outline remembers it"), true);
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

Deno.test("deterministic allocation budget constraints do not trigger a paid retry", async () => {
  let calls = 0;
  const req = {
    ...sparseRequest,
    requestedFormat: "novel",
    existingSections: Array.from({ length: 30 }, () => ({ container: "chapter" })),
  } as any;
  const allocation = await planSectionAllocation(req, "test-key", (async () => {
    calls++;
    return { content: JSON.stringify({ allocations: [
      { beatIndex: 0, minSections: 1, rationale: "opening" },
      { beatIndex: 1, minSections: 1, rationale: "closure" },
    ] }), creditCostCharged: 1, remainingCredits: 1 };
  }) as any);
  assertEquals(calls, 1);
  assertEquals(allocation.size, 2);
});

Deno.test("global buildPrompt includes the requested concrete-event guardrails", () => {
  const { system } = buildPrompt(sparseRequest as any, new Map());
  assertEquals(system.includes("Every section must commit to one canonical event."), true);
  assertEquals(system.includes("Each section must produce a materially new resulting state."), true);
  assertEquals(system.includes("The Resurrection must not replay the Ordeal at greater scale."), true);
  assertEquals(system.includes("Planner categories are possible story ingredients, not an already chosen plot"), true);
  assertEquals(system.includes("Author-supplied names and facts"), true);
  assertEquals(system.includes("A revelation, discovery, confession, or relationship change may occur only once as the primary dramatic event."), true);
  assertEquals(system.includes("Maintain the established narrative POV mode across the outline unless the supplied recipe explicitly requires a POV change."), true);
  assertEquals(system.includes("Every section must make a distinct irreversible contribution: reveal new information, force a consequential choice, alter a relationship, or materially change the tactical situation."), true);
  assertEquals(system.includes("Whenever practical, relationship and character-arc turns should cause or complicate plot events rather than occurring as isolated character-development scenes."), true);
  assertEquals(system.includes("## Premise outcome and ending causality"), true);
  assertEquals(system.includes("Before drafting sections, identify the intended reader experience from this recipe's specific genre, tone"), true);
  assertEquals(system.includes("the decisive climax, the irreversible character/world change it causes"), true);
  assertEquals(system.includes("Do not let a subsequent section restart the same countdown"), true);
  assertEquals(system.includes("must deliver the premise's consequential promise"), true);
  assertEquals(system.includes("Favor specific, memorable events and evocative section titles over functional briefing, regrouping, mapping, or explanatory scenes."), true);
});

Deno.test("global buildPrompt favors character-driven dramatic selection without overriding recipe or continuity", () => {
  const { system } = buildPrompt(sparseRequest as any, new Map());
  assertStringIncludes(system, "## Character-Driven Dramatic Selection");
  assertStringIncludes(system, "most entertaining, original, surprising, and dramatically compelling option");
  assertStringIncludes(system, "distinctive personalities, desires, flaws, obsessions, relationships, and unpredictable decisions");
  assertStringIncludes(system, "rather than serving as informants, exposition, transportation, or other functional devices");
  assertStringIncludes(system, "outrageous encounters, reckless decisions, dark humor, grotesque absurdity");
  assertStringIncludes(system, "Preserve intended adult intensity without sanitizing it");
  assertStringIncludes(system, "climax emerge from the protagonists' distinctive choices and behavior");
  assertStringIncludes(system, "Do not force randomness, spectacle, or artificial chaos into restrained stories");
  assertStringIncludes(system, "Preserve causality, continuity, and authorial intent");
  assertStringIncludes(system, "The recipe is the governing creative brief");
  assertStringIncludes(system, "## Narrative-state continuity");
});


Deno.test("outliner selects character-caused events before deciding its climax or slots", () => {
  const material: any = {
    ...enrichmentFixture(),
    characters: [
      { id: "vee", label: "Vee Sato, the attention broker", source: "planner", description: "Leaks the trio's location to manufacture a viral spectacle." },
      { id: "pike", label: "Marlon Pike, the security consultant", source: "planner", description: "Provokes an unstable man to improve his contract." },
      { id: "fred", label: "Fred", source: "recipe", description: "An authored protagonist." },
    ],
  };
  const { system, user } = buildPrompt({ ...sparseRequest, storyMaterialEnrichment: material } as any, new Map(), [], material);
  const payload = JSON.parse(user);
  assertEquals(payload.planningContext.characterDecisionCandidates.map((candidate: any) => candidate.id), ["vee", "pike"]);
  assertStringIncludes(payload.planningContext.characterDecisionCandidates[0].description, "Leaks the trio");
  assertEquals(payload.planningContext.recipe, sparseRequest.recipe);
  assertEquals(payload.planningContext.materialIndex.some((item: any) => item.id === "pike"), true);
  assertStringIncludes(system, "## Character-caused story selection before plot construction");
  assertStringIncludes(system, "First choose the story's causal drivers, BEFORE deciding");
  assertStringIncludes(system, "what they want, the distinctive choice they make, whose plan it derails");
  assertStringIncludes(system, "Do not force every generated character into the outline");
  assertStringIncludes(system, "do not replace a distinctive, consequential candidate with a nameless official");
  assertStringIncludes(system, "if substituting an interchangeable job title would leave the important events unchanged");
  assertEquals(system.indexOf("## Character-caused story selection before plot construction") < system.indexOf("## Premise outcome and ending causality"), true);
  assertStringIncludes(system, "preserve it, but still let authored character agency");
  assertStringIncludes(system, "Preserve the author's tone, adult intensity, ambiguity, restrained genres");
  assertStringIncludes(system, "Before drafting sections, identify the intended reader experience from this recipe's specific genre, tone");
  assertStringIncludes(system, "## Narrative-state continuity");
});

Deno.test("character integration diagnostic rejects generic label words and distinguishes cameos from causal anchors", () => {
  const material: any = {
    ...enrichmentFixture(),
    characters: [
      { id: "briggs", label: "Garnet Briggs, the deputy who hates being a meme", source: "planner" },
      { id: "vee", label: "Vee Sato, the attention broker", source: "planner" },
      { id: "pike", label: "Marlon Pike, the celebrated security consultant", source: "planner" },
      { id: "inez", label: "Inez Bell, the motel night auditor", source: "planner" },
      { id: "rusk", label: "Dale Rusk, the roadside livestream preacher", source: "planner" },
      { id: "nash", label: "Merritt Nash, Millie's handler", source: "planner" },
      { id: "recipe-character", label: "Fred", source: "recipe" },
    ],
  };
  const suggestions: any[] = [
    {
      title: "Being watched", summary: "The public's attention forces a security response. Inez counts the motel receipts.",
      dramaticEvent: "Rusk edits a livestream to exploit the attack.", resultingChange: "Ted gains a following.",
      entryState: "The crowd is tense.", terminalState: "The crowd leaves.",
    },
    {
      title: "Handler's lie", summary: "The hybrid operation loses control.",
      dramaticEvent: "Nash lies to Millie about an extraction.", resultingChange: "Millie breaks with Nash.",
      entryState: "They are hidden.", terminalState: "Millie leaves him.",
    },
  ];
  const integration = analyzePlannerCharacterIntegration(suggestions, material);
  assertEquals(integration, {
    absent: ["briggs", "vee", "pike"],
    mentionedWithoutCausalAnchor: ["inez"],
    withCausalAnchor: ["rusk", "nash"],
  });
  assertEquals(analyzePlannerCharacterIntegration(suggestions, undefined), {
    absent: [], mentionedWithoutCausalAnchor: [], withCausalAnchor: [],
  });
  assertEquals(collectAdvisoryOutlineQuality(suggestions, material).plannerCharacterIntegration, integration);
});

Deno.test("global buildPrompt requires continuity review while allowing valid offscreen transitions", () => {
  const { system } = buildPrompt(sparseRequest as any, new Map());
  assertStringIncludes(system, "evaluate the complete proposed sequence in canonical order");
  assertStringIncludes(system, "Each section must begin from a state that plausibly follows the previous section's terminal state");
  assertStringIncludes(system, "Apply the same continuity expectations across Story Arc boundaries");
  assertStringIncludes(system, "Legitimate offscreen travel, elapsed time, flashbacks, parallel action");
  assertStringIncludes(system, "if a character must participate in an event at one location but has already departed for another");
});

Deno.test("global buildPrompt communicates whole-outline dramatic comparison and resulting-change priority", () => {
  const { system } = buildPrompt(sparseRequest as any, new Map());
  // Whole-outline dramatic comparison guidance.
  assertEquals(
    system.includes("Evaluate the WHOLE proposed novel"),
    true,
    "must compare across the whole proposed novel, not just adjacent sections",
  );
  assertEquals(
    system.includes("primarily by the dramaticEvent, resultingChange, and terminalState fields"),
    true,
    "novelty must be anchored in dramaticEvent/resultingChange/terminalState",
  );
  // Differentiation guidance must preserve length/allocation.
  assertEquals(
    system.includes("Do not solve redundant dramatic work by adding sections"),
    true,
    "allocation and novel length must remain authoritative",
  );
  assertEquals(
    system.includes("Allocation, minimum section coverage, and the novel length policy remain authoritative"),
    true,
  );
  // Earned place principle.
  assertEquals(
    system.includes("Each section should earn its place by changing something the previous sections have not already changed"),
    true,
  );
  // Cross-beat continuity.
  assertEquals(
    system.includes("A Story Arc beat transition does NOT reset dramatic novelty"),
    true,
    "later beat must inherit earlier beat's changed conditions",
  );
  // Resurrection must depend on the Ordeal's changed condition.
  assertEquals(
    system.includes("The Resurrection must depend on that changed condition"),
    true,
  );
  // Global self-comparison.
  assertEquals(
    system.includes("compare the proposed sequence of resultingChange and terminalState values across the whole outline"),
    true,
    "planner must compare resultingChange/terminalState across the whole outline",
  );
  // PR #617 refinement: the obsolete "combine them" instruction
  // contradicted the preserve-allocation rule and re-introduced the
  // exact length-risk this PR is supposed to avoid. It must be gone.
  assertEquals(
    system.includes("combine them"),
    false,
    "obsolete 'combine them' instruction must be removed from the prompt",
  );
  // The replacement anti-shrink phrasing must be present.
  assertEquals(
    system.includes("Preserve the amount of story; increase the amount of distinct story"),
    true,
    "anti-shrink / preserve-length phrasing must be present",
  );
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

Deno.test("terminalBeat replaces UUID and END with the existing closing action", () => {
  const beatIds = new Set(["beat-1", "beat-2"]);
  const base = {
    title: "Freezer Door",
    summary: "Mara seals the freezer.",
    container: "chapter",
    pov: "thirdPersonLimited",
    entryState: "The creature has entered the freezer.",
    dramaticEvent: "Mara slams the freezer door and locks the ratcoon inside.",
    resultingChange: "The freezer becomes a temporary containment point.",
    terminalState: "The ratcoon scratches behind the sealed door.",
    dramaticFunction: "escalation",
    storyArcBeatID: "beat-1",
    recipeRequirementIDs: [],
  };
  const uuidResult = validateSuggestions({
    suggestions: [{ ...base, terminalBeat: "A77B4AFD-AEF0-40E9-983F-3CA5105E1DD6" }],
  }, beatIds).suggestions[0];
  const endResult = validateSuggestions({
    suggestions: [{ ...base, terminalBeat: "END", storyArcBeatID: "beat-2" }],
  }, beatIds).suggestions[0];

  assertEquals(uuidResult.terminalBeat, base.terminalState);
  assertEquals(endResult.terminalBeat, base.terminalState);
  assertEquals(uuidResult.storyArcBeatID, "beat-1");
  assertEquals(endResult.storyArcBeatID, "beat-2");
  assertEquals(uuidResult.entryState, base.entryState);
  assertEquals(uuidResult.dramaticEvent, base.dramaticEvent);
  assertEquals(uuidResult.resultingChange, base.resultingChange);
  assertEquals(uuidResult.terminalState, base.terminalState);
  assertEquals(normalizeTerminalBeat({ ...base, terminalBeat: "The door clicks shut." }, beatIds), "The door clicks shut.");
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

Deno.test("novel outline handoff treats allocation as complete and projects mixed containers honestly", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 15, rationale: "rising material" }],
    ["beat-2", { minSections: 14, rationale: "resolution material" }],
  ]);
  const novelPrompt = buildPrompt({ ...sparseRequest, requestedFormat: "novel" } as any, allocation).system;
  assertEquals(novelPrompt.includes("## Complete first-pass allocation"), true);
  assertEquals(novelPrompt.includes("not a minimum-only Story Arc coverage floor"), true);
  assertEquals(novelPrompt.includes("complete first-pass allocation: 15 sections"), true);
  assertEquals(novelPrompt.includes("The allocator already priced each planned section at its actual midpoint"), true);
  assertEquals(novelPrompt.includes("Routine book-length development belongs in the first pass"), true);
  assertEquals(novelPrompt.includes("## Use the minimum-only allocation"), false);

  // Production-shaped deterministic fixture: 29 allocated units, only eight
  // chapters, with the remainder using shorter but valid container types.
  const productionShape = [
    ...Array.from({ length: 8 }, () => ({ container: "chapter" })),
    ...Array.from({ length: 15 }, () => ({ container: "developedScene" })),
    ...Array.from({ length: 5 }, () => ({ container: "setPiece" })),
    { container: "sceneSequence" },
  ];
  assertEquals(productionShape.length, 29);
  assertEquals(Math.round(projectedExpectedTokens(productionShape) / 1.3), 77115);
  assertEquals(Math.round(projectedExpectedTokens(Array.from({ length: 29 }, () => ({ container: "chapter" }))) / 1.3), 122692);

  const nonNovelPrompt = buildPrompt({ ...sparseRequest, requestedFormat: "shortStory" } as any, allocation).system;
  assertEquals(nonNovelPrompt.includes("## Use the minimum-only allocation"), true);
  assertEquals(nonNovelPrompt.includes("## Complete first-pass allocation"), false);
});

Deno.test("novel planning exposes container semantics and projected-size expansion", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const allocationPrompt = buildAllocationPrompt(sparseRequest as any).system;
  assertEquals(allocationPrompt.includes("complete first-pass book at approximately 115,000 projected words"), true);
  assertEquals(allocationPrompt.includes("each known container's midpoint"), true);
  assertEquals(allocationPrompt.includes("3,500-token mixed-section planning estimate"), true);
  assertEquals(allocationPrompt.includes("about 43 sections at the preferred target"), true);
  assertEquals(allocationPrompt.includes("minSections is the intended complete first-pass allocation"), true);
  assertEquals(allocationPrompt.includes("a beat with sufficient existing coverage must remain at 0"), true);
  assertEquals(allocationPrompt.includes("Do not add sections to a sufficiently covered beat"), true);
  assertEquals(source.includes("targetSections"), false);
  assertEquals(source.includes("maxSections"), false);
  assertEquals(source.includes("fitAllocationToNovelTarget"), false);
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
  assertEquals(outlinePrompt.includes("Novel length policy"), true);
  assertEquals(outlinePrompt.includes("Every defining behavior, event, or conflict explicitly specified by the author must have a concrete realization"), true);
  assertEquals(outlinePrompt.includes("dramaticEvent, resultingChange, or terminalState"), true);
  assertEquals(outlinePrompt.includes("Mentioning it in a summary, labeling a character with the trait, or assigning a recipe requirement ID does not constitute realization"), true);
  assertEquals(outlinePrompt.includes("Preserve creative freedom over how and when the requirement is realized"), true);
  assertEquals(outlinePrompt.includes("125,000-word hard cap"), true);
  assertEquals(outlinePrompt.includes("Fit the complete story package into the budget"), true);
  assertEquals(outlinePrompt.includes("Existing accepted sections already contribute to the complete projection"), true);
  assertEquals(outlinePrompt.includes("do not drop story material"), true);
  assertEquals(outlinePrompt.includes("expected 800-1,800 tokens"), true);
  assertEquals(outlinePrompt.includes("Recipe realization priority"), true);
  assertEquals(outlinePrompt.includes("governing creative brief"), true);
  assertEquals(outlinePrompt.includes("Novel-ready section titles"), true);
  assertEquals(outlinePrompt.includes("Do not restate or lightly rephrase"), true);
  assertEquals(outlinePrompt.includes("evocative fiction headings, not outline summaries"), true);
  assertEquals(outlinePrompt.includes("takes the hit"), true);
  assertEquals(outlinePrompt.includes("Character + verb + outcome"), true);
  assertEquals(outlinePrompt.includes("suitable for a novel outline or novel-ready table of contents"), true);
  assertEquals(projectedTokenRange([
    { container: "scene" }, { container: "developedScene" },
  ]), [2300, 4800]);
  assertEquals(projectedExpectedTokens([{ container: "scene" }]), 1300);
  assertEquals(evaluateNovelScale([{ container: "scene" }]).meetsMinimum, false);
  assertEquals(evaluateNovelScale([{ container: "scene" }]).minimumWords, 115000);
  assertEquals(projectedExpectedTokens([{ container: "sceneSequence" }]), 5000);
  assertEquals(projectedExpectedTokens([{ container: "scene" }, { container: "scene" }]), 2600);
  assertEquals(needsNovelExpansion([{ container: "sceneSequence" }]), true);
  assertEquals(needsNovelExpansion([{ container: "scene" }]), true);
  const expansion = buildExpansionPrompt(sparseRequest as any, [{
    title: "Setup", summary: "A setup", container: "scene", pov: "thirdPersonLimited",
    terminalBeat: "The choice is made", storyArcBeatID: "beat-1",
  }]);
  assertEquals(expansion.system.includes("Add distinct events, consequences"), true);
  assertEquals(expansion.system.includes("used-event ledger"), true);
  assertEquals(expansion.system.includes("advance the recipe's authored premise"), true);
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

Deno.test("first-pass deduplication removes cross-beat replay and keeps the first section", () => {
  const base = {
    title: "Same Event", summary: "Same summary", container: "chapter", pov: "thirdPersonLimited",
    terminalBeat: "The state changes.", entryState: "Before.", dramaticEvent: "The same event.",
    resultingChange: "The same change.", terminalState: "After.", dramaticFunction: "escalation",
  };
  const result = removeDuplicateOutlineSections([
    { ...base, storyArcBeatID: "beat-1" },
    { ...base, storyArcBeatID: "beat-2" },
  ] as any);
  assertEquals(result.suggestions.length, 1);
  assertEquals(result.suggestions[0].storyArcBeatID, "beat-1");
  assertEquals(result.removed, [{ title: "Same Event", index: 1 }]);
});

Deno.test("outline rejects repeated titles across Story Arc beats", () => {
  const section = (beat: string) => ({
    title: "The Archive Handoff", summary: "A distinct handoff.", container: "scene",
    pov: "thirdPersonLimited", terminalBeat: "The handoff ends", storyArcBeatID: beat,
  });
  assertThrows(() => assertDistinctOutlineTitles([section("beat-1"), section("beat-2")] as any), Error, "duplicate outline title across sections");
  assertDistinctOutlineTitles([section("beat-1"), { ...section("beat-2"), title: "The Cooling Annex" }] as any);
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
  const initial = sceneOutline(111).map((section, index) => ({
    ...section,
    storyArcBeatID: index < 56 ? "beat-1" : "beat-2",
  }));
  const calls: Array<{ beatID: string; currentSections: number }> = [];
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1", "beat-2"]),
    async (_current, _context, beat) => {
      if (!beat) throw new Error("beat context missing");
      calls.push({ beatID: beat.beatID, currentSections: beat.currentSections.length });
      return [
        expansionSection(`${beat.beatID} addition 1`, "scene", beat.beatID),
        expansionSection(`${beat.beatID} addition 2`, "scene", beat.beatID),
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
    { beatID: "beat-1", currentSections: 56 },
  ]);
  assertEquals(result.suggestions.length, 113);
  assertEquals(result.suggestions.filter((section) => section.storyArcBeatID === "beat-1").length, 58);
  assertEquals(result.suggestions.filter((section) => section.storyArcBeatID === "beat-2").length, 55);
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
    desiredWords: [115000, 125000],
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
  const existing = sceneOutline(94);
  const generated = sceneOutline(21);
  const deltaOnly = evaluateNovelScale(generated);
  const complete = evaluateNovelScale(generated, existing);
  assertEquals(deltaOnly.meetsMinimum, false);
  assertEquals(complete.meetsMinimum, true);
  assertEquals(complete.projectedWords >= 115000, true);
});

Deno.test("existing accepted sections can prevent unnecessary expansion", async () => {
  const existing = sceneOutline(115);
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

Deno.test("first-pass validation rejects a missing allocated Story Arc beat", () => {
  const allocation = new Map([
    ["beat-1", { minSections: 1, rationale: "opening" }],
    ["beat-2", { minSections: 1, rationale: "aftermath" }],
  ]);
  const section = (title: string, storyArcBeatID: string) => ({
    title,
    summary: `${title} changes the story.`,
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: `${title} ends with a consequential turn.`,
    storyArcBeatID,
  });
  assertThrows(
    () => validateSuggestions(
      { suggestions: [section("Opening", "beat-1")] },
      new Set(["beat-1", "beat-2"]),
      allocation,
    ),
    AllocationCoverageValidationError,
    "beat beat-2 returned 0 sections; minimum is 1",
  );
});

Deno.test("dynamic response contract removes model-owned beat IDs and target/max allocation semantics", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  const schema = buildSuggestionResponseSchema([{ id: "beat-1" }], new Map([["beat-1", { minSections: 2, rationale: "coverage" }]]), [], "", "novel") as any;
  assertEquals(schema.properties.beats.properties["beat-1"].items.properties.storyArcBeatID, undefined);
  assertEquals(schema.properties.beats.properties["beat-1"].maxItems, schema.properties.beats.properties["beat-1"].minItems);
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

Deno.test("non-novel response schema treats allocation as a minimum", () => {
  const schema = buildSuggestionResponseSchema(
    [{ id: "beat-1" }],
    new Map([["beat-1", { minSections: 2, rationale: "coverage" }]]),
    [],
    "",
    "shortStory",
  ) as any;
  assertEquals(schema.properties.beats.properties["beat-1"].minItems, 2);
  assertEquals(schema.properties.beats.properties["beat-1"].maxItems > 2, true);
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
  const initial = sceneOutline(65);
  const result = await progressivelyExpandOutline(initial as any, new Set(["beat-1"]), async (current, context) => {
    calls.push({ current: current.length, context });
    return context.round === 1
      ? Array.from({ length: 10 }, (_, i) => expansionSection(`Round 1 ${i + 1}`, "scene"))
      : Array.from({ length: 10 }, (_, i) => expansionSection(`Round 2 ${i + 1}`, "chapter"));
  });
  assertEquals(calls.map((call) => call.context.round), [1, 2]);
  assertEquals(calls[0].current, 65);
  assertEquals(calls[1].current, 75);
  assertEquals(result.diagnostics.length, 2);
  assertEquals(result.diagnostics[0].sectionCountBefore, 65);
  assertEquals(result.diagnostics[0].sectionCountAfter, 75);
  assertEquals(result.diagnostics[1].sectionCountBefore, 75);
  assertEquals(result.diagnostics[1].sectionCountAfter, 85);
  assertEquals(result.warnings, []);
});

Deno.test("required allocation coverage expands even when novel scale is already sufficient", async () => {
  const initial = sceneOutline(115);
  let calls = 0;
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1"]),
    async () => {
      calls++;
      return [expansionSection("Coverage repair", "scene")];
    },
    undefined,
    { coverageGate: (current) => current.length < 116 },
  );
  assertEquals(calls, 1);
  assertEquals(result.suggestions.length, 116);
});

Deno.test("optional enrichment expansion is global when no allocation deficit identifies a beat", async () => {
  const initial = [
    ...sceneOutline(114),
    { ...sceneOutline(1)[0], storyArcBeatID: "beat-2" },
  ];
  const calls: Array<string | undefined> = [];
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1", "beat-2"]),
    async (_current, context, beat) => {
      calls.push(beat?.beatID);
      return context.round === 1
        ? [expansionSection("Later Beat Material", "scene", "beat-2")]
        : [];
    },
    undefined,
    { qualityGate: () => true },
  );
  assertEquals(calls, [undefined, undefined]);
  assertEquals(result.suggestions.at(-1)?.storyArcBeatID, "beat-2");
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
  assertEquals((failure as NovelScalePlanningError).message.includes("2% tolerance for the 115,000-word preferred planning target"), true);
});

Deno.test("stale expansion anchors append within their beat while exact anchors remain stable", () => {
  const original = [
    expansionSection("Setup", "scene", "beat-1"),
    expansionSection("Beat Two Opening", "scene", "beat-2"),
    expansionSection("Beat Two Closer", "scene", "beat-2"),
  ];
  const stale = validateExpansionAdditions({
    suggestions: [expansionSection("Beat Two Addition", "scene", "beat-2", "Removed section")],
  }, new Set(["beat-1", "beat-2"]), original as any);
  assertEquals(stale[0].insertAfterTitle, null);
  assertEquals(mergeExpansionAdditions(original as any, stale as any).map((s) => s.title), [
    "Setup", "Beat Two Opening", "Beat Two Closer", "Beat Two Addition",
  ]);

  const exact = validateExpansionAdditions({
    suggestions: [expansionSection("Anchored Addition", "scene", "beat-2", "Beat Two Opening")],
  }, new Set(["beat-1", "beat-2"]), original as any);
  assertEquals(exact[0].insertAfterTitle, "Beat Two Opening");
  assertEquals(mergeExpansionAdditions(original as any, exact as any).map((s) => s.title), [
    "Setup", "Beat Two Opening", "Anchored Addition", "Beat Two Closer",
  ]);
});

Deno.test("hard-valid novel preserves the outline when optional expansion validation fails", async () => {
  const initial = sceneOutline(115);
  let providerCalls = 0;
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1"]),
    async () => {
      providerCalls++;
      throw new ExpansionValidationError("expansion placement crosses arc beats");
    },
    undefined,
    { qualityGate: () => true },
  );
  assertEquals(providerCalls, 1);
  assertEquals(result.suggestions.length, initial.length);
  assertEquals(result.diagnostics[0].status, "invalid");
  assertEquals(result.warnings.length, 1);
});

Deno.test("optional expansion persists rejected provider attempt diagnostics", async () => {
  const initial = sceneOutline(115);
  let diagnostic: any = null;
  const attempt = {
    round: 1,
    beatID: "beat-1",
    sectionCountBefore: initial.length,
    projectedTokensBefore: 100_000,
    returnedCount: 4,
    acceptedCount: 0,
    candidateTitles: ["Candidate A", "Candidate B"],
    candidateContainers: ["chapter", "chapter"],
    projectedTokensAfter: 170_000,
    status: "rejected" as const,
    error: "projected novel scale exceeded 125,000-word hard cap",
  };
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1"]),
    async () => { throw new ExpansionValidationError(attempt.error, attempt); },
    async (roundDiagnostic) => { diagnostic = roundDiagnostic; },
    { qualityGate: () => true },
  );
  assertEquals(result.suggestions.length, initial.length);
  assertEquals(diagnostic.attempts, [attempt]);
});

Deno.test("budget fitting records partial acceptance and discarded candidates", () => {
  const current = Array.from({ length: 20 }, (_, index) => expansionSection(`Current ${index + 1}`, "chapter"));
  const additions = Array.from({ length: 11 }, (_, index) => expansionSection(`Candidate ${index + 1}`, "chapter"));
  const fitted = fitExpansionAdditionsToBudget(current as any, additions as any, [], { round: 1 });
  assertEquals(fitted.additions.length, 10);
  assertEquals(fitted.attempt.returnedCount, 11);
  assertEquals(fitted.attempt.acceptedCount, 10);
  assertEquals(fitted.attempt.rejectedCount, 1);
  assertEquals(fitted.attempt.budgetTruncated, true);
});

Deno.test("later-beat expansion failure preserves earlier accepted additions", async () => {
  const initial = Array.from({ length: 28 }, (_, index) => expansionSection(`Current ${index + 1}`, "chapter", "beat-1"));
  let checkpoint: any[] | null = null;
  const result = await progressivelyExpandOutline(
    initial as any,
    new Set(["beat-1", "beat-2"]),
    async (_current, context, beat) => {
      if (beat?.beatID === "beat-1") return [expansionSection("Earlier accepted", "scene", "beat-1")];
      throw new ExpansionValidationError("later beat rejected", {
        round: context.round,
        beatID: beat?.beatID,
        sectionCountBefore: 29,
        projectedTokensBefore: 90_000,
        returnedCount: 3,
        acceptedCount: 0,
        rejectedCount: 3,
        candidateTitles: ["Later A", "Later B", "Later C"],
        candidateContainers: ["chapter", "chapter", "chapter"],
        projectedTokensAfter: 110_000,
        status: "rejected",
        error: "later beat rejected",
      });
    },
    async (_diagnostic, _all, current) => { checkpoint = current; },
    { beats: [{ id: "beat-1" }, { id: "beat-2" }], qualityGate: () => true },
  );
  assertEquals(result.suggestions.length, 29);
  assertEquals(result.suggestions.at(-1)?.title, "Earlier accepted");
  assertEquals((checkpoint as any)?.[28]?.title, "Earlier accepted");
  assertEquals(result.diagnostics.at(-1)?.sectionCountAfter, 29);
  assertEquals(result.diagnostics.at(-1)?.attempts?.at(-1)?.rejectedCount, 3);
});

Deno.test("cross-beat expansion anchors append within the addition's validated beat", () => {
  const original = [
    expansionSection("Beat One", "scene", "beat-1"),
    expansionSection("Beat Two", "scene", "beat-2"),
  ];
  const additions = validateExpansionAdditions(
    { suggestions: [expansionSection("Beat Two Addition", "scene", "beat-2", "Beat One")] },
    new Set(["beat-1", "beat-2"]),
    original as any,
  );
  assertEquals(additions[0].insertAfterTitle, null);
  assertEquals(mergeExpansionAdditions(original as any, additions as any).map((section) => section.title), [
    "Beat One", "Beat Two", "Beat Two Addition",
  ]);
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
  const firstPass = sceneOutline(25);
  let checkpoint: any = null;
  let failure: unknown;
  try {
    await progressivelyExpandOutline(
      firstPass as any,
      new Set(["beat-1"]),
      async (_current, context) => {
        if (context.round === 1) return Array.from({ length: 2 }, (_, i) => expansionSection(`Round 1 checkpoint ${i + 1}`));
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
  assertEquals(checkpoint.scale.projectedWords, evaluateNovelScale(Array.from({ length: 27 }, () => ({ container: "scene" }))).projectedWords);
});

Deno.test("insufficient-credit expansion failures are resumable from their durable checkpoint", () => {
  const run = {
    status: "failed",
    error_code: "insufficient_credits",
    suggestions: sceneOutline(37),
    diagnostics: {
      expansionCheckpoint: {
        stage: "expansion",
        nextRound: 2,
        nextBeatIndex: 0,
        scale: evaluateNovelScale(sceneOutline(37)),
        expansionRounds: [],
      },
    },
  };
  assertEquals(isRetryableExpansionFailure(run), true);
  const exhaustedFailedRun = {
    ...run,
    planning_state: {
      phase: "failed",
      nextAction: "allocation-repair-exhausted",
      expansionCheckpoint: run.diagnostics.expansionCheckpoint,
    },
    diagnostics: {
      ...run.diagnostics,
      stage: "failed",
      failureStage: "allocation_repair_exhausted",
    },
  };
  assertEquals(isRetryableExpansionFailure(exhaustedFailedRun), false);
  assertEquals(isRetryableExpansionFailure({ ...run, error_code: "server_error" }), false);
  assertEquals(isRetryableExpansionFailure({ ...run, suggestions: [] }), false);
});

Deno.test("retry resumes from the persisted expansion checkpoint without repeating first-pass work", async () => {
  const checkpointSuggestions = sceneOutline(39);
  const completedRound = {
    round: 1,
    sectionCountBefore: 27,
    projectedTokensBefore: 35100,
    projectedWordsBefore: 27000,
    additionsReturned: 10,
    sectionCountAfter: 39,
    projectedTokensAfter: 48100,
    projectedWordsAfter: 39000,
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
      return Array.from({ length: 18 }, (_, i) => expansionSection(`Retry round ${i + 1}`, "chapter"));
    },
    undefined,
    { startRound: resumed!.startRound, priorDiagnostics: resumed!.priorDiagnostics },
  );
  assertEquals(calls, [2]);
  assertEquals(result.suggestions.length, 57);
});

Deno.test("a ~34K projected novel cannot terminate as completed below the 115K minimum", async () => {
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
  assertEquals((failure as NovelScalePlanningError).message.includes("2% tolerance for the 115,000-word preferred planning target"), true);
});

Deno.test("expansion prompt includes round projection, broad range, and remaining deficit", () => {
  const prompt = buildExpansionPrompt(sparseRequest as any, sceneOutline(27) as any, { round: 2, projectedTokens: 35100, projectedWords: 27000, desiredWords: [115000, 125000], remainingDeficitTokens: 22700 });
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
  assertEquals(prompt.system.includes("Preserve supplied material and deepen it rather than replacing it"), true);
  assertEquals(prompt.system.includes("support the approximately 115,000-word planning target"), true);
  assertEquals(prompt.system.includes("connected conflicts, consequences, reversals, discoveries, relationships"), true);
  assertEquals(prompt.system.includes("not a large inventory of disconnected concepts"), true);
  assertEquals(prompt.system.includes("source=recipe"), false);
  assertEquals(prompt.system.includes("source=planner"), true);
  assertEquals(prompt.system.includes("Character-first invention"), true);
  assertEquals(prompt.system.includes("Build a Distinctive Narrative Engine"), true);
  assertEquals(prompt.system.includes("Do not suppress supporting-character invention"), true);
  assertEquals(prompt.system.includes("There is no cast quota"), true);
  assertEquals(prompt.system.includes("Do not minimize candidate count as an objective"), true);
  assertEquals(prompt.system.includes("replaceable development candidate"), true);
  assertEquals(prompt.user.includes("Monsters kill humans"), true);
  assertEquals(prompt.user.includes("Douche"), true);
});

Deno.test("enrichment prompt favors audacity, adult intensity, and memorable experiences without flattening genre", () => {
  const prompt = buildEnrichmentPrompt(sparseRequest as any).system;
  assertStringIncludes(prompt, "## Entertainment, Audacity, and Creative Intensity");
  assertStringIncludes(prompt, "most compelling, original, entertaining, and dramatically exciting");
  assertStringIncludes(prompt, "wild, eccentric, larger-than-life supporting characters");
  assertStringIncludes(prompt, "spectacular mistakes, escalating disasters, reckless decisions");
  assertStringIncludes(prompt, "addictions, appetites, obsessions, moral corruption");
  assertStringIncludes(prompt, "Do not automatically transform morally compromised protagonists into responsible heroes");
  assertStringIncludes(prompt, "Do not impose redemption arcs, moral lessons, institutional reform");
  assertStringIncludes(prompt, "Do not unnecessarily sanitize or dilute authored adult intensity");
  assertStringIncludes(prompt, "subject to applicable content constraints");
  assertStringIncludes(prompt, "## Invent distinctive experiences");
  assertStringIncludes(prompt, "Let information matter through what it makes people do");
  assertStringIncludes(prompt, "Quiet, intricate, realistic, or investigative experiences remain entirely valid");
  assertStringIncludes(prompt, "intensity and originality come from the recipe, not a universal genre preference");
  assertStringIncludes(prompt, "## Keep enrichment genuinely exploratory");
  assertEquals(prompt.includes("There is no cast quota"), true);
});

Deno.test("enrichment prompt favors inventive situations over generic machinery", () => {
  const prompt = buildEnrichmentPrompt(sparseRequest as any);
  const payload = JSON.parse(prompt.user);
  assertStringIncludes(prompt.system, "personality, independent desire, flaw or contradiction");
  assertStringIncludes(prompt.system, "Build a Distinctive Narrative Engine");
  assertStringIncludes(prompt.system, "particular experiences, tensions, surprises, and unresolved questions promised by the author's recipe");
  assertStringIncludes(prompt.system, "Escalation means their choices produce increasingly consequential and distinctive experiences");
  assertStringIncludes(prompt.system, "independent characters, conflicting agendas, accidental encounters");
  assertStringIncludes(prompt.system, "not a directive to construct one complete and coordinated plot apparatus");
  assertStringIncludes(prompt.system, "do not all need to describe the same invented opposition or operation");
  assertStringIncludes(prompt.system, "A planner-invented mechanism is an optional candidate");
  assertEquals(prompt.system.includes("Do not default to rosters, manifests, inventories, ledgers"), false);
  assertEquals(prompt.system.includes("A document is not a dramatic event"), false);
  assertStringIncludes(prompt.system, "Sparse input still carries a larger invention burden");
  assertStringIncludes(prompt.system, "retain distinct people and situations");
  assertStringIncludes(prompt.system, "The schema and existing sufficiency requirements remain authoritative");
  assertStringIncludes(prompt.system, "existing enrichment schema");
  assertEquals(payload.arcTemplate, sparseRequest.arcTemplate);
  assertEquals(payload.recipe, sparseRequest.recipe);
});

Deno.test("character-first enrichment direction precedes situations, escalation, and mechanics", () => {
  const prompt = buildEnrichmentPrompt(sparseRequest as any).system;
  const characters = prompt.indexOf("## Character-first invention");
  const engine = prompt.indexOf("## Build a Distinctive Narrative Engine");
  assertEquals(characters >= 0, true);
  assertEquals(characters < engine, true);
  assertEquals(prompt.includes("independent desire"), true);
  assertEquals(prompt.includes("derail the protagonists' plans"), true);
  assertStringIncludes(prompt, "Every invented character must be more than a job title or plot function");
  assertStringIncludes(prompt, "If a character could be replaced by an anonymous role");
  assertEquals(prompt.includes('role such as "handler"'), false);
  assertEquals(prompt.includes('"contractor"'), false);
  assertEquals(prompt.includes("Do not automatically invent a central mission"), false);
});

Deno.test("enrichment categories do not preselect one operational plot and preserve authored possibilities", () => {
  const richRequest: any = {
    ...sparseRequest,
    recipe: {
      ...sparseRequest.recipe,
      project: { ...sparseRequest.recipe.project, summary: "A peculiar ensemble of companions misreads catastrophe as celebrity." },
      setting: { ...sparseRequest.recipe.setting, included: true, worldRules: ["An invented institution should not be required as the central plot."] },
    },
  };
  const prompt = buildEnrichmentPrompt(richRequest);
  assertEquals(JSON.parse(prompt.user).recipe, richRequest.recipe);
  assertStringIncludes(prompt.system, "The enrichment categories are ways to describe possible material");
  assertStringIncludes(prompt.system, "do not all need to describe the same invented opposition or operation");
  assertStringIncludes(prompt.system, "Some ideas may connect; others can be alternatives");
  assertStringIncludes(prompt.system, "the outliner will choose between");
  assertEquals(prompt.system.includes("Do not automatically invent a central mission, investigation, pursuit"), false);
  assertEquals(prompt.system.includes("Do not globally prohibit procedural storytelling"), false);
  const outline = buildPrompt(richRequest, new Map());
  assertStringIncludes(outline.system, "Planner categories are possible story ingredients, not an already chosen plot");
  assertStringIncludes(outline.system, "frequency across categories does not make it canon");
  assertEquals(JSON.parse(outline.user).planningContext.recipe, richRequest.recipe);
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
  assertEquals(prompt.user.includes("force-emergency-network"), false);
  assertEquals(prompt.system.includes("deepen the authored recipe's premise"), true);
  assertEquals(prompt.system.includes("unused or underdeveloped enrichment items"), false);
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
    {
      ...semanticSection("den", "A New Balance", "The new order settles and the surviving relationships find a changed normal.", "resolution"),
      resultingChange: "The central conflict settles and the surviving relationships accept a changed normal.",
      terminalState: "The new order holds after the former conflict ends.",
    },
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
    {
      ...semanticSection("return", "The Changed World", "The hero returns with the elixir and a new normal settles.", "resolution"),
      resultingChange: "The former conflict resolves and the hero accepts the cost of return.",
      terminalState: "A new normal holds after the old threat ends.",
    },
  ] as any, template), []);
});

Deno.test("PR3 server repair reassigns a locally misallocated decisive section", () => {
  const result = repairStoryArcMacroStructure([
    {
      ...semanticSection("den", "The Open Bid for Rule", "Brody launches a citywide takeover and seizes the government.", "resolution"),
      resultingChange: "The takeover begins but the central conflict remains unsettled.",
      terminalState: "The government is seized while the primary confrontation continues.",
    },
    {
      ...semanticSection("den", "The Quiet Settlement", "The surviving relationships settle into a changed normal.", "resolution"),
      resultingChange: "The surviving relationships settle into a changed normal.",
      terminalState: "The former conflict ends and the new order holds.",
    },
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

const romanticSuspenseFixture = {
  name: "Romantic Suspense",
  beats: [
    { id: "intimacy", role: "intimacy_under_pressure", label: "Intimacy Under Pressure" },
    { id: "showdown", role: "joint_showdown", label: "Joint Showdown" },
    { id: "safety", role: "safety_and_commitment", label: "Safety and Commitment" },
  ],
};

function assertOpenAIStrictSchema(schema: any, path = "schema"): void {
  if (!schema || typeof schema !== "object") return;
  if (schema.type === "object") {
    assertEquals(schema.additionalProperties, false, `${path} must close additional properties`);
    const propertyNames = Object.keys(schema.properties ?? {}).sort();
    const requiredNames = [...(schema.required ?? [])].sort();
    assertEquals(requiredNames, propertyNames, `${path} must require every defined property`);
  }
  for (const [key, value] of Object.entries(schema.properties ?? {})) {
    assertOpenAIStrictSchema(value, `${path}.${key}`);
  }
  if (schema.items) assertOpenAIStrictSchema(schema.items, `${path}.items`);
  if (schema.additionalProperties && typeof schema.additionalProperties === "object") {
    assertOpenAIStrictSchema(schema.additionalProperties, `${path}.additionalProperties`);
  }
}

Deno.test("semantic evidence schemas satisfy strict Structured Outputs for the 10-beat Romance / HEA arc", () => {
  const roles = [
    "ordinary_life", "meet_attraction", "resistance", "connection_deepens", "midpoint_intimacy",
    "pressure_test", "rupture", "realization", "grand_choice", "hea_hfn",
  ];
  const beats = roles.map((role, index) => ({
    id: `romance-beat-${index + 1}`,
    role,
    label: role,
    description: `Authored Romance / HEA requirement for ${role}.`,
  }));
  const allocation = new Map(beats.map((beat) => [beat.id, { minSections: 1, rationale: "schema regression" }]));
  const schema: any = buildSuggestionResponseSchema(beats, allocation, [], "Romance / HEA");
  assertOpenAIStrictSchema(schema);

  for (const beat of beats) {
    const item = schema.properties.beats.properties[beat.id].items;
    assertEquals(item.required.includes("arcObligationEvidence"), true);
    const evidence = item.properties.arcObligationEvidence;
    assertEquals(evidence.required, Object.keys(evidence.properties));
    for (const obligationSchema of Object.values(evidence.properties) as any[]) {
      assertEquals(obligationSchema.items.required, ["field", "quote"]);
    }
  }

  const expansion: any = buildExpansionResponseSchema(arcRoleContract(beats[9], "Romance / HEA"));
  assertOpenAIStrictSchema(expansion);
  assertEquals(expansion.properties.suggestions.items.required.includes("arcObligationEvidence"), false);
  assertEquals("arcObligationEvidence" in expansion.properties.suggestions.items.properties, false);
});

Deno.test("semantic beat obligations reject generic Romantic Suspense completion", () => {
  const generic = [
    semanticSection("intimacy", "The Danger", "The danger escalates.", "escalation"),
    semanticSection("showdown", "The Confrontation", "The leads confront the threat.", "climax"),
    semanticSection("safety", "The Aftermath", "The aftermath settles.", "resolution"),
  ];
  const issues = validateArcSemanticObligations(generic as any, romanticSuspenseFixture as any);
  assertEquals(issues.length, 5);
  assertEquals(issues.some((issue) => issue.includes("relationship_deepens_under_pressure")), true);
  assertEquals(issues.some((issue) => issue.includes("coordinated_danger_resolution")), true);
  assertEquals(issues.some((issue) => issue.includes("earned_romantic_future")), true);
});

Deno.test("semantic beat obligations require concrete evidence for Romantic Suspense roles", () => {
  const sections: any[] = [
    {
      ...semanticSection("intimacy", "The Safehouse Confession", "The leads shelter together while the threat closes in.", "escalation"),
      resultingChange: "The guarded lead reveals the evidence and the other lead takes a personal risk to protect them, changing their mutual trust.",
      arcObligationEvidence: { relationship_deepens_under_pressure: [{ field: "dramaticEvent", quote: "The guarded lead reveals the evidence" }] },
    },
    {
      ...semanticSection("showdown", "The Two-Way Trap", "Both leads coordinate the trap that corners the pursuer, and one stays behind to draw fire so the other can finish it.", "climax"),
      resultingChange: "The threat is defeated because their coordinated plan succeeds, and their commitment changes the cost each is willing to pay.",
      terminalState: "The danger is ended and the leads face the consequences together.",
      arcObligationEvidence: {
        coordinated_danger_resolution: [{ field: "dramaticEvent", quote: "Both leads coordinate the trap" }],
        emotional_commitment_in_action: [{ field: "resultingChange", quote: "their commitment changes the cost" }],
      },
    },
    {
      ...semanticSection("safety", "A Door Left Open", "The leads expose the conspirator and choose a shared life after the danger ends.", "resolution"),
      resultingChange: "The threat is dismantled and the leads establish an earned future together shaped by the trust they chose under pressure.",
      terminalState: "The threat cannot resume; the leads begin their committed future with a concrete shared plan.",
      arcObligationEvidence: {
        threat_is_settled: [{ field: "dramaticEvent", quote: "expose the conspirator" }],
        earned_romantic_future: [{ field: "resultingChange", quote: "establish an earned future together" }],
      },
    },
  ];
  assertEquals(validateArcSemanticObligations(sections, romanticSuspenseFixture as any), []);
  const schema: any = buildSuggestionResponseSchema(
    romanticSuspenseFixture.beats,
    new Map(romanticSuspenseFixture.beats.map((beat) => [beat.id, { minSections: 1, rationale: "semantic test" }])),
    [],
    romanticSuspenseFixture.name,
  );
  const intimacySchema = schema.properties.beats.properties.intimacy.items;
  assertEquals(intimacySchema.required.includes("arcObligationEvidence"), true);
  assertEquals(intimacySchema.properties.arcObligationEvidence.properties.relationship_deepens_under_pressure.type, "array");
});

Deno.test("authored Story Arc beat requirements survive context compaction for every template", () => {
  const authoredRequirement = `An authored requirement that is intentionally longer than the old 650-character compaction boundary: ${"preserve this narrative obligation ".repeat(30)}`.trim();
  const template: any = {
    id: "custom",
    name: "Custom Arc",
    description: authoredRequirement,
    beats: [{
      id: "custom-beat",
      role: "custom_role",
      label: "Custom Beat",
      description: authoredRequirement,
    }],
  };
  const contract = arcRoleContract(template.beats[0], template.name);
  assertEquals(contract.semanticObligations[0].id, "authored_beat_requirement");
  assertEquals(contract.semanticObligations[0].instruction.includes(authoredRequirement), true);
  assertEquals(compactArcNarrativeText(authoredRequirement), authoredRequirement);

  const section: any = {
    ...semanticSection("custom-beat", "The Requirement", "The beat's authored requirement is enacted in a concrete event.", "escalation"),
    resultingChange: "The authored requirement changes the protagonist's relationship and the story's available choices.",
    terminalState: "The changed condition carries the authored requirement into the next beat.",
    arcObligationEvidence: {
      authored_beat_requirement: [{ field: "dramaticEvent", quote: "The beat's authored requirement is enacted in a concrete event." }],
    },
  };
  assertEquals(validateArcSemanticObligations([section], template), []);

  const schema: any = buildSuggestionResponseSchema(
    template.beats,
    new Map([["custom-beat", { minSections: 1, rationale: "semantic test" }]]),
    [],
    template.name,
  );
  assertEquals(schema.properties.beats.properties["custom-beat"].items.required.includes("arcObligationEvidence"), true);
  const prompt = buildPrompt({ ...sparseRequest, arcTemplate: template } as any, new Map([["custom-beat", { minSections: 1, rationale: "semantic test" }]]));
  assertEquals(prompt.system.includes(authoredRequirement), true);
  assertEquals(prompt.user.includes(authoredRequirement), true);
});

Deno.test("resolution function validation is structural, not literary", () => {
  const template: any = { name: "Save the Cat!", beats: [{ id: "final", role: "final_image", label: "Final Image" }] };
  const declaredButUnresolved: any = {
    storyArcBeatID: "final",
    dramaticFunction: "resolution",
    dramaticEvent: "Ted tries to destroy the transmitter but fails.",
    resultingChange: "Ted and Fred retreat without disabling it.",
    terminalState: "The transmitter remains active and the invasion continues.",
  };
  assertEquals(validateRequiredStoryArcFunctions([declaredButUnresolved], template), []);
  const missingDeclaration = { ...declaredButUnresolved, dramaticFunction: "aftermath" };
  assertEquals(validateRequiredStoryArcFunctions([missingDeclaration], template).some((issue) => issue.includes("missing required dramatic function resolution")), true);
});

Deno.test("PR3 expansion schema and parser enforce beat-local structural functions without conflict rejection", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const schema = buildExpansionResponseSchema(arcRoleContract(template.beats[0], template.name)) as any;
  assertEquals(schema.properties.suggestions.items.properties.dramaticFunction.enum.includes("climax"), false);
  const addition: any = semanticSection("fall", "Second Assault", "The antagonist launches a larger decisive assault on the city.", "consequence");
  addition.insertAfterTitle = null;
  const parsed = parseExpansionResponse(JSON.stringify({ suggestions: [addition] }), new Set(["fall"]), [], [], template as any);
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].title, "Second Assault");
  const denouement = { name: "Freytag's Pyramid", beats: [{ id: "den", role: "denouement", label: "Denouement" }] };
  const denAddition: any = semanticSection("den", "Another Assault", "The antagonist launches another takeover.", "consequence");
  denAddition.insertAfterTitle = null;
  const denParsed = parseExpansionResponse(JSON.stringify({ suggestions: [denAddition] }), new Set(["den"]), [], [], denouement as any);
  assertEquals(denParsed.length, 1);
  assertEquals(denParsed[0].title, "Another Assault");
});

Deno.test("PR3 expansion allows local conflict actions that are not decisive takeovers", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const addition: any = semanticSection(
    "fall",
    "The Emergency Stores",
    "The guards seize emergency stores from the abandoned depot, then distribute them under the new ration plan.",
    "consequence",
  );
  addition.insertAfterTitle = null;
  const parsed = parseExpansionResponse(
    JSON.stringify({ suggestions: [addition] }),
    new Set(["fall"]),
    [],
    [],
    template as any,
  );
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].title, "The Emergency Stores");
});

Deno.test("expansion schema restricts recipe requirement IDs to canonical obligations", () => {
  const obligations = [
    { id: "R1", label: "First requirement", description: "Canonical requirement" },
    { id: "R2", label: "Second requirement", description: "Another canonical requirement" },
  ];
  const schema = buildExpansionResponseSchema(undefined, "novel", obligations as any) as any;
  assertEquals(
    schema.properties.suggestions.items.properties.recipeRequirementIDs.items.enum,
    ["R1", "R2"],
  );
});

Deno.test("optional expansion does not apply the first-pass beat semantic gate", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const addition: any = semanticSection(
    "fall",
    "Sophie Vale’s Unscheduled Escort",
    "Sophie arranges an unscheduled escort that gives Mira access to a restricted service route.",
    "setup",
  );
  addition.insertAfterTitle = null;
  const parsed = parseExpansionResponse(
    JSON.stringify({ suggestions: [addition] }),
    new Set(["fall"]),
    [],
    [],
    template as any,
  );
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].title, "Sophie Vale’s Unscheduled Escort");
});

Deno.test("optional expansion does not apply the first-pass beat semantic gate", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const addition: any = semanticSection(
    "fall",
    "Sophie Vale’s Unscheduled Escort",
    "Sophie arranges an unscheduled escort that gives Mira access to a restricted service route.",
    "setup",
  );
  addition.insertAfterTitle = null;
  const parsed = parseExpansionResponse(
    JSON.stringify({ suggestions: [addition] }),
    new Set(["fall"]),
    [],
    [],
    template as any,
  );
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].title, "Sophie Vale’s Unscheduled Escort");
});

Deno.test("optional expansion ignores provider obligation evidence metadata", () => {
  const template = { name: "Freytag's Pyramid", beats: [{ id: "fall", role: "falling_action", label: "Falling Action" }] };
  const addition: any = semanticSection(
    "fall",
    "Anika Voss and the Consent Fracture",
    "Anika reveals how the system turned private desire into leverage.",
    "setup",
  );
  addition.insertAfterTitle = null;
  addition.arcObligationEvidence = {
    romanticTension: [{ field: "dramaticEvent", quote: "Anika reveals how the system turned private desire into leverage." }],
  };
  const parsed = parseExpansionResponse(
    JSON.stringify({ suggestions: [addition] }),
    new Set(["fall"]),
    [],
    [],
    template as any,
  );
  assertEquals(parsed.length, 1);
  assertEquals(parsed[0].title, "Anika Voss and the Consent Fracture");
  assertEquals("arcObligationEvidence" in parsed[0], false);
});

Deno.test("PR3 expansion prompt carries the complete target semantic contract", () => {
  const template = { ...sparseRequest, arcTemplate: { name: "Freytag's Pyramid", id: "f", beats: freytagFixture.beats } } as any;
  const prompt = buildExpansionPrompt(template, [], { round: 1, projectedTokens: 1, projectedWords: 1, desiredWords: [115000, 125000], remainingDeficitTokens: 100, beat: { beatID: "fall", beatLabel: "Falling Action", currentSections: [], projectedTokens: 0, projectedWords: 0 } } as any);
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

Deno.test("unresolved semantic verification gets one bounded checkpoint retry", () => {
  const base = {
    status: "failed",
    error_code: "story_arc_semantic_unresolved",
    planning_state: { nextAction: "semantic-reverification" },
    diagnostics: { semanticRetryCount: 0 },
  };
  assertEquals(isRetryableSemanticVerificationFailure(base), true);
  assertEquals(isRetryableSemanticVerificationFailure({ ...base, diagnostics: { semanticRetryCount: 1 } }), false);
  assertEquals(isRetryableSemanticVerificationFailure({ ...base, planning_state: { nextAction: "semantic-repair" } }), false);
});

Deno.test("paid semantic repair target failures are recoverable once from their checkpoint", () => {
  const base = {
    status: "failed",
    error_code: "server_error",
    error: "story_arc_semantic_repair: repair target is not affected 12.29 credits were already settled",
    credit_cost_charged: 12.29,
    planning_state: { nextAction: "semantic-repair" },
  };
  assertEquals(isRetryableSemanticRepairFailure(base), true);
  assertEquals(isRetryableSemanticRepairFailure({ ...base, diagnostics: { semanticRecoveryAttempts: 1 } }), false);
  assertEquals(isRetryableSemanticRepairFailure({ ...base, planning_state: { nextAction: "semantic-reverification" } }), false);
});

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

Deno.test("outline kickoff telemetry uses the chosen model rather than the legacy default", async () => {
  let inserted: any = null;
  const mockSupabase = {
    from(table: string) {
      assertEquals(table, "generation_request_logs");
      return {
        insert(data: any) {
          inserted = data;
          return Promise.resolve({ error: null });
        },
      };
    },
  };
  await logRequest(mockSupabase as any, "user-luna", "queued", undefined, {
    id: "gpt-6-luna",
    provider_model: "gpt-6-luna",
  });
  assertEquals(inserted.model_name, "gpt-6-luna");
  assertEquals(inserted.selected_model_id, "gpt-6-luna");
  assertEquals(inserted.provider_model, "gpt-6-luna");
  assertEquals(inserted.action, "outline-from-recipe");
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
  const logRequestCall = source.indexOf("await logRequest(db, user.id, \"queued\", undefined, selectedModel);");
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
    const prompt = buildExpansionPrompt(sparseRequest as any, current as any, { round: 1, projectedTokens: 1200, projectedWords: 300, desiredWords: [115000, 125000], remainingDeficitTokens: 1000, beat: target as any }, []);
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
  patchHistory: Array<Record<string, unknown>> = [];
  failPatchField: string | null = null;
  failAsZeroRows = false;
  failRead = false;
  rpc?: (name: string, args: Record<string, unknown>) => Promise<{ error: unknown }>;
  constructor(row: any, options: { singleClaimOnly?: boolean; failPatchField?: string; failAsZeroRows?: boolean; failRead?: boolean; reconciledCredits?: number; reconciledRemainingCredits?: number } = {}) {
    this.row = structuredClone(row);
    this.singleClaimOnly = options.singleClaimOnly ?? false;
    this.failPatchField = options.failPatchField ?? null;
    this.failAsZeroRows = options.failAsZeroRows ?? false;
    this.failRead = options.failRead ?? false;
    if (typeof options.reconciledCredits === "number") {
      this.rpc = async () => {
        this.row.credit_cost_charged = options.reconciledCredits;
        if (typeof options.reconciledRemainingCredits === "number") this.row.remaining_credits = options.reconciledRemainingCredits;
        return { error: null };
      };
    }
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
      is(column: string, value: unknown) { filters.push([column, value]); return query; },
      lte(column: string, value: unknown) { ranges.push([column, value]); return query; },
      order(_column: string, _options?: unknown) { return query; },
      limit(_count: number) { return query; },
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
      if (this.failRead && !patch) return { data: null, error: { message: "simulated authoritative read failure" } };
      if (!this.matches(this.row, filters, ranges)) return { data: null, error: null };
      if (patch?.status === "running" && this.singleClaimOnly && this.claims > 0) return { data: null, error: null };
      if (patch && this.failPatchField && this.failPatchField in patch) {
        return this.failAsZeroRows
          ? { data: null, error: null }
          : { data: null, error: { message: "simulated PostgREST checkpoint failure" } };
      }
      if (patch?.status === "running") this.claims++;
      if (patch) {
        this.patchHistory.push(structuredClone(patch));
        Object.assign(this.row, patch);
      }
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
    if (request.action === "outline-semantic-verification") {
      return { featureResult: JSON.stringify(semanticVerifierFixture(request)), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
    }
    if (request.action === "outline-suggestions") {
      const section = (beat: string, title: string) => ({ title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`), entryState: "The prior state holds.", dramaticEvent: beat === "beat-1" ? `${title} happens.` : `${title} resolves the central conflict.`, resultingChange: beat === "beat-1" ? `${title} changes the pressure.` : `${title} settles the central conflict.`, terminalState: beat === "beat-1" ? `${title} hands forward a new pressure.` : `${title} establishes the new normal.` });
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

function semanticVerifierFixture(request: any): unknown {
  const input = JSON.parse(request.messages?.find((message: any) => message.role === "user")?.content ?? "{}");
  return {
    arcWideObligations: (input.arcWideObligations ?? []).map((obligation: any) => {
      const section = (obligation.sections ?? [])[0];
      const field = obligation.obligationID === CREATIVE_FIDELITY_OBLIGATION ? "dramaticEvent" : "resultingChange";
      const quote = section?.[field] ?? "";
      return { obligationID: obligation.obligationID, satisfied: Boolean(section && quote), sectionIndex: section?.sectionIndex ?? -1, field, quote, reason: "fixture evidence" };
    }),
    beats: (input.beats ?? []).map((beat: any) => ({
      beatID: beat.beatID,
      obligations: (beat.obligations ?? []).map((obligation: any) => {
        const section = (beat.sections ?? [])[0];
        const field = "resultingChange";
        const quote = section?.[field] ?? "";
        return { obligationID: obligation.obligationID, satisfied: Boolean(section && quote), sectionIndex: section?.sectionIndex ?? -1, field, quote, reason: "fixture evidence" };
      }),
    })),
  };
}

function validatedWorkerBilling(
  actions: string[],
  responseFor: (action: string) => string | unknown,
  semanticResponseFor: (request: any) => string | unknown = semanticVerifierFixture,
) {
  return async (request: any) => {
    actions.push(request.action);
    const content = request.action === "outline-semantic-verification"
      ? semanticResponseFor(request)
      : responseFor(request.action);
    if (request.onProviderSuccess) {
      await request.onProviderSuccess({ content: typeof content === "string" ? content : JSON.stringify(content) });
    }
    return { featureResult: typeof content === "string" ? content : JSON.stringify(content), charged: true, actualCharge: 1, remainingCredits: 99 } as any;
  };
}

function outputExhaustedBilling(actions: string[]) {
  return async (request: any) => {
    actions.push(request.action);
    await request.onProviderSuccess?.({ content: '{"truncated":', finishReason: "length" });
    throw new Error("output exhaustion callback unexpectedly returned");
  };
}

Deno.test("new semantic verification reports unmet obligations without launching a rewrite or re-verification", async () => {
  const body = await executableWorkerBody();
  const ids = Array.from({ length: 63 }, (_, index) => `R${index + 1}`);
  const section = (beat: string, title: string) => ({
    title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`, storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution",
    recipeRequirementIDs: ids, entryState: "Continuity holds.",
    dramaticEvent: beat === "beat-1" ? "The journey begins." : "The conflict ends.",
    resultingChange: beat === "beat-1" ? "New pressure begins." : "The conflict resolves.",
    terminalState: beat === "beat-1" ? "The crisis remains." : "The new normal persists.",
  });
  const original = [section("beat-1", "First"), section("beat-2", "Last")];
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: original,
    planning_state: {
      version: 2, phase: "semantic_verification_pending", nextAction: "semantic-verification",
      allocationEntries: [
        ["beat-1", { minSections: 1, rationale: "start" }],
        ["beat-2", { minSections: 1, rationale: "end" }],
      ],
    },
  });
  const calls: string[] = [];
  const billable = validatedWorkerBilling(calls, () => ({ suggestions: [] }), (request) => {
    const response: any = semanticVerifierFixture(request);
    if (response.beats[0]?.obligations[0]) {
      response.beats[0].obligations[0].satisfied = false;
      response.beats[0].obligations[0].reason = "The authored beat obligation was not achieved.";
    }
    return response;
  });
  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  assertEquals(calls, ["outline-semantic-verification"]);
  assertEquals(db.row.status, "completed", db.row.error ?? "no error");
  assertEquals(db.row.suggestions, original);
  assertEquals(db.row.diagnostics.automaticNarrativeRepair, "disabled");
  assertEquals(db.row.diagnostics.semanticAssessment, "needs_review");
  assertEquals(db.row.diagnostics.semanticUnresolvedCount, 1);
  assertEquals(db.row.warnings ?? [], []);
  assertEquals(db.row.planning_state.nextAction, "completed");
});

Deno.test("old semantic and obligation repair checkpoints preserve paid story without dispatching new repair calls", async () => {
  const body = await executableWorkerBody();
  const ids = Array.from({ length: 63 }, (_, index) => `R${index + 1}`);
  const section = (beat: string, title: string) => ({
    title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`, storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution",
    recipeRequirementIDs: ids, entryState: "Continuity holds.",
    dramaticEvent: beat === "beat-1" ? "The journey begins." : "The conflict ends.",
    resultingChange: beat === "beat-1" ? "New pressure begins." : "The conflict resolves.",
    terminalState: beat === "beat-1" ? "The crisis remains." : "The new normal persists.",
  });
  const original = [section("beat-1", "First"), section("beat-2", "Last")];
  const candidate = [section("beat-1", "Unwanted replacement"), original[1]];
  for (const nextAction of ["semantic-repair", "semantic-reverification", "obligation-repair"]) {
    const db = new ExecutableRunDb({
      ...checkpointedWorkerRow(body),
      suggestions: nextAction === "obligation-repair" ? original : candidate,
      diagnostics: {
        semanticVerification: {
          arcWideObligations: [], beats: [],
          unsatisfied: [{ beatID: "beat-1", obligationID: "authored_beat_requirement", reason: "fixture gap" }],
        },
      },
      planning_state: {
        version: 2, phase: nextAction, nextAction,
        semanticRepairOriginalSuggestions: original,
        allocationEntries: [
          ["beat-1", { minSections: 1, rationale: "start" }],
          ["beat-2", { minSections: 1, rationale: "end" }],
        ],
      },
    });
    const actions: string[] = [];
    await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
      db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
      billableLLM: fakeWorkerBilling(actions) as any, scheduleContinuation: async () => {},
    });
    assertEquals(actions, [], nextAction);
    assertEquals(db.row.status, "completed", JSON.stringify({ nextAction, error: db.row.error }));
    assertEquals(db.row.suggestions, original, nextAction);
    assertEquals(db.row.diagnostics.automaticNarrativeRepair, "disabled");
  }
});

Deno.test("first-pass prompts own whole-book obligations and active worker has no narrative repair dispatch", async () => {
  const request: any = await executableWorkerBody();
  assertStringIncludes(buildPrompt(request, new Map()).system, "## First-pass whole-book obligations (no narrative repair later)");
  assertStringIncludes(buildPrompt(request, new Map()).system, "required functions=");
  assertStringIncludes(buildAllocationPrompt(request).system, "Do not pack all story-wide obligations into the first beat");
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  for (const action of ['nextAction: "semantic-repair"', 'nextAction: "semantic-reverification"', 'nextAction: "obligation-repair"']) {
    assertEquals(source.includes(action), false, action);
  }
});

Deno.test("authored premise is decomposed into independent source-backed obligations without renumbering old IDs", () => {
  const summary = "Two damaged drifters cross the country. One violent act turns them into public symbols. Their fame exposes a national conspiracy, and their disastrous choices become essential to preventing humanity's destruction.";
  const components = [
    { sourceQuote: "Two damaged drifters cross the country", requirement: "The drifters are damaged and cross the country." },
    { sourceQuote: "One violent act turns them into public symbols", requirement: "A violent event produces an unintended public mythology." },
    { sourceQuote: "Their fame exposes a national conspiracy", requirement: "Notoriety exposes the national conspiracy." },
    { sourceQuote: "their disastrous choices become essential to preventing humanity's destruction", requirement: "Their flawed actions materially advance humanity's survival." },
  ];
  assertEquals(validatePremiseComponents(components, summary), components);
  const recipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, summary } };
  const baseline = deriveRecipeObligations(recipe);
  const decomposed = deriveRecipeObligations(recipe, components);
  assertEquals(decomposed.slice(0, baseline.length), baseline);
  assertEquals(decomposed.length, baseline.length + 4);
  assertEquals(decomposed.slice(-4).map((item) => item.source), [
    "project.summary.component.1", "project.summary.component.2",
    "project.summary.component.3", "project.summary.component.4",
  ]);
  assertEquals(decomposed.slice(-4).every((item) => item.required), true);
  assertStringIncludes(decomposed.at(-1)!.statement, "humanity");
  const material: any = { premiseComponents: components };
  const request: any = { ...sparseRequest, recipe, storyMaterialEnrichment: material };
  const planning = buildCompactPlanningView(request, decomposed, material);
  assertEquals((planning.premiseComponents as any[]).length, 4);
  assertEquals((planning.materialIndex as any[]).some((item) => item.category === "premiseComponents"), false);
  assertStringIncludes(buildEnrichmentPrompt(request).system, "Decompose the AUTHOR'S project summary");
  assertStringIncludes(buildAllocationPrompt(request, decomposed).user, "preventing humanity");
  assertStringIncludes(buildPrompt(request, new Map(), decomposed, material).user, "preventing humanity");
});

Deno.test("premise extraction rejects invented source claims and omitted large promises", () => {
  const summary = "The friends become notorious. Their unintended influence shakes the entire country. Their unpredictable choices will one day determine whether humanity survives.";
  assertThrows(() => validatePremiseComponents([
    { sourceQuote: "They overthrow the national government", requirement: "The government is overthrown." },
  ], summary), Error, "invented source quote");
  assertThrows(() => validatePremiseComponents([
    { sourceQuote: "The friends become notorious", requirement: "Their notoriety grows." },
    { sourceQuote: "Their unintended influence shakes the entire country", requirement: "The country is destabilized." },
  ], summary), Error, "failed to cover");
  assertThrows(() => validatePremiseComponents(undefined, summary), Error, "premiseComponents must contain");
});

Deno.test("independent verifier does not pass a humanity-scale premise component because a local victory happened", async () => {
  const summary = "One violent event creates new public symbols. The national institutions begin to break down. The protagonists' mistakes become essential to humanity surviving a hidden threat.";
  const components = [
    { sourceQuote: "One violent event creates new public symbols", requirement: "Fame arises from a violent event." },
    { sourceQuote: "The national institutions begin to break down", requirement: "The country begins a consequential transformation." },
    { sourceQuote: "The protagonists' mistakes become essential to humanity surviving a hidden threat", requirement: "Their mistakes must be causally important to humanity's survival." },
  ];
  const recipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, summary } };
  const template: any = { name: "Custom", beats: [{ id: "b1", label: "Beginning", role: "setup", description: "" }] };
  const sections: any[] = [{
    title: "A raid is stopped", storyArcBeatID: "b1",
    dramaticEvent: "A viral clip makes the pair notorious and they stop a local raid.",
    resultingChange: "Several detainees survive the confrontation.",
    terminalState: "Their popularity is national, but the systemic threat and any causal link to humanity's fate remain unexplained.",
  }];
  const input = semanticVerificationInput(sections, template, recipe, components) as any;
  assertEquals(input.arcWideObligations.filter((o: any) => o.obligationID.startsWith("premise_component_")).length, 3);
  const response: any = semanticVerifierFixture({ messages: [{ role: "user", content: JSON.stringify(input) }] });
  const humanity = response.arcWideObligations.find((o: any) => o.obligationID === "premise_component_2");
  humanity.satisfied = false;
  humanity.reason = "The local rescue does not establish the protagonists' causal importance to humanity's survival.";
  const result = await verifyStoryArcSemantics(
    sections, template, async () => ({ content: JSON.stringify(response) }) as any,
    recipe, "outline-semantic-verification", components,
  );
  assertEquals(result.unsatisfied.some((failure) => failure.obligationID === "premise_component_2"), true);
  assertEquals(result.arcWideObligations.filter((o) => o.obligationID.startsWith("premise_component_")).length, 3);
  assertEquals(result.arcWideObligations.find((o) => o.obligationID === "premise_component_0")?.satisfied, true);
});

Deno.test("retired Story Arc rewrite resumes old paid checkpoints without AI calls or changing their plot", async () => {
  const fullBody = await executableWorkerBody();
  const body: any = {
    ...fullBody,
    arcTemplate: {
      ...fullBody.arcTemplate,
      name: "Save the Cat!",
      beats: fullBody.arcTemplate.beats.map((beat: any, index: number) => index === 1
        ? { ...beat, role: "final_image", label: "Final Image", description: "Show what survives." }
        : beat),
    },
  };
  const ids = Array.from({ length: 63 }, (_, index) => `R${index + 1}`);
  const section = (title: string, beat: string, dramaticFunction: string, event: string, change: string, terminal: string) => ({
    title, summary: event, container: "scene", pov: "thirdPersonLimited", terminalBeat: terminal,
    entryState: "The former event remains true.", dramaticEvent: event, resultingChange: change,
    terminalState: terminal, dramaticFunction, storyArcBeatID: beat, recipeRequirementIDs: ids,
  });
  const paidOutline = [
    section("The first escape", "beat-1", "setup", "The captives leave the transport.", "The transport is empty.", "The captives remain free."),
    section("The survivors continue", "beat-2", "aftermath", "The group drives away after the rescue.", "The costly escape remains accomplished.", "The rescued people are safe and the new normal persists."),
  ];
  for (const nextAction of ["story-arc-repair", "story-arc-repair-completion", "semantic-completion"]) {
    const row: any = {
      ...checkpointedWorkerRow(body),
      suggestions: structuredClone(paidOutline),
      planning_state: {
        version: 2, phase: "story_arc_repair_pending", nextAction,
        allocationEntries: [
          ["beat-1", { minSections: 1, rationale: "fixture" }],
          ["beat-2", { minSections: 1, rationale: "fixture" }],
        ],
      },
    };
    const db = new ExecutableRunDb(row);
    const calls: string[] = [];
    await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
      db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
      billableLLM: fakeWorkerBilling(calls) as any, scheduleContinuation: async () => {},
    });
    assertEquals(calls, [], nextAction);
    assertEquals(db.row.status, "completed", JSON.stringify({ nextAction, error: db.row.error, diagnostics: db.row.diagnostics }));
    assertEquals(db.row.suggestions, paidOutline, nextAction);
    assertEquals(db.row.diagnostics.storyArcRewriteSkipped, true, nextAction);
    assertEquals((db.row.warnings ?? []).length, 0, nextAction);
  }
});

Deno.test("first-pass missing climax declaration stays intact after verification with no Story Arc rewrite", async () => {
  const fullBody = await executableWorkerBody();
  const body: any = {
    ...fullBody,
    arcTemplate: {
      ...fullBody.arcTemplate,
      name: "Save the Cat!",
      beats: fullBody.arcTemplate.beats.map((beat: any, index: number) => index === 1
        ? { ...beat, role: "final_image", label: "Final Image", description: "Show the accomplished result." }
        : beat),
    },
  };
  const ids = Array.from({ length: 63 }, (_, index) => `R${index + 1}`);
  const original = [
    {
      title: "The attempt fails", summary: "The captives remain on the transport.", container: "scene",
      pov: "thirdPersonLimited", terminalBeat: "They must improvise.", entryState: "Captives remain locked inside.",
      dramaticEvent: "The first attempt fails.", resultingChange: "The problem persists.",
      terminalState: "Captives remain on the transport.", dramaticFunction: "setup", storyArcBeatID: "beat-1", recipeRequirementIDs: ids,
    },
    {
      title: "They finally escape", summary: "The crowd opens the way and the captives escape.", container: "scene",
      pov: "thirdPersonLimited", terminalBeat: "The captives are free.", entryState: "The captives remain on the transport.",
      dramaticEvent: "The captives escape when the crowd blocks the guards.",
      resultingChange: "The transfer is stopped and the captives escape.",
      terminalState: "The captives remain free and the transfer cannot resume.",
      dramaticFunction: "aftermath", storyArcBeatID: "beat-2", recipeRequirementIDs: ids,
    },
  ];
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: original,
    planning_state: {
      version: 2, phase: "semantic_verification_pending", nextAction: "semantic-verification",
      allocationEntries: [
        ["beat-1", { minSections: 1, rationale: "fixture" }],
        ["beat-2", { minSections: 1, rationale: "fixture" }],
      ],
    },
  });
  const calls: string[] = [];
  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: fakeWorkerBilling(calls) as any, scheduleContinuation: async () => {},
  });
  assertEquals(calls, ["outline-semantic-verification"]);
  assertEquals(db.row.status, "completed", JSON.stringify({ error: db.row.error, diagnostics: db.row.diagnostics }));
  assertEquals(db.row.suggestions, original);
  assertEquals(db.row.diagnostics.storyArcRewriteSkipped, true);
  assertEquals((db.row.warnings ?? []).length, 0);
});

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

Deno.test("empty arc evidence is no claim and still reaches semantic verification", async () => {
  const body = await executableWorkerBody();
  const row: any = { ...checkpointedWorkerRow(body), request_json: body };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const section = (beat: string, title: string) => ({
    title,
    summary: `${title} summary`,
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`,
    storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution",
    recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`),
    entryState: "The prior state holds.",
    dramaticEvent: `${title} happens.`,
    resultingChange: `${title} changes the pressure.`,
    terminalState: `${title} hands forward the next state.`,
    arcObligationEvidence: { authored_beat_requirement: [] },
  });
  const billable = validatedWorkerBilling(actions, (action) => action === "outline-suggestions"
    ? { beats: { "beat-1": [section("beat-1", "Opening")], "beat-2": [section("beat-2", "Cost")] } }
    : { suggestions: [] });
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {}, billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.status, "pending");
  assertEquals(db.patchHistory.some((patch: any) => patch.suggestions?.[0]?.arcObligationEvidence?.authored_beat_requirement?.length === 0), true);
  assertEquals(db.row.suggestions[0].arcObligationEvidence, {});
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
});

Deno.test("malformed arc evidence preserves the paid outline candidate without rerunning completed stages", async () => {
  const body = await executableWorkerBody();
  const row: any = { ...checkpointedWorkerRow(body), request_json: body };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const malformed = (beat: string, title: string) => ({
    title,
    summary: `${title} summary`,
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`,
    storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution",
    recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`),
    entryState: "The prior state holds.",
    dramaticEvent: `${title} happens.`,
    resultingChange: `${title} changes the pressure.`,
    terminalState: `${title} hands forward the next state.`,
    arcObligationEvidence: { fabricated_obligation: [{ field: "resultingChange", quote: "invented proof" }] },
  });
  const billable = validatedWorkerBilling(actions, (action) => action === "outline-suggestions"
    ? { beats: { "beat-1": [malformed("beat-1", "Opening")], "beat-2": [malformed("beat-2", "Cost")] } }
    : { suggestions: [] });
  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {}, billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.status, "failed");
  assertEquals(db.row.suggestions[0].title, "Opening");
  assertEquals(db.row.diagnostics.outlineCandidatePersistedBeforeValidation, true);
});

Deno.test("missing authored beat evidence remains a beat-level semantic issue", () => {
  const template: any = { name: "Custom", beats: [{ id: "beat", role: "setup", label: "Setup", description: "Establish the route." }] };
  const sections: any[] = [{
    storyArcBeatID: "beat",
    title: "Opening",
    summary: "Opening",
    dramaticEvent: "The route opens.",
    resultingChange: "The route is uncertain.",
    terminalState: "The travelers continue.",
    arcObligationEvidence: {},
  }];
  const issues = validateArcSemanticObligations(sections, template);
  assertEquals(issues.length, 1);
  assertStringIncludes(issues[0], "authored_beat_requirement");
});

Deno.test("optional enrichment expansion checkpoints a global round before the next dispatch", async () => {
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
  const baseSection = (beat: string, title: string) => ({ title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`), entryState: "Prior state", dramaticEvent: `${title} happens`, resultingChange: `${title} changes the pressure`, terminalState: `${title} hands forward pressure` });
  const billable = validatedWorkerBilling(actions, (action) => {
    if (action === "outline-suggestions") return { beats: { "beat-1": [baseSection("beat-1", "Opening")], "beat-2": [baseSection("beat-2", "Closing")] } };
    const beat = action.endsWith("beat-1") ? "beat-1" : "beat-2";
    const count = beat === "beat-1" ? 7 : 2;
    return { suggestions: Array.from({ length: count }, (_, index) => expansionSection(`${action}-${index}`, "scene", beat)) };
  });
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.status, "pending");
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.planning_state.phase, "expansion");
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification", "outline-expansion-1-global"]);
  assertEquals(db.row.planning_state.expansionCheckpoint.nextRound, 2);
  assertEquals(db.row.planning_state.expansionCheckpoint.nextBeatIndex, 0);
  assertEquals(db.row.suggestions.some((section: any) => section.title.includes("global-0")), true);
  assertEquals(db.row.status, "pending");
  assertEquals(db.row.planning_state.phase, "expansion");
  assertEquals(db.row.attempt_count, 0);
});

Deno.test("unused enrichment does not expand a novel with scale and beat coverage", async () => {
  const fullBody = await executableWorkerBody();
  const novelMaterial = attachRecipeProvenance({
    ...fullBody.storyMaterialEnrichment,
    format: "novel",
    locations: [
      { id: "unused-location-1", source: "planner", sourceReference: null, label: "Shelter", description: "A defensible shelter." },
      { id: "unused-location-2", source: "planner", sourceReference: null, label: "Crossing", description: "A dangerous crossing." },
    ],
    escalationLadder: [
      { id: "unused-escalation-1", source: "planner", sourceReference: null, label: "First pressure", description: "The first pressure rises." },
      { id: "unused-escalation-2", source: "planner", sourceReference: null, label: "Second pressure", description: "The second pressure rises." },
      { id: "unused-escalation-3", source: "planner", sourceReference: null, label: "Unused escalation", description: "An unused escalation." },
    ],
    reversals: [{ id: "unused-reversal", source: "planner", sourceReference: null, label: "Reversal", description: "The plan turns." }],
    consequences: [{ id: "unused-consequence", source: "planner", sourceReference: null, label: "Consequence", description: "The choice costs something." }],
  } as any, await recipeProvenance(fullBody.recipe as any));
  const body = {
    ...fullBody,
    requestedFormat: "novel",
    storyMaterialEnrichment: novelMaterial,
    existingSections: Array.from({ length: 27 }, (_, index) => ({
      title: `Existing chapter ${index + 1}`,
      summary: "Existing chapter material.",
      container: "chapter",
    })),
  } as any;
  const db = new ExecutableRunDb({ ...checkpointedWorkerRow(body), story_material: novelMaterial });
  const actions: string[] = [];
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: fakeWorkerBilling(actions) as any,
    scheduleContinuation: async () => {},
  });
  await run();
  await run();
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.diagnostics.unusedStoryMaterialItems > 0, true);
  assertEquals(db.row.diagnostics.expansionRounds ?? [], []);
});

Deno.test("weak resolution preserves existing no-semantic-call scheduling", async () => {
  const fullBody = await executableWorkerBody();
  const novelMaterial = attachRecipeProvenance({
    ...fullBody.storyMaterialEnrichment,
    format: "novel",
    locations: [
      { id: "repair-location-1", source: "planner", sourceReference: null, label: "Shelter", description: "A defensible shelter." },
      { id: "repair-location-2", source: "planner", sourceReference: null, label: "Crossing", description: "A dangerous crossing." },
    ],
    escalationLadder: [
      { id: "repair-escalation-1", source: "planner", sourceReference: null, label: "First pressure", description: "The first pressure rises." },
      { id: "repair-escalation-2", source: "planner", sourceReference: null, label: "Second pressure", description: "The second pressure rises." },
      { id: "repair-escalation-3", source: "planner", sourceReference: null, label: "Final pressure", description: "The final pressure rises." },
    ],
    reversals: [{ id: "repair-reversal", source: "planner", sourceReference: null, label: "Reversal", description: "The plan turns." }],
    consequences: [{ id: "repair-consequence", source: "planner", sourceReference: null, label: "Consequence", description: "The choice costs something." }],
  } as any, await recipeProvenance(fullBody.recipe as any));
  const body = {
    ...fullBody,
    requestedFormat: "novel",
    storyMaterialEnrichment: novelMaterial,
    existingSections: Array.from({ length: 27 }, (_, index) => ({ title: `Existing chapter ${index + 1}`, summary: "Existing chapter material.", container: "chapter" })),
    arcTemplate: {
      ...fullBody.arcTemplate,
      name: "Save the Cat!",
      beats: fullBody.arcTemplate.beats.map((beat: any, index: number) => ({ ...beat, role: index === 1 ? "final_image" : beat.role, label: index === 1 ? "Final Image" : beat.label, description: "" })),
    },
  } as any;
  const weakSection = (beat: string, title: string) => ({ title, summary: `${title} summary`, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`), entryState: "The prior state holds.", dramaticEvent: beat === "beat-1" ? `${title} happens.` : "The survivors mourn what was lost.", resultingChange: beat === "beat-1" ? `${title} changes the pressure.` : "The aftermath continues.", terminalState: beat === "beat-1" ? `${title} hands forward a new pressure.` : "The former conflict remains unresolved." });
  const repairedSection = { ...weakSection("beat-2", "The Settled Cost"), summary: "The central conflict is settled and its cost is accepted.", dramaticEvent: "The survivors resolve the central conflict and choose the new normal.", resultingChange: "The central conflict is resolved and the cost is accepted.", terminalState: "The new normal holds without the former conflict continuing." };
  const db = new ExecutableRunDb({ ...checkpointedWorkerRow(body), story_material: novelMaterial });
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (action) => {
    if (action === "outline-suggestions") return { beats: { "beat-1": [weakSection("beat-1", "Opening")], "beat-2": [weakSection("beat-2", "The Aftermath")] } };
    if (action === "outline-semantic-repair-batch") return { replacements: [{ sectionIndex: 1, beatID: "beat-2", section: repairedSection }] };
    return { suggestions: [] };
  }, (request) => {
    const response: any = semanticVerifierFixture(request);
    for (const beat of response.beats ?? []) {
      for (const obligation of beat.obligations ?? []) {
        if (obligation.obligationID === REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id) {
          obligation.satisfied = false;
          obligation.reason = "The aftermath leaves the central conflict unresolved.";
        }
      }
    }
    return response;
  });
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {}, billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(actions, ["outline-suggestions"]);
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.planning_state.nextAction, "completed");
  assertEquals(db.row.suggestions.some((section: any) => section.title === "The Aftermath"), true);
  assertEquals(actions.some((action) => action.startsWith("outline-semantic-")), false);
  assertEquals(actions.some((action) => action.startsWith("outline-expansion-")), false);
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
  await run();
  assertEquals(actions, ["story-material-enrichment", "outline-plan", "outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.diagnostics.generatedOrReused, "generated", "a continuation must not rewrite a fresh run as prior-run enrichment reuse");
  assertEquals(db.row.diagnostics.enrichmentLoadedFromCheckpoint, true);
  assertEquals(db.row.attempt_count, 0);
  assertEquals(actions.some((action) => action.startsWith("outline-route-")), false);
  assertEquals(actions.some((action) => action.startsWith("outline-suggestions-beat-")), false);
  assertEquals(db.row.status, "completed");
});

Deno.test("worker resume rehydrates prior stages without fabricating cross-stage progress", async () => {
  const fullBody = await executableWorkerBody();
  const body = { ...fullBody, storyMaterialEnrichment: undefined } as any;
  const row = {
    ...checkpointedWorkerRow(body),
    story_material: null,
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
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });

  await run();
  const afterEnrichment = db.row.diagnostics.worker.lastMeaningfulProgressAt;
  await run();
  const afterAllocation = db.row.diagnostics.worker.lastMeaningfulProgressAt;
  assertEquals(afterAllocation !== afterEnrichment, true);
  assertEquals(db.row.id, "run-worker-fixture");

  const replayStart = db.patchHistory.length;
  await run();
  await run();
  assertEquals(actions, ["story-material-enrichment", "outline-plan", "outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  const replayedStages = db.patchHistory.slice(replayStart)
    .filter((patch) => (patch.diagnostics as any)?.stage === "story_material_ready")
    .map((patch) => (patch.diagnostics as any).worker.lastMeaningfulProgressAt);
  assertEquals(replayedStages.length > 0, true);
  assertEquals(replayedStages.every((value) => value === afterAllocation), true);
  assertEquals((db.row.diagnostics.worker.completedMeaningfulCheckpointIdentities as string[]).some((value) => value.startsWith("allocation_validated:")), true);
});

Deno.test("actual worker replay of the same persisted checkpoint keeps its timestamp", async () => {
  const body = await executableWorkerBody();
  const before = "2026-01-01T00:00:00.000Z";
  const row = {
    ...checkpointedWorkerRow(body),
    diagnostics: {
      worker: {
        lastMeaningfulProgressAt: before,
        lastMeaningfulProgressCheckpoint: "allocation_validated:fixture",
        completedMeaningfulCheckpointIdentities: ["planning_context_persisted:fixture", "allocation_validated:fixture"],
      },
    },
  };
  const db = new ExecutableRunDb(row);
  const dispatches: string[] = [];
  const billable = async (request: any) => {
    dispatches.push(request.action);
    throw new SuggestionWorkerYield();
  };
  const run = () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  await run();
  const firstReplay = db.row.diagnostics.worker.lastMeaningfulProgressAt;
  await run();
  const secondReplay = db.row.diagnostics.worker.lastMeaningfulProgressAt;
  assertEquals(dispatches, ["outline-suggestions", "outline-suggestions"]);
  assertEquals(firstReplay !== before, true);
  assertEquals(secondReplay, firstReplay);
  assertEquals(db.row.status, "pending");
});

Deno.test("actual worker persistence advances for a genuinely new allocation checkpoint", async () => {
  const body = await executableWorkerBody();
  const before = "2026-01-01T00:00:00.000Z";
  const row = {
    ...checkpointedWorkerRow(body),
    diagnostics: { worker: { lastMeaningfulProgressAt: before, completedMeaningfulCheckpointIdentities: [] } },
    planning_state: { version: 2, phase: "enrichment_complete", nextAction: "outline-plan" },
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (action) => action === "outline-plan"
    ? { allocations: [{ beatIndex: 0, minSections: 1, rationale: "new" }, { beatIndex: 1, minSections: 1, rationale: "new" }] }
    : { beats: { "beat-1": [], "beat-2": [] } });
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  assertEquals(actions, ["outline-plan"]);
  assertEquals(db.row.status, "pending");
  assertEquals(db.row.diagnostics.worker.lastMeaningfulProgressAt !== before, true);
  assertEquals((db.row.diagnostics.worker.completedMeaningfulCheckpointIdentities as string[]).some((value) => value.startsWith("allocation_validated:")), true);
});

Deno.test("failed durable checkpoint persistence prevents the next provider stage", async () => {
  const body = await executableWorkerBody();
  for (const failAsZeroRows of [false, true]) {
    const before = "2026-01-01T00:00:00.000Z";
    const db = new ExecutableRunDb({
      ...checkpointedWorkerRow(body),
      diagnostics: { worker: { lastMeaningfulProgressAt: before, completedMeaningfulCheckpointIdentities: [] } },
    }, { failPatchField: "diagnostics", failAsZeroRows });
    const providerCalls: string[] = [];
    await assertRejects(
      () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
        db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
        billableLLM: (async (request: any) => { providerCalls.push(request.action); return fakeWorkerBilling([])(request); }) as any,
        scheduleContinuation: async () => {},
      }),
      Error,
      failAsZeroRows ? "updated zero rows" : "simulated PostgREST checkpoint failure",
    );
    assertEquals(providerCalls, []);
    assertEquals(db.row.status === "completed", false);
    assertEquals(db.row.diagnostics.worker.lastMeaningfulProgressAt, before);
  }
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
  await run();
  assertEquals(actions, ["story-material-enrichment", "outline-plan", "outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
});

Deno.test("initial and resumed optional expansion preserve the newest valid checkpoint", async () => {
  const shortBody = await executableWorkerBody();
  const provenance = await recipeProvenance(shortBody.recipe as any);
  const plannerItem = (id: string) => ({
    id, source: "planner", sourceReference: null, label: id,
    description: `${id} creates a concrete pressure, decision, and consequence.`,
  });
  const novelMaterial = attachRecipeProvenance({
    ...repairStoryMaterialFromRecipe(shortBody.recipe, provenance, "novel"),
    conflictSources: [plannerItem("conflict-1"), plannerItem("conflict-2")],
    escalationLadder: [plannerItem("escalation-1"), plannerItem("escalation-2"), plannerItem("escalation-3")],
    reversals: [plannerItem("reversal-1")],
    consequences: [plannerItem("consequence-1")],
  } as any, provenance);
  const body = {
    ...shortBody,
    requestedFormat: "novel",
    storyMaterialEnrichment: novelMaterial,
  } as any;
  const baseSection = (beat: string, title: string) => ({
    title, summary: `${title} summary`, container: "chapter", pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`, storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution",
    recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`),
    entryState: "The prior state holds.", dramaticEvent: `${title} happens.`,
    resultingChange: `${title} changes the pressure.`, terminalState: `${title} hands forward pressure.`,
  });
  const firstPass = Array.from({ length: 25 }, (_, index) =>
    baseSection(index === 24 ? "beat-2" : "beat-1", `First-pass chapter ${index + 1}`));
  const initialDB = new ExecutableRunDb(checkpointedWorkerRow(body));
  const initialActions: string[] = [];
  const initialBilling = validatedWorkerBilling(initialActions, (action) => {
    if (action === "outline-suggestions") {
      return {
        beats: {
          "beat-1": firstPass.filter((section) => section.storyArcBeatID === "beat-1"),
          "beat-2": firstPass.filter((section) => section.storyArcBeatID === "beat-2"),
        },
      };
    }
    if (action === "outline-expansion-1-global") {
      return { suggestions: [expansionSection("Checkpoint chapter 26", "chapter"), expansionSection("Checkpoint chapter 27", "chapter")] };
    }
    // A valid first expansion is followed by a recoverable under-target
    // failure, exercising completion from the persisted 27-section state.
    return { suggestions: [] };
  });
  const initialRun = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db: initialDB,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: initialBilling as any,
    scheduleContinuation: async () => {},
  });
  await initialRun();
  await initialRun();
  await initialRun();
  await initialRun();
  assertEquals(initialDB.row.status, "completed");
  assertEquals(initialDB.row.suggestions.length, 27);
  assertEquals(initialDB.row.suggestions.map((section: any) => section.title), [
    ...firstPass.slice(0, 24).map((section) => section.title),
    "Checkpoint chapter 26",
    "Checkpoint chapter 27",
    firstPass[24].title,
  ]);
  assertEquals(initialActions, ["outline-suggestions", "outline-semantic-verification", "outline-expansion-1-global"]);
  assertEquals(initialDB.row.warnings.some((warning: string) => warning.includes("Optional novel expansion did not finish")), false);

  const completedRound = {
    round: 1,
    sectionCountBefore: 2,
    projectedTokensBefore: 11000,
    projectedWordsBefore: 8462,
    additionsReturned: 0,
    sectionCountAfter: 2,
    projectedTokensAfter: 11000,
    projectedWordsAfter: 8462,
    remainingEstimatedDeficitTokens: 138500,
    status: "completed",
  } as const;
  const resumedRow = {
    ...initialDB.row,
    status: "pending",
    error: null,
    error_code: null,
    completed_at: null,
    lease_owner: null,
    lease_expires_at: null,
    planning_state: {
      ...initialDB.row.planning_state,
      phase: "expansion",
      nextAction: "expansion",
      expansionCheckpoint: {
        stage: "expansion",
        nextRound: 2,
        nextBeatIndex: 0,
        scale: evaluateNovelScale(initialDB.row.suggestions),
        expansionRounds: [completedRound],
      },
    },
    diagnostics: {
      ...initialDB.row.diagnostics,
      expansionCheckpoint: {
        stage: "expansion",
        nextRound: 2,
        nextBeatIndex: 0,
        scale: evaluateNovelScale(initialDB.row.suggestions),
        expansionRounds: [completedRound],
      },
    },
  };
  const resumedDB = new ExecutableRunDb(resumedRow);
  const resumedActions: string[] = [];
  const resumedRun = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db: resumedDB,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: fakeWorkerBilling(resumedActions) as any,
    scheduleContinuation: async () => {},
  });
  await resumedRun();
  assertEquals(resumedDB.row.status, "completed");
  assertEquals(resumedDB.row.suggestions, initialDB.row.suggestions);
  assertEquals(resumedDB.row.warnings, initialDB.row.warnings);
  assertEquals(resumedActions, []);
});

Deno.test("production checkpoint resume executes the single global outline call once", async () => {
  const body = await executableWorkerBody();
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const billableActions: string[] = [];
  const providerCalls: string[] = [];
  const scheduled: Array<{ body: any; auth: string }> = [];
  const run = () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: fakeWorkerBilling(billableActions, providerCalls) as any,
    scheduleContinuation: async (continuationBody, auth) => { scheduled.push({ body: continuationBody, auth }); },
  });
  await run();
  await run();
  assertEquals(providerCalls, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(billableActions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  assertEquals(scheduled.length, 1);
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
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: fakeWorkerBilling(actions) as any, scheduleContinuation: async () => {},
  });
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  const diagnostics = db.row.diagnostics;
  assertEquals(Array.isArray(diagnostics.dramaticDistinctnessIssues), true);
  assertEquals(Array.isArray(diagnostics.semanticArcIssues), true);
  assertEquals(Array.isArray(diagnostics.causalScaleIssues), true);
  assertEquals(typeof diagnostics.unusedStoryMaterialItems, "number");
  assertEquals(typeof diagnostics.plannerCharacterIntegration, "object");
  assertEquals("advisoryValidationError" in diagnostics, false);
  assertEquals(typeof diagnostics.recipeObligationCoverage, "object");
  assertEquals(diagnostics.missingRequiredRecipeObligations, []);
});


Deno.test("required-obligation repair prompt and validator preserve the contract", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const template = sparseRequest.arcTemplate as any;
  const section = { title: "Repair", summary: "A repair", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Repair ends", entryState: "Before", dramaticEvent: "Repair happens", resultingChange: "Pressure changes", terminalState: "After", dramaticFunction: arcRoleContract(template.beats[0], template.name).allowedFunctions[0], storyArcBeatID: template.beats[0].id, recipeRequirementIDs: [obligations[0].id] };
  const prompt = buildObligationRepairPrompt(sparseRequest as any, [], [], [obligations[0]]);
  assertEquals(prompt.user.includes(obligations[0].id), true);
  const repaired = mergeObligationRepairOperations([], { operations: [{ action: "add", replaceIndex: null, section }] }, new Set(template.beats.map((beat: any) => beat.id)), obligations, template);
  assertEquals(repaired[0].recipeRequirementIDs, [obligations[0].id]);
  assertThrows(() => mergeObligationRepairOperations([], { operations: [{ action: "add", replaceIndex: null, section: { ...section, recipeRequirementIDs: ["R999"] } }] }, new Set(template.beats.map((beat: any) => beat.id)), obligations, template));
});

Deno.test("required-obligation repair schema is strict and obligation-enumerated", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const template = sparseRequest.arcTemplate as any;
  const schema: any = buildObligationRepairResponseSchema(
    new Set(template.beats.map((beat: any) => beat.id)),
    obligations,
    template,
  );
  const section = schema.properties.operations.items.properties.section;
  assertEquals(section.additionalProperties, false);
  assertEquals(section.required.sort(), Object.keys(section.properties).sort());
  assertEquals(section.properties.recipeRequirementIDs.items.enum, obligations.map((obligation) => obligation.id));
  assertEquals(schema.properties.operations.items.additionalProperties, false);
});

Deno.test("required-obligation repair replacement uses stable index with duplicate titles", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const template = sparseRequest.arcTemplate as any;
  const base = (beatIndex: number) => ({ title: "Duplicate", summary: "Old", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Old ends", entryState: "Before", dramaticEvent: "Old event", resultingChange: "Old change", terminalState: "After", dramaticFunction: arcRoleContract(template.beats[beatIndex], template.name).allowedFunctions[0], storyArcBeatID: template.beats[beatIndex].id, recipeRequirementIDs: [] });
  const replacement = { ...base(1), summary: "New", recipeRequirementIDs: [obligations[0].id] };
  const repaired = mergeObligationRepairOperations(
    [base(0), base(1)],
    { operations: [{ action: "replace", replaceIndex: 1, section: replacement }] },
    new Set(template.beats.map((beat: any) => beat.id)),
    obligations,
    template,
  );
  assertEquals(repaired[0].title, "Duplicate");
  assertEquals(repaired[1].title, "Duplicate");
  assertEquals(repaired[1].storyArcBeatID, template.beats[1].id);
  assertThrows(
    () => mergeObligationRepairOperations(
      [base(0), base(1)],
      { operations: [{ action: "replace", replaceIndex: 1, section: { ...replacement, storyArcBeatID: template.beats[0].id } }] },
      new Set(template.beats.map((beat: any) => beat.id)),
      obligations,
      template,
    ),
    RecipeObligationValidationError,
  );
});

Deno.test("required-obligation repair inserts additions in canonical beat order", () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const template = sparseRequest.arcTemplate as any;
  const section = (title: string, beatIndex: number, ids: string[] = []) => ({ title, summary: title, container: "scene", pov: "thirdPersonLimited", terminalBeat: `${title} ends`, entryState: "Before", dramaticEvent: `${title} happens`, resultingChange: `${title} changes pressure`, terminalState: "After", dramaticFunction: arcRoleContract(template.beats[beatIndex], template.name).allowedFunctions[0], storyArcBeatID: template.beats[beatIndex].id, recipeRequirementIDs: ids });
  const current = [section("Beat 1 A", 0), section("Beat 2 B", 1)];
  const repaired = mergeObligationRepairOperations(
    current,
    { operations: [{ action: "add", replaceIndex: null, section: section("Beat 1 C", 0, [obligations[0].id]) }] },
    new Set(template.beats.map((beat: any) => beat.id)),
    obligations,
    template,
  );
  assertEquals(repaired.map((item) => item.title), ["Beat 1 A", "Beat 1 C", "Beat 2 B"]);
  const finalBeatRepair = mergeObligationRepairOperations(
    current,
    { operations: [{ action: "add", replaceIndex: null, section: section("Beat 2 C", 1, [obligations[0].id]) }] },
    new Set(template.beats.map((beat: any) => beat.id)),
    obligations,
    template,
  );
  assertEquals(finalBeatRepair.map((item) => item.title), ["Beat 1 A", "Beat 2 B", "Beat 2 C"]);
});

Deno.test("required-obligation repair is one billable stage and rechecks coverage", async () => {
  const obligations = deriveRecipeObligations(sparseRequest.recipe as any);
  const template = sparseRequest.arcTemplate as any;
  const section = { title: "Repair", summary: "A repair", container: "scene", pov: "thirdPersonLimited", terminalBeat: "Repair ends", entryState: "Before", dramaticEvent: "Repair happens", resultingChange: "Pressure changes", terminalState: "After", dramaticFunction: arcRoleContract(template.beats[0], template.name).allowedFunctions[0], storyArcBeatID: template.beats[0].id, recipeRequirementIDs: obligations.map((obligation) => obligation.id) };
  const actions: string[] = [];
  const result = await repairRequiredRecipeObligations([], sparseRequest as any, obligations, (async (_a: any, _b: any, _c: any, _d: any, action: string, validate: any) => { actions.push(action); const content = JSON.stringify({ operations: [{ action: "add", replaceIndex: null, section }] }); await validate(content); return { content, creditCostCharged: 1, remainingCredits: 1 }; }) as any);
  assertEquals(actions, ["outline-obligation-repair"]);
  assertEquals(result.missing, []);
});

Deno.test("authored recipe and character candidates survive but procedural enrichment never re-enters planning, outline, or expansion", () => {
  const apparatus = { id: "invented-raid", source: "planner", label: "Government detainment", description: "Contractor transport and containment mission." };
  const alternateApparatus = { id: "procedural-reversal", source: "planner", label: "Rescue requires a screening raid", description: "The heroes disable an official tracking program." };
  const character = { id: "eccentric-character", source: "planner", label: "Feral road grifter", description: "An impulsive friend lies, steals, and wrecks relationships." };
  const relationship = { id: "poisonous-pact", source: "planner", label: "Toxic friendship", description: "Mutual dependency drives escalating catastrophe." };
  const authored = { id: "recipe-person", source: "recipe", label: "Authored antagonist", description: "A character the author requires." };
  const categories = [
    "characters", "antagonisticForces", "locations", "institutionsAndGroups",
    "conflictSources", "escalationLadder", "reversals", "consequences",
    "relationships", "discoveries", "unresolvedQuestions", "thematicPressures",
  ];
  const material = {
    ...Object.fromEntries(categories.map((category) => [category, []])),
    characters: [character],
    relationships: [relationship],
    antagonisticForces: [apparatus, authored],
    escalationLadder: [apparatus],
    locations: [apparatus],
    institutionsAndGroups: [apparatus],
    conflictSources: [apparatus],
    discoveries: [apparatus],
    reversals: [alternateApparatus],
    consequences: [apparatus],
    unresolvedQuestions: [apparatus],
  };
  const request: any = { ...sparseRequest, storyMaterialEnrichment: material };
  const planning = buildArchitecturePlanningView(request, [], material);
  const index = planning.materialIndex as any[];
  assertEquals(index.some((item) => item.id === "invented-raid"), false);
  assertEquals(index.some((item) => item.id === "procedural-reversal"), false);
  assertEquals(index.some((item) => item.id === "recipe-person"), true);
  assertEquals(index.some((item) => item.id === "eccentric-character"), true);
  assertEquals(index.some((item) => item.id === "poisonous-pact"), true);
  assertEquals((planning.recipe as any).project.summary, request.recipe.project.summary);
  assertEquals((buildCompactPlanningView(request).materialIndex as any[]).some((item) => item.id === "invented-raid"), true, "full material stays available for QA and provenance");

  const allocationPrompt = buildAllocationPrompt(request);
  const outlinePrompt = buildPrompt(request, new Map(), [], material as any);
  const expansionPrompt = buildExpansionPrompt(request, [], undefined, []);
  for (const [stage, prompt] of [
    ["architecture", allocationPrompt],
    ["initial outline", outlinePrompt],
    ["length expansion", expansionPrompt],
  ] as const) {
    assertEquals(prompt.user.includes("invented-raid"), false, stage);
    assertEquals(prompt.user.includes("procedural-reversal"), false, stage);
    assertEquals(prompt.user.includes("Contractor transport and containment mission"), false, stage);
    assertEquals(prompt.user.includes("eccentric-character"), true, stage);
    assertEquals(prompt.user.includes("recipe-person"), true, stage);
  }
  assertStringIncludes(outlinePrompt.user, "poisonous-pact");
  assertStringIncludes(outlinePrompt.system, "Selected causal architecture");
});

Deno.test("series-scale authored premise components are preserved without forced book-one world-saving operations", () => {
  const summary = "Their notoriety destabilizes America's institutions, and their chaotic actions someday become essential to humanity's survival.";
  const premiseComponents = [
    { sourceQuote: "Their notoriety destabilizes America's institutions", requirement: "Their notoriety eventually destabilizes institutions." },
    { sourceQuote: "their chaotic actions someday become essential to humanity's survival", requirement: "Their decisions eventually matter to humanity's survival." },
  ];
  const recipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, summary } };
  const obligations = deriveRecipeObligations(recipe, premiseComponents);
  const statements = obligations.filter((obligation) => obligation.source.startsWith("project.summary.component."));
  assertEquals(statements.length, 2);
  assertEquals(statements.every((obligation) => obligation.required), true);
  assertStringIncludes(statements[1].statement, "foreshadow");
  assertStringIncludes(statements[1].statement, "multi-book");
  assertEquals(statements[1].statement.includes("concrete, causally meaningful contribution"), false);
  const request: any = { ...sparseRequest, recipe, storyMaterialEnrichment: { premiseComponents } };
  assertStringIncludes(buildAllocationPrompt(request, obligations).system, "Series-level consequences can be seeded");
  assertStringIncludes(buildPrompt(request, new Map(), obligations, request.storyMaterialEnrichment as any).system, "may be seeded");
});


Deno.test("missing recipe IDs remain internal QA and never discard a paid outline", async () => {
  const body = await executableWorkerBody();
  const section = (beat: string) => ({
    title: `Missing ${beat}`, summary: "Missing recipe coverage", container: "scene",
    pov: "thirdPersonLimited", terminalBeat: "It ends", entryState: "Before",
    dramaticEvent: "It happens", resultingChange: "Pressure changes",
    terminalState: "After", storyArcBeatID: beat,
    dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: [],
  });
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (action) => action === "outline-suggestions"
    ? { beats: { "beat-1": [section("beat-1")], "beat-2": [section("beat-2")] } }
    : { suggestions: [] });
  const run = () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  await run();
  assertEquals(db.row.status, "pending");
  await run();
  assertEquals(db.row.status !== "failed", true, db.row.error ?? "no error");
  assertEquals(db.row.error_code ?? null, null);
  assertEquals(db.row.suggestions.length, 2, "the paid first-pass outline survives");
  assertEquals(db.row.diagnostics.missingRequiredRecipeObligations.length > 0, true);
  assertEquals(db.row.diagnostics.premiseCoverageAssessment, "needs_review");
  assertEquals(db.row.diagnostics.automaticNarrativeRepair, "disabled");
  assertEquals(actions.slice(0, 2), ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(actions.some((action) => action.includes("repair")), false);
  assertEquals((db.row.warnings ?? []).some((warning: string) => /semantic|validation|obligation|recipe/i.test(warning)), false);
});

Deno.test("missing recipe ID coverage never schedules an obligation repair checkpoint", async () => {
  const body = await executableWorkerBody();
  const row = {
    ...checkpointedWorkerRow(body),
    suggestions: [
      { title: "Opening", storyArcBeatID: "beat-1", container: "scene", recipeRequirementIDs: [] },
      { title: "Ending", storyArcBeatID: "beat-2", container: "scene", recipeRequirementIDs: [] },
    ],
    planning_state: { version: 2, phase: "semantic_completion", nextAction: "semantic-completion" },
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: fakeWorkerBilling(actions) as any, scheduleContinuation: async () => {},
  });
  assertEquals(actions, []);
  assertEquals(db.row.status !== "failed", true, db.row.error ?? "no error");
  assertEquals(db.row.error_code ?? null, null);
  assertEquals(db.row.diagnostics.missingRequiredRecipeObligations.length > 0, true);
  assertEquals(db.row.planning_state.nextAction !== "obligation-repair", true);
});

Deno.test("first-pass recipe coverage enters novel length controls without a narrative repair", async () => {
  const fullBody = await executableWorkerBody();
  const novelMaterial = attachRecipeProvenance({
    ...repairStoryMaterialFromRecipe(fullBody.recipe as any, {
      sourceRecipeHash: "worker-fixture",
      sourceRecipeVersion: 1,
      sourcePromptPackID: "worker-pack",
      sourcePromptPackName: "Worker fixture",
    }, "novel"),
    schema: "cathedralos.story_material_enrichment",
    rationale: "Worker fixture",
    locations: [
      { id: "worker-location-1", source: "planner", sourceReference: null, label: "Shelter", description: "A defensible shelter." },
      { id: "worker-location-2", source: "planner", sourceReference: null, label: "Crossing", description: "A dangerous crossing." },
    ],
    escalationLadder: [
      { id: "worker-escalation-1", source: "planner", sourceReference: null, label: "First pressure", description: "The first pressure rises." },
      { id: "worker-escalation-2", source: "planner", sourceReference: null, label: "Second pressure", description: "The second pressure rises." },
      { id: "worker-escalation-3", source: "planner", sourceReference: null, label: "Final pressure", description: "The final pressure rises." },
    ],
    reversals: [{ id: "worker-reversal-1", source: "planner", sourceReference: null, label: "Reversal", description: "The plan turns." }],
    consequences: [{ id: "worker-consequence-1", source: "planner", sourceReference: null, label: "Consequence", description: "The choice costs something." }],
  } as any,
    await recipeProvenance(fullBody.recipe as any),
  );
  const body = { ...fullBody, requestedFormat: "novel", storyMaterialEnrichment: novelMaterial } as any;
  const obligations = deriveRecipeObligations(body.recipe as any);
  const section = (ids: string[], beat = "beat-1") => ({ title: `Repairable ${beat}`, summary: "A section", container: "scene", pov: "thirdPersonLimited", terminalBeat: "It ends", entryState: "Before", dramaticEvent: "It happens", resultingChange: "Pressure changes", terminalState: "After", storyArcBeatID: beat, dramaticFunction: beat === "beat-1" ? "setup" : "resolution", recipeRequirementIDs: ids });
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (action) => {
    if (action === "outline-suggestions") return { beats: { "beat-1": [section(obligations.map((obligation) => obligation.id))], "beat-2": [section(obligations.map((obligation) => obligation.id), "beat-2")] } };
    return { suggestions: [] };
  });
  const run = () => runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {}, billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  await run();
  await run();
  await run();
  assertEquals(db.row.status, "completed", db.row.error ?? "no error");
  assertEquals(db.row.planning_state.phase, "completed");
  assertEquals(actions.slice(0, 3), ["outline-suggestions", "outline-semantic-verification", "outline-expansion-1-global"]);
  assertEquals(actions.some((action) => action.includes("repair")), false);
  assertEquals(db.row.diagnostics.automaticNarrativeRepair, "disabled");
});

Deno.test("provider billing unavailable during allocation bypasses retry and fails safely", async () => {
  const body = await executableWorkerBody();
  const existingSuggestion = { title: "Allocation checkpoint", summary: "Preserve this suggestion" };
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: [existingSuggestion],
    planning_state: { version: 2, phase: "enrichment_complete", nextAction: "outline-plan" },
  });
  const contexts: any[] = [];
  const scheduled: Promise<unknown>[] = [];
  let continuationCount = 0;
  const billable = async (request: any) => {
    assertEquals(request.action, "outline-plan");
    throw new ProviderBillingUnavailableError({
      code: "organization_spend_limit_exceeded",
      message: "allocation upstream spend limit",
      status: 429,
    });
  };

  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: billable as any,
    scheduleContinuation: async () => { continuationCount++; },
    notifyProviderBillingUnavailable: async (context) => { contexts.push(context); },
    scheduleAlert: (promise) => { scheduled.push(promise); },
  });
  await Promise.all(scheduled);

  assertEquals(continuationCount, 0);
  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "provider_billing_unavailable");
  assertEquals(db.row.error.startsWith("Temporarily unavailable — try again later."), true);
  assertEquals(db.row.error.includes("No settled customer charge is recorded"), true);
  assertEquals(db.row.suggestions, [existingSuggestion]);
  assertEquals(db.row.planning_state.nextAction, "outline-plan");
  assertEquals("allocationRetryReason" in db.row.planning_state, false);
  assertEquals(JSON.stringify(db.row.planning_state).includes("spend limit"), false);
  assertEquals(JSON.stringify(db.row.diagnostics).includes("spend limit"), false);
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
  assertEquals(contexts[0].upstreamProviderCode, "organization_spend_limit_exceeded");
  assertEquals(contexts[0].upstreamMessage, "allocation upstream spend limit");
  assertEquals(contexts[0].upstreamStatus, 429);
});

Deno.test("provider billing unavailable during resumed expansion suppresses raw diagnostics", async () => {
  const baseBody = await executableWorkerBody();
  const body = { ...baseBody, requestedFormat: "novel", storyMaterialEnrichment: undefined } as any;
  const recoveredNovelMaterial = repairStoryMaterialFromRecipe(baseBody.recipe as any, {
    sourceRecipeHash: "worker-fixture",
    sourceRecipeVersion: 1,
    sourcePromptPackID: "worker-pack",
    sourcePromptPackName: "Worker fixture",
  }, "novel");
  const plannerItem = (id: string, label: string) => ({
    id, label, description: `${label} description`, source: "planner", sourceReference: null,
  });
  const novelMaterial = attachRecipeProvenance({
    ...recoveredNovelMaterial,
    locations: [plannerItem("resume-location-1", "Route"), plannerItem("resume-location-2", "Shelter")],
    escalationLadder: [
      plannerItem("resume-escalation-1", "Pressure one"),
      plannerItem("resume-escalation-2", "Pressure two"),
      plannerItem("resume-escalation-3", "Pressure three"),
    ],
    reversals: [plannerItem("resume-reversal-1", "Reversal")],
    consequences: [plannerItem("resume-consequence-1", "Consequence")],
  } as any, await recipeProvenance(baseBody.recipe as any));
  const suggestions = sceneOutline(37);
  const completedRound = {
    round: 1,
    sectionCountBefore: 27,
    projectedTokensBefore: 35100,
    projectedWordsBefore: 27000,
    additionsReturned: 10,
    sectionCountAfter: 39,
    projectedTokensAfter: 48100,
    projectedWordsAfter: 39000,
    remainingEstimatedDeficitTokens: 42900,
    status: "completed",
  };
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    story_material: novelMaterial,
    suggestions,
    planning_state: { version: 2, phase: "expansion", nextAction: "expansion" },
    diagnostics: {
      expansionCheckpoint: {
        stage: "expansion",
        nextRound: 2,
        scale: evaluateNovelScale(suggestions),
        expansionRounds: [completedRound],
      },
    },
  });
  const contexts: any[] = [];
  const scheduled: Promise<unknown>[] = [];
  const billable = async (request: any) => {
    assertEquals(request.action.startsWith("outline-expansion-"), true);
    throw new ProviderBillingUnavailableError({
      code: "organization_spend_limit_exceeded",
      message: "resumed expansion upstream spend limit",
      status: 429,
    });
  };

  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: billable as any,
    notifyProviderBillingUnavailable: async (context) => { contexts.push(context); },
    scheduleAlert: (promise) => { scheduled.push(promise); },
  });
  await Promise.all(scheduled);

  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "provider_billing_unavailable");
  assertEquals(db.row.error.startsWith("Temporarily unavailable — try again later."), true);
  assertEquals(db.row.error.includes("No settled customer charge is recorded"), true);
  assertEquals(db.row.suggestions, suggestions);
  assertEquals(db.row.completed_at !== null, true);
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
  assertEquals(JSON.stringify(db.row.diagnostics).includes("resumed expansion upstream spend limit"), false);
  assertEquals(JSON.stringify(db.row.diagnostics).includes("expansionError"), false);
  assertEquals(contexts[0].upstreamProviderCode, "organization_spend_limit_exceeded");
  assertEquals(contexts[0].upstreamMessage, "resumed expansion upstream spend limit");
  assertEquals(contexts[0].upstreamStatus, 429);
});

Deno.test("provider billing unavailable fails Suggest Sections safely and alerts with structured upstream details", async () => {
  const body = await executableWorkerBody();
  const existingSuggestion = { title: "Already preserved", summary: "Existing valid suggestion" };
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: [existingSuggestion],
  });
  const contexts: any[] = [];
  const scheduled: Promise<unknown>[] = [];
  const billable = async () => {
    throw new ProviderBillingUnavailableError({
      code: "organization_spend_limit_exceeded",
      message: "Your organization has reached its configured enforced spend limit.",
      status: 429,
    }, "OpenAI error (status=429, code=organization_spend_limit_exceeded)");
  };

  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: billable as any,
    notifyProviderBillingUnavailable: async (context) => { contexts.push(context); },
    scheduleAlert: (promise) => { scheduled.push(promise); },
  });
  await Promise.all(scheduled);

  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "provider_billing_unavailable");
  assertEquals(db.row.error.startsWith("Temporarily unavailable — try again later."), true);
  assertEquals(db.row.error.includes("No settled customer charge is recorded"), true);
  assertEquals(db.row.suggestions, [existingSuggestion]);
  assertEquals(db.row.completed_at !== null, true);
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
  assertEquals(JSON.stringify(db.row.diagnostics).includes("organization_spend_limit_exceeded"), false);
  assertEquals(JSON.stringify(db.row.diagnostics).includes("configured enforced spend limit"), false);
  assertEquals(contexts, [{
    stableCode: "provider_billing_unavailable",
    upstreamProviderCode: "organization_spend_limit_exceeded",
    upstreamMessage: "Your organization has reached its configured enforced spend limit.",
    upstreamStatus: 429,
    providerModel: "fixture-model",
    chapterRunID: "run-worker-fixture",
    projectID: "worker-project",
    environment: "production",
  }]);
});

Deno.test("provider alert failure cannot change terminal Suggest Sections state", async () => {
  const body = await executableWorkerBody();
  const db = new ExecutableRunDb(checkpointedWorkerRow(body));
  const scheduled: Promise<unknown>[] = [];
  const billable = async () => {
    throw new ProviderBillingUnavailableError({
      code: "organization_spend_limit_exceeded",
      message: "upstream spend limit",
      status: 429,
    });
  };

  await runSuggestionJob("run-worker-fixture", body, "user-worker", "test-key", 0, "Bearer worker-token", {
    db,
    model: { provider_model: "fixture-model" },
    provider: {},
    creditStore: {},
    billableLLM: billable as any,
    notifyProviderBillingUnavailable: async () => { throw new Error("Resend unavailable"); },
    scheduleAlert: (promise) => { scheduled.push(promise); },
  });
  await Promise.all(scheduled);

  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "provider_billing_unavailable");
  assertEquals(db.row.error.startsWith("Temporarily unavailable — try again later."), true);
  assertEquals(db.row.error.includes("No settled customer charge is recorded"), true);
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
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
  assertEquals(schedules.length, 1);
  assertEquals(db.row.status, "pending");
});

Deno.test("interrupted worker recovery resumes outline stage without replaying settled stages", async () => {
  const body = await executableWorkerBody();
  const old = new Date(Date.now() - MAX_SUGGESTION_NO_PROGRESS_MS - 60_000).toISOString();
  const expired = new Date(Date.now() - 60_000).toISOString();
  const row: any = {
    ...checkpointedWorkerRow(body),
    status: "running",
    lease_owner: "interrupted-worker",
    lease_expires_at: expired,
    attempt_count: 1,
    created_at: new Date(Date.now() - 11 * 60_000).toISOString(),
    updated_at: old,
    diagnostics: { worker: { lastMeaningfulProgressAt: old } },
  };
  const db = new ExecutableRunDb(row);
  db.attempts = [{
    feature_run_id: row.id,
    status: "started",
    started_at: old,
  }];
  const actions: string[] = [];
  const reclaimed = await reclaimExpiredSuggestionRun(db, { ...row });
  assertEquals(reclaimed, true);
  assertEquals(db.row.status, "pending");
  assertEquals(db.row.planning_state.phase, "allocation_complete");
  assertEquals(db.row.attempt_count, 2);
  assertEquals(db.attempts[0].provider_error_code, "worker_interrupted");

  let started = 0;
  const recovered = await recoverPendingSuggestionRun(
    db.row,
    "user-worker",
    "test-key",
    "Bearer recovered",
    async (runID, recoveredBody, userID, openaiKey, attemptCount, authHeader) => {
      started++;
      await runSuggestionJob(runID, recoveredBody, userID, openaiKey, attemptCount, authHeader, {
        db,
        model: { provider_model: "fixture-model" },
        provider: {},
        creditStore: {},
        billableLLM: fakeWorkerBilling(actions) as any,
        scheduleContinuation: async () => {},
      });
      await runSuggestionJob(runID, recoveredBody, userID, openaiKey, attemptCount, authHeader, {
        db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
        billableLLM: fakeWorkerBilling(actions) as any, scheduleContinuation: async () => {},
      });
    },
  );

  assertEquals(recovered, true);
  assertEquals(started, 1);
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.planning_state.phase, "completed");
  assertEquals(db.row.suggestions.length, 2);
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
});

Deno.test("stale reclaim is a compare-and-set race and only the winner cleans orphan attempts", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb({ id: "run-stale", status: "running", lease_expires_at: expired, attempt_count: 1 });
  db.attempts = [{ feature_run_id: "run-stale", status: "started", started_at: new Date(Date.now() - 2000).toISOString() }];
  const run = { id: "run-stale", status: "running", lease_expires_at: expired, attempt_count: 1 };
  const results = await Promise.all([reclaimExpiredSuggestionRun(db, run), reclaimExpiredSuggestionRun(db, run)]);
  assertEquals(results, [true, false]);
  assertEquals(db.row.status, "pending");
  assertEquals(db.row.attempt_count, 2);
  assertEquals(db.cleanupCalls, 1);
  assertEquals(db.attempts[0].status, "provider_failed");
  assertEquals(db.attempts[0].provider_error_code, "worker_interrupted");
  assertEquals(db.attempts[0].completed_at !== null, true);
});

Deno.test("expired worker reaches a terminal state after finite attempts", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb({ id: "run-exhausted", status: "running", lease_expires_at: expired, attempt_count: 4 });
  db.attempts = [{ feature_run_id: "run-exhausted", status: "started", started_at: new Date(Date.now() - 2000).toISOString() }];
  const run = { id: "run-exhausted", status: "running", lease_expires_at: expired, attempt_count: 4 };
  assertEquals(await reclaimExpiredSuggestionRun(db, run), true);
  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "worker_attempts_exhausted");
  assertEquals(db.row.lease_owner, null);
  assertEquals(db.row.lease_expires_at, null);
  assertEquals(db.attempts[0].provider_error_code, "worker_interrupted");
});

Deno.test("exhausted worker preserves settled billing in its terminal message", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb({ id: "run-partially-settled", status: "running", lease_expires_at: expired, attempt_count: 4 });
  const run = { id: "run-partially-settled", status: "running", lease_expires_at: expired, attempt_count: 4, credit_cost_charged: 2.5 };
  assertEquals(await reclaimExpiredSuggestionRun(db, run), true);
  assertEquals(db.row.status, "failed");
  assertEquals(db.row.error_code, "worker_attempts_exhausted");
  assertEquals(db.row.error.includes("2.50 credits were already settled"), true);
  assertEquals(db.row.error.includes("No credits were charged"), false);
});

Deno.test("GET terminal recovery serializes the refreshed authoritative billing row", async () => {
  const source = await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts");
  assertEquals(source.includes("JSON.stringify(suggestionRunResponse(recoveredRun))"), true);

  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb(
    { id: "run-get-authoritative-billing", status: "running", lease_expires_at: expired, attempt_count: 4, credit_cost_charged: 0, remaining_credits: 100 },
    { reconciledCredits: 2, reconciledRemainingCredits: 98 },
  );
  const staleSnapshot = { ...db.row };
  assertEquals(await reclaimExpiredSuggestionRun(db, staleSnapshot), true);
  const recoveredRun = await loadAuthoritativeSuggestionRun(db, staleSnapshot.id);
  if (!recoveredRun) throw new Error("expected authoritative recovered row");
  const response = suggestionRunResponse(recoveredRun);
  assertEquals(response.status, "failed");
  assertEquals(response.creditCostCharged, 2);
  assertEquals(response.remainingCredits, 98);
  assertEquals(suggestionRunResponse({ ...recoveredRun, credit_cost_charged: null, remaining_credits: null, error: "Billing reconciliation is unresolved; any settled stages were preserved." }).creditCostCharged, null);
});

Deno.test("terminal recovery refreshes authoritative settled and remaining credits", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb(
    { id: "run-authoritative-billing", status: "running", lease_expires_at: expired, attempt_count: 4, credit_cost_charged: 0, remaining_credits: 100 },
    { reconciledCredits: 2, reconciledRemainingCredits: 98 },
  );
  const run = { ...db.row };
  assertEquals(await reclaimExpiredSuggestionRun(db, run), true);
  const authoritative = await loadAuthoritativeSuggestionRun(db, run.id);
  if (!authoritative) throw new Error("expected authoritative recovered row");
  assertEquals(authoritative.status, "failed");
  assertEquals(authoritative.credit_cost_charged, 2);
  assertEquals(authoritative.remaining_credits, 98);
  const response = suggestionRunResponse(authoritative);
  assertEquals(response.creditCostCharged, 2);
  assertEquals(response.remainingCredits, 98);
});

Deno.test("terminal recovery reports confirmed zero only after authoritative reconciliation", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb(
    { id: "run-authoritative-zero", status: "running", lease_expires_at: expired, attempt_count: 4, credit_cost_charged: 0, remaining_credits: 100 },
    { reconciledCredits: 0, reconciledRemainingCredits: 100 },
  );
  const run = { ...db.row };
  assertEquals(await reclaimExpiredSuggestionRun(db, run), true);
  const authoritative = await loadAuthoritativeSuggestionRun(db, run.id);
  if (!authoritative) throw new Error("expected authoritative recovered row");
  assertEquals(authoritative.credit_cost_charged, 0);
  assertEquals(suggestionRunResponse(authoritative).creditCostCharged, 0);
});

Deno.test("unresolved reconciliation never presents stale credit fields", async () => {
  const expired = new Date(Date.now() - 1000).toISOString();
  const db = new ExecutableRunDb({ id: "run-unresolved-billing", status: "running", lease_expires_at: expired, attempt_count: 4, credit_cost_charged: 0, remaining_credits: 100 });
  const run = { ...db.row, credit_cost_charged: null };
  assertEquals(await reclaimExpiredSuggestionRun(db, run), true);
  const authoritative = await loadAuthoritativeSuggestionRun(db, run.id);
  if (!authoritative) throw new Error("expected terminal row");
  const response = suggestionRunResponse(authoritative);
  assertEquals(response.creditCostCharged, null);
  assertEquals(response.remainingCredits, null);
  assertEquals(String(response.error).includes("Billing reconciliation is unresolved"), true);
});

Deno.test("authoritative refresh failure is not converted into a stale terminal snapshot", async () => {
  const db = new ExecutableRunDb({ id: "run-refresh-fails", status: "failed", error: "terminal", credit_cost_charged: 7, remaining_credits: 93 });
  db.failRead = true;
  assertEquals(await loadAuthoritativeSuggestionRun(db, db.row.id), null);
});

Deno.test("durable checkpoint update fails closed on database errors and lost ownership", () => {
  assertThrows(
    () => assertDurableUpdateSucceeded({ data: null, error: { message: "lease lost" } }),
    Error,
    "persistence failed: lease lost",
  );
  assertThrows(
    () => assertDurableUpdateSucceeded({ data: null, error: null }),
    Error,
    "updated zero rows",
  );
  assertDurableUpdateSucceeded({ data: { id: "run-1" }, error: null });
});

Deno.test("identical durable checkpoint preserves its original progress marker", () => {
  const before = "2026-01-01T00:00:00.000Z";
  const diagnostics = { worker: { lastMeaningfulProgressAt: before, lastMeaningfulProgressCheckpoint: "allocation_validated", sliceCount: 4 } };
  const replayed = markMeaningfulProgress(diagnostics, "allocation_validated", "2026-01-01T01:00:00.000Z");
  assertEquals((replayed.worker as Record<string, unknown>).lastMeaningfulProgressAt, before);
  assertEquals((replayed.worker as Record<string, unknown>).lastMeaningfulProgressCheckpoint, "allocation_validated");
  assertEquals((replayed.worker as Record<string, unknown>).sliceCount, 4);
});

Deno.test("meaningful progress advances only at durable checkpoints", () => {
  const before = "2026-01-01T00:00:00.000Z";
  const diagnostics = { worker: { lastMeaningfulProgressAt: before, sliceCount: 4 } };
  const progressed = markMeaningfulProgress(diagnostics, "allocation_validated", "2026-01-01T00:05:00.000Z");
  assertEquals((progressed.worker as Record<string, unknown>).lastMeaningfulProgressAt, "2026-01-01T00:05:00.000Z");
  assertEquals((progressed.worker as Record<string, unknown>).lastMeaningfulProgressCheckpoint, "allocation_validated");
  assertEquals((diagnostics.worker as Record<string, unknown>).lastMeaningfulProgressAt, before);
  assertEquals((progressed.worker as Record<string, unknown>).sliceCount, 4);
});

Deno.test("scheduler recovery delay never terminalizes a saved checkpoint", () => {
  const now = Date.now();
  assertEquals(suggestionLifecycleFailure({
    created_at: new Date(now - 31 * 60_000).toISOString(),
    updated_at: new Date(now - 31 * 60_000).toISOString(),
    diagnostics: { worker: { lastMeaningfulProgressAt: new Date(now - 31 * 60_000).toISOString() } },
  }, now), null);
});

Deno.test("outline provider deadline leaves margin before Supabase Free wall clock", () => {
  assertEquals(OUTLINE_PROVIDER_TIMEOUT_MS < SUPABASE_FREE_WALL_CLOCK_MS, true);
  assertEquals(SUPABASE_FREE_WALL_CLOCK_MS - OUTLINE_PROVIDER_TIMEOUT_MS, 30_000);
});

Deno.test("outline billing estimate remains bounded while Luna Fast owns provider output ceiling", () => {
  assertEquals(OUTLINE_OUTPUT_TOKEN_BUDGET, 16_000);
});

Deno.test("length-truncated outline JSON is classified as output exhaustion", () => {
  assertThrows(
    () => parseOutlineJSON('{"suggestions":[{"title":"unfinished', "length"),
    OutlineOutputExhaustedError,
  );
  assertEquals(parseOutlineJSON('{"ok":true}', "stop"), { ok: true });
});

Deno.test("provider output exhaustion reaches terminal run state for each production stage", async () => {
  const fullBody = await executableWorkerBody();
  const cases = [
    {
      name: "enrichment",
      body: { ...fullBody, storyMaterialEnrichment: undefined },
      row: {
        ...checkpointedWorkerRow({ ...fullBody, storyMaterialEnrichment: undefined }),
        story_material: null,
        planning_state: { version: 2, phase: "start" },
      },
      action: "story-material-enrichment",
      failureStage: "enrichment_generation",
    },
    {
      name: "allocation",
      body: fullBody,
      row: {
        ...checkpointedWorkerRow(fullBody),
        planning_state: { version: 2, phase: "enrichment_complete", nextAction: "outline-plan" },
      },
      action: "outline-plan",
      failureStage: "allocation_generation",
    },
    {
      name: "outline",
      body: fullBody,
      row: checkpointedWorkerRow(fullBody),
      action: "outline-suggestions",
      failureStage: "outline_generation",
    },
  ];

  for (const testCase of cases) {
    const db = new ExecutableRunDb({ ...testCase.row, request_json: testCase.body });
    const actions: string[] = [];
    await runSuggestionJob(
      "run-worker-fixture",
      testCase.body as any,
      "user-worker",
      "test-key",
      0,
      "Bearer worker-token",
      {
        db,
        model: { provider_model: "fixture-model" },
        provider: {},
        creditStore: {},
        billableLLM: outputExhaustedBilling(actions) as any,
        scheduleContinuation: async () => {},
      },
    );
    assertEquals(actions, [testCase.action], testCase.name);
    assertEquals(db.row.status, "failed", testCase.name);
    assertEquals(db.row.error_code, "provider_output_exhausted", testCase.name);
    assertEquals(db.row.diagnostics.errorCode, "provider_output_exhausted", testCase.name);
    assertEquals(db.row.diagnostics.failureStage, testCase.failureStage, testCase.name);
    assertEquals(db.row.lease_owner, null, testCase.name);
    assertEquals(db.row.lease_expires_at, null, testCase.name);
  }
});

Deno.test("output exhaustion is not wrapped by expansion validation", () => {
  assertThrows(
    () => parseExpansionResponse('{"suggestions":', new Set(["beat-1"]), [], [], undefined, "length"),
    OutlineOutputExhaustedError,
  );
  assertThrows(
    () => parseExpansionResponse('{"suggestions":', new Set(["beat-1"]), []),
    ExpansionValidationError,
  );
});

Deno.test("active lease is never terminalized by an old lifecycle timestamp", async () => {
  const future = new Date(Date.now() + 60_000).toISOString();
  const db = new ExecutableRunDb({
    id: "run-active-old-progress",
    status: "running",
    lease_owner: "worker-token",
    lease_expires_at: future,
    attempt_count: 4,
    created_at: new Date(Date.now() - 31 * 60_000).toISOString(),
    updated_at: new Date(Date.now() - MAX_SUGGESTION_NO_PROGRESS_MS - 1).toISOString(),
  });
  const result = await reclaimExpiredSuggestionRun(db, {
    id: db.row.id,
    status: db.row.status,
    lease_expires_at: future,
    attempt_count: db.row.attempt_count,
    created_at: db.row.created_at,
    updated_at: db.row.updated_at,
  });
  assertEquals(result, false);
  assertEquals(db.row.status, "running");
  assertEquals(db.row.lease_owner, "worker-token");
  assertEquals(db.claims, 0);
});

Deno.test("pending jobs with delayed progress remain recoverable", async () => {
  const old = new Date(Date.now() - MAX_SUGGESTION_NO_PROGRESS_MS - 1).toISOString();
  const db = new ExecutableRunDb({
    id: "run-pending-delayed",
    status: "pending",
    lease_owner: null,
    lease_expires_at: null,
    attempt_count: 1,
    created_at: new Date(Date.now() - 1_000).toISOString(),
    updated_at: old,
    diagnostics: { worker: { lastMeaningfulProgressAt: old } },
  });
  const result = await reclaimExpiredSuggestionRun(db, {
    id: db.row.id,
    status: db.row.status,
    lease_expires_at: null,
    attempt_count: db.row.attempt_count,
    created_at: db.row.created_at,
    updated_at: db.row.updated_at,
    diagnostics: db.row.diagnostics,
  });
  assertEquals(result, false);
  assertEquals(db.row.status, "pending");
  assertEquals(db.claims, 0);
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
  const run = () => runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: fakeWorkerBilling(providerCalls) as any,
    scheduleContinuation: async () => { scheduleCount++; },
  });
  await run();
  await run();
  assertEquals(providerCalls.length, 2, JSON.stringify({ providerCalls, planningState: db.row.planning_state, diagnostics: db.row.diagnostics }));
  assertEquals(providerCalls, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed", JSON.stringify({ providerCalls, planningState: db.row.planning_state, diagnostics: db.row.diagnostics }));
  assertEquals(db.row.diagnostics.completedStages, ["outline"]);
  assertEquals(scheduleCount, 1);
});


Deno.test("privileged watchdog handler runs the real checkpointed worker exactly once", async () => {
  const body = await executableWorkerBody();
  const row: any = {
    ...checkpointedWorkerRow(body),
    id: "run-watchdog-handler",
    user_id: "user-worker",
    status: "pending",
    attempt_count: 1,
    diagnostics: { stage: "worker_interrupted", recoveryState: "waiting_for_recovery" },
  };
  const db = new ExecutableRunDb(row);
  const actions: string[] = [];
  let starts = 0;
  const startWorker = async (...args: any[]) => {
    starts += 1;
    await runSuggestionJob(args[0], args[1], args[2], args[3], args[4], args[5], {
      db,
      model: { provider_model: "fixture-model" },
      provider: {},
      creditStore: {},
      billableLLM: fakeWorkerBilling(actions) as any,
    });
    await runSuggestionJob(args[0], args[1], args[2], args[3], args[4], args[5], {
      db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
      billableLLM: fakeWorkerBilling(actions) as any,
    });
  };
  const request = new Request("https://project.supabase.co/functions/v1/outline-from-recipe", {
    method: "POST",
    headers: { "apikey": "operator-secret", "Authorization": "Bearer operator-secret" },
    body: JSON.stringify({ watchdog_run_id: row.id }),
  });
  const response = await recoverWatchdogRun(request, {
    db,
    openaiKey: "fixture-key",
    authHeader: "Bearer operator-secret",
    startWorker: startWorker as any,
  });
  assertEquals(response.status, 202);
  assertEquals(starts, 1);
  assertEquals(actions, ["outline-suggestions", "outline-semantic-verification"]);
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.diagnostics.recoveryState, "not_needed");
  assertEquals(db.row.credit_cost_charged, 0);
});

Deno.test("Story Arc evidence must quote the actual Section Contract field", () => {
  const section: any = {
    dramaticEvent: "Elin and Temur arrange the source documents at the winter court.",
    resultingChange: "The case becomes auditable.",
    terminalState: "The court has a documented evidence sequence.",
  };
  const rejected = validateGroundedArcEvidence({ authored_beat_requirement: [{ field: "resultingChange", quote: "This proves what their relationship means." }] }, section, new Set(["authored_beat_requirement"]));
  assertEquals(rejected.error, undefined);
  assertEquals(rejected.value, {});
  const grounded = validateGroundedArcEvidence({ authored_beat_requirement: [{ field: "resultingChange", quote: "The case becomes auditable." }] }, section, new Set(["authored_beat_requirement"]));
  assertEquals(grounded.error, undefined);
  assertEquals(grounded.value?.authored_beat_requirement?.length, 1);
});

Deno.test("empty optional Story Arc evidence does not fail outline validation", () => {
  const section: any = {
    dramaticEvent: "The lie gets them through the motel lobby.",
    resultingChange: "The crowd now believes Ted is leading a movement.",
    terminalState: "Their route is exposed and the next stop is no longer safe.",
  };
  const result = validateGroundedArcEvidence(
    { authored_beat_requirement: [] },
    section,
    new Set(["authored_beat_requirement"]),
  );
  assertEquals(result.error, undefined);
  assertEquals(result.value, {});
});

Deno.test("semantic evidence normalization accepts harmless wrappers but not paraphrases", () => {
  const section: any = {
    dramaticEvent: "Elin and Temur arrange the source documents at the winter court.",
    resultingChange: "The case becomes auditable.",
    terminalState: "The court has a documented evidence sequence.",
  };
  assertEquals(normalizeEvidenceText("The   case becomes auditable."), "The case becomes auditable.");
  assertEquals(normalizeEvidenceText("“The   case becomes auditable.”"), "The case becomes auditable.");
  assertEquals(normalizeEvidenceText('"The case becomes auditable."'), "The case becomes auditable.");
  assertEquals(findGroundedSemanticField(section, "The case becomes auditable.", ["resultingChange"]), "resultingChange");
  assertEquals(findGroundedSemanticField(section, "“The case becomes auditable.”", ["resultingChange"]), "resultingChange");
  assertEquals(findGroundedSemanticField(section, "The case is now verifiable.", ["resultingChange"]), undefined);
  assertEquals(findGroundedSemanticField(section, "The court has no evidence.", ["terminalState"]), undefined);
});


Deno.test("PR #798 semantic evidence correction recovers only uniquely grounded permitted quotes", async () => {
  const a: any = {
    storyArcBeatID: "setup", dramaticEvent: "The trio are stopped by a broken television.",
    resultingChange: "Their ordinary routine is established, including drug use and repeated explicit sex.",
    terminalState: "The trio remain together.",
  };
  const b: any = {
    storyArcBeatID: "isolation", dramaticEvent: "The shelter closes and leaves the trio stranded.",
    resultingChange: "The attention that once offered cover now destroys credibility and access to safety; Millie's organization and the public are both unavailable to them.",
    terminalState: "The group leaves the shelter.",
  };
  const c: any = {
    storyArcBeatID: "confrontation", dramaticEvent: "The trio halt the relay.",
    resultingChange: "Humanity and the hidden hybrids have gained a chance to survive, not a repaired system or a clear victory.",
    terminalState: "They flee the facility.",
  };
  const d: any = {
    storyArcBeatID: "final", dramaticEvent: "The trio survive the catastrophe.",
    resultingChange: "Ted refuses to pretend the damage is repaired.",
    terminalState: "They keep driving into an uncertain future.",
  };
  const sections = [a, b, c, d];
  const all = [0, 1, 2, 3];
  const misplaced = resolveSemanticEvidenceCitation(
    sections, 1, "Their ordinary routine is established, including drug use and repeated explicit sex",
    ["dramaticEvent", "resultingChange", "terminalState"], all,
  );
  assertEquals(misplaced, {
    sectionIndex: 0, field: "resultingChange",
    quote: "Their ordinary routine is established, including drug use and repeated explicit sex",
  });
  const caseOnly = resolveSemanticEvidenceCitation(
    sections, 1, "the attention that once offered cover now destroys credibility and access to safety",
    ["resultingChange"], [1],
  );
  assertEquals(caseOnly?.sectionIndex, 1);
  assertEquals(caseOnly?.field, "resultingChange");
  assertEquals(caseOnly?.quote.startsWith("The attention"), true);
  // Verbatim evidence in a DIFFERENT beat is not evidence for Final Image.
  assertEquals(resolveSemanticEvidenceCitation(
    sections, 2, c.resultingChange, ["resultingChange", "terminalState"], [3],
  ), undefined);
  assertEquals(resolveSemanticEvidenceCitation(
    sections, 0, "The system was perfectly repaired.", ["dramaticEvent", "resultingChange", "terminalState"], all,
  ), undefined);
  assertEquals(resolveSemanticEvidenceCitation(sections, 0, "", ["dramaticEvent"], all), undefined);
  assertEquals(resolveSemanticEvidenceCitation(
    [a, { ...a }], 9, "Their ordinary routine is established", ["resultingChange"], [0, 1],
  ), undefined, "multiple candidates cannot silently redirect a citation");
  assertEquals(isSemanticEvidenceGroundingFailure("provider evidence quote was not grounded in any allowed Section Contract field; semantic repair required"), true);
  assertEquals(isSemanticEvidenceGroundingFailure("creative-fidelity evidence quote was not grounded in a Section Contract field; creative-fidelity review required"), true);
  assertEquals(isSemanticEvidenceGroundingFailure("The climax does not resolve the central threat."), false);
});

Deno.test("PR #798 verifier corrects quote metadata without accepting wrong-beat resolution evidence", async () => {
  const template: any = {
    name: "Save the Cat!",
    beats: [
      { id: "setup", role: "setup", label: "Setup", description: "" },
      { id: "isolation", role: "isolation", label: "Isolation", description: "The protagonists lose access to safe help." },
      { id: "confrontation", role: "climax", label: "Confrontation", description: "" },
      { id: "final", role: "final_image", label: "Final", description: "Show survival." },
    ],
  };
  const sections: any[] = [
    { storyArcBeatID: "setup", dramaticEvent: "The trio celebrate.", resultingChange: "Their ordinary routine is established, including drug use and repeated explicit sex.", terminalState: "They continue traveling." },
    { storyArcBeatID: "isolation", dramaticEvent: "The public shelter closes.", resultingChange: "The attention that once offered cover now destroys credibility and access to safety.", terminalState: "They lose access to safe help." },
    { storyArcBeatID: "confrontation", dramaticEvent: "Fred stops the regional broadcast.", resultingChange: "Humanity and the hidden hybrids have gained a chance to survive.", terminalState: "The regional threat is disrupted." },
    { storyArcBeatID: "final", dramaticEvent: "They drive west.", resultingChange: "The trio survive while the cause remains unknown.", terminalState: "They continue driving." },
  ];
  const recipe: any = { project: {}, storyNonNegotiables: ["The trio have repeated explicit sex."] };
  const result = await verifyStoryArcSemantics(sections, template, async () => ({
    content: JSON.stringify({
      arcWideObligations: [{
        obligationID: "story_non_negotiable_0", satisfied: true, sectionIndex: 1,
        field: "dramaticEvent", quote: "Their ordinary routine is established, including drug use and repeated explicit sex",
        reason: "The routine is explicit.",
      }],
      beats: [
        { beatID: "isolation", obligations: [{
          obligationID: "authored_beat_requirement", satisfied: true, sectionIndex: 1,
          field: "dramaticEvent", quote: "the attention that once offered cover now destroys credibility and access to safety",
          reason: "They lose social support.",
        }] },
        { beatID: "final", obligations: [
          { obligationID: "authored_beat_requirement", satisfied: true, sectionIndex: 3, field: "terminalState", quote: sections[3].terminalState, reason: "They survive." },
          { obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id, satisfied: true, sectionIndex: 2, field: "resultingChange", quote: sections[2].resultingChange, reason: "Quote from the wrong beat." },
        ] },
      ],
    }),
  }) as any, recipe);
  assertEquals(result.arcWideObligations[0].satisfied, true);
  assertEquals(result.arcWideObligations[0].sectionIndex, 0);
  const isolation = result.beats.find((beat) => beat.beatID === "isolation")!;
  assertEquals(isolation.obligations[0].satisfied, true);
  assertEquals(isolation.obligations[0].field, "resultingChange");
  assertEquals(isolation.obligations[0].quote.startsWith("The attention"), true);
  const final = result.beats.find((beat) => beat.beatID === "final")!;
  assertEquals(final.obligations.find((o) => o.obligationID === REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id)?.satisfied, false);
  assertEquals(result.unsatisfied.length, 1);
  assertEquals(result.unsatisfied[0].obligationID, REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id);
});

Deno.test("PR #798 evidence-only semantic checkpoint uses one verifier call, no prose rewrite", async () => {
  const body = await executableWorkerBody();
  const ids = Array.from({ length: 63 }, (_, i) => `R${i + 1}`);
  const original: any[] = [
    { title: "One", summary: "The opening happens.", container: "scene", pov: "thirdPersonLimited",
      terminalBeat: "The plan changes.", entryState: "Nothing has happened.", dramaticEvent: "The trio try to escape.",
      resultingChange: "The system becomes harder to trust.", terminalState: "The trio are on the road.",
      storyArcBeatID: "beat-1", dramaticFunction: "setup", recipeRequirementIDs: ids },
    { title: "Two", summary: "The survivors drive away.", container: "scene", pov: "thirdPersonLimited",
      terminalBeat: "They leave.", entryState: "The attempt has happened.", dramaticEvent: "The trio face the cost of escaping.",
      resultingChange: "The dangerous cycle ends at a cost.", terminalState: "Their survival is real but compromised.",
      storyArcBeatID: "beat-2", dramaticFunction: "resolution", recipeRequirementIDs: ids },
  ];
  const failures = [{ beatID: "beat-2", obligationID: "authored_beat_requirement",
    reason: "provider evidence quote was not grounded in any allowed Section Contract field; semantic repair required" }];
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: structuredClone(original),
    planning_state: {
      version: 2, phase: "semantic_repair_pending", nextAction: "semantic-repair",
      semanticRepairFailures: failures, semanticRepairOriginalSuggestions: original,
    },
    diagnostics: { semanticVerification: { arcWideObligations: [], beats: [], unsatisfied: failures } },
  });
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, (_action) => JSON.stringify(semanticVerifierFixture({
    messages: [{ role: "user", content: JSON.stringify(semanticVerificationInput(original, body.arcTemplate, body.recipe)) }],
  })));
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {},
    billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  assertEquals(actions, [], "retired semantic repair must not run a paid evidence-only re-verification");
  assertEquals(db.row.status, "completed", JSON.stringify({error: db.row.error, diagnostics: db.row.diagnostics}));
  assertEquals(db.row.suggestions, original);
  assertEquals(db.row.diagnostics.legacySemanticRepairCheckpointRecovered, true);
  assertEquals(db.row.diagnostics.semanticVerification.unsatisfied, failures);
});

Deno.test("semantic verifier preserves a provider false judgment even with grounded evidence", async () => {
  const section: any = { storyArcBeatID: "beat", dramaticEvent: "The source is filed.", resultingChange: "The case becomes auditable.", terminalState: "The court has a documented evidence sequence." };
  const recipe: any = { ...sparseRequest.recipe, storyNonNegotiables: ["The case must become auditable."] };
  const result = await verifyStoryArcSemantics([section], { name: "Custom", beats: [{ id: "beat", role: "setup", label: "Setup" }] } as any, async () => ({
    content: JSON.stringify({
      arcWideObligations: [{ obligationID: "story_non_negotiable_0", satisfied: false, sectionIndex: 0, field: "resultingChange", quote: "“The case becomes auditable.”", reason: "provider determined the requirement is not met" }],
      beats: [{ beatID: "beat", obligations: [] }],
    }),
  }) as any, recipe);
  assertEquals(result.arcWideObligations[0].satisfied, false);
  assertEquals(result.unsatisfied[0].obligationID, "story_non_negotiable_0");
});

Deno.test("Story Arc obligations are beat-level rather than required on every section", () => {
  const template: any = { name: "Custom", beats: [{ id: "beat", role: "midpoint_intimacy", label: "Midpoint", description: "Deepen the relationship." }] };
  const suggestions: any[] = [
    { storyArcBeatID: "beat", title: "Plot cleanup", summary: "Cleanup", dramaticEvent: "The record is filed.", resultingChange: "The case becomes auditable.", terminalState: "The hearing continues.", arcObligationEvidence: {} },
    { storyArcBeatID: "beat", title: "Threshold", summary: "Threshold", dramaticEvent: "They kiss after each entrusts the other with damaging professional evidence.", resultingChange: "Their relationship crosses from charged possibility into acknowledged intimacy.", terminalState: "They leave more vulnerable to each other.", arcObligationEvidence: { authored_beat_requirement: [{ field: "resultingChange", quote: "Their relationship crosses from charged possibility into acknowledged intimacy." }] } },
  ];
  assertEquals(validateArcSemanticObligations(suggestions as any, template), []);
});


Deno.test("creative authority keeps planner candidates provisional in enrichment and outline prompts", () => {
  const material = enrichmentFixture();
  material.institutionsAndGroups = [{ id: "planner-institution", source: "planner", sourceReference: null, label: "Emergency network", description: "A planner candidate." }];
  const prompt = buildPrompt({ ...sparseRequest, storyMaterialEnrichment: material } as any, new Map(), [], material).system;
  assertStringIncludes(prompt, "source=planner are development candidates");
  assertStringIncludes(prompt, "adapted, replaced by a better recipe-faithful idea, or discarded entirely");
  assertStringIncludes(prompt, "do not promote a planner proposal to canon");
});

Deno.test("intimacy permission and non-negotiables do not manufacture a Story Arc milestone", () => {
  const template: any = { name: "Epic Fantasy Quest", relationshipFocus: "none", intimacyMilestoneRoles: [], beats: [{ id: "b", role: "setup", label: "Setup" }] };
  const permissiveRecipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, intimacyRating: "explicit" } };
  assertEquals(intimacyRequirement({ recipe: permissiveRecipe, arcTemplate: template }), null);
  const negativeRecipe: any = { ...permissiveRecipe, storyNonNegotiables: ["No sexual content." ] };
  assertEquals(intimacyRequirement({ recipe: negativeRecipe, arcTemplate: template }), null);
  assertEquals((semanticVerificationInput([], template, negativeRecipe).arcWideObligations as any[]).some((item) => item.obligationID === SELECTED_INTIMACY_LEVEL_OBLIGATION), false);
});

Deno.test("explicit authored non-negotiables remain in the verifier without changing generic arc intimacy", () => {
  const recipe: any = { ...sparseRequest.recipe, storyNonNegotiables: ["The author requires frequent explicit sexual content between consenting adults."] };
  const template: any = { name: "Epic Fantasy Quest", relationshipFocus: "none", intimacyMilestoneRoles: [], beats: [{ id: "b", role: "setup", label: "Setup" }] };
  assertEquals(intimacyRequirement({ recipe, arcTemplate: template }), null);
  const input: any = semanticVerificationInput([], template, recipe);
  assertEquals(input.storyNonNegotiables[0].instruction, recipe.storyNonNegotiables[0]);
  assertEquals(input.arcWideObligations.some((item: any) => item.obligationID === SELECTED_INTIMACY_LEVEL_OBLIGATION), false);
  assertEquals(intimacyPlanningDirective({ recipe, arcTemplate: template } as any), "");
});

Deno.test("semantic repair selection requires resolving existing keys without introducing new ones", () => {
  const original: any[] = [{ title: "Original", storyArcBeatID: "b", dramaticEvent: "The authored conflict advances." }];
  const repaired: any[] = [{ title: "Repair", storyArcBeatID: "b", dramaticEvent: "A generic subplot replaces the conflict." }];
  const originalVerification: any = { unsatisfied: [
    { beatID: "b", obligationID: "creative_fidelity", reason: "drift" },
    { beatID: "c", obligationID: "required_resolution_outcome", reason: "unresolved" },
  ] };
  assertEquals(chooseBestSemanticOutline(original, repaired, originalVerification, {
    unsatisfied: [{ beatID: "c", obligationID: "required_resolution_outcome", reason: "unresolved" }],
  }), repaired);
  assertEquals(chooseBestSemanticOutline(original, repaired, originalVerification, {
    unsatisfied: [{ beatID: "b", obligationID: "creative_fidelity", reason: "still unresolved" }, { beatID: "new", obligationID: "new_failure", reason: "introduced" }],
  }), original);
  assertEquals(chooseBestSemanticOutline(original, repaired, originalVerification, {
    unsatisfied: [{ beatID: "b", obligationID: "creative_fidelity", reason: "same failure" }, { beatID: "c", obligationID: "required_resolution_outcome", reason: "same failure" }],
  }), original);
  assertEquals(chooseBestSemanticOutline(original, repaired, originalVerification, undefined), original);
  assertEquals(chooseBestSemanticOutline(original, repaired,
    { unsatisfied: [{ beatID: "first", obligationID: CREATIVE_FIDELITY_OBLIGATION, reason: "same story-wide failure" }] },
    { unsatisfied: [] }), repaired);
  assertEquals(chooseBestSemanticOutline(original, repaired,
    { unsatisfied: [{ beatID: "first", obligationID: "story_non_negotiable_0", reason: "one story-wide failure" }] },
    { unsatisfied: [{ beatID: "story_arc", obligationID: "story_non_negotiable_1", reason: "different story-wide failure" }] }), original);
  assertEquals(chooseBestSemanticOutline(original, repaired,
    { unsatisfied: [{ beatID: "first", obligationID: "authored_beat_requirement", reason: "beat failure" }] },
    { unsatisfied: [{ beatID: "second", obligationID: "authored_beat_requirement", reason: "different beat failure" }] }), original);
});

Deno.test("worker persists selected original suggestions with authoritative original verification", async () => {
  const body = await executableWorkerBody();
  const section = (title: string, beatID: string, dramaticFunction: string, dramaticEvent: string) => ({
    title,
    summary: `${title} summary`,
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: `${title} ends`,
    entryState: "The prior state holds.",
    storyArcBeatID: beatID,
    dramaticFunction,
    dramaticEvent,
    resultingChange: `${title} changes the achieved state.`,
    terminalState: `${title} establishes the resulting state.`,
    recipeRequirementIDs: Array.from({ length: 63 }, (_, index) => `R${index + 1}`),
  });
  const original = [section("Original paid section", "beat-1", "setup", "The authored route advances."), section("Original resolution", "beat-2", "resolution", "The cost is faced.")] as any[];
  const repaired = [{ ...original[0], title: "Rejected repair" }, { ...original[1], title: "Rejected resolution" }] as any[];
  const originalVerification: any = {
    arcWideObligations: [],
    beats: [],
    unsatisfied: [{ beatID: "beat-1", obligationID: "authored_beat_requirement", reason: "original warning" }],
  };
  const db = new ExecutableRunDb({
    ...checkpointedWorkerRow(body),
    suggestions: repaired,
    planning_state: {
      version: 2,
      phase: "semantic_reverification_pending",
      nextAction: "semantic-reverification",
      semanticRepairOriginalSuggestions: original,
    },
    diagnostics: { semanticVerification: originalVerification },
  });
  const actions: string[] = [];
  const billable = validatedWorkerBilling(actions, () => ({}), (request) => {
    const input = JSON.parse(request.messages.find((message: any) => message.role === "user").content);
    return JSON.stringify({
      arcWideObligations: (input.arcWideObligations ?? []).map((obligation: any) => {
        const section = obligation.sections?.[0];
        const field = obligation.obligationID === CREATIVE_FIDELITY_OBLIGATION ? "dramaticEvent" : "resultingChange";
        return { obligationID: obligation.obligationID, satisfied: true, sectionIndex: section?.sectionIndex ?? -1, field, quote: section?.[field] ?? "evidence", reason: "candidate evidence" };
      }),
      beats: (input.beats ?? []).map((beat: any) => ({
        beatID: beat.beatID,
        obligations: (beat.obligations ?? []).map((obligation: any) => {
          const section = beat.sections?.[0];
          const isIntroducedFailure = beat.beatID === "beat-2" && obligation.obligationID === "authored_beat_requirement";
          return { obligationID: obligation.obligationID, satisfied: !isIntroducedFailure, sectionIndex: section?.sectionIndex ?? -1, field: "resultingChange", quote: section?.resultingChange ?? "evidence", reason: isIntroducedFailure ? "repair introduced an unresolved beat requirement" : "candidate evidence" };
        }),
      })),
    });
  });
  await runSuggestionJob("run-worker-fixture", body as any, "user-worker", "test-key", 0, "Bearer worker-token", {
    db, model: { provider_model: "fixture-model" }, provider: {}, creditStore: {}, billableLLM: billable as any, scheduleContinuation: async () => {},
  });
  assertEquals(actions, [], "old paid repair checkpoints must be recovered without another verification");
  assertEquals(db.row.status, "completed");
  assertEquals(db.row.suggestions, original);
  assertEquals(db.row.diagnostics.semanticVerification, originalVerification);
  assertEquals(db.row.diagnostics.legacySemanticRepairCheckpointRecovered, true);
  assertEquals(db.row.diagnostics.semanticRepairRejectedVerification, undefined);
});

Deno.test("creative-fidelity verifier rejects procedural drift and routes it to the affected beat", async () => {
  const template: any = { name: "Custom", beats: [{ id: "b", role: "setup", label: "Setup", description: "" }] };
  const recipe: any = {
    ...sparseRequest.recipe,
    project: { ...sparseRequest.recipe.project, audienceNotes: "Grotesque character-driven satire; absurdity and destructive behavior should drive the reader experience." },
    selectedCharacters: [{ id: "c", name: "Mara", instructionBias: "Selfish and chaotic.", failurePatterns: ["Turns every escape into a public spectacle."], contradictions: ["Accidental savior who rejects responsibility."] }],
  };
  const section: any = { storyArcBeatID: "b", dramaticEvent: "A contractor synchronizes emergency databases to locate the protagonists.", resultingChange: "The investigation becomes the story's central engine.", terminalState: "The protagonists prepare to interrupt the synchronization system." };
  const result = await verifyStoryArcSemantics([section], template, async () => ({
    content: JSON.stringify({
      arcWideObligations: [{ obligationID: CREATIVE_FIDELITY_OBLIGATION, satisfied: false, sectionIndex: 0, field: "dramaticEvent", quote: section.dramaticEvent, reason: "The sequence replaces the authored character-driven satire with a procedural infrastructure thriller." }],
      beats: [{ beatID: "b", obligations: [] }],
    }),
  }) as any, recipe);
  assertEquals(result.arcWideObligations[0].obligationID, CREATIVE_FIDELITY_OBLIGATION);
  assertEquals(result.arcWideObligations[0].satisfied, false);
  assertEquals(result.unsatisfied, [{ beatID: "b", obligationID: CREATIVE_FIDELITY_OBLIGATION, reason: "The sequence replaces the authored character-driven satire with a procedural infrastructure thriller." }]);
});

Deno.test("creative-fidelity verifier accepts institutional scenes when the recipe makes them central", async () => {
  const template: any = { name: "Custom", beats: [{ id: "b", role: "setup", label: "Setup", description: "" }] };
  const recipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, audienceNotes: "A procedural investigation of institutional corruption with evidence chains and emergency communications." } };
  const section: any = { storyArcBeatID: "b", dramaticEvent: "The investigator matches the emergency communications log to the contractor's evidence chain.", resultingChange: "The institutional case becomes independently verifiable.", terminalState: "The investigator can confront the agency with the matched records." };
  const result = await verifyStoryArcSemantics([section], template, async () => ({
    content: JSON.stringify({
      arcWideObligations: [{ obligationID: CREATIVE_FIDELITY_OBLIGATION, satisfied: true, sectionIndex: 0, field: "dramaticEvent", quote: section.dramaticEvent, reason: "The procedural sequence realizes the authored investigation." }],
      beats: [{ beatID: "b", obligations: [] }],
    }),
  }) as any, recipe);
  assertEquals(result.unsatisfied, []);
});

Deno.test("relationship metadata drives intimacy capability without role detection", async () => {
  const darkRomance = {
    name: "Dark Romance",
    relationshipFocus: "primary",
    intimacyMilestoneRoles: ["entanglement", "vulnerability_revealed", "chosen_terms", "earned_resolution"],
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "" }],
  } as any;
  const mystery = { name: "Mystery", beats: [{ id: "m", role: "the_crime", label: "The Crime", description: "" }] } as any;
  const recipe = { project: { intimacyRating: "explicit" } } as any;
  assertEquals(intimacyRequirement({ arcTemplate: darkRomance, recipe })?.level, "explicit");
  assertEquals(intimacyRequirement({ arcTemplate: mystery, recipe }), null);
  assertStringIncludes(intimacyPlanningDirective({ arcTemplate: darkRomance, recipe } as any), SELECTED_INTIMACY_LEVEL_OBLIGATION);
  assertEquals((await Deno.readTextFile("./supabase/functions/outline-from-recipe/index.ts")).includes('new Set(["meet_attraction"'), false);
});

Deno.test("explicit intimacy is a whole-arc verifier obligation and generic arcs stay clean", () => {
  const template = {
    name: "Dark Romance",
    relationshipFocus: "primary",
    intimacyMilestoneRoles: ["entanglement"],
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "" }],
  } as any;
  const recipe = { project: { intimacyRating: "explicit" } } as any;
  const suggestions = [{ storyArcBeatID: "e", dramaticEvent: "Mira reaches for Julian's hand and closes the distance.", resultingChange: "Their intimacy becomes chosen rather than engineered.", terminalState: "They remain together." }];
  const input = semanticVerificationInput(suggestions as any, template, recipe);
  assertEquals((input.arcWideObligations as any[])[0].obligationID, SELECTED_INTIMACY_LEVEL_OBLIGATION);
  assertEquals((input.arcWideObligations as any[])[0].sections.length, 1);
  const generic = { name: "Mystery", relationshipFocus: "none", intimacyMilestoneRoles: [], beats: [{ id: "m", role: "the_crime", label: "The Crime", description: "" }] } as any;
  assertEquals((semanticVerificationInput(suggestions as any, generic, recipe).arcWideObligations as any[]).length, 0);
});

Deno.test("semantic verifier adds resolution outcome only to required-resolution beats", () => {
  const template: any = {
    name: "Save the Cat!",
    beats: [{ id: "final", role: "final_image", label: "Final Image", description: "Close the authored central question." }],
  };
  const section = {
    storyArcBeatID: "final",
    dramaticEvent: "Ted tries to destroy the transmitter but fails.",
    resultingChange: "Ted retreats without disabling it.",
    terminalState: "The transmitter remains active.",
  };
  const recipe: any = { ...sparseRequest.recipe, storyNonNegotiables: ["Preserve the author's ending intent."] };
  const input: any = semanticVerificationInput([section] as any, template, recipe);
  const beat = input.beats[0];
  const ids = beat.obligations.map((obligation: any) => obligation.obligationID);
  assertEquals(ids, ["authored_beat_requirement", REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id]);
  assertEquals(input.recipe, recipe);
  assertEquals(verificationObligationsForBeat({ id: "setup", role: "setup", label: "Setup" }, "Save the Cat!").some((obligation) => obligation.id === REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id), false);
  assertEquals(verificationObligationsForBeat(template.beats[0], template.name).filter((obligation) => obligation.id === REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id).length, 1);
});

Deno.test("semantic verifier classifies resolution by achieved outcome, not attempted event vocabulary", async () => {
  const template: any = {
    name: "Save the Cat!",
    relationshipFocus: "none",
    intimacyMilestoneRoles: [],
    beats: [{ id: "final", role: "final_image", label: "Final Image" }],
  };
  const recipe: any = { ...sparseRequest.recipe, project: { ...sparseRequest.recipe.project, summary: "Ted must answer whether the invasion can be stopped." } };
  const rejected = [
    ["Failed transmitter destruction", "Ted tries to destroy the transmitter but fails.", "The sabotage fails again and the invaders destroy their safehouse.", "The safehouse is gone, but the transmitter stays active and the invasion proceeds."],
    ["Postponed confrontation", "Ted unsuccessfully attempts to end the conspiracy.", "Ted postpones the decisive confrontation until tomorrow.", "The conspiracy still operates and the agents continue their pursuit."],
    ["Unrelated death", "Ted dies confronting the alien presence.", "Ted is gone, but the central threat is untouched.", "The invasion continues and the central question remains open."],
  ];
  for (const [, dramaticEvent, resultingChange, terminalState] of rejected) {
    const section: any = { storyArcBeatID: "final", dramaticEvent, resultingChange, terminalState };
    const result = await verifyStoryArcSemantics([section], template, async () => ({
      content: JSON.stringify({ beats: [{ beatID: "final", obligations: [{
        obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id,
        satisfied: false,
        sectionIndex: 0,
        field: "resultingChange",
        quote: resultingChange,
        reason: "The achieved state leaves the central commitment unresolved.",
      }] }] }),
    }) as any, recipe);
    assertEquals(result.unsatisfied, [{ beatID: "final", obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id, reason: "The achieved state leaves the central commitment unresolved." }]);
  }
  const accepted = [
    ["Destroyed transmitter", "Ted smashes the transmitter with a wrench.", "The transmitter fractures into glass and the invasion signal falls silent.", "The portal seals behind the last refugees as dawn breaks."],
    ["Permanent impossibility", "The archive burns before the protagonists arrive.", "The objective becomes permanently impossible because the evidence is destroyed.", "The investigation can never recover that evidence, though other mysteries remain."],
    ["Definitive abandonment", "Mara walks away from the campaign.", "Mara permanently abandons the central objective and forfeits the alliance.", "The campaign is over and her choice reshapes the survivors' future."],
    ["Tragic defeat", "The protagonist loses the final confrontation.", "The protagonist's failure decisively ends the attempt to reclaim the city.", "The city remains under the regime and the objective is no longer attainable."],
    ["Morally ambiguous", "Mara burns the evidence to protect one faction.", "Neither faction can claim the evidence and the central struggle for it is over.", "The public consequences remain uncertain, but the evidence conflict is settled."],
    ["Conventional victory", "The protagonists defeat the threat at the gate.", "The central conflict ends and the survivors accept the cost.", "A new normal holds without the former threat continuing."],
  ];
  for (const [, dramaticEvent, resultingChange, terminalState] of accepted) {
    const section: any = { storyArcBeatID: "final", dramaticEvent, resultingChange, terminalState };
    const result = await verifyStoryArcSemantics([section], template, async () => ({
      content: JSON.stringify({ beats: [{ beatID: "final", obligations: [{
        obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id,
        satisfied: true,
        sectionIndex: 0,
        field: "resultingChange",
        quote: resultingChange,
        reason: "The achieved state answers the central commitment.",
      }] }] }),
    }) as any, recipe);
    assertEquals(result.unsatisfied, []);
    assertEquals(result.beats[0].obligations[0].obligationID, REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id);
    assertEquals(result.beats[0].obligations[0].field, "resultingChange");
  }
});

Deno.test("semantic resolution failure uses the existing targeted repair and reverification path", async () => {
  const template: any = {
    name: "Save the Cat!",
    beats: [{ id: "final", role: "final_image", label: "Final Image" }],
  };
  const weak: any = {
    ...semanticSection("final", "The Unfinished Signal", "Ted tries to stop the transmitter but fails.", "resolution"),
    storyArcBeatID: "final",
    resultingChange: "Ted retreats without disabling the transmitter.",
    terminalState: "The transmitter remains active and the invasion continues.",
  };
  let capturedRecipe: unknown;
  let capturedAction = "";
  const repaired = await repairStoryArcSemanticObligations(
    [weak],
    template,
    [{ beatID: "final", obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id, reason: "The central threat remains active." }],
    async (_system, user, _max, _format, action) => {
      capturedAction = action;
      capturedRecipe = JSON.parse(user).recipe;
      return {
        content: JSON.stringify({ replacements: [{
          sectionIndex: 0,
          beatID: "final",
          section: {
            ...weak,
            resultingChange: "The transmitter fractures and the invasion signal falls silent.",
            terminalState: "The portal seals behind the refugees and the central threat ends.",
          },
        }] }),
      } as any;
    },
    [],
    sparseRequest.recipe as any,
  );
  assertEquals(capturedAction, "outline-semantic-repair-batch");
  assertEquals(capturedRecipe, sparseRequest.recipe);
  const reverification = await verifyStoryArcSemantics(
    repaired,
    template,
    async () => ({
      content: JSON.stringify({ beats: [{ beatID: "final", obligations: [{
        obligationID: REQUIRED_RESOLUTION_OUTCOME_OBLIGATION.id,
        satisfied: true,
        sectionIndex: 0,
        field: "resultingChange",
        quote: repaired[0].resultingChange,
        reason: "The revised achieved state resolves the threat.",
      }] }] }),
    }) as any,
    sparseRequest.recipe as any,
  );
  assertEquals(reverification.unsatisfied, []);
});

Deno.test("semantic verifier receives every story non-negotiable with Section Contract fields", () => {
  const template = {
    name: "Dark Romance",
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "" }],
  } as any;
  const suggestions = [{
    storyArcBeatID: "e",
    dramaticEvent: "They choose intimacy after accountability.",
    resultingChange: "Trust becomes mutual.",
    terminalState: "They remain together.",
  }];
  const input = semanticVerificationInput(suggestions as any, template, {
    project: {},
    storyNonNegotiables: ["The protagonists must choose intimacy after accountability."],
  } as any);
  const requirements = input.storyNonNegotiables as any[];
  assertEquals(requirements.length, 1);
  assertEquals(requirements[0].obligationID, "story_non_negotiable_0");
  assertEquals(requirements[0].sections[0].resultingChange, "Trust becomes mutual.");
});

Deno.test("semantic verifier captures returned obligations and validation errors", async () => {
  const template = {
    name: "Dark Romance",
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "The protagonists must make a concrete choice that changes their relationship." }],
  } as any;
  const captured: Record<string, unknown>[] = [];
  await assertRejects(
    () => verifyStoryArcSemantics(
      [{ storyArcBeatID: "e", dramaticEvent: "They choose intimacy.", resultingChange: "Trust becomes mutual.", terminalState: "They remain together." }] as any,
      template,
      async () => ({
        content: JSON.stringify({ beats: [{ beatID: "e", obligations: [] }] }),
        recordProviderAttemptMetadata: async (metadata: Record<string, unknown>) => captured.push(metadata),
      }) as any,
    ),
    Error,
    "missing obligation",
  );
  const semanticVerification = captured[0].semanticVerification as Record<string, unknown>;
  assertEquals(semanticVerification.returnedBeatIDs, ["e"]);
  assertEquals(semanticVerification.returnedObligationIDs, []);
  assertStringIncludes(String((semanticVerification.validationError as Record<string, unknown>).message), "missing obligation");
  assertEquals((semanticVerification.expectedObligationIDs as unknown[]).length > 0, true);
});

Deno.test("ungrounded intimacy verifier evidence enters semantic repair instead of throwing", async () => {
  const template = {
    name: "Dark Romance",
    relationshipFocus: "primary",
    intimacyMilestoneRoles: ["entanglement"],
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "" }],
  } as any;
  const recipe = { project: { intimacyRating: "explicit" } } as any;
  const suggestions = [{
    storyArcBeatID: "e",
    dramaticEvent: "Mira reaches for Julian's hand and closes the distance.",
    resultingChange: "Their intimacy becomes chosen rather than engineered.",
    terminalState: "They remain together.",
  }];
  const result = await verifyStoryArcSemantics(
    suggestions as any,
    template,
    async () => ({
      content: JSON.stringify({
        arcWideObligations: [{
          obligationID: SELECTED_INTIMACY_LEVEL_OBLIGATION,
          satisfied: true,
          sectionIndex: 0,
          field: "resultingChange",
          quote: "This quote is not in the section.",
          reason: "claimed milestone",
        }],
        beats: [],
      }),
    }) as any,
    recipe,
  );
  assertEquals(result.arcWideObligations[0].satisfied, false);
  assertEquals(result.unsatisfied[0].obligationID, SELECTED_INTIMACY_LEVEL_OBLIGATION);
  assertStringIncludes(result.unsatisfied[0].reason, "not grounded");
});

Deno.test("whole-arc intimacy evidence is accepted on eligible beat sections", () => {
  const template = {
    name: "Dark Romance",
    relationshipFocus: "primary",
    intimacyMilestoneRoles: ["entanglement"],
    beats: [{ id: "e", role: "entanglement", label: "Entanglement", description: "" }],
  } as any;
  const result = validateSuggestions({ suggestions: [{
    title: "The Staff Corridor Kiss",
    summary: "Mira and Julian cross the selected intimacy threshold.",
    container: "scene",
    pov: "thirdPersonLimited",
    terminalBeat: "They leave changed.",
    storyArcBeatID: "e",
    dramaticFunction: arcRoleContract(template.beats[0], template.name).allowedFunctions[0],
    dramaticEvent: "Mira and Julian kiss in the staff corridor.",
    resultingChange: "Their intimacy becomes chosen rather than engineered.",
    terminalState: "They leave more vulnerable to each other.",
    arcObligationEvidence: {
      selected_intimacy_level: [{ field: "resultingChange", quote: "Their intimacy becomes chosen rather than engineered." }],
    },
  }] }, new Set(["e"]), undefined, [], template);
  assertEquals(result.suggestions.length, 1);
  assertEquals(result.suggestions[0].arcObligationEvidence?.selected_intimacy_level?.length, 1);
});

Deno.test("novel scale uses the preferred 115,000-word floor and rejects tiny new leaves", () => {
  assertEquals(NOVEL_LEAF_CONTAINERS, ["scene", "developedScene", "setPiece", "sceneSequence", "chapter"]);
  assertThrows(() => validateNovelLeafContainers([{ container: "moment" }]));
  assertThrows(() => validateNovelLeafContainers([{ container: "vignette" }]));
  validateNovelLeafContainers([{ container: "moment" }], "shortStory");
  assertEquals(true, true);
  assertEquals(needsNovelExpansion(Array.from({ length: 54 }, () => ({ container: "scene" }))), true);
});

Deno.test("semantic verifier canonicalizes an exact quote mislabeled to another allowed field", async () => {
  const template: any = {
    name: "Custom",
    relationshipFocus: "none",
    intimacyMilestoneRoles: [],
    beats: [{ id: "b", role: "setup", label: "Setup", description: "Make the attraction undeniable." }],
  };
  const suggestions: any[] = [{
    storyArcBeatID: "b",
    dramaticEvent: "They enter the monitored ballroom.",
    resultingChange: "Their attraction becomes undeniable under observation.",
    terminalState: "The resort can now exploit the visible change.",
  }];
  const result = await verifyStoryArcSemantics(suggestions as any, template, async () => ({
    content: JSON.stringify({
      arcWideObligations: [],
      beats: [{
        beatID: "b",
        obligations: [{
          obligationID: "authored_beat_requirement",
          satisfied: true,
          sectionIndex: 0,
          field: "dramaticEvent",
          quote: "Their attraction becomes undeniable under observation.",
          reason: "The authored requirement is satisfied.",
        }],
      }],
    }),
    creditCostCharged: 0,
    remainingCredits: 1,
  }) as any);
  assertEquals(result.unsatisfied, []);
  assertEquals(result.beats[0].obligations[0].field, "resultingChange");
});
