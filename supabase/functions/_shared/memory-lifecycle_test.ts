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

Deno.test("missing semantic history normalizes, while ambiguity fails closed", () => {
  const first = reconcileSceneMemory([], {
    continuity_facts: [{
      operation: "establish",
      reference: "fact-a",
      fact: "The door is locked.",
    }],
  }, "s1");
  const recovered = reconcileSceneMemory([first], {
    continuity_facts: [{
      operation: "supersede",
      reference: "fact-b",
      fact: "The door is open.",
      prior_fact_reference: "database-id",
    }],
  }, "s2");
  assertEquals(recovered.continuity_facts.length, 1);
  assertEquals(recovered.continuity_facts[0].operation, "establish");
  assertEquals(recovered.continuity_facts[0].active, true);

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
  assertThrows(() =>
    reconcileSceneMemory([{
      plot_thread_deltas: [{
        id: "thread-a",
        reference: "thread:signal",
        thread_name: "signal",
        status: "introduced",
      }],
    }, {
      plot_thread_deltas: [{
        id: "thread-b",
        reference: "thread:signal",
        thread_name: "signal",
        status: "introduced",
      }],
    }], {
      plot_thread_deltas: [{
        reference: "thread:signal",
        thread_name: "signal",
        status: "advanced",
      }],
    }, "s4")
  );
});

Deno.test("first lifecycle hints establish safe canonical identities", () => {
  const result = reconcileSceneMemory([], {
    plot_thread_deltas: [{
      reference: "thread:new-thread",
      thread_name: "new thread",
      status: "advanced",
    }, {
      reference: "thread:resolved-thread",
      thread_name: "resolved thread",
      status: "resolved",
    }],
    open_loops: [{
      reference: "loop-mystery:missing-history",
      type: "mystery",
      description: "What happened before the scene?",
      status: "resolved",
    }],
  }, "s1");
  assertEquals(result.plot_thread_deltas.map((item) => item.status), [
    "introduced",
    "introduced",
  ]);
  assertEquals(result.open_loops[0].status, "open");
  assertEquals(typeof result.plot_thread_deltas[0].id, "string");
  assertEquals(typeof result.open_loops[0].id, "string");
});

Deno.test("canonical project state defaults to 50k and prioritizes stable identity facts", () => {
  const state = formatCanonicalProjectState([{
    continuity_facts: [{
      reference: "character:Sava:identity:pronouns",
      fact: "Sava uses he/him pronouns.",
      active: true,
    }, {
      reference: "ordinary-fact",
      fact: "The lantern remains lit.",
      active: true,
    }],
    character_deltas: [{
      character_name: "Mara",
      state: "x".repeat(60_000),
    }],
  }]);

  assertEquals(state.length, 50_000);
  assertEquals(
    state.indexOf("## Stable Identity Facts") <
      state.indexOf("## Cumulative Story State"),
    true,
  );
  assertEquals(
    state.indexOf(
      "character:Sava:identity:pronouns: Sava uses he/him pronouns.",
    ) <
      state.indexOf("Characters:"),
    true,
  );
});

Deno.test("stable identity facts survive a smaller project-state cap", () => {
  const state = formatCanonicalProjectState(
    [{
      continuity_facts: [{
        reference: "character:Sava:identity:pronouns",
        fact: "Sava uses he/him pronouns.",
        active: true,
      }],
      character_deltas: [{
        character_name: "Mara",
        state: "x".repeat(10_000),
      }],
    }],
    undefined,
    1_000,
  );

  assertStringIncludes(
    state,
    "character:Sava:identity:pronouns: Sava uses he/him pronouns.",
  );
});

Deno.test("canonical project state keeps active ordinary facts and omits inactive facts", () => {
  const state = formatCanonicalProjectState([{
    continuity_facts: [{
      reference: "ordinary-active",
      fact: "The lantern remains lit.",
      active: true,
    }, {
      reference: "ordinary-inactive",
      fact: "The door is locked.",
      active: false,
    }, {
      reference: "ordinary-superseded",
      fact: "The road is open.",
      superseded_by: "ordinary-active",
    }],
  }]);

  assertStringIncludes(state, "ordinary-active: The lantern remains lit.");
  assertEquals(state.includes("ordinary-inactive"), false);
  assertEquals(state.includes("ordinary-superseded"), false);
});

Deno.test("character identity facts canonicalize model-supplied entity references", () => {
  const prior = {
    continuity_facts: [{
      id: "name-fact",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:name:Dr. Sela Aro",
      active: true,
    }, {
      id: "pronoun-fact",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:pronouns:she/her",
      active: true,
    }, {
      id: "role-fact",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:role:doctor",
      active: true,
    }],
  };

  const result = reconcileSceneMemory([prior], {
    continuity_facts: [{
      operation: "preserve",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:pronouns:she/her",
      prior_fact_reference: null,
    }],
  }, "s24");

  assertEquals(result.continuity_facts.length, 1);
  assertEquals(result.continuity_facts[0].id, "pronoun-fact");
  assertEquals(
    result.continuity_facts[0].reference,
    "character:dr-sela-aro:identity:pronouns",
  );
  assertEquals(result.continuity_facts[0].operation, "preserve");
});

Deno.test("legacy character-name supersede reference resolves by identity attribute", () => {
  const prior = {
    continuity_facts: [{
      id: "pronoun-fact",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:pronouns:she/her",
      active: true,
    }, {
      id: "role-fact",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:role:doctor",
      active: true,
    }],
  };

  const result = reconcileSceneMemory([prior], {
    continuity_facts: [{
      operation: "supersede",
      reference: "Dr. Sela Aro",
      fact: "character:Dr. Sela Aro:identity:pronouns:they/them",
      prior_fact_reference: "Dr. Sela Aro",
    }],
  }, "s25");

  assertEquals(result.continuity_facts.length, 2);
  assertEquals(result.continuity_facts[0].id, "pronoun-fact");
  assertEquals(result.continuity_facts[0].active, false);
  assertEquals(
    result.continuity_facts[0].superseded_by,
    "character:dr-sela-aro:identity:pronouns",
  );
  assertEquals(result.continuity_facts[1].id, "pronoun-fact");
  assertEquals(result.continuity_facts[1].active, true);
  assertEquals(
    result.continuity_facts[1].reference,
    "character:dr-sela-aro:identity:pronouns",
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
