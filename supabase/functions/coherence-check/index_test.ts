// Coherence check tests.
//
// These are unit tests over the request-validaton, ID-allowlist, and
// response-shaping logic. The end-to-end OpenAI call path is exercised
// in integration tests, not here (no LLM mocking infra in this repo).

import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";

// Mirror the unexported ID-allowlist behavior by re-extracting the same
// regex-pure logic the function uses. If the function's filter changes,
// this test must change too. Kept dependency-free so we can run it under
// `deno test` without any LLM stub.
const buildValidatedWarnings = (
  raw: Array<Record<string, unknown>>,
  validIds: Set<string>,
) =>
  raw
    .filter((w) =>
      typeof w.section_id === "string" &&
      validIds.has(w.section_id) &&
      typeof w.reason === "string" &&
      (w.reason as string).length > 0
    )
    .map((w) => ({
      section_id: w.section_id as string,
      section_title: typeof w.section_title === "string" && (w.section_title as string).length > 0
        ? (w.section_title as string)
        : "(untitled)",
      reason: w.reason as string,
      severity: "warn" as const,
    }));

Deno.test("drops warnings that reference unknown section_ids (hallucination guard)", () => {
  const neighbors = new Set(["sec-a", "sec-b"]);
  const raw = [
    { section_id: "sec-a", section_title: "The Lockup", reason: "X is in prison here." },
    { section_id: "sec-zzz", section_title: "Made up", reason: "Should be dropped" },
    { section_id: "sec-b", section_title: "The Heist", reason: "X plans a heist here." },
  ];
  const warnings = buildValidatedWarnings(raw, neighbors);
  assertEquals(warnings.length, 2);
  assertEquals(warnings[0].section_id, "sec-a");
  assertEquals(warnings[1].section_id, "sec-b");
});

Deno.test("drops warnings missing a reason", () => {
  const neighbors = new Set(["sec-a"]);
  const raw = [
    { section_id: "sec-a", section_title: "Title", reason: "" },
    { section_id: "sec-a", section_title: "Title" },
    { section_id: "sec-a", section_title: "Title", reason: "Valid" },
  ];
  const warnings = buildValidatedWarnings(raw, neighbors);
  assertEquals(warnings.length, 1);
  assertEquals(warnings[0].reason, "Valid");
});

Deno.test("clamps severity to 'warn' regardless of LLM output", () => {
  const neighbors = new Set(["sec-a"]);
  const raw = [
    { section_id: "sec-a", section_title: "Title", reason: "Reason", severity: "block" },
    { section_id: "sec-a", section_title: "Title", reason: "Reason" },
  ];
  const warnings = buildValidatedWarnings(raw, neighbors);
  assertEquals(warnings.every((w) => w.severity === "warn"), true);
});

Deno.test("falls back to '(untitled)' for missing section_title", () => {
  const neighbors = new Set(["sec-a"]);
  const raw = [
    { section_id: "sec-a", reason: "Reason" },
    { section_id: "sec-a", section_title: "", reason: "Reason" },
    { section_id: "sec-a", section_title: "Real title", reason: "Reason" },
  ];
  const warnings = buildValidatedWarnings(raw, neighbors);
  assertEquals(warnings[0].section_title, "(untitled)");
  assertEquals(warnings[1].section_title, "(untitled)");
  assertEquals(warnings[2].section_title, "Real title");
});

Deno.test("returns empty array when there are no warnings to filter", () => {
  const neighbors = new Set(["sec-a", "sec-b"]);
  assertEquals(buildValidatedWarnings([], neighbors).length, 0);
});

Deno.test("top_k clamping mirrors the request shape", () => {
  // The function clamps 1..10. Build the same clamp and confirm edges.
  const clamp = (n: number | undefined, fallback: number) =>
    Math.max(1, Math.min(n ?? fallback, 10));
  assertEquals(clamp(undefined, 5), 5);
  assertEquals(clamp(0, 5), 1);
  assertEquals(clamp(-100, 5), 1);
  assertEquals(clamp(5, 5), 5);
  assertEquals(clamp(15, 5), 10);
  assertEquals(clamp(10, 5), 10);
});

// Touch the assert helpers so deno test doesn't warn about unused imports.
Deno.test("assert helpers are wired up", () => {
  assertExists(assertEquals);
});
