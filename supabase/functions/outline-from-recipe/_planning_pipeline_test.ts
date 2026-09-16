import {
  allocationBeatSummary,
  compilePlanningContextV2,
  dedupeMaterialBySourceReference,
  packetizeAtoms,
  splitLosslessText,
} from "./_planning_pipeline.ts";
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";

function fixture(multiplier = 1) {
  const recipe: Record<string, unknown> = {
    schema: "cathedralos.story_packet",
    version: 1,
    project: {
      id: "project-1",
      summary: "A durable premise that must remain authoritative.".repeat(
        multiplier * 40,
      ),
    },
    selectedCharacters: Array.from(
      { length: 13 * multiplier },
      (_, index) => ({
        id: `character-${index}`,
        name: `Character ${index}`,
        summary: `Character evidence ${index} `.repeat(30),
      }),
    ),
    selectedRelationships: Array.from(
      { length: 7 * multiplier },
      (_, index) => ({
        id: `relationship-${index}`,
        label: `Relationship ${index}`,
        description: `Relationship evidence ${index} `.repeat(24),
      }),
    ),
    selectedThemeQuestions: Array.from(
      { length: 2 * multiplier },
      (_, index) => ({
        id: `theme-${index}`,
        label: `Theme ${index}`,
        description: `Theme evidence ${index} `.repeat(24),
      }),
    ),
    selectedMotifs: Array.from(
      { length: 3 * multiplier },
      (_, index) => ({
        id: `motif-${index}`,
        label: `Motif ${index}`,
        description: `Motif evidence ${index} `.repeat(24),
      }),
    ),
    selectedStorySpark: { id: "spark-1", situation: "The spark.".repeat(50) },
    selectedAftertaste: { id: "aftertaste-1", note: "The ending.".repeat(50) },
  };
  const beats = Array.from(
    { length: 15 },
    (_, index) => ({
      id: `beat-${index}`,
      role: "escalation",
      label: `Beat ${index}`,
      description: "Beat contract",
    }),
  );
  const obligations = Array.from(
    { length: 29 * multiplier },
    (_, index) => ({
      id: `R${index + 1}`,
      required: index < 24 * multiplier,
      statement: `Required obligation ${index} `.repeat(20),
    }),
  );
  return {
    recipe,
    arcTemplate: { id: "arc-1", name: "Test Arc", beats },
    obligations,
  };
}

Deno.test("lossless atomization preserves long canonical evidence", () => {
  const source = "paragraph one.\n\nparagraph two.\n\n" + "x".repeat(9000);
  const chunks = splitLosslessText(source, 500);
  assert(chunks.length > 10);
  assertEquals(chunks.join(""), source);
});

Deno.test("production-shaped context compiles to bounded packets without dropping atoms", () => {
  const fixtureData = fixture();
  const context = compilePlanningContextV2(fixtureData);
  const atoms = Object.values(context.evidenceByID);
  const packets = packetizeAtoms(atoms, 9000);
  assert(packets.length > 1);
  assert(packets.every((packet) => packet.estimatedInputTokens <= 10000));
  assertEquals(
    packets.flatMap((packet) => packet.atoms).map((atom) => atom.id),
    atoms.map((atom) => atom.id),
  );
  assertEquals(context.version, 2);
  assertEquals(context.schema, "cathedralos.outline_planning_context");
});

Deno.test("2x and 5x evidence scale packet count rather than packet size", () => {
  const one = packetizeAtoms(
    Object.values(compilePlanningContextV2(fixture()).evidenceByID),
    9000,
  );
  const two = packetizeAtoms(
    Object.values(compilePlanningContextV2(fixture(2)).evidenceByID),
    9000,
  );
  const five = packetizeAtoms(
    Object.values(compilePlanningContextV2(fixture(5)).evidenceByID),
    9000,
  );
  assert(two.length > one.length);
  assert(five.length > two.length);
  assert(
    Math.max(...five.map((packet) => packet.estimatedInputTokens)) <= 10000,
  );
});

Deno.test("recipe material dedupes by canonical sourceReference, not provider-local id", () => {
  const items = dedupeMaterialBySourceReference([
    {
      id: "provider-a",
      source: "recipe",
      sourceReference: "character:canonical",
      label: "A",
    },
    {
      id: "provider-b",
      source: "recipe",
      sourceReference: "character:canonical",
      label: "A duplicate",
    },
    {
      id: "planner-a",
      source: "planner",
      sourceReference: null,
      label: "Planner A",
    },
    {
      id: "planner-b",
      source: "planner",
      sourceReference: null,
      label: "Planner B",
    },
  ]);
  assertEquals(items.map((item) => item.id), [
    "provider-a",
    "planner-a",
    "planner-b",
  ]);
});

Deno.test("allocation summaries carry counts instead of full evidence prose", () => {
  const summary = allocationBeatSummary({
    beatIndex: 3,
    beat: { role: "crisis", label: "Crisis", description: "The contract" },
    existingSectionCount: 2,
    existingRecipeRequirementIDs: ["R1"],
    requiredObligationIDs: ["R2"],
    routedEvidenceCount: 12,
    routedMaterialCounts: { characters: 3 },
  });
  assertEquals(summary.beatIndex, 3);
  assertEquals(summary.routedEvidenceCount, 12);
  assertEquals("fullRecipe" in summary, false);
  assertNotEquals(summary, undefined);
});
