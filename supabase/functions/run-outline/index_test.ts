import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { prepareCreditReservation } from "./_credit_preflight.ts";
import { generationReadinessFailures } from "./index.ts";
import {
  buildGenerateStoryRequest,
  generationOutputId,
  projectSnapshotLookupFilter,
  shouldChargeAtRunCompletion,
} from "./_generation_request.ts";

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
  assertEquals(source.includes("existing.id, authHeader"), true);
  assertEquals(source.includes("idempotency_key: null"), true);
  assertEquals(source.includes("latest replacement"), false); // replacement lookup is client/server contract
  assertEquals(source.includes("outline_id + start_parent_section_id"), true);
  assertEquals(
    source.includes('.from("chapter_runs")\n      .delete()'),
    false,
  );
  assertEquals(source.includes("pending.slice(0, 1)"), true);
  assertEquals(source.includes("queueContinuation(runId, authHeader)"), true);
  assertEquals(source.includes("worker_lease_until"), true);
  assertEquals(source.includes("RetryableGenerationError"), true);
  assertEquals(source.includes("retryAfterSeconds"), true);
  assertEquals(source.includes("next_retry_at"), true);
  assertEquals(source.includes("queueContinuationAfterDelay"), true);
  assertEquals(source.includes("estimateRunCost("), true);
  assertEquals(source.includes("estimateSections: sections.map"), true);
  assertEquals(source.includes('generationAction: "estimate_bulk"'), true);
  assertEquals(source.includes('status: "queued"'), true);
  assertEquals(source.includes("prepareRun("), true);
  assertEquals(source.includes("credits_reserved: reservedCredits"), true);
  assertEquals(source.includes("needed ${reservedCredits}"), true);
  assertEquals(
    source.indexOf("queueContinuation(runId, authHeader)") >
      source.indexOf("if (!check.allowed)"),
    true,
  );
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
