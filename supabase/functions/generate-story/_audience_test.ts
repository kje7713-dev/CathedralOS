import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { isIntimacyCompatible, resolveAudienceFields, validateAudienceCompatibility } from "./_audience.ts";
import { buildPrompt } from "./index.ts";

Deno.test("audience compatibility matrix rejects incompatible intimacy before provider work", () => {
  assertEquals(isIntimacyCompatible("all_ages", "explicit"), false);
  assertEquals(isIntimacyCompatible("13_plus", "open_door"), false);
  assertEquals(isIntimacyCompatible("16_plus", "fade_to_black"), true);
  assertEquals(isIntimacyCompatible("16_plus", "open_door"), false);
  assertEquals(isIntimacyCompatible("18_plus", "explicit"), true);
  assertStringIncludes(validateAudienceCompatibility("all_ages", "explicit") ?? "", "incompatible");
});

Deno.test("legacy generation request falls back to frozen source project audience", () => {
  const resolved = resolveAudienceFields({
    sourcePayloadJSON: { project: { readingLevel: "adult", contentRating: "18_plus", intimacyRating: "open_door", audienceNotes: "FROZEN_AUDIENCE" } },
  });
  assertEquals(resolved, { readingLevel: "adult", contentRating: "18_plus", intimacyRating: "open_door", audienceNotes: "FROZEN_AUDIENCE" });
});

Deno.test("intimacy prompt guidance is conditional and Section Contract remains authoritative", () => {
  const romantic = buildPrompt({ sourcePayloadJSON: {}, generationAction: "generate", generationLengthMode: "short", container: "scene", pov: "thirdPersonLimited", outputBudget: 500, projectName: "Test", promptPackName: "Pack", contentRating: "13_plus", intimacyRating: "romantic", sectionDramaticEvent: "They kiss." });
  assertStringIncludes(romantic.context, "Intimacy level: romantic");
  assertStringIncludes(romantic.craft, "do not write sexual activity");
  const explicit = buildPrompt({ sourcePayloadJSON: {}, generationAction: "generate", generationLengthMode: "short", container: "scene", pov: "thirdPersonLimited", outputBudget: 500, projectName: "Test", promptPackName: "Pack", contentRating: "18_plus", intimacyRating: "explicit", sectionDramaticEvent: "They sign the contract." });
  assertStringIncludes(explicit.craft, "do not sanitize");
  assertEquals(explicit.craft.includes("Favor implication, subtext, and reader imagination."), false);
  assertStringIncludes(explicit.context, "Intimacy level: explicit");
});
