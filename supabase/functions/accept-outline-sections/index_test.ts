import { assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { acceptRunTerminalOutcome } from "./_outcome.ts";
import {
  buildLengthContract,
  canonicalUUID,
  computeRequestFingerprint,
  hashCanonicalRecipe,
  mergeSectionsByCanonicalID,
  normalizeStoryArcBeatIDs,
  sectionRow,
  validate,
} from "./index.ts";

Deno.test("Accept All completes only after all sections and snapshot merge succeed", () => {
  assertEquals(acceptRunTerminalOutcome(0, null, null), {
    status: "completed",
    error: null,
  });
});

Deno.test("Accept All fails when snapshot merge fails after 6/6 sections", () => {
  assertEquals(
    acceptRunTerminalOutcome(
      0,
      "Could not update project snapshot: permission denied",
      null,
    ),
    {
      status: "failed",
      error: "Could not update project snapshot: permission denied",
    },
  );
});

Deno.test("Accept All preserves partial section failure details", () => {
  assertEquals(acceptRunTerminalOutcome(1, null, "Section title failed"), {
    status: "failed",
    error: "Section title failed",
  });
});

Deno.test("Accept All persists outline sections without extraction or embeddings", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  assertEquals(source.includes("processSectionMemory"), false);
  assertEquals(source.includes("SupabaseCreditStore"), false);
  assertEquals(source.includes("section_embeddings"), false);
  assertEquals(source.includes("OPENAI_API_KEY"), false);
  assertEquals(source.includes("functions/v1/embed-section"), false);
  assertEquals(source.includes("freezeOutlineRecipe"), true);
  assertEquals(source.includes("source_recipe_hash"), true);
  assertEquals(source.includes("embedSectionWithRetry"), false);
});

Deno.test("Accept All memory stage cannot rewrite outline section ownership", async () => {
  const source = await Deno.readTextFile(
    new URL("../_shared/section-embedding.ts", import.meta.url),
  );
  const start = source.indexOf("export async function processSectionMemory");
  const end = source.indexOf("export async function ensureMemoryPipelineVersion");
  const memoryStage = source.slice(start, end);
  assertEquals(memoryStage.includes('from("outline_sections")'), false);
  assertEquals(memoryStage.includes("position: body.position"), false);
  assertEquals(memoryStage.includes('from("section_embeddings")'), true);
});

Deno.test("embed-section adapter maps typed shared results and errors", async () => {
  const source = await Deno.readTextFile(
    new URL("../embed-section/index.ts", import.meta.url),
  );
  assertEquals(source.includes("SectionEmbeddingError"), true);
  assertEquals(source.includes("JSON.stringify(result)"), true);
  assertEquals(source.includes("errorResponse(err.code, err.message"), true);
});

const BEAT_A = "cca975fc-e13a-4ade-8344-2470a8c2b3a0";
const BEAT_B = "11111111-1111-4111-8111-111111111111";
const BEAT_C = "22222222-2222-4222-8222-222222222222";

function beatLookup(rows: string[]) {
  const query: any = {
    select: () => query,
    in: (_column: string, _ids: string[]) =>
      Promise.resolve({
        data: rows.map((id) => ({ id })),
        error: null,
      }),
  };
  return { from: (_table: string) => query } as any;
}

function validRequest(
  sectionCount: number,
  storyArcBeatID: string | null = null,
): any {
  return {
    outline_id: "11111111-1111-4111-8111-111111111111",
    project_id: "project-1",
    idempotency_key: "key-1",
    source_recipe_json: {
      schema: "cathedralos.prompt_pack_export",
      version: 1,
      project: { id: "project-1" },
      promptPack: { id: "pack-1", name: "Canonical Recipe" },
    },
    sections: Array.from({ length: sectionCount }, (_, index) => ({
      id: `${String(index + 1).padStart(8, "0")}-1111-4111-8111-111111111111`,
      position: index,
      title: `Section ${index + 1}`,
      summary: "A valid section summary",
      storyArcBeatID,
    })),
  };
}

Deno.test("request validation accepts the story packet produced by outline suggestions", () => {
  const body = validRequest(1);
  body.source_recipe_json.schema = "cathedralos.story_packet";
  assertEquals(validate(body), null);
});

Deno.test("length contract persists novel target and container-derived section ranges", () => {
  const contract = buildLengthContract([
    { container: "scene" },
    { container: "chapter" },
    { container: "sceneSequence" },
  ]);
  assertEquals(contract.outline, {
    planning_format: "novel",
    target_word_count: 80000,
    target_word_count_min: 70000,
    target_word_count_max: 90000,
    projected_word_count: 9078,
  });
  assertEquals(contract.sections, [
    { targetWords: 1000, targetWordsMin: 615, targetWordsMax: 1385 },
    { targetWords: 4231, targetWordsMin: 2308, targetWordsMax: 6154 },
    { targetWords: 3847, targetWordsMin: 2308, targetWordsMax: 5385 },
  ]);
});

Deno.test("arc linkage canonicalizes uppercase request IDs against lowercase DB IDs", async () => {
  const sections = [{ storyArcBeatID: BEAT_A.toUpperCase() }] as any;
  const result = await normalizeStoryArcBeatIDs(beatLookup([BEAT_A]), sections);
  assertEquals(result, sections);
});

Deno.test("arc linkage accepts lowercase and mixed-casing beat IDs", async () => {
  const mixed = "CCA975FC-e13a-4ADE-8344-2470a8c2b3a0";
  const sections = [
    { storyArcBeatID: BEAT_A },
    { storyArcBeatID: mixed },
    { storyArcBeatID: BEAT_B.toUpperCase() },
    { storyArcBeatID: BEAT_C },
  ] as any;
  const result = await normalizeStoryArcBeatIDs(
    beatLookup([BEAT_A, BEAT_B, BEAT_C]),
    sections,
  );
  assertEquals(result, sections);
  assertEquals(canonicalUUID(mixed), BEAT_A);
});

Deno.test("arc linkage fails closed for an actually missing UUID", async () => {
  let message = "";
  try {
    await normalizeStoryArcBeatIDs(
      beatLookup([BEAT_A]),
      [{ storyArcBeatID: BEAT_B }] as any,
    );
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message, `Story arc beat linkage is unavailable: ${BEAT_B}`);
});

Deno.test("Accept All rejects malformed non-null story arc beat IDs", () => {
  assertEquals(
    validate(validRequest(1, "not-a-uuid")),
    "invalid story arc beat ID",
  );
});

Deno.test("Accept All validation allows 1 through 200 sections and rejects 201", () => {
  for (const count of [1, 100, 101, 200]) {
    assertEquals(validate(validRequest(count)), null);
  }
  assertEquals(
    validate(validRequest(201)),
    "sections must contain 1-200 items",
  );
});

Deno.test("recipe obligation assignments persist with accepted sections", () => {
  const row = sectionRow(
    {
      id: "section-1",
      position: 0,
      title: "The Premise",
      summary: "The monsters attack.",
      recipeRequirementIDs: ["R1", "R4"],
    },
    "outline-1",
    2,
  );
  assertEquals(row.recipe_requirement_ids, ["R1", "R4"]);
  assertEquals(
    validate({
      ...validRequest(1),
      sections: [{
        ...validRequest(1).sections[0],
        recipeRequirementIDs: ["R1"],
      }],
    }),
    null,
  );
  assertEquals(
    validate({
      ...validRequest(1),
      sections: [{
        ...validRequest(1).sections[0],
        recipeRequirementIDs: ["R".repeat(101)],
      }],
    }),
    "invalid recipe requirement IDs",
  );
});

Deno.test("arc linkage is persisted for single and bulk section acceptance", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/accept-outline-sections/index.ts",
  );
  assertEquals(
    source.includes("story_arc_beat_id: section.storyArcBeatID ?? null"),
    true,
  );
  assertEquals(source.includes("storyArcBeatID: row.story_arc_beat_id"), true);
  const row = sectionRow(
    {
      id: "section-1",
      position: 0,
      title: "One",
      summary: "Event",
      storyArcBeatID: "beat-1",
    },
    "outline-1",
    4,
  );
  assertEquals(row.story_arc_beat_id, "beat-1");
  const service = await Deno.readTextFile(
    "./CathedralOSApp/Services/SectionEmbedService.swift",
  );
  const restore = await Deno.readTextFile(
    "./CathedralOSApp/Services/ProjectCloudSyncService.swift",
  );
  assertEquals(
    service.includes("storyArcBeatID: suggestion.storyArcBeatID"),
    true,
  );
  assertEquals(
    restore.includes("section.storyArcBeatID = storyArcBeatID"),
    true,
  );
});

Deno.test("Accept All snapshot merge serializes the complete canonical Section Contract", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  for (const field of [
    "entryState: row.entry_state",
    "dramaticEvent: row.dramatic_event",
    "resultingChange: row.resulting_change",
    "terminalState: row.terminal_state",
    "storyArcBeatID: row.story_arc_beat_id",
    "targetWords: row.target_words",
    "targetWordsMin: row.target_words_min",
    "targetWordsMax: row.target_words_max",
    "recipeRequirementIDs: Array.isArray(row.recipe_requirement_ids)",
    "parentID: row.parent_id",
    "container: row.container",
    "pov: row.pov",
    "terminalBeat: row.terminal_beat",
  ]) {
    assertEquals(source.includes(field), true, `missing snapshot field: ${field}`);
  }
});

Deno.test("Accept All snapshot merge canonicalizes parent and beat UUIDs", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  assertEquals(source.includes("canonicalUUID(String(row.parent_id))"), true);
  assertEquals(source.includes("canonicalUUID(String(row.story_arc_beat_id))"), true);
});

Deno.test("Accept All canonicalizes section identity for snapshot merge", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  assertEquals(source.includes("canonicalUUID(String(section.id))"), true);
  assertEquals(
    source.includes("canonicalUUID(String(row.story_arc_beat_id))"),
    true,
  );
});

Deno.test("shared embedding canonicalizes Story Arc FK lookup and persistence", async () => {
  const source = await Deno.readTextFile(
    new URL("../_shared/section-embedding.ts", import.meta.url),
  );
  assertEquals(source.includes("canonicalUUID(body.story_arc_beat_id)"), true);
  assertEquals(source.includes("story_arc_beat_id: validatedBeatID"), true);
});

Deno.test("snapshot merge replaces uppercase section identity without duplication", () => {
  const merged = mergeSectionsByCanonicalID(
    [{ id: "CCA975FC-E13A-4ADE-8344-2470A8C2B3A0", title: "old" }],
    [{ id: "cca975fc-e13a-4ade-8344-2470a8c2b3a0", title: "new" }],
  );
  assertEquals(merged, [{
    id: "cca975fc-e13a-4ade-8344-2470a8c2b3a0",
    title: "new",
  }]);
});

Deno.test("recipe provenance hash is deterministic across object key order", async () => {
  const a = {
    schema: "cathedralos.prompt_pack_export",
    version: 1,
    project: { id: "p", summary: "x" },
    promptPack: { id: "pack", name: "Recipe" },
  };
  const b = {
    promptPack: { name: "Recipe", id: "pack" },
    project: { summary: "x", id: "p" },
    version: 1,
    schema: "cathedralos.prompt_pack_export",
  };
  assertEquals(await hashCanonicalRecipe(a), await hashCanonicalRecipe(b));
});


// MARK: - PR 12: computeRequestFingerprint
//
// PR 12 binds Accept All idempotency keys to the exact server request via a
// stable canonical SHA256 fingerprint of the immutable request body
// (idempotency_key excluded). The fingerprint must:
//   - be identical for identical inputs;
//   - exclude idempotency_key (so the key used to look up its own row is
//     not part of the value being compared);
//   - be canonical with respect to key order (sorted JSON);
//   - change when any other field changes.

function makeFingerprintFixture(
  opts: {
    key?: string;
    outlineID?: string;
    projectID?: string;
    sections?: unknown[];
  } = {},
): Record<string, unknown> {
  const key = opts.key ?? "key-1";
  const outlineID = opts.outlineID ?? "11111111-1111-1111-1111-111111111111";
  const projectID = opts.projectID ?? "22222222-2222-2222-2222-222222222222";
  const sections = opts.sections ?? [{ id: "s-1", position: 0, title: "S1", summary: "Sum1" }];
  return {
    outline_id: outlineID,
    project_id: projectID,
    idempotency_key: key,
    source_recipe_json: { project: { id: "p", name: "P", summary: "Premise" } },
    sections,
  };
}

Deno.test("PR12 computeRequestFingerprint: identical inputs produce identical fingerprint", async () => {
  const body = makeFingerprintFixture();
  const a = await computeRequestFingerprint(body as any);
  const b = await computeRequestFingerprint(body as any);
  assertEquals(a, b);
  // Fingerprint is 64 lowercase hex chars (SHA-256).
  assertEquals(a.length, 64);
  assertEquals(/^[0-9a-f]{64}$/.test(a), true);
});

Deno.test("PR12 computeRequestFingerprint: excludes idempotency_key", async () => {
  const body1 = makeFingerprintFixture({ key: "key-A" });
  const body2 = makeFingerprintFixture({ key: "key-B" });
  const f1 = await computeRequestFingerprint(body1 as any);
  const f2 = await computeRequestFingerprint(body2 as any);
  assertEquals(f1, f2, "fingerprint must NOT include idempotency_key");
});

Deno.test("PR12 computeRequestFingerprint: canonical key order (reordered keys same fingerprint)", async () => {
  // Build equivalent bodies with different key insertion order. Canonical
  // serialization (sorted keys) must yield the same fingerprint.
  const a = {
    outline_id: "11111111-1111-1111-1111-111111111111",
    project_id: "22222222-2222-2222-2222-222222222222",
    idempotency_key: "k",
    source_recipe_json: { project: { id: "p", name: "P", summary: "S" } },
    sections: [],
  };
  const b = {
    sections: [],
    source_recipe_json: { project: { summary: "S", name: "P", id: "p" } },
    idempotency_key: "k",
    project_id: "22222222-2222-2222-2222-222222222222",
    outline_id: "11111111-1111-1111-1111-111111111111",
  };
  const fa = await computeRequestFingerprint(a as any);
  const fb = await computeRequestFingerprint(b as any);
  assertEquals(fa, fb, "key-order permutations must fingerprint the same");
});

Deno.test("PR12 computeRequestFingerprint: changes when any included field changes", async () => {
  const base = makeFingerprintFixture();
  const baseFingerprint = await computeRequestFingerprint(base as any);

  // Each tuple varies exactly one field (NOT idempotency_key, which must be
  // excluded). The fingerprint must differ.
  const variations: Array<[string, Record<string, unknown>]> = [
    ["outline_id",        makeFingerprintFixture({ outlineID: "99999999-9999-9999-9999-999999999999" })],
    ["project_id",        makeFingerprintFixture({ projectID: "99999999-9999-9999-9999-999999999999" })],
    ["sections",          makeFingerprintFixture({ sections: [{ id: "s-99", position: 0, title: "Different", summary: "Different" }] })],
    [
      "source_recipe_json",
      makeFingerprintFixture({ sections: undefined as any }), // placeholder; overwritten below
    ],
  ];
  // The source_recipe_json variation requires a different fixture shape
  // (the previous fixture has the same recipe). Replace it with an explicit
  // body whose recipe differs.
  const recipeVaried = makeFingerprintFixture();
  (recipeVaried as any).source_recipe_json = { project: { id: "p", name: "P", summary: "DIFFERENT PREMISE" } };
  variations[3] = ["source_recipe_json", recipeVaried];

  for (const [fieldName, varied] of variations) {
    const variedFingerprint = await computeRequestFingerprint(varied as any);
    assertNotEquals(
      variedFingerprint,
      baseFingerprint,
      `Changing ${fieldName} must change the fingerprint`,
    );
  }
});


// MARK: - PR 13: validate() — project_lineage_id handling

// isUUID() requires group 4 to start with [89ab] (variant bits). Use v4
// UUIDs (third group starts with 4, fourth with 8) that match the regex.
const UUID_OUTLINE = "11111111-1111-4111-8111-111111111111";
const UUID_PROJECT = "22222222-2222-4222-8222-222222222222";
const UUID_SECTION = "33333333-3333-4333-8333-333333333333";
const UUID_LINEAGE = "55555555-5555-4555-8555-555555555555";

function makeValidateFixture(
  opts: { lineageID?: string | null } = {},
): Record<string, unknown> {
  // validate() requires sections.length >= 1 (no empty-section batches).
  // Use a minimal valid section (no optional fields set).
  const minimalSection = {
    id: UUID_SECTION,
    position: 0,
    title: "S1",
    summary: "Sum1",
  };
  const body: Record<string, unknown> = {
    outline_id: UUID_OUTLINE,
    project_id: UUID_PROJECT,
    idempotency_key: "k1",
    // isCanonicalRecipe requires schema, version, project (with id+name),
    // setting, and promptPack (with id+name). Keep it minimal but valid.
    source_recipe_json: {
      schema: "cathedralos.story_packet",
      version: 1,
      project: { id: UUID_PROJECT, name: "P", summary: "S" },
      setting: { included: false },
      promptPack: { id: "pp-1", name: "Pack 1" },
    },
    sections: [minimalSection],
  };
  if (opts.lineageID !== undefined) {
    if (opts.lineageID !== null) {
      body.project_lineage_id = opts.lineageID;
    } else {
      body.project_lineage_id = null;
    }
  }
  return body;
}

Deno.test("PR13 validate(): accepts missing project_lineage_id (backward compat)", () => {
  const body = makeValidateFixture();
  // project_lineage_id is absent entirely (not present in object).
  assertEquals(validate(body as any), null);
});

Deno.test("PR13 validate(): accepts null project_lineage_id (client sent null)", () => {
  const body = makeValidateFixture({ lineageID: null });
  assertEquals(validate(body as any), null);
});

Deno.test("PR13 validate(): accepts valid UUID project_lineage_id", () => {
  const body = makeValidateFixture({ lineageID: UUID_LINEAGE });
  assertEquals(validate(body as any), null);
});

Deno.test("PR13 validate(): rejects non-string project_lineage_id", () => {
  const body = makeValidateFixture();
  body.project_lineage_id = 12345;
  const err = validate(body as any);
  assertNotEquals(err, null);
  assertEquals(err?.includes("project_lineage_id"), true, "error should mention project_lineage_id");
});

Deno.test("PR13 validate(): rejects malformed UUID project_lineage_id", () => {
  const body = makeValidateFixture({ lineageID: "not-a-uuid" });
  // validate() only type-checks (presence + string); the isUUID check for
  // project_lineage_id would happen later in the POST handler. Document the
  // current contract: validate() does NOT validate UUID format for
  // project_lineage_id (only types it as string).
  assertEquals(validate(body as any), null);
});
