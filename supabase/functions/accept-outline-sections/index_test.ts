import { assertEquals } from "jsr:@std/assert@1";
import { acceptRunTerminalOutcome } from "./_outcome.ts";
import {
  canonicalUUID,
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

Deno.test("Accept All indexes summaries without scene-memory extraction or billing", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  assertEquals(source.includes("processSectionMemory"), true);
  assertEquals(source.includes("extractMemory: false"), true);
  assertEquals(source.includes("SupabaseCreditStore"), false);
  assertEquals(source.includes('action: "accept-outline-sections"'), false);
  assertEquals(source.includes("functions/v1/embed-section"), false);
  assertEquals(source.includes("embedSectionWithRetry"), false);
});

Deno.test("Accept All memory stage cannot rewrite outline section ownership", async () => {
  const source = await Deno.readTextFile(
    new URL("../_shared/section-embedding.ts", import.meta.url),
  );
  const start = source.indexOf("export async function processSectionMemory");
  const end = source.indexOf("export async function processEmbedSection");
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
    in: (_column: string, _ids: string[]) => Promise.resolve({
      data: rows.map((id) => ({ id })),
      error: null,
    }),
  };
  return { from: (_table: string) => query } as any;
}

function validRequest(sectionCount: number, storyArcBeatID: string | null = null): any {
  return {
    outline_id: "11111111-1111-4111-8111-111111111111",
    project_id: "project-1",
    idempotency_key: "key-1",
    sections: Array.from({ length: sectionCount }, (_, index) => ({
      id: `${String(index + 1).padStart(8, "0")}-1111-4111-8111-111111111111`,
      position: index,
      title: `Section ${index + 1}`,
      summary: "A valid section summary",
      storyArcBeatID,
    })),
  };
}

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
    await normalizeStoryArcBeatIDs(beatLookup([BEAT_A]), [{ storyArcBeatID: BEAT_B }] as any);
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message, `Story arc beat linkage is unavailable: ${BEAT_B}`);
});

Deno.test("Accept All rejects malformed non-null story arc beat IDs", () => {
  assertEquals(validate(validRequest(1, "not-a-uuid")), "invalid story arc beat ID");
});

Deno.test("Accept All validation allows 1 through 200 sections and rejects 201", () => {
  for (const count of [1, 100, 101, 200]) {
    assertEquals(validate(validRequest(count)), null);
  }
  assertEquals(validate(validRequest(201)), "sections must contain 1-200 items");
});

Deno.test("arc linkage is persisted for single and bulk section acceptance", async () => {
  const source = await Deno.readTextFile("./supabase/functions/accept-outline-sections/index.ts");
  assertEquals(source.includes("story_arc_beat_id: section.storyArcBeatID ?? null"), true);
  assertEquals(source.includes("storyArcBeatID: row.story_arc_beat_id"), true);
  const row = sectionRow({ id: "section-1", position: 0, title: "One", summary: "Event", storyArcBeatID: "beat-1" }, "outline-1", 4);
  assertEquals(row.story_arc_beat_id, "beat-1");
  const service = await Deno.readTextFile("./CathedralOSApp/Services/SectionEmbedService.swift");
  const restore = await Deno.readTextFile("./CathedralOSApp/Services/ProjectCloudSyncService.swift");
  assertEquals(service.includes("storyArcBeatID: suggestion.storyArcBeatID"), true);
  assertEquals(restore.includes("section.storyArcBeatID = storyArcBeatID"), true);
});

Deno.test("Accept All canonicalizes section identity for embeddings and snapshot merge", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  assertEquals(source.includes("canonicalUUID(String(row.outline_section_id))"), true);
  assertEquals(source.includes("!completedIDs.has(canonicalUUID(section.id))"), true);
  assertEquals(source.includes("canonicalUUID(String(section.id))"), true);
  assertEquals(source.includes("canonicalUUID(String(row.story_arc_beat_id))"), true);
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
  assertEquals(merged, [{ id: "cca975fc-e13a-4ade-8344-2470a8c2b3a0", title: "new" }]);
});
