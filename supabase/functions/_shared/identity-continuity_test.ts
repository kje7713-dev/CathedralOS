import {
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { SCENE_MEMORY_GENERATION_INSTRUCTIONS } from "./scene-memory.ts";
import { SYSTEM_PROMPT } from "../coherence-check/_prompts.ts";

Deno.test("scene memory treats stable character identity as durable continuity", () => {
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "stable character identity attributes",
  );
  assertStringIncludes(SCENE_MEMORY_GENERATION_INSTRUCTIONS, "pronouns");
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:<normalized-name>:identity:<attribute>",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "incidental conflicting pronoun or wording alone is not a supersession",
  );
});

Deno.test("coherence checker treats unexplained stable identity drift as high severity", () => {
  assertStringIncludes(SYSTEM_PROMPT, "Stable character identity drift");
  assertStringIncludes(SYSTEM_PROMPT, "pronouns");
  assertStringIncludes(
    SYSTEM_PROMPT,
    "stable identity/pronoun contradiction",
  );
});
