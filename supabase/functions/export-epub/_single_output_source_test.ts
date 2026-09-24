import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  buildStandaloneOutputOutline,
  makeStandaloneOutputOutline,
  StandaloneOutputSourceError,
} from "./_single_output_source.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const PROJECT = "PR623-STORY";
const OUTPUT = "22222222-2222-4222-8222-222222222222";

function mockedClient(
  ...responses: Array<{ data: unknown; error: unknown }>
): SupabaseClient {
  let index = 0;
  const chain: Record<string, (...args: unknown[]) => unknown> = {};
  chain.select = () => chain;
  chain.eq = () => chain;
  chain.maybeSingle = async () =>
    responses[index++] ?? { data: null, error: null };
  return {
    from: () => chain,
  } as unknown as SupabaseClient;
}

function outputRow(overrides: Record<string, unknown> = {}) {
  return {
    id: OUTPUT,
    user_id: USER,
    project_local_id: PROJECT,
    title: "Generated Title",
    output_text: "First paragraph.\n\nSecond paragraph.",
    source_payload_json: {},
    status: "complete",
    ...overrides,
  };
}

async function expectCode(
  client: SupabaseClient,
  id: string = OUTPUT,
  projectID: string = PROJECT,
) {
  const error = await assertRejects(
    () =>
      buildStandaloneOutputOutline(
        client,
        USER,
        projectID,
        "snapshot",
        id,
        "Book Title",
      ),
    StandaloneOutputSourceError,
  );
  return (error as StandaloneOutputSourceError).code;
}

Deno.test("validation rejects invalid UUID", async () => {
  assertEquals(
    await expectCode(mockedClient(), "not-a-uuid"),
    "invalid_generation_output_id",
  );
});

Deno.test("validation rejects missing and cross-user sources without leaking existence", async () => {
  assertEquals(
    await expectCode(mockedClient({ data: null, error: null })),
    "generation_output_not_found",
  );
  assertEquals(
    await expectCode(
      mockedClient({
        data: outputRow({ user_id: "33333333-3333-4333-8333-333333333333" }),
        error: null,
      }),
    ),
    "generation_output_not_found",
  );
});

Deno.test("validation rejects cross-project and missing-project sources", async () => {
  assertEquals(
    await expectCode(
      mockedClient({
        data: outputRow({ project_local_id: "OTHER-PROJECT" }),
        error: null,
      }),
    ),
    "generation_output_project_mismatch",
  );
  assertEquals(
    await expectCode(
      mockedClient({
        data: outputRow({ project_local_id: null }),
        error: null,
      }),
    ),
    "generation_output_project_mismatch",
  );
});

Deno.test("validation rejects empty, failed, and generating sources", async () => {
  assertEquals(
    await expectCode(
      mockedClient({ data: outputRow({ output_text: "   " }), error: null }),
    ),
    "generation_output_empty",
  );
  assertEquals(
    await expectCode(
      mockedClient({ data: outputRow({ status: "failed" }), error: null }),
    ),
    "generation_output_not_exportable",
  );
  assertEquals(
    await expectCode(
      mockedClient({ data: outputRow({ status: "generating" }), error: null }),
    ),
    "generation_output_not_exportable",
  );
});

for (const status of ["complete", "draft"]) {
  Deno.test(`validation accepts ${status} prose and builds exact standalone outline`, async () => {
    const prose = "First paragraph.\n\nSecond paragraph.";
    const outline = await buildStandaloneOutputOutline(
      mockedClient(
        { data: outputRow({ status, output_text: prose }), error: null },
        {
          data: { snapshot_json: { project: { summary: "A premise." } } },
          error: null,
        },
      ),
      USER,
      PROJECT,
      "snapshot",
      OUTPUT,
      "Selected Book Title",
    );
    const section = outline.chapters[0].sections[0];
    assertEquals(outline.chapters.length, 1);
    assertEquals(outline.parts.length, 0);
    assertEquals(section.body, prose);
    assertEquals(outline.title, "Selected Book Title");
    assertEquals(section.parent_id, null);
    assertEquals(section.story_arc_beat_id, null);
    assertEquals(section.story_arc_role, null);
  });
}

Deno.test("outline builder itself remains a pure one-unit adapter", () => {
  const outline = makeStandaloneOutputOutline(
    { id: OUTPUT, title: "Generated Title", output_text: "Prose" },
    { project: { summary: "A concise premise." }, outlines: [], storyArcs: [] },
    "The Actual Book Title",
  );
  assertEquals(outline.chapters.length, 1);
  assertEquals(outline.chapters[0].sections.length, 1);
  assertEquals(outline.parts, []);
  assertEquals(outline.storyBrief?.projectSummary, "A concise premise.");
  assert(!("outlines" in outline));
});
