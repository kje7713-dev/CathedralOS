import { assertEquals } from "jsr:@std/assert@1";
import { acceptRunTerminalOutcome } from "./_outcome.ts";

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

Deno.test("Accept All uses the shared service without nested embed-section HTTP", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  assertEquals(source.includes("processSectionMemory"), true);
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
