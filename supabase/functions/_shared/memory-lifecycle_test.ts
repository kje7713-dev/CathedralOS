import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  normalizeSceneMemory,
  SCENE_MEMORY_RESPONSE_FORMAT,
} from "./scene-memory.ts";
import {
  loadPriorMemoryRows,
  reconcileSceneMemory,
} from "./memory-lifecycle.ts";
import { formatCanonicalProjectState } from "./memory-state.ts";

Deno.test("production extractor contract normalizes lifecycle operations", () => {
  const extracted = normalizeSceneMemory({
    extracted_summary: "Mara traces the signal.",
    character_deltas: [],
    plot_thread_deltas: [{
      thread_name: "signal",
      status: "introduced",
      description: "A signal exists.",
    }],
    continuity_facts: [{
      operation: "establish",
      fact: "The station loses power at midnight.",
      prior_fact_reference: null,
    }],
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "open",
      description: "Who transmits it?",
    }],
    scene_ending_state: {
      character_positions: [],
      immediate_pressure: "The signal repeats.",
    },
  });
  const result = reconcileSceneMemory(
    [],
    extracted as unknown as Record<string, unknown>,
    "s1",
  );
  assertEquals(result.plot_thread_deltas[0].status, "introduced");
  assertEquals(result.open_loops[0].status, "open");
  assertEquals(result.continuity_facts[0].operation, "establish");
  assertEquals(
    (SCENE_MEMORY_RESPONSE_FORMAT as any).json_schema.schema.properties
      .open_loops.items.properties.status.enum,
    ["open", "resolved"],
  );
});

Deno.test("thread, loop, and fact lifecycle retains IDs through resolve and supersede", () => {
  const first = reconcileSceneMemory([], {
    plot_thread_deltas: [{
      thread_name: "signal",
      status: "introduced",
      description: "A signal exists.",
    }],
    continuity_facts: [{
      operation: "establish",
      reference: "station-power",
      fact: "The station loses power at midnight.",
    }],
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "open",
      description: "Who transmits it?",
    }],
  }, "s1");
  const second = reconcileSceneMemory([first], {
    plot_thread_deltas: [{
      thread_name: "signal",
      status: "advanced",
      description: "Mara traces it.",
    }],
    continuity_facts: [{
      operation: "preserve",
      reference: "station-power",
      fact: "The station loses power at midnight.",
    }],
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "open",
      description: "Who transmits it?",
    }],
  }, "s2");
  const third = reconcileSceneMemory([first, second], {
    plot_thread_deltas: [{
      thread_name: "signal",
      status: "resolved",
      description: "Mara identifies the transmitter.",
    }],
    continuity_facts: [{
      operation: "supersede",
      reference: "station-power-v2",
      fact: "The station remains powered through midnight.",
      prior_fact_reference: "station-power",
    }],
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "resolved",
      description: "Who transmits it?",
    }],
  }, "s3");
  assertEquals(second.plot_thread_deltas[0].id, first.plot_thread_deltas[0].id);
  assertEquals(third.plot_thread_deltas[0].id, first.plot_thread_deltas[0].id);
  assertEquals(third.open_loops[0].id, first.open_loops[0].id);
  assertEquals(third.continuity_facts[0].active, false);
  assertEquals(third.continuity_facts[1].active, true);
});

Deno.test("character deltas remain per-scene while canonical context merges fields", () => {
  const one = reconcileSceneMemory([], {
    character_deltas: [{ character_name: "Mara", location: "station" }],
  }, "s1");
  const two = reconcileSceneMemory([one], {
    character_deltas: [{
      character_name: "Mara",
      knowledge_delta: "The signal repeats.",
    }],
  }, "s2");
  assertEquals(two.character_deltas, [{
    character_name: "Mara",
    knowledge_delta: "The signal repeats.",
  }]);
  const state = formatCanonicalProjectState([{
    character_deltas: one.character_deltas,
  }, { character_deltas: two.character_deltas }]);
  assertStringIncludes(state, "station");
  assertStringIncludes(state, "The signal repeats.");
});

function mockAdmin(
  rows: any[],
  sections: any[],
  current: any,
  fail = false,
): any {
  return {
    from(table: string) {
      const state: any = { table, filters: {} };
      const builder: any = {
        select() {
          return builder;
        },
        eq(k: string, v: any) {
          state.filters[k] = v;
          return builder;
        },
        lt(k: string, v: any) {
          state.filters[k] = v;
          return builder;
        },
        in(k: string, v: any[]) {
          state.filters[k] = v;
          return builder;
        },
        maybeSingle() {
          return Promise.resolve({
            data: current,
            error: fail ? { message: "db down" } : null,
          });
        },
        then(resolve: any, reject: any) {
          let data = table === "section_embeddings" ? rows : sections;
          if (table === "outline_sections" && state.filters.outline_id) {
            data = sections.filter((row: any) =>
              row.outline_id === state.filters.outline_id &&
              row.position < state.filters.position
            );
          }
          if (
            table === "section_embeddings" &&
            Array.isArray(state.filters.outline_section_id)
          ) {
            data = rows.filter((row: any) =>
              state.filters.outline_section_id.includes(row.outline_section_id)
            );
          }
          return Promise.resolve({
            data,
            error: fail ? { message: "db down" } : null,
          }).then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

Deno.test("prior loader excludes future sections and other outlines", async () => {
  const rows = [
    {
      outline_section_id: "prior",
      character_deltas: [{ character_name: "Mara", location: "old" }],
    },
    {
      outline_section_id: "future",
      character_deltas: [{ character_name: "Mara", location: "future" }],
    },
    {
      outline_section_id: "other",
      character_deltas: [{ character_name: "Mara", location: "other" }],
    },
  ];
  const sections = [
    { id: "prior", outline_id: "o1", position: 1 },
    { id: "current", outline_id: "o1", position: 2 },
    { id: "future", outline_id: "o1", position: 3 },
    { id: "other", outline_id: "o2", position: 1 },
  ];
  const result = await loadPriorMemoryRows(
    mockAdmin(rows, sections, sections[1]),
    "project",
    "current",
  );
  assertEquals(result.map((row: any) => row.character_deltas[0].location), [
    "old",
  ]);
  await assertRejects(() =>
    loadPriorMemoryRows(
      mockAdmin(rows, sections, sections[1], true),
      "project",
      "current",
    )
  );
});

Deno.test("reworded loop resolution uses the repeated semantic reference", () => {
  const first = reconcileSceneMemory([], {
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "open",
      description: "Who transmits it?",
    }],
  }, "s1");
  const second = reconcileSceneMemory([first], {
    open_loops: [{
      type: "mystery",
      reference: "signal-source",
      status: "resolved",
      description: "Mara identifies the transmitter in the tower.",
    }],
  }, "s2");
  assertEquals(second.open_loops[0].id, first.open_loops[0].id);
  assertEquals(second.open_loops[0].status, "resolved");
});

Deno.test("missing or ambiguous semantic references fail closed", () => {
  const first = reconcileSceneMemory([], {
    continuity_facts: [{
      operation: "establish",
      reference: "fact-a",
      fact: "The door is locked.",
    }],
  }, "s1");
  assertThrows(() =>
    reconcileSceneMemory([first], {
      continuity_facts: [{
        operation: "supersede",
        reference: "fact-b",
        fact: "The door is open.",
        prior_fact_reference: "database-id",
      }],
    }, "s2")
  );
  assertThrows(() =>
    reconcileSceneMemory([first, {
      ...first,
      continuity_facts: [{ ...first.continuity_facts[0], id: "another" }],
    }], {
      continuity_facts: [{
        operation: "supersede",
        reference: "fact-b",
        fact: "The door is open.",
        prior_fact_reference: "fact-a",
      }],
    }, "s3")
  );
});

Deno.test("legacy random IDs do not override semantic matching", () => {
  const result = reconcileSceneMemory([{
    plot_thread_deltas: [{
      id: "random-uuid",
      thread_name: "signal",
      status: "introduced",
      description: "old",
    }],
  }], {
    plot_thread_deltas: [{
      reference: "thread:signal",
      thread_name: "signal",
      status: "resolved",
      description: "reworded",
    }],
  }, "s2");
  assertEquals(result.plot_thread_deltas[0].id, "random-uuid");
  assertEquals(result.plot_thread_deltas[0].status, "resolved");
});
