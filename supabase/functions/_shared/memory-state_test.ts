import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { formatCanonicalProjectState } from "./memory-state.ts";

Deno.test("scene-specific project state keeps relevant hard facts and drops unrelated history", () => {
  const previous = {
    extracted_summary:
      "Marek left the relief office with the sealed refugee papers.",
    character_deltas: [{ character_name: "Marek", location: "relief office" }],
    scene_ending_state: {
      character_positions: [{ character: "Marek", location: "relief office" }],
    },
  };
  const state = formatCanonicalProjectState(
    [
      {
        character_deltas: [
          {
            character_name: "Marek",
            location: "relief office",
            knowledge_delta:
              "He carries the sealed refugee papers toward the river checkpoint.",
            possessions: "sealed refugee papers",
          },
          {
            character_name: "Ilyana",
            location: "hospital ward",
            knowledge_delta: "The fever ward is overcrowded.",
          },
        ],
        plot_thread_deltas: [
          {
            reference: "river-passage-authority",
            thread_name: "River passage authority",
            status: "advanced",
            description:
              "Marek must use the checkpoint papers to cross the river wardens.",
          },
          {
            reference: "hospital-overload",
            thread_name: "Hospital overload",
            status: "active",
            description: "Ilyana struggles to keep the fever ward supplied.",
          },
        ],
        continuity_facts: [
          {
            reference: "object:refugee-papers:custody",
            fact: "Marek holds the sealed refugee papers.",
            active: true,
          },
          {
            reference: "character:marek:identity:pronouns",
            fact: "Marek uses he/him pronouns.",
            active: true,
          },
          {
            reference: "character:ilyana:identity:pronouns",
            fact: "Ilyana uses she/her pronouns.",
            active: true,
          },
        ],
        open_loops: [
          {
            reference: "river-warden-infiltration",
            type: "threat",
            status: "open",
            description:
              "False refugee names may conceal spies at the river checkpoint.",
          },
          {
            reference: "fever-ward-supplies",
            type: "problem",
            status: "open",
            description: "The hospital lacks clean water.",
          },
        ],
      },
    ],
    previous,
    45_000,
    {
      query:
        "Marek follows refugee papers through river wardens' checkpoints and discovers spies moving under humanitarian cover.",
    },
  );

  assertStringIncludes(state, "Marek");
  assertStringIncludes(state, "refugee-papers:custody");
  assertStringIncludes(state, "river-passage-authority");
  assertStringIncludes(state, "river-warden-infiltration");
  assert(!state.includes("hospital-overload"));
  assert(!state.includes("fever-ward-supplies"));
  assert(!state.includes("Ilyana uses she/her"));
  assert(state.length < 45_000);
});

Deno.test("scene-specific project state keeps the previous section regardless of relevance filter", () => {
  const state = formatCanonicalProjectState(
    [],
    {
      extracted_summary: "Marek sealed the archive ledger.",
      scene_ending_state: {
        immediate_pressure: "The ledger is being pursued.",
      },
    },
    45_000,
    { query: "river checkpoint" },
  );
  assertStringIncludes(state, "Marek sealed the archive ledger.");
  assertStringIncludes(state, "The ledger is being pursued.");
  assertEquals(state.includes("Cumulative Story State"), true);
});
