import {
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { SCENE_MEMORY_GENERATION_INSTRUCTIONS } from "./scene-memory.ts";

Deno.test("scene memory keeps audited facts focused on human continuity", () => {
  for (
    const phrase of [
      "object:<normalized-object>:custody",
      "quantity:<normalized-subject>:<unit>",
      "assignment:<normalized-subject>",
      "event:<normalized-event>:irreversible",
      "critical to human continuity",
      "one audited fact per durable change",
      "preserve the prior_fact_reference",
    ]
  ) {
    assertStringIncludes(SCENE_MEMORY_GENERATION_INSTRUCTIONS, phrase);
  }
});
