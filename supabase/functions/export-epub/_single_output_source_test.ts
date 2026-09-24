import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { makeStandaloneOutputOutline } from "./_single_output_source.ts";

Deno.test("standalone source builds one flat reading unit without persisted outline data", () => {
  const outline = makeStandaloneOutputOutline(
    {
      id: "11111111-1111-4111-8111-111111111111",
      title: "Quick Story — Draft",
      output_text: "First paragraph.\n\nSecond paragraph.",
    },
    { project: { summary: "A concise premise." }, outlines: [], storyArcs: [] },
    "The Actual Book Title",
  );

  assertEquals(outline.title, "The Actual Book Title");
  assertEquals(outline.parts, []);
  assertEquals(outline.chapters.length, 1);
  assertEquals(outline.chapters[0].sections.length, 1);
  assertEquals(
    outline.chapters[0].sections[0].body,
    "First paragraph.\n\nSecond paragraph.",
  );
  assertEquals(outline.chapters[0].sections[0].parent_id, null);
  assertEquals(outline.chapters[0].sections[0].story_arc_beat_id, null);
  assertEquals(outline.storyBrief?.projectSummary, "A concise premise.");
  assert(!("outlines" in outline));
});

Deno.test("standalone source falls back to generated title only when book title is empty", () => {
  const outline = makeStandaloneOutputOutline(
    {
      id: "22222222-2222-4222-8222-222222222222",
      title: "Generated Title",
      output_text: "Prose",
    },
    {},
    "   ",
  );
  assertEquals(outline.title, "Generated Title");
  assertEquals(outline.chapters[0].title, "Generated Title");
});
