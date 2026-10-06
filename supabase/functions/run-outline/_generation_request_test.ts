import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildFutureOutlineContext,
  buildGenerateStoryRequest,
} from "./_generation_request.ts";

Deno.test("future outline context: is ordered, bounded to eight, and excludes the current section", () => {
  const sections = Array.from({ length: 11 }, (_, index) => ({
    id: `s${index}`,
    position: index,
    title: `Section ${index}`,
    dramatic_event: `Event ${index}`,
    resulting_change: `Change ${index}`,
    terminal_state: `State ${index}`,
  }));
  const context = buildFutureOutlineContext(sections[1], sections);
  assertEquals((context.match(/^- Section /gm) ?? []).length, 8);
  assertEquals(context.includes("- Section 1"), false);
  assertStringIncludes(context, "- Section 2");
  assertStringIncludes(context, "- Section 9");
  assertEquals(context.includes("- Section 10"), false);
});

Deno.test("generation request: Run All future context is forwarded to generate-story", () => {
  const request = buildGenerateStoryRequest({
    snapshot: {
      project: { name: "Test" },
      promptPacks: [{ id: "pack-1", name: "Pack", prompts: [] }],
    },
    futureOutlineContext: "## Future Outline Obligations\n- Later",
    section: {
      id: "section-1",
      title: "Current",
      summary: "Current summary",
      container: "scene",
      pov: "thirdPersonLimited",
      terminal_beat: null,
    },
    projectId: "project-1",
    lengthMode: "short",
  });
  assertEquals(
    request.futureOutlineContext,
    "## Future Outline Obligations\n- Later",
  );
});
