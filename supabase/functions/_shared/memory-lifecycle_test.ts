import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { reconcileSceneMemory } from "./memory-lifecycle.ts";

Deno.test("memory lifecycle keeps thread and loop IDs and supersedes facts", () => {
  const first = reconcileSceneMemory([], {
    character_deltas: [{ character_name: "Mara", location: "station" }],
    plot_thread_deltas: [{ thread_name: "The signal", status: "introduced", description: "Mara hears a signal." }],
    continuity_facts: ["The station loses power at midnight."],
    open_loops: [{ type: "mystery", description: "Who is transmitting the signal?" }],
  }, "s1", "2026-01-01T00:00:00Z");
  const threadId = first.plot_thread_deltas[0].id;
  const loopId = first.open_loops[0].id;
  const factId = first.continuity_facts[0].id;

  const second = reconcileSceneMemory([first], {
    character_deltas: [{ character_name: "Mara", knowledge_delta: "The signal repeats." }],
    plot_thread_deltas: [{ thread_name: "The signal", status: "advanced", description: "Mara traces the signal." }],
    continuity_facts: ["The station loses power at midnight."],
    open_loops: [{ type: "mystery", description: "Who is transmitting the signal?" }],
  }, "s2", "2026-01-02T00:00:00Z");
  assertEquals(second.plot_thread_deltas[0].id, threadId);
  assertEquals(second.open_loops[0].id, loopId);
  assertEquals(second.continuity_facts[0].id, factId);
  assertEquals(second.character_deltas[0].location, "station");
  assertEquals(second.character_deltas[0].knowledge_delta, "The signal repeats.");

  const third = reconcileSceneMemory([first, second], {
    character_deltas: [],
    plot_thread_deltas: [{ thread_name: "The signal", status: "resolved", description: "Mara identifies the transmitter." }],
    continuity_facts: [{ fact: "The station remains powered through midnight.", supersedes_id: factId }],
    open_loops: [{ type: "mystery", description: "Who is transmitting the signal?", status: "resolved" }],
  }, "s3", "2026-01-03T00:00:00Z");
  assertEquals(third.plot_thread_deltas[0].id, threadId);
  assertEquals(third.plot_thread_deltas[0].status, "resolved");
  assertEquals(third.open_loops[0].id, loopId);
  assertEquals(third.open_loops[0].status, "resolved");
  assertEquals(third.continuity_facts[0].active, false);
  assertEquals(third.continuity_facts[1].active, true);
  assertEquals(third.continuity_facts[1].superseded_by, null);
});
