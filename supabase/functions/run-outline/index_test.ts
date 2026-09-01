import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
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
    selectedModelId: "model-1",
    lengthMode: "long",
  });
  assertEquals(request.generationAction, "generate");
  assertEquals(request.generationLengthMode, "long");
  assertEquals(request.selectedModelId, "model-1");
  assertEquals(request.container, "scene");
  assertEquals(request.pov, "firstPerson");
  assertEquals(request.terminalBeat, "The door locks.");
  assertEquals(request.projectName, "Novel");
  assertEquals(request.promptPackName, "Recipe");
  assertExists(request.sourcePayloadJSON);
  const payload = request.sourcePayloadJSON as Record<string, unknown>;
  assertEquals((payload.selectedCharacters as unknown[]).length, 1);
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
  assertEquals(source.includes("pending.slice(0, 2)"), true);
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
});

Deno.test("missing-run recovery is definitive while transient errors remain retryable", async () => {
  const source = await Deno.readTextFile(
    "./CathedralOSApp/Services/DataDurabilityCoordinator.swift",
  );
  assertEquals(source.includes("case .runNotFound"), true);
  assertEquals(source.includes("clearPersistedRunStatus"), true);
  assertEquals(source.includes("reconcileRunOutputs"), true);
  assertEquals(source.includes("generation continues on the server"), true);
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
});
