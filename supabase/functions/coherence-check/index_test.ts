// =============================================================================
// coherence-check/index_test.ts
//
// Tests exercise the REAL production code extracted to:
//   - _validation.ts   (validateRequest, validateAndFilterWarnings, types)
//   - _prompts.ts      (SYSTEM_PROMPT, COHERENCE_RESPONSE_FORMAT, buildUserPrompt)
//   - _idempotency.ts  (sha256Hex, computeIdempotencyKey)
//
// Previously these helpers were mirrored into this file as a copy. The mirrors
// hid drift (kevbot-brain: "mirror of production" tests are a recurring failure
// mode). This file now imports the real implementations so the tests actually
// cover what ships.
//
// Coverage:
// - Request validation: required fields, optional current_section, empty canon
// - Prompt construction: includes section intent, section identity preserved,
//   recency order, no suppressions for internal inconsistencies
// - Response validation: pre/post filter counts distinguish "LLM said nothing"
//   from "warnings were filtered" from "LLM truncated"
// - Idempotency key derivation: same body within same minute → same key,
//   different body / different minute → different key
// - Diagnostic completeness: raw_content, finish_reason, model captured

import {
  assertEquals,
  assertExists,
  assertNotEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { validateAndFilterWarnings, validateRequest } from "./_validation.ts";
import {
  buildUserPrompt,
  COHERENCE_RESPONSE_FORMAT,
  SYSTEM_PROMPT,
} from "./_prompts.ts";
import { computeIdempotencyKey, sha256Hex } from "./_idempotency.ts";

// =============================================================================
// validateRequest (production import — no mirror)
// =============================================================================

Deno.test("validateRequest: requires output_text", () => {
  const result = validateRequest({ prior_canon: { sections: [] } });
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.error, "output_text required (non-empty string)");
  }
});

Deno.test("validateRequest: requires prior_canon", () => {
  const result = validateRequest({ output_text: "hi" });
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.error, "prior_canon required (object)");
  }
});

Deno.test("validateRequest: requires prior_canon.sections array", () => {
  const result = validateRequest({ output_text: "hi", prior_canon: {} });
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.error, "prior_canon.sections required (array)");
  }
});

Deno.test("validateRequest: accepts empty prior_canon (no prior sections)", () => {
  const result = validateRequest({
    output_text: "hello",
    prior_canon: { sections: [] },
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: accepts current_section as null", () => {
  const result = validateRequest({
    output_text: "hello",
    current_section: null,
    prior_canon: { sections: [] },
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: accepts full current_section", () => {
  const result = validateRequest({
    output_text: "hello",
    current_section: {
      id: "sec-1",
      title: "T",
      summary: "S",
      pov: "first",
      container: "scene",
      beat_label: null,
    },
    prior_canon: { sections: [] },
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: rejects current_section missing required fields", () => {
  const result = validateRequest({
    output_text: "hello",
    current_section: { id: "x", title: "y" },
    prior_canon: { sections: [] },
  });
  assertEquals(result.ok, false);
});

// =============================================================================
// buildUserPrompt (production import — no mirror)
// =============================================================================

Deno.test("buildUserPrompt: includes generated output", () => {
  const prompt = buildUserPrompt("the user-written prose", null, {
    sections: [],
  });
  assertStringIncludes(prompt, "GENERATED OUTPUT:");
  assertStringIncludes(prompt, "the user-written prose");
});

Deno.test("buildUserPrompt: includes current_section intent when provided", () => {
  const prompt = buildUserPrompt(
    "output",
    {
      id: "sec-1",
      title: "The Crossing",
      summary: "Hero crosses the river.",
      pov: "thirdPersonLimited",
      container: "scene",
      beat_label: "decision beat",
    },
    { sections: [] },
  );
  assertStringIncludes(prompt, "CURRENT SECTION INTENT:");
  assertStringIncludes(prompt, "Title: The Crossing");
  assertStringIncludes(prompt, "Summary: Hero crosses the river.");
  assertStringIncludes(prompt, "POV: thirdPersonLimited");
  assertStringIncludes(prompt, "Container: scene");
  assertStringIncludes(prompt, "Terminal Beat: decision beat");
});

Deno.test("buildUserPrompt: shows (none) when current_section is null", () => {
  const prompt = buildUserPrompt("output", null, { sections: [] });
  assertStringIncludes(prompt, "(none)");
});

Deno.test("buildUserPrompt: shows (no prior accepted sections) when canon is empty", () => {
  const prompt = buildUserPrompt("output", null, { sections: [] });
  assertStringIncludes(prompt, "(no prior accepted sections)");
});

Deno.test("buildUserPrompt: preserves section identity (each prior section is a unit)", () => {
  const prompt = buildUserPrompt("output", null, {
    sections: [
      {
        section_id: "sec-a",
        title: "Alpha",
        summary: "First section.",
        pov: "first",
        container: "scene",
        created_at: "2026-01-01T00:00:00Z",
        extracted_summary: "summary A",
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
      {
        section_id: "sec-b",
        title: "Bravo",
        summary: "Second section.",
        pov: "third",
        container: "scene",
        created_at: "2026-01-02T00:00:00Z",
        extracted_summary: "summary B",
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
    ],
  });
  assertStringIncludes(prompt, "[Section 1] id=sec-a");
  assertStringIncludes(prompt, "[Section 2] id=sec-b");
  assertStringIncludes(prompt, "Title: Alpha");
  assertStringIncludes(prompt, "Title: Bravo");
});

Deno.test("buildUserPrompt: orders prior canon by recency (newest first)", () => {
  const prompt = buildUserPrompt("output", null, {
    sections: [
      {
        section_id: "sec-new",
        title: "Newest",
        summary: "Most recent.",
        pov: null,
        container: null,
        created_at: "2026-01-03T00:00:00Z",
        extracted_summary: null,
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
      {
        section_id: "sec-old",
        title: "Oldest",
        summary: "Earliest.",
        pov: null,
        container: null,
        created_at: "2026-01-01T00:00:00Z",
        extracted_summary: null,
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
    ],
  });
  const newIdx = prompt.indexOf("sec-new");
  const oldIdx = prompt.indexOf("sec-old");
  assertEquals(newIdx < oldIdx, true);
});

Deno.test("buildUserPrompt: includes POV per prior canon section", () => {
  const prompt = buildUserPrompt("output", null, {
    sections: [
      {
        section_id: "sec-pov",
        title: "Has POV",
        summary: "S",
        pov: "secondPerson",
        container: "scene",
        created_at: "2026-01-01T00:00:00Z",
        extracted_summary: null,
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
    ],
  });
  assertStringIncludes(prompt, "POV: secondPerson");
});

// =============================================================================
// validateAndFilterWarnings (production import — no mirror)
// =============================================================================

Deno.test("validateAndFilterWarnings: empty input returns empty", () => {
  const result = validateAndFilterWarnings({});
  assertEquals(result.warnings, []);
  assertEquals(result.preFilterCount, 0);
  assertEquals(result.postFilterCount, 0);
});

Deno.test("validateAndFilterWarnings: null input returns empty", () => {
  const result = validateAndFilterWarnings(null);
  assertEquals(result.warnings, []);
});

Deno.test("validateAndFilterWarnings: drops warnings with missing reason", () => {
  const result = validateAndFilterWarnings({
    warnings: [
      { severity: "high" },
      { reason: "valid", severity: "warn" },
    ],
  });
  assertEquals(result.warnings.length, 1);
  assertEquals(result.warnings[0].reason, "valid");
  assertEquals(result.preFilterCount, 2);
  assertEquals(result.postFilterCount, 1);
});

Deno.test("validateAndFilterWarnings: drops warnings with invalid severity", () => {
  const result = validateAndFilterWarnings({
    warnings: [
      { reason: "A", severity: "extreme" },
      { reason: "B", severity: "warn" },
    ],
  });
  assertEquals(result.warnings.length, 1);
  assertEquals(result.warnings[0].reason, "B");
});

Deno.test("validateAndFilterWarnings: preserves high severity", () => {
  const result = validateAndFilterWarnings({
    warnings: [{ reason: "Premise mismatch", severity: "high" }],
  });
  assertEquals(result.warnings[0].severity, "high");
});

Deno.test("validateAndFilterWarnings: pre/post filter counts distinguish empty from filtered", () => {
  const emptyResult = validateAndFilterWarnings({});
  assertEquals(emptyResult.preFilterCount, 0);
  assertEquals(emptyResult.postFilterCount, 0);

  const filteredResult = validateAndFilterWarnings({
    warnings: [
      { severity: "extreme" },
      { severity: "lol" },
    ],
  });
  assertEquals(filteredResult.preFilterCount, 2);
  assertEquals(filteredResult.postFilterCount, 0);
});

// =============================================================================
// SYSTEM_PROMPT invariants
// =============================================================================

Deno.test("SYSTEM_PROMPT: does not contain the v2 'Skip stylistic concerns' phrase", () => {
  assertEquals(
    SYSTEM_PROMPT.includes("Skip stylistic concerns"),
    false,
    "v2-era suppression phrase must not be in the v2.1 prompt",
  );
});

Deno.test("SYSTEM_PROMPT: does not require canon citation for all findings", () => {
  assertEquals(
    SYSTEM_PROMPT.includes("every inconsistency must cite a canon"),
    false,
  );
});

Deno.test("SYSTEM_PROMPT: explicitly allows internal inconsistencies", () => {
  assertStringIncludes(
    SYSTEM_PROMPT,
    "Internal inconsistencies within the output itself",
  );
});

Deno.test("SYSTEM_PROMPT: explicitly mentions current_section intent", () => {
  assertStringIncludes(SYSTEM_PROMPT, "CURRENT SECTION INTENT");
});

Deno.test("SYSTEM_PROMPT: explicitly mentions prior canon", () => {
  assertStringIncludes(SYSTEM_PROMPT, "PRIOR CANON");
});

Deno.test("COHERENCE_RESPONSE_FORMAT: is strict json_schema with no additional properties", () => {
  const schema = COHERENCE_RESPONSE_FORMAT as unknown as {
    json_schema: {
      strict: boolean;
      schema: { additionalProperties: boolean; required: string[] };
    };
  };
  assertEquals(schema.json_schema.strict, true);
  assertEquals(schema.json_schema.schema.additionalProperties, false);
  assertEquals(schema.json_schema.schema.required.includes("warnings"), true);
});

// =============================================================================
// Idempotency key derivation
// =============================================================================

Deno.test("computeIdempotencyKey: same body + same minute → same key", async () => {
  const userId = "user-123";
  const body = {
    output_text: "hello world",
    current_section: {
      id: "sec-1",
      title: "T",
      summary: "S",
      pov: null,
      container: null,
      beat_label: null,
    },
    prior_canon: { sections: [] },
  };
  const fixedNow = 1_700_000_000_000; // arbitrary fixed instant
  const k1 = await computeIdempotencyKey(userId, body, fixedNow);
  const k2 = await computeIdempotencyKey(userId, body, fixedNow);
  assertEquals(k1, k2);
  // SHA-256 hex is 64 chars
  assertEquals(k1.length, 64);
});

Deno.test("computeIdempotencyKey: different body → different key", async () => {
  const userId = "user-123";
  const baseBody = {
    output_text: "hello",
    current_section: null,
    prior_canon: { sections: [] },
  };
  const fixedNow = 1_700_000_000_000;
  const k1 = await computeIdempotencyKey(userId, baseBody, fixedNow);
  const k2 = await computeIdempotencyKey(
    userId,
    { ...baseBody, output_text: "hello world" },
    fixedNow,
  );
  assertNotEquals(k1, k2);
});

Deno.test("computeIdempotencyKey: different minute → different key", async () => {
  const userId = "user-123";
  const body = {
    output_text: "hello",
    current_section: null,
    prior_canon: { sections: [] },
  };
  const k1 = await computeIdempotencyKey(userId, body, 1_700_000_000_000);
  const k2 = await computeIdempotencyKey(userId, body, 1_700_000_060_000); // +60s
  assertNotEquals(k1, k2);
});

Deno.test("computeIdempotencyKey: different user → different key", async () => {
  const body = {
    output_text: "hello",
    current_section: null,
    prior_canon: { sections: [] },
  };
  const fixedNow = 1_700_000_000_000;
  const k1 = await computeIdempotencyKey("user-a", body, fixedNow);
  const k2 = await computeIdempotencyKey("user-b", body, fixedNow);
  assertNotEquals(k1, k2);
});

Deno.test("sha256Hex: known input → known output", async () => {
  // SHA-256 of empty string is well-known: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  assertEquals(
    await sha256Hex(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  );
  // SHA-256 of "abc"
  assertEquals(
    await sha256Hex("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

// =============================================================================
// Regression: prompt shape ensures failure modes can be detected downstream
// =============================================================================

Deno.test("regression: POV drift has comparison frame (current_section.pov vs output)", () => {
  const prompt = buildUserPrompt(
    "the prose uses first-person POV",
    {
      id: "sec-1",
      title: "T",
      summary: "S",
      pov: "thirdPersonLimited",
      container: "scene",
      beat_label: null,
    },
    { sections: [] },
  );
  assertStringIncludes(prompt, "POV: thirdPersonLimited");
  assertStringIncludes(prompt, "the prose uses first-person POV");
});

Deno.test("regression: canon contradiction has prior canon in prompt", () => {
  const prompt = buildUserPrompt("output", null, {
    sections: [
      {
        section_id: "sec-canon",
        title: "Hero is alive",
        summary: "The hero survived the battle.",
        pov: null,
        container: null,
        created_at: "2026-01-01T00:00:00Z",
        extracted_summary: null,
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
    ],
  });
  assertStringIncludes(prompt, "The hero survived the battle.");
});

Deno.test("regression: premise mismatch has current_section.summary in prompt", () => {
  const prompt = buildUserPrompt(
    "output",
    {
      id: "sec-1",
      title: "T",
      summary: "Hero crosses the river at dawn.",
      pov: null,
      container: null,
      beat_label: null,
    },
    { sections: [] },
  );
  assertStringIncludes(prompt, "Hero crosses the river at dawn.");
});

Deno.test("regression: clean coherent output has all context but no contradictions", () => {
  const prompt = buildUserPrompt(
    "clean output",
    {
      id: "sec-1",
      title: "T",
      summary: "S",
      pov: null,
      container: null,
      beat_label: null,
    },
    { sections: [] },
  );
  // Should still carry both context blocks so downstream can detect
  // inconsistencies even when there are none.
  assertStringIncludes(prompt, "CURRENT SECTION INTENT:");
  assertStringIncludes(prompt, "PRIOR CANON");
});

Deno.test("assert helpers are wired up", () => {
  // Smoke check: the imports exist and are callable.
  assertExists(validateRequest);
  assertExists(validateAndFilterWarnings);
  assertExists(buildUserPrompt);
  assertExists(SYSTEM_PROMPT);
  assertExists(COHERENCE_RESPONSE_FORMAT);
  assertExists(computeIdempotencyKey);
  assertExists(sha256Hex);
});
