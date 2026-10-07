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
    "consistent pronoun set",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:<normalized-name>:identity:<attribute>",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:sava:identity:pronouns",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:<normalized-name>:identity:physical:<attribute>",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:anika-reedrunner:identity:physical:hair",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "the final segment identifies the physical attribute, not its value",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:anika:identity:dark-hair-with-blue-cloth-binding",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "do not encode descriptive prose directly into the reference",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "The attribute portion identifies the category, not its value",
  );
  assertStringIncludes(
    SCENE_MEMORY_GENERATION_INSTRUCTIONS,
    "character:sava:identity:pronouns-he/him",
  );
  for (
    const mutableAttribute of [
      "location",
      "possessions",
      "inventory",
      "tools or equipment",
      "clothing",
      "temporary injuries",
      "goals",
      "knowledge",
      "emotions",
      "current status",
      "temporary resources",
      "current occupation or assignment",
    ]
  ) {
    assertStringIncludes(
      SCENE_MEMORY_GENERATION_INSTRUCTIONS,
      mutableAttribute,
    );
  }
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
