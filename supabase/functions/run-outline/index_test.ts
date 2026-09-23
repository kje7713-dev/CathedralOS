import {
  assertEquals,
  assertExists,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { prepareCreditReservation } from "./_credit_preflight.ts";
import {
  computeMaxChargeCredits,
  type GenerationModel,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";
import {
  generationReadinessFailures,
  handleProviderBillingUnavailableTerminal,
  handleRetryableGenerationFailure,
  isInsufficientCreditsError,
  loadRunOutline,
  parseEmbedSectionError,
  providerBillingTerminalState,
  requireRunOutlineRecipe,
  RunOutlineOutlineError,
  runOutlineSectionLifecycle,
} from "./index.ts";
import {
  buildGenerateStoryRequest,
  generationOutputId,
  projectSnapshotLookupFilter,
  shouldChargeAtRunCompletion,
} from "./_generation_request.ts";

function prepareRunSource(source: string): string {
  const start = source.indexOf("async function prepareRun(");
  const end = source.indexOf("// ---- GET /functions/v1/run-outline", start);
  return source.slice(start, end);
}

const snapshot = {
  project: { id: "project-1", name: "Novel", summary: "A mystery" },
  setting: { summary: "Old house" },
  characters: [{ id: "character-1", name: "Ada" }],
  storySparks: [{ id: "spark-1", title: "A letter" }],
  aftertastes: [],
  relationships: [],
  themeQuestions: [],
  motifs: [],
  promptPacks: [{
    id: "pack-1",
    name: "Recipe",
    includeProjectSetting: true,
    selectedCharacterIDs: ["character-1"],
    selectedStorySparkID: "spark-1",
    selectedRelationshipIDs: [],
    selectedThemeQuestionIDs: [],
    selectedMotifIDs: [],
  }],
};

function mockOutlineClient(result: { data: unknown; error: unknown }) {
  return {
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => result,
        }),
      }),
    }),
  } as never;
}

Deno.test("outline loader accepts a valid authoritative outline", async () => {
  const outline = await loadRunOutline(
    mockOutlineClient({
      data: {
        id: "outline-1",
        user_id: "user-1",
        local_project_id: "PROJECT-1",
        source_recipe_json: { schema: "recipe" },
        source_recipe_hash: "hash-1",
      },
      error: null,
    }),
    "outline-1",
  );
  assertEquals(outline.local_project_id, "PROJECT-1");
  assertEquals(requireRunOutlineRecipe(outline).hash, "hash-1");
});

Deno.test("outline query failures preserve the database diagnostic and remain retryable", async () => {
  try {
    await loadRunOutline(
      mockOutlineClient({
        data: null,
        error: {
          code: "57014",
          message: "statement timeout",
          details: "canceling statement due to user request",
          hint: "retry the query",
        },
      }),
      "outline-1",
    );
    throw new Error("expected lookup failure");
  } catch (error) {
    assertEquals(error instanceof RunOutlineOutlineError, true);
    const typed = error as RunOutlineOutlineError;
    assertEquals(typed.kind, "query");
    assertEquals(typed.retryable, true);
    assertEquals(typed.dbError?.code, "57014");
    assertEquals(
      typed.message,
      "outline_lookup_failed: 57014: statement timeout",
    );
    assertEquals(typed.message.includes("local_project_id missing"), false);
  }
});

Deno.test("missing recipe provenance is a distinct terminal Run All invariant", () => {
  try {
    requireRunOutlineRecipe({
      id: "outline-1",
      local_project_id: "PROJECT-1",
      source_recipe_json: null,
      source_recipe_hash: null,
    });
    throw new Error("expected recipe provenance failure");
  } catch (error) {
    assertEquals(
      (error as Error).message,
      "outline_recipe_provenance_missing: re-plan this outline before Run All",
    );
  }
});

Deno.test("missing outline and missing project identity are distinct terminal invariants", async () => {
  for (
    const [data, expectedKind, expectedMessage] of [
      [null, "not_found", "outline_not_found: outline-1"],
      [
        { id: "outline-1", local_project_id: "   " },
        "missing_project_id",
        "outline_incomplete: local_project_id missing",
      ],
    ] as const
  ) {
    try {
      await loadRunOutline(
        mockOutlineClient({ data, error: null }),
        "outline-1",
      );
      throw new Error("expected lookup failure");
    } catch (error) {
      const typed = error as RunOutlineOutlineError;
      assertEquals(typed.kind, expectedKind);
      assertEquals(typed.retryable, false);
      assertEquals(typed.message, expectedMessage);
    }
  }
});

const entitlement = {
  user_id: "user-1",
  plan_name: "free",
  is_pro: false,
  monthly_credit_allowance: 100,
  purchased_credit_balance: 0,
  current_period_start: null,
  current_period_end: null,
  entitlement_source: "test",
  updated_at: new Date().toISOString(),
};

Deno.test("rounds fractional bulk estimates up for integer run reservations", () => {
  const result = prepareCreditReservation(48.703689999999995, entitlement);
  assertEquals(result.reservedCredits, 49);
  assertEquals(result.check.allowed, true);
  assertEquals(result.check.requiredCredits, 49);
});

Deno.test("uses the rounded reserve for insufficient-credit preflight", () => {
  const result = prepareCreditReservation(48.703689999999995, {
    ...entitlement,
    monthly_credit_allowance: 48,
  });
  assertEquals(result.reservedCredits, 49);
  assertEquals(result.check.allowed, false);
  assertEquals(result.check.requiredCredits, 49);
});

Deno.test("maps a snapshot and section to generate-story's canonical request", () => {
  const request = buildGenerateStoryRequest({
    snapshot,
    section: {
      id: "section-1",
      title: "Arrival",
      summary: "Ada enters.",
      container: "scene",
      pov: "firstPerson",
      terminal_beat: "The door locks.",
    },
    projectId: "project-1",
    runId: "run-1",
    selectedModelId: "model-1",
    lengthMode: "long",
  });
  assertEquals(request.generationAction, "generate");
  assertEquals(request.generationLengthMode, "long");
  assertEquals(request.selectedModelId, "model-1");
  assertEquals(request.run_id, "run-1");
  assertEquals(request.container, "scene");
  assertEquals(request.pov, "firstPerson");
  assertEquals(request.terminalBeat, "The door locks.");
  assertEquals(request.projectName, "Novel");
  assertEquals(request.promptPackName, "Recipe");
  assertExists(request.sourcePayloadJSON);
  const payload = request.sourcePayloadJSON as Record<string, unknown>;
  assertEquals((payload.selectedCharacters as unknown[]).length, 1);
});

Deno.test("Run All request uses frozen recipe provenance instead of a mutable snapshot", () => {
  const frozen = {
    schema: "cathedralos.prompt_pack_export",
    version: 1,
    project: { id: "frozen-project", name: "Frozen" },
    promptPack: { id: "frozen-pack", name: "Frozen Recipe" },
  };
  const request = buildGenerateStoryRequest({
    snapshot: { project: { id: "mutable-project" }, promptPacks: [] },
    frozenRecipe: frozen,
    frozenRecipeHash: "abc123",
    recipeObligations: [{ id: "R1", label: "Save the world" }],
    assignedRecipeRequirementIDs: ["R1"],
    section: {
      id: "section-1",
      title: "Now",
      summary: "Act.",
      container: "scene",
      pov: "firstPerson",
      terminal_beat: "Pressure.",
    },
    projectId: "frozen-project",
    lengthMode: "long",
  });
  assertEquals(
    (request.sourcePayloadJSON as Record<string, unknown>).project,
    frozen.project,
  );
  assertEquals(request.frozenRecipeHash, "abc123");
  assertEquals(request.assignedRecipeRequirementIDs, ["R1"]);
});

Deno.test("generation readiness rejects incomplete or undersized outlines", () => {
  const failures = generationReadinessFailures(
    {
      source_recipe_json: {},
      source_recipe_hash: "hash",
      target_word_count_min: 70000,
      projected_word_count: 29000,
    },
    [{
      id: "s1",
      title: "One",
      summary: "Same",
      container: "scene",
      pov: "firstPerson",
      terminal_beat: "End",
      target_words: 1000,
      story_arc_beat_id: "beat",
      recipe_requirement_ids: [],
    }],
  );
  assertEquals(failures.includes("projected_length_below_minimum"), true);
  assertEquals(failures.includes("section_budgets_below_minimum"), true);
  assertEquals(failures.includes("outline_missing_story_arc_linkage"), true);

  const linkedFailures = generationReadinessFailures(
    {
      source_recipe_json: {},
      source_recipe_hash: "hash",
      target_word_count_min: 1,
      projected_word_count: 100,
      story_arc_id: "arc-1",
    },
    [{
      id: "s1",
      title: "One",
      summary: "Same",
      container: "scene",
      pov: "firstPerson",
      terminal_beat: "End",
      target_words: 100,
      story_arc_beat_id: "beat",
      recipe_requirement_ids: [],
    }],
  );
  assertEquals(
    linkedFailures.includes("outline_missing_story_arc_linkage"),
    false,
  );
});

Deno.test("uses cloudGenerationOutputID as the output handoff", () => {
  assertEquals(
    generationOutputId({ cloudGenerationOutputID: "output-1" }),
    "output-1",
  );
  assertEquals(generationOutputId({ output_id: "legacy" }), "");
});

Deno.test("run completion never charges outputs a second time", () => {
  assertEquals(shouldChargeAtRunCompletion(), false);
});

Deno.test("successful finalization preserves fractional actual credits", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/run-outline/index.ts",
  );
  const finalize = source.indexOf("async function finalizeRun(");
  const helpers = source.indexOf("// ---- helpers", finalize);
  const body = source.slice(finalize, helpers);
  assertStringIncludes(body, "const actual = await loadActualCredits");
  assertStringIncludes(body, "credits_actual: actual");
  assertEquals(body.includes("Math.ceil(actual)"), false);

  const migration = await Deno.readTextFile(
    "./supabase/migrations/20260918143000_make_chapter_run_actual_credits_numeric.sql",
  );
  assertStringIncludes(migration, "credits_actual type numeric(18,6)");
  assertEquals(migration.includes("alter column credits_reserved"), false);
});

Deno.test("run finalization verifies the terminal database update", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/run-outline/index.ts",
  );
  const finalize = source.indexOf("async function finalizeRun(");
  const helpers = source.indexOf("// ---- helpers", finalize);
  const body = source.slice(finalize, helpers);
  assertStringIncludes(body, 'eq("status", "running")');
  assertStringIncludes(body, '.select("id, status")');
  assertStringIncludes(body, "finalizeError");
  assertStringIncludes(body, "no running chapter run row updated");
});

Deno.test("finds a project snapshot through either local ID or lineage", () => {
  assertEquals(
    projectSnapshotLookupFilter("local-1", "lineage-1"),
    "local_project_id.eq.local-1,lineage_id.eq.lineage-1",
  );
  assertEquals(
    projectSnapshotLookupFilter("local-1", null),
    "local_project_id.eq.local-1",
  );
});

Deno.test("run-outline uses leased bounded continuations", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/run-outline/index.ts",
  );
  assertEquals(source.includes('"claim_chapter_run"'), true);
  assertEquals(source.includes("queueContinuation(existing.id)"), true);
  assertEquals(
    source.includes("queueContinuation(existing.id, authHeader)"),
    false,
  );
  assertEquals(source.includes("idempotency_key: null"), true);
  assertEquals(source.includes("latest replacement"), false); // replacement lookup is client/server contract
  assertEquals(source.includes("outline_id + start_parent_section_id"), true);
  assertEquals(
    source.includes('.from("chapter_runs")\n      .delete()'),
    false,
  );
  assertEquals(source.includes("pending.slice(0, 1)"), true);
  assertEquals(source.includes("queueContinuation(runId)"), true);
  assertEquals(source.includes("queueContinuation(runId, authHeader)"), false);
  assertEquals(source.includes("worker_lease_until"), true);
  assertEquals(source.includes("RetryableGenerationError"), true);
  assertEquals(source.includes("retryAfterSeconds"), true);
  assertEquals(source.includes("next_retry_at"), true);
  assertEquals(source.includes("queueContinuationAfterDelay"), true);
  assertEquals(source.includes("estimateRunCost("), true);
  assertEquals(source.includes("estimate_only"), true);
  assertEquals(source.includes("handleEstimate("), true);
  assertEquals(source.includes("loadRunOutline("), true);
  assertEquals(source.includes("outline_lookup_failed:"), true);
  assertEquals(source.includes("scheduleTransientOutlineLookupRetry"), true);
  assertEquals(source.includes("MAX_TRANSIENT_OUTLINE_LOOKUP_ATTEMPTS"), true);
  assertEquals(source.includes("outline.local_project_id missing"), false);
  assertEquals(source.includes("estimated_credits: reservedCredits"), true);
  assertEquals(source.includes("estimateSections: sections.map"), true);
  assertEquals(source.includes('generationAction: "estimate_bulk"'), true);
  assertEquals(source.includes('status: "queued"'), true);
  assertEquals(source.includes("prepareRun("), true);
  assertEquals(source.includes("credits_reserved: reservedCredits"), true);
  assertEquals(source.includes("needed ${reservedCredits}"), false);
  assertEquals(source.includes("if (!check.allowed)"), false);
  assertStringIncludes(
    prepareRunSource(source),
    "queueContinuation(runId)",
  );
  assertEquals(prepareRunSource(source).includes("authHeader"), false);
  assertEquals(
    source.includes(
      "queueContinuationAfterDelay(\n                runId,\n                authHeader",
    ),
    false,
  );
  assertEquals(
    source.includes(
      "scheduleTransientOutlineLookupRetry(\n          adminClient,\n          runId,\n          authHeader",
    ),
    false,
  );
});

Deno.test("durable continuation auth is server-trusted and owner-derived", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/run-outline/index.ts",
  );
  const handler = source.slice(
    source.indexOf("async function handleKickoff"),
    source.indexOf("// 1. Public auth"),
  );
  assertStringIncludes(handler, "trustedResumeRunId(");
  assertStringIncludes(
    handler,
    "loadDurableRunOwner(adminClient, trustedResumeId)",
  );
  assertStringIncludes(handler, "run.user_id");
  assertStringIncludes(
    handler,
    'return errorResponse("not_found", "run not found", 404)',
  );
  assertEquals(handler.includes("body.user_id"), false);

  const publicAuth = source.slice(
    source.indexOf("// 1. Public auth"),
    source.indexOf("// 2. Resume an ordinary user-initiated recovery request."),
  );
  assertStringIncludes(publicAuth, 'req.headers.get("Authorization")');
  assertStringIncludes(publicAuth, "userClient.auth.getUser()");

  const queueStart = source.indexOf("async function queueContinuation(\n");
  const queue = source.slice(queueStart, source.indexOf("/**", queueStart));
  assertStringIncludes(
    queue,
    'Authorization": internalAuthHeader(SUPABASE_SERVICE_ROLE_KEY)',
  );
  assertStringIncludes(queue, "resume_run_id: runId");
  assertEquals(queue.includes("authHeader"), false);
});

Deno.test("missing-run recovery is definitive while transient errors remain retryable", async () => {
  const source = await Deno.readTextFile(
    "./CathedralOSApp/Services/DataDurabilityCoordinator.swift",
  );
  assertEquals(source.includes("case .runNotFound"), true);
  assertEquals(source.includes("clearPersistedRunStatus"), true);
  assertEquals(source.includes("reconcileRunOutputs"), true);
  assertEquals(source.includes("generation continues on the server"), true);
  assertEquals(source.includes("installRunStatus"), true);
});

Deno.test("terminal kickoff status is installed before reconciliation", async () => {
  const source = await Deno.readTextFile(
    "./CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift",
  );
  const install = source.indexOf("durabilityCoordinator.installRunStatus(");
  const reconcile = source.indexOf("performManualSyncAll", install);
  assertEquals(install >= 0, true);
  assertEquals(reconcile > install, true);
});

Deno.test("run status endpoint exposes an exact idempotent replacement lookup", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/run-outline/index.ts",
  );
  assertEquals(source.includes("idempotency_key"), true);
  assertEquals(
    source.includes('order("created_at", { ascending: false })'),
    true,
  );
  assertEquals(source.includes("maybeSingle()"), true);
  assertEquals(source.includes('.eq("user_id", userData.user.id)'), true);
  assertEquals(
    source.includes("causing a false 404"),
    true,
  );
});

Deno.test("initial Run All estimate is not duplicated by model state initialization", async () => {
  const source = await Deno.readTextFile(
    "./CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift",
  );
  assertEquals(
    source.includes("@State private var hasLoadedModels = false"),
    true,
  );
  assertEquals(source.includes("guard hasLoadedModels else { return }"), true);
  assertEquals(
    source.includes("await refreshEstimate()\n        hasLoadedModels = true"),
    true,
  );
});

Deno.test("Run All recovery reuses exact persisted output before generation or normalization", async () => {
  const source = await Deno.readTextFile(
    "supabase/functions/run-outline/index.ts",
  );
  const existing = source.indexOf(
    "const existingOutput = await findRunOutput(",
  );
  const normalize = source.indexOf(
    "const normalize = await ensureMemoryPipelineVersion(",
  );
  const generate = source.indexOf("const result = await callGenerateStory(");
  const repair = source.indexOf("await ensureOutputMemory(", existing);
  const advance = source.indexOf('status: "completed"', repair);
  assertEquals(existing >= 0, true);
  assertEquals(existing < normalize, true);
  assertEquals(normalize < generate, true);
  assertEquals(existing < repair && repair < advance, true);
  assertStringIncludes(
    source.slice(existing, normalize),
    "run.id",
    "recovery lookup must be scoped by the durable run id",
  );
  assertStringIncludes(
    source.slice(existing, normalize),
    "section.id",
    "recovery lookup must be scoped by the exact run section id",
  );
  assertStringIncludes(
    source,
    "RetryableMemoryError",
    "memory failure after prose persistence must schedule recovery rather than fail the run",
  );
  assertEquals(
    source.includes('select("id, status, was_truncated")'),
    false,
    "recovery lookup must select only columns that exist in generation_outputs",
  );
});

Deno.test("Run All preserves memory lineage and avoids duplicate prose billing on recovery", async () => {
  const [runOutline, embedding] = await Promise.all([
    Deno.readTextFile("supabase/functions/run-outline/index.ts"),
    Deno.readTextFile("supabase/functions/_shared/section-embedding.ts"),
  ]);
  assertStringIncludes(runOutline, '.eq("run_id", runId)');
  assertStringIncludes(runOutline, '.eq("run_section_id", sectionId)');
  assertStringIncludes(runOutline, '.eq("status", "complete")');
  assertStringIncludes(runOutline, "existingOutputID: existingOutput");
  assertStringIncludes(runOutline, "output_id: outputID");
  assertStringIncludes(
    embedding,
    "repaired?.generation_output_id !== outputId",
  );
  assertStringIncludes(
    runOutline,
    "await ensureOutputMemory(",
    "existing prose must repair memory before the section advances",
  );
});

Deno.test("Run All Luna estimate uses canonical token pricing, not the legacy 709-credit floor", () => {
  const luna: GenerationModel = {
    id: "gpt-5.6-luna",
    provider: "openai",
    provider_model: "gpt-5.6-luna",
    display_name: "GPT-5.6 Luna",
    description: null,
    input_credit_rate: 0,
    output_credit_rate: 0,
    minimum_charge_credits: 0.25,
    max_output_tokens: 4096,
    enabled: true,
    sort_order: 1,
    provider_available: true,
    model_kind: "text_generation",
    pricing_state: "verified",
    pricing_verified_at: "2026-09-17T00:00:00Z",
    cache_write_pricing_required: true,
    billing_multiplier: 2,
    provider_input_usd_per_1m: 0.2,
    provider_cached_input_usd_per_1m: 0.02,
    provider_cache_write_usd_per_1m: 0.25,
    provider_output_usd_per_1m: 1.2,
    pricing_effective_at: "2026-09-17T23:00:00Z",
    cacheMode: "explicit",
  };
  const estimate = computeMaxChargeCredits(
    {
      uncachedInputTokens: 1_000,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 4_096,
      toolCostUsd: 0,
    },
    snapshotPricing(luna),
  );
  const reservation = prepareCreditReservation(estimate, entitlement);
  assertEquals(reservation.reservedCredits, 1);
  assertEquals(reservation.reservedCredits < 709, true);
});

Deno.test("whole-run maximum estimate is informational, not a kickoff gate", async () => {
  const source = await Deno.readTextFile(
    "supabase/functions/run-outline/index.ts",
  );
  const prepare = source.slice(
    source.indexOf("async function prepareRun("),
    source.indexOf(
      "// ---- GET /functions/v1/run-outline",
      source.indexOf("async function prepareRun("),
    ),
  );
  assertStringIncludes(
    prepare,
    "const reservedCredits = Math.ceil(estimatedCost)",
  );
  assertStringIncludes(prepare, 'status: "running"');
  assertEquals(prepare.includes("if (!check.allowed)"), false);
  const estimate = source.slice(
    source.indexOf("async function handleEstimate("),
    source.indexOf("// ---- durable estimate/credit preflight"),
  );
  assertStringIncludes(estimate, "estimated_credits: reservedCredits");
  assertStringIncludes(estimate, "allowed: true");
  assertStringIncludes(estimate, "can_afford_estimate: check.allowed");
});

Deno.test("insufficient credits are classified narrowly", () => {
  assertEquals(
    isInsufficientCreditsError(
      new Error("insufficient_credits: need 2, have 1"),
    ),
    true,
  );
  assertEquals(isInsufficientCreditsError(new Error("provider failed")), false);
  assertEquals(
    isInsufficientCreditsError({ code: "insufficient_credits" }),
    true,
  );
});

Deno.test("embed-section HTTP 402 body reaches Run All credit classifier", () => {
  const error = parseEmbedSectionError(
    402,
    JSON.stringify({
      errorCode: "insufficient_credits",
      message: "Insufficient credits for the next billable stage.",
    }),
  );
  assertEquals(isInsufficientCreditsError(error), true);
  assertEquals(
    error.message,
    "Insufficient credits for the next billable stage.",
  );
});

Deno.test("credit shortage pauses a resumable run and preserves the exact prose output", async () => {
  const source = await Deno.readTextFile(
    "supabase/functions/run-outline/index.ts",
  );
  const pauseStart = source.indexOf(
    "async function pauseRunInsufficientCredits(",
  );
  const pauseEnd = source.indexOf("class RetryableMemoryError", pauseStart);
  const pause = source.slice(pauseStart, pauseEnd);
  assertStringIncludes(pause, 'status: "paused_insufficient_credits"');
  assertStringIncludes(pause, 'status: "pending"');
  assertStringIncludes(pause, "credits_actual: actual");
  assertStringIncludes(pause, "completed_at: null");
  assertStringIncludes(source, "outputID: result.output_id");
  assertStringIncludes(source, "Resume skips whole-run estimate/preflight");
  assertStringIncludes(source, 'run.status === "paused_insufficient_credits"');
  assertStringIncludes(source, "runOutline(runId, adminClient)");
  assertEquals(pause.includes('status: "failed"'), false);
});

Deno.test("live actual spend reconciles after completed and recovered sections", async () => {
  const source = await Deno.readTextFile(
    "supabase/functions/run-outline/index.ts",
  );
  const reconcile = source.indexOf("async function reconcileActualCredits(");
  assertStringIncludes(
    source.slice(reconcile, reconcile + 900),
    "loadActualCredits",
  );
  assertStringIncludes(
    source.slice(reconcile, reconcile + 900),
    "credits_actual: actual",
  );
  const recovery = source.indexOf(
    "const existingOutput = await findRunOutput(",
  );
  const recoveryEnd = source.indexOf("continue;", recovery);
  assertStringIncludes(
    source.slice(recovery, recoveryEnd),
    "reconcileActualCredits",
  );
  const generation = source.indexOf("const result = await callGenerateStory(");
  const memory = source.indexOf("await ensureOutputMemory(", generation);
  assertEquals(generation < memory, true);
  assertStringIncludes(source.slice(generation, memory), 'status: "pending"');
});

Deno.test("paused status is included only in the new forward migration", async () => {
  const migration = await Deno.readTextFile(
    "supabase/migrations/20260920170000_pause_run_on_insufficient_credits.sql",
  );
  assertStringIncludes(migration, "paused_insufficient_credits");
  const historical = await Deno.readTextFile(
    "supabase/migrations/20260901120000_durable_run_outline_estimate_preflight.sql",
  );
  assertEquals(historical.includes("paused_insufficient_credits"), false);
});

Deno.test("Run All iOS presentation treats paused as resumable and shows actual spend", async () => {
  const [sheet, banner, coordinator, service] = await Promise.all([
    Deno.readTextFile(
      "CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift",
    ),
    Deno.readTextFile(
      "CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift",
    ),
    Deno.readTextFile(
      "CathedralOSApp/Services/DataDurabilityCoordinator.swift",
    ),
    Deno.readTextFile("CathedralOSApp/Services/RunOutlineService.swift"),
  ]);
  assertStringIncludes(sheet, "Maximum estimated cost:");
  assertStringIncludes(sheet, "!isStarting");
  assertEquals(sheet.includes("return est.allowed"), false);
  assertStringIncludes(banner, "Generation paused");
  assertStringIncludes(banner, "More credits needed");
  assertStringIncludes(banner, 'Button("Resume")');
  assertStringIncludes(banner, "Final cost:");
  assertStringIncludes(
    coordinator,
    'status.status == "paused_insufficient_credits"',
  );
  assertStringIncludes(
    coordinator,
    "preserving status without terminal reconciliation",
  );
  assertStringIncludes(service, "resume_run_id");
  assertStringIncludes(service, "actualCreditsText");
});

Deno.test("Run All executable lifecycle pauses after prose settlement and resumes memory without duplicate generation", async () => {
  const state: {
    run: "running" | "paused_insufficient_credits" | "completed";
    section: "running" | "pending" | "completed";
    outputID: string | null;
    creditsActual: number;
  } = {
    run: "running",
    section: "running",
    outputID: null,
    creditsActual: 0,
  };
  let providerCalls = 0;
  let proseBillingCalls = 0;
  let memoryCalls = 0;
  const outputID = "output-prose-1";

  const first = await runOutlineSectionLifecycle({
    generate: async () => {
      providerCalls++;
      proseBillingCalls++;
      state.creditsActual += 2.75;
      return { outputID, status: "complete", wasTruncated: false };
    },
    persistPendingOutput: async (id) => {
      state.outputID = id;
      state.section = "pending";
    },
    ensureMemory: async () => {
      memoryCalls++;
      throw { code: "insufficient_credits" };
    },
    persistCompleted: async () => {
      state.section = "completed";
    },
    isInsufficientCredits: (error) =>
      (error as { code?: string }).code === "insufficient_credits",
  });
  state.run = first.status;

  assertEquals(first.status, "paused_insufficient_credits");
  assertEquals(first.outputID, outputID);
  assertEquals(state.outputID, outputID);
  assertEquals(state.section, "pending");
  assertEquals(state.run, "paused_insufficient_credits");
  assertEquals(state.creditsActual, 2.75);
  assertEquals(providerCalls, 1);
  assertEquals(proseBillingCalls, 1);
  assertEquals(memoryCalls, 1);

  const resumed = await runOutlineSectionLifecycle({
    existingOutputID: state.outputID,
    generate: async () => {
      providerCalls++;
      proseBillingCalls++;
      return { outputID: "unexpected-new-output", status: "complete" };
    },
    persistPendingOutput: async () => {
      throw new Error("persistPendingOutput must not run during recovery");
    },
    ensureMemory: async (id) => {
      memoryCalls++;
      assertEquals(id, outputID);
    },
    persistCompleted: async (id) => {
      assertEquals(id, outputID);
      state.section = "completed";
      state.run = "completed";
    },
    isInsufficientCredits: () => false,
  });

  assertEquals(resumed.status, "completed");
  assertEquals(resumed.outputID, outputID);
  assertEquals(state.section, "completed");
  assertEquals(state.run, "completed");
  assertEquals(state.creditsActual, 2.75);
  assertEquals(providerCalls, 1);
  assertEquals(proseBillingCalls, 1);
  assertEquals(memoryCalls, 2);
});

Deno.test("Run All atomic memory settlement race pauses instead of failing", async () => {
  let providerCalls = 0;
  let billingCalls = 0;
  let finalStatus = "running";
  const result = await runOutlineSectionLifecycle({
    generate: async () => {
      providerCalls++;
      billingCalls++;
      return { outputID: "output-race-1", status: "complete" };
    },
    persistPendingOutput: async () => {},
    ensureMemory: async () => {
      throw new Error("insufficient credits for stage");
    },
    persistCompleted: async () => {
      finalStatus = "completed";
    },
    isInsufficientCredits: (error) =>
      /insufficient credits for stage/i.test(String(error)),
  });
  finalStatus = result.status;
  assertEquals(finalStatus, "paused_insufficient_credits");
  assertEquals(providerCalls, 1);
  assertEquals(billingCalls, 1);
});

// =============================================================================
// Provider billing-unavailable terminal behavior tests (Kevin 2026-09-21 v2 #1)
//
// Verifies the canonical predicate detects BOTH error surfaces caught by the
// run-outline catch chain (ProviderBillingUnavailableError from
// callGenerateStory generation stage AND SectionEmbeddingError from
// ensureOutputMemory memory/embedding stage), and that markRunFailed writes
// the canonical friendly-message terminal state. Full end-to-end catch-chain
// tests with chapter_runs inspection require a separate integration harness;
// these smoke tests cover the predicate + helper behavior exercised by the
// chain. The catch chain itself is verified manually in the v2 review
// REPORT-BACK.
// =============================================================================

import { ProviderBillingUnavailableError } from "../generate-story/_provider.ts";
import { SectionEmbeddingError } from "../_shared/section-embedding.ts";
import { isProviderBillingUnavailable } from "../generate-story/_provider.ts";

Deno.test("run-outline: isProviderBillingUnavailable catches ProviderBillingUnavailableError", () => {
  const err = new ProviderBillingUnavailableError({
    code: "credit_balance_exhausted",
    message: "no credits remaining",
    status: 429,
  });
  assertEquals(isProviderBillingUnavailable(err), true);
});

Deno.test("run-outline: isProviderBillingUnavailable catches SectionEmbeddingError(code=provider_billing_unavailable)", () => {
  const err = new SectionEmbeddingError(
    "provider_billing_unavailable",
    "OpenAI embed 429 (upstream=credit_balance_exhausted)",
  );
  assertEquals(isProviderBillingUnavailable(err), true);
});

Deno.test("run-outline: isProviderBillingUnavailable does NOT match a plain HTTP 429 provider_rate_limited error (preserves existing retry semantics)", () => {
  // Real provider_rate_limited (no upstream code) must continue to flow
  // through the existing RetryableGenerationError path, NOT be misclassified
  // as billing_unavailable. This proves the canonical predicate does not
  // over-classify.
  const err = new Error("provider_rate_limited: 429 from upstream");
  assertEquals(isProviderBillingUnavailable(err), false);
  const classified = err instanceof Error && err.message.includes("rate");
  assertEquals(
    classified,
    true,
    "sanity: 429 rate-limit error still looks like a rate limit",
  );
});

Deno.test("Run All provider billing failure writes the exact terminal database state", () => {
  const state = providerBillingTerminalState(
    "Temporarily unavailable — try again later.",
    12.75,
    "2026-09-21T16:00:00.000Z",
  );
  assertEquals(state, {
    status: "failed",
    error: "Temporarily unavailable — try again later.",
    credits_reserved: 0,
    credits_actual: 12.75,
    completed_at: "2026-09-21T16:00:00.000Z",
    worker_lease_until: null,
    next_retry_at: null,
  });
});

Deno.test("Run All generation-stage billing failure remains terminal before memory", async () => {
  let pendingWrites = 0;
  let completedWrites = 0;
  try {
    await runOutlineSectionLifecycle({
      generate: async () => {
        throw new ProviderBillingUnavailableError({
          code: "credit_balance_exhausted",
          message: "upstream detail stays private",
          status: 429,
        });
      },
      persistPendingOutput: async () => pendingWrites++,
      ensureMemory: async () => {
        throw new Error("memory must not run after generation failure");
      },
      persistCompleted: async () => completedWrites++,
      isInsufficientCredits: () => false,
    });
    throw new Error("expected generation-stage billing failure");
  } catch (error) {
    assertEquals(isProviderBillingUnavailable(error), true);
    assertEquals(pendingWrites, 0);
    assertEquals(completedWrites, 0);
  }
});

Deno.test("Run All memory-stage billing failure preserves output and skips completion", async () => {
  let pendingOutput = "";
  let completedWrites = 0;
  try {
    await runOutlineSectionLifecycle({
      generate: async () => ({
        outputID: "output-generation-1",
        status: "complete",
      }),
      persistPendingOutput: async (outputID) => pendingOutput = outputID,
      ensureMemory: async () => {
        throw new SectionEmbeddingError(
          "provider_billing_unavailable",
          "OpenAI embed 429",
          { code: "credit_balance_exhausted", status: 429 },
        );
      },
      persistCompleted: async () => completedWrites++,
      isInsufficientCredits: () => false,
    });
    throw new Error("expected memory-stage billing failure");
  } catch (error) {
    assertEquals(isProviderBillingUnavailable(error), true);
    assertEquals(pendingOutput, "output-generation-1");
    assertEquals(completedWrites, 0);
  }
});

Deno.test("Run All terminal handler: generation stage fails run and section without alert or continuation", async () => {
  const writes: Record<string, unknown>[] = [];
  let released = 0;
  let alerts = 0;
  let continuations = 0;
  const actualSpend = 12.75;
  await handleProviderBillingUnavailableTerminal({
    adminClient: {} as never,
    runId: "run-generation-terminal",
    section: { id: "section-1", output_id: "prior-output" },
    projectId: "project-1",
    selectedModel: "luna",
    stage: "generation",
    upstream: {
      code: "credit_balance_exhausted",
      message: "real upstream detail",
      status: 429,
    },
    updateSection: async (_client, _runId, section) => writes.push(section),
    markRun: async (_client, _runId, error) => {
      const state = providerBillingTerminalState(error, actualSpend, "now");
      writes.push(state);
    },
    releaseLease: async () => released++,
    notify: async () => {
      alerts++;
    },
    scheduleAlert: () => {
      continuations++;
    },
  });
  assertEquals(writes[0], {
    id: "section-1",
    output_id: "prior-output",
    status: "failed",
    error: "Temporarily unavailable — try again later.",
    completed_at: writes[0].completed_at,
  });
  assertEquals(writes[1], {
    status: "failed",
    error: "Temporarily unavailable — try again later.",
    credits_reserved: 0,
    credits_actual: actualSpend,
    completed_at: "now",
    worker_lease_until: null,
    next_retry_at: null,
  });
  assertEquals(released, 1);
  assertEquals(alerts, 0);
  assertEquals(continuations, 0);
});

Deno.test("Run All terminal handler: memory stage preserves output and sends one trusted alert", async () => {
  let section: Record<string, unknown> | null = null;
  let runError = "";
  let released = 0;
  let continuationCalls = 0;
  const alerts: Record<string, unknown>[] = [];
  await handleProviderBillingUnavailableTerminal({
    adminClient: {} as never,
    runId: "run-memory-terminal",
    section: { id: "section-2", output_id: "output-1" },
    projectId: "project-2",
    selectedModel: "luna",
    stage: "memory",
    upstream: {
      code: "credit_balance_exhausted",
      message: "trusted OpenAI message",
      status: 429,
    },
    updateSection: async (_client, _runId, value) => {
      section = value;
    },
    markRun: async (_client, _runId, error) => {
      runError = error;
    },
    releaseLease: async () => released++,
    notify: async (context) => {
      alerts.push(context);
    },
    scheduleAlert: (promise) => {
      continuationCalls++;
      void promise;
    },
  });
  assertEquals(section?.output_id, "output-1");
  assertEquals(section?.status, "failed");
  assertEquals(section?.error, "Temporarily unavailable — try again later.");
  assertEquals(runError, "Temporarily unavailable — try again later.");
  assertEquals(released, 1);
  assertEquals(continuationCalls, 1);
  assertEquals(alerts.length, 1);
  assertEquals(alerts[0].upstreamProviderCode, "credit_balance_exhausted");
  assertEquals(alerts[0].upstreamStatus, 429);
  assertEquals(alerts[0].upstreamMessage, "trusted OpenAI message");
  assertEquals(alerts[0].chapterRunID, "run-memory-terminal");
  assertEquals(alerts[0].projectID, "project-2");
});

Deno.test("Run All provider_rate_limited keeps section pending and schedules one retry", async () => {
  let section: Record<string, unknown> | null = null;
  let retryAt = "";
  let released = 0;
  const scheduled: number[] = [];
  await handleRetryableGenerationFailure({
    adminClient: {} as never,
    runId: "run-rate-limit",
    section: { id: "section-rate" },
    message: "provider_rate_limited",
    retryAfterSeconds: 60,
    now: () => 1_000,
    updateSection: async (_client, _runId, value) => {
      section = value;
    },
    updateRunRetry: async (_client, _runId, value) => {
      retryAt = value;
    },
    releaseLease: async () => released++,
    scheduleContinuation: (seconds) => scheduled.push(seconds),
  });
  assertEquals(section?.status, "pending");
  assertEquals(section?.retry_after_seconds, 60);
  assertEquals(section?.error, "provider_rate_limited");
  assertEquals(retryAt, new Date(61_000).toISOString());
  assertEquals(released, 1);
  assertEquals(scheduled, [60]);
});
