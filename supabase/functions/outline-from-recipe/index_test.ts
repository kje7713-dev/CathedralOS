import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";

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
  buildPrompt,
  parseAndValidateAllocation,
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

Deno.test("sparse recipe context is preserved for allocation and outline prompts", () => {
  const allocation = new Map([
    ["beat-1", { count: 1, rationale: "A concise setup." }],
    ["beat-2", { count: 2, rationale: "The conflict needs room to escalate." }],
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
  assertEquals(system.includes("Opening Image: 1 sections"), true);
  assertEquals(system.includes("Break into Two: 2 sections"), true);
});

Deno.test("allocation parser preserves varying counts and rejects malformed roots", () => {
  const beats = sparseRequest.arcTemplate.beats;
  const result = parseAndValidateAllocation(
    JSON.stringify({
      allocations: [
        { beatID: "beat-1", sectionCount: 1, rationale: "setup" },
        { beatID: "beat-2", sectionCount: 2, rationale: "escalation" },
      ],
    }),
    beats,
  );
  assertEquals(result.get("beat-1")?.count, 1);
  assertEquals(result.get("beat-2")?.count, 2);

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
      JSON.stringify({
        allocations: [{
          beatID: "beat-1",
          sectionCount: 1,
          rationale: "setup",
        }],
      }),
      beats,
    );
  } catch (caught) {
    missingError = String(caught);
  }
  assertEquals(missingError.includes("missing beat"), true);
});

Deno.test("outline validation requires the exact allocation total and grounded content", () => {
  const allocation = new Map([
    ["beat-1", { count: 1, rationale: "setup" }],
    ["beat-2", { count: 2, rationale: "escalation" }],
  ]);
  const suggestions = [
    {
      title: "The First Attack",
      summary: "Monsters kill humans; Douche witnesses the first attack.",
      container: "scene",
      pov: "thirdPersonLimited",
      terminalBeat: "The threat is undeniable.",
      storyArcBeatID: "beat-1",
    },
    {
      title: "The Flight",
      summary: "Douche escapes as monsters hunt humans.",
      container: "scene",
      pov: "thirdPersonLimited",
      terminalBeat: "The shelter fails.",
      storyArcBeatID: "beat-2",
    },
    {
      title: "The Countermove",
      summary: "Douche chooses how to protect the remaining humans.",
      container: "scene",
      pov: "thirdPersonLimited",
      terminalBeat: "A plan forms.",
      storyArcBeatID: "beat-2",
    },
  ];
  const result = validateSuggestions(
    { suggestions },
    new Set(["beat-1", "beat-2"]),
    allocation,
  );
  assertEquals(result.suggestions.length, 3);
  assertEquals(
    result.suggestions.filter((s) => s.storyArcBeatID === "beat-2").length,
    2,
  );

  let error = "";
  try {
    validateSuggestions(
      { suggestions: suggestions.slice(0, 2) },
      new Set(["beat-1", "beat-2"]),
      allocation,
    );
  } catch (caught) {
    error = String(caught);
  }
  assertEquals(error.includes("expected 2"), true);
});
