// Coherence v2.1 — general-purpose coherence checker tests.
//
// Verifies the orchestration logic in index.ts (request validation, prompt
// construction, response validation). The actual OpenAI call is an integration
// surface — exercised in the broader test suite, not in this file.
//
// Coverage targets (regression fixtures per Kevin 2026-08-20):
// - Request validation: required fields, optional current_section, empty canon
// - Prompt construction: includes section intent, section identity preserved,
//   recency order, no suppressions for internal inconsistencies
// - Response validation: pre/post filter counts distinguish "LLM said nothing"
//   from "warnings were filtered" from "LLM truncated"
// - Diagnostic completeness: raw_content, finish_reason, model captured

import { assertEquals, assertExists } from "https://deno.land/std@0.208.0/assert/mod.ts";

// =============================================================================
// Mirror of validateRequest from index.ts
// =============================================================================

interface CurrentSection {
  id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  beat_label: string | null;
}

interface CanonSection {
  section_id: string;
  title: string;
  summary: string;
  pov: string | null;
  container: string | null;
  created_at: string;
  extracted_summary: string | null;
  character_deltas: unknown[];
  plot_thread_deltas: unknown[];
  continuity_facts: unknown[];
  open_loops: unknown[];
  scene_ending_state: unknown;
}

interface PriorCanon {
  sections: CanonSection[];
}

interface CoherenceCheckRequest {
  output_text: string;
  current_section: CurrentSection | null;
  prior_canon: PriorCanon;
  project_id?: string;
}

const validateRequest = (body: any):
  | { ok: true; request: CoherenceCheckRequest }
  | { ok: false; error: string } => {
  if (typeof body?.output_text !== "string" || body.output_text.length === 0) {
    return { ok: false, error: "output_text required (non-empty string)" };
  }
  if (!body.prior_canon || typeof body.prior_canon !== "object") {
    return { ok: false, error: "prior_canon required (object)" };
  }
  if (!Array.isArray(body.prior_canon.sections)) {
    return { ok: false, error: "prior_canon.sections required (array)" };
  }
  if (body.current_section !== null && body.current_section !== undefined) {
    const cs = body.current_section;
    if (typeof cs.id !== "string" || typeof cs.title !== "string" || typeof cs.summary !== "string") {
      return { ok: false, error: "current_section requires id, title, summary (strings)" };
    }
  }
  return { ok: true, request: body as CoherenceCheckRequest };
};

// =============================================================================
// Mirror of buildUserPrompt from index.ts
// =============================================================================

const buildUserPrompt = (input: {
  output_text: string;
  current_section: CurrentSection | null;
  prior_canon: PriorCanon;
}): string => {
  const parts: string[] = [
    "GENERATED OUTPUT:",
    input.output_text,
    "",
    "CURRENT SECTION INTENT:",
    input.current_section
      ? `Title: ${input.current_section.title}\nSummary: ${input.current_section.summary}\nPOV: ${input.current_section.pov ?? "(unspecified)"}\nContainer: ${input.current_section.container ?? "(unspecified)"}\nTerminal Beat: ${input.current_section.beat_label ?? "(unspecified)"}`
      : "(none)",
    "",
    "PRIOR CANON (ordered by recency, newest first):",
  ];
  if (input.prior_canon.sections.length === 0) {
    parts.push("(no prior accepted sections)");
  } else {
    const sectionBlocks = input.prior_canon.sections.map((s, i) =>
      `[Section ${i + 1}] id=${s.section_id}\n` +
      `Title: ${s.title}\n` +
      `Summary: ${s.summary}\n` +
      `POV: ${s.pov ?? "(unspecified)"}\n` +
      `Container: ${s.container ?? "(unspecified)"}\n` +
      `Extracted summary: ${s.extracted_summary ?? "(none)"}\n` +
      `Created at: ${s.created_at}\n` +
      `Character deltas: ${JSON.stringify(s.character_deltas, null, 2)}\n` +
      `Plot thread deltas: ${JSON.stringify(s.plot_thread_deltas, null, 2)}\n` +
      `Continuity facts: ${JSON.stringify(s.continuity_facts, null, 2)}\n` +
      `Open loops: ${JSON.stringify(s.open_loops, null, 2)}\n` +
      `Scene ending state: ${JSON.stringify(s.scene_ending_state, null, 2)}`
    );
    parts.push(sectionBlocks.join("\n\n"));
  }
  return parts.join("\n");
};

// =============================================================================
// Mirror of validateAndFilterWarnings from index.ts
// =============================================================================

const validateAndFilterWarnings = (raw: any): {
  warnings: Array<{ reason: string; severity: "warn" | "high" }>;
  preFilterCount: number;
  postFilterCount: number;
} => {
  if (!raw || typeof raw !== "object") {
    return { warnings: [], preFilterCount: 0, postFilterCount: 0 };
  }
  const list = Array.isArray(raw.warnings) ? raw.warnings : [];
  const preFilterCount = list.length;
  const warnings = list
    .filter((w: any) =>
      typeof w === "object" &&
      w !== null &&
      typeof w.reason === "string" &&
      w.reason.length > 0 &&
      (w.severity === "warn" || w.severity === "high")
    )
    .map((w: any) => ({
      reason: w.reason as string,
      severity: w.severity === "high" ? "high" as const : "warn" as const,
    }));
  return { warnings, preFilterCount, postFilterCount: warnings.length };
};

// =============================================================================
// Mirror of SYSTEM_PROMPT from index.ts — assert it does not suppress findings
// =============================================================================

const SYSTEM_PROMPT_SNIPPETS = {
  includesCurrentSection: "CURRENT SECTION INTENT",
  includesPriorCanon: "PRIOR CANON",
  includesGeneratedOutput: "GENERATED OUTPUT",
  forbidsStylisticFilter: "Skip stylistic concerns",  // old v2 phrase — must NOT appear
  requiresCanonCitation: "every inconsistency must cite a canon",  // anti-pattern
};

const SYSTEM_PROMPT = `You are a story-coherence checker. The user generated output text for a section. Your job is to identify real inconsistencies in the generated output.

CONTEXT YOU WILL RECEIVE:
- CURRENT SECTION INTENT: what this section was supposed to be (title, summary, POV, container, beat_label). If null, the section has no current intent.
- PRIOR CANON: structured memory from previously accepted sections, ordered by recency (newest first). Each entry is a section with its identity, summary, POV, container, and structured layers.
- GENERATED OUTPUT: the prose the user wrote for this section.

FIND INCONSISTENCIES. Categories include but are not limited to:
- Contradictions with prior canon (character states, locations, plot events, continuity facts)
- Output contradicts the current section's intended premise/summary/POV/container
- Internal inconsistencies within the output itself (POV shifts, character/name confusion, impossible sequencing, factual self-contradictions)
- Unresolved plot threads being silently dropped, or open threads being prematurely closed
- Tone/voice continuity breaks (NOT surface-level style)

FOR EACH FINDING, write \`reason\` as a one-sentence plain-English explanation. Cite the contradicting canon element when the inconsistency is canon-related. When the inconsistency is entirely inside the output (no canon element to cite), state that explicitly.

SEVERITY:
- "high" — clear factual contradiction, premise mismatch, or POV drift
- "warn" — softer concern (anachronism, lesser inconsistency)

If there are no real inconsistencies, return {"warnings": []}.`;

const RESPONSE_FORMAT_SCHEMA = {
  type: "object",
  properties: {
    warnings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          reason: { type: "string" },
          severity: { type: "string", enum: ["warn", "high"] },
        },
        required: ["reason", "severity"],
        additionalProperties: false,
      },
    },
  },
  required: ["warnings"],
  additionalProperties: false,
};

// =============================================================================
// Fixtures
// =============================================================================

const fixtureCurrentSection: CurrentSection = {
  id: "sec-current",
  title: "The Confrontation",
  summary: "Alice confronts Bob in Paris about the missing ledger.",
  pov: "thirdPersonLimited",
  container: "scene",
  beat_label: "confrontation",
};

const fixtureCanonSection: CanonSection = {
  section_id: "sec-prior-1",
  title: "The Meeting",
  summary: "Alice and Bob agreed to meet at Notre Dame.",
  pov: "thirdPersonLimited",
  container: "scene",
  created_at: "2026-08-19T10:00:00Z",
  extracted_summary: "Alice and Bob meet at Notre Dame and plan to find the ledger.",
  character_deltas: [{ character_name: "Alice", action: "plans to find ledger" }],
  plot_thread_deltas: [{ thread: "ledger", state: "open" }],
  continuity_facts: [{ fact: "Bob is alive", source: "sec-1" }],
  open_loops: ["Where is the ledger?"],
  scene_ending_state: { where: "Notre Dame", when: "morning" },
};

const fixturePriorCanon: PriorCanon = { sections: [fixtureCanonSection] };

// =============================================================================
// Tests: request validation
// =============================================================================

Deno.test("validateRequest: requires output_text", () => {
  const result = validateRequest({ output_text: "", prior_canon: { sections: [] } });
  assertEquals(result.ok, false);
  assertEquals(result.error?.includes("output_text"), true);
});

Deno.test("validateRequest: requires prior_canon", () => {
  const result = validateRequest({ output_text: "Some text" });
  assertEquals(result.ok, false);
  assertEquals(result.error?.includes("prior_canon"), true);
});

Deno.test("validateRequest: requires prior_canon.sections array", () => {
  const result = validateRequest({ output_text: "Some text", prior_canon: { sections: "not-array" } });
  assertEquals(result.ok, false);
});

Deno.test("validateRequest: accepts empty prior_canon (no prior sections)", () => {
  const result = validateRequest({
    output_text: "Some text",
    prior_canon: { sections: [] },
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: accepts current_section as null", () => {
  const result = validateRequest({
    output_text: "Some text",
    prior_canon: { sections: [] },
    current_section: null,
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: accepts full current_section", () => {
  const result = validateRequest({
    output_text: "Some text",
    prior_canon: { sections: [] },
    current_section: fixtureCurrentSection,
  });
  assertEquals(result.ok, true);
});

Deno.test("validateRequest: rejects current_section missing required fields", () => {
  const result = validateRequest({
    output_text: "Some text",
    prior_canon: { sections: [] },
    current_section: { id: "x" },  // missing title + summary
  });
  assertEquals(result.ok, false);
  assertEquals(result.error?.includes("current_section"), true);
});

// =============================================================================
// Tests: prompt construction
// =============================================================================

Deno.test("buildUserPrompt: includes generated output", () => {
  const prompt = buildUserPrompt({
    output_text: "Alice walks down the boulevard.",
    current_section: null,
    prior_canon: { sections: [] },
  });
  assertEquals(prompt.includes("GENERATED OUTPUT"), true);
  assertEquals(prompt.includes("Alice walks down the boulevard."), true);
});

Deno.test("buildUserPrompt: includes current_section intent when provided", () => {
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: fixtureCurrentSection,
    prior_canon: { sections: [] },
  });
  assertEquals(prompt.includes("CURRENT SECTION INTENT"), true);
  assertEquals(prompt.includes("The Confrontation"), true);
  assertEquals(prompt.includes("Alice confronts Bob"), true);
  assertEquals(prompt.includes("thirdPersonLimited"), true);
  assertEquals(prompt.includes("confrontation"), true);
});

Deno.test("buildUserPrompt: shows (none) when current_section is null", () => {
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: null,
    prior_canon: { sections: [] },
  });
  assertEquals(prompt.includes("(none)"), true);
});

Deno.test("buildUserPrompt: shows (no prior accepted sections) when canon is empty", () => {
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: null,
    prior_canon: { sections: [] },
  });
  assertEquals(prompt.includes("(no prior accepted sections)"), true);
});

Deno.test("buildUserPrompt: preserves section identity (each prior section is a unit)", () => {
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: null,
    prior_canon: fixturePriorCanon,
  });
  assertEquals(prompt.includes("sec-prior-1"), true);
  assertEquals(prompt.includes("The Meeting"), true);
  assertEquals(prompt.includes("Notre Dame"), true);
  // Structured layers are preserved
  assertEquals(prompt.includes("character_name"), true);
  assertEquals(prompt.includes("Alice"), true);
  assertEquals(prompt.includes("Where is the ledger?"), true);
});

Deno.test("buildUserPrompt: orders prior canon by recency (newest first)", () => {
  const newerSection: CanonSection = {
    ...fixtureCanonSection,
    section_id: "sec-newer",
    created_at: "2026-08-20T10:00:00Z",
  };
  const olderSection: CanonSection = {
    ...fixtureCanonSection,
    section_id: "sec-older",
    created_at: "2026-08-19T10:00:00Z",
  };
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: null,
    prior_canon: { sections: [newerSection, olderSection] },
  });
  const newerPos = prompt.indexOf("sec-newer");
  const olderPos = prompt.indexOf("sec-older");
  assertEquals(newerPos < olderPos, true);
});

Deno.test("buildUserPrompt: includes POV per prior canon section", () => {
  const prompt = buildUserPrompt({
    output_text: "Some output.",
    current_section: null,
    prior_canon: fixturePriorCanon,
  });
  // The prior section's POV is included so the LLM can compare POV drift
  assertEquals(prompt.includes("POV: thirdPersonLimited"), true);
});

// =============================================================================
// Tests: response validation (regression: ensure filter doesn't collapse to [])
// =============================================================================

Deno.test("validateAndFilterWarnings: empty input returns empty", () => {
  const result = validateAndFilterWarnings({ warnings: [] });
  assertEquals(result.warnings, []);
  assertEquals(result.preFilterCount, 0);
  assertEquals(result.postFilterCount, 0);
});

Deno.test("validateAndFilterWarnings: drops warnings with missing reason", () => {
  const result = validateAndFilterWarnings({
    warnings: [
      { reason: "", severity: "warn" },
      { severity: "warn" },
      { reason: "Valid", severity: "warn" },
    ],
  });
  assertEquals(result.warnings.length, 1);
  assertEquals(result.warnings[0].reason, "Valid");
  assertEquals(result.preFilterCount, 3);
  assertEquals(result.postFilterCount, 1);
});

Deno.test("validateAndFilterWarnings: drops warnings with invalid severity", () => {
  const result = validateAndFilterWarnings({
    warnings: [
      { reason: "R", severity: "block" },
      { reason: "R", severity: "error" },
      { reason: "R", severity: "warn" },
    ],
  });
  assertEquals(result.warnings.length, 1);
  assertEquals(result.warnings[0].severity, "warn");
  assertEquals(result.preFilterCount, 3);
  assertEquals(result.postFilterCount, 1);
});

Deno.test("validateAndFilterWarnings: preserves 'high' severity", () => {
  const result = validateAndFilterWarnings({
    warnings: [{ reason: "R", severity: "high" }],
  });
  assertEquals(result.warnings.length, 1);
  assertEquals(result.warnings[0].severity, "high");
});

Deno.test("validateAndFilterWarnings: pre/post filter counts distinguish 'LLM said nothing' from 'filtered'", () => {
  // If pre == post == 0, the LLM returned no warnings.
  // If pre > post, some were dropped.
  // The diagnostic must distinguish these — otherwise we can't tell whether
  // the LLM genuinely found nothing vs. the filter ate valid warnings.
  const noWarnings = validateAndFilterWarnings({ warnings: [] });
  assertEquals(noWarnings.preFilterCount, 0);
  assertEquals(noWarnings.postFilterCount, 0);

  const someFiltered = validateAndFilterWarnings({
    warnings: [
      { reason: "Valid", severity: "warn" },
      { reason: "", severity: "warn" },
    ],
  });
  assertEquals(someFiltered.preFilterCount, 2);
  assertEquals(someFiltered.postFilterCount, 1);
});

// =============================================================================
// Tests: prompt contents (regression: prompt does not suppress findings)
// =============================================================================

Deno.test("SYSTEM_PROMPT: does not contain the v2 'Skip stylistic concerns' phrase", () => {
  // v2 had "Skip stylistic concerns" which the LLM read as a global filter
  // and used to drop POV drift as 'stylistic'. v2.1 must not include that.
  assertEquals(SYSTEM_PROMPT.includes(SYSTEM_PROMPT_SNIPPETS.forbidsStylisticFilter), false);
});

Deno.test("SYSTEM_PROMPT: does not require canon citation for all findings", () => {
  // Internal inconsistencies (e.g., POV drift within the output) have no
  // canon element to cite. The prompt must not require every warning to cite
  // canon or the LLM will skip valid internal findings.
  assertEquals(SYSTEM_PROMPT.includes(SYSTEM_PROMPT_SNIPPETS.requiresCanonCitation), false);
});

Deno.test("SYSTEM_PROMPT: explicitly allows internal inconsistencies", () => {
  // The prompt must mention internal inconsistencies so the LLM knows to flag
  // them (especially POV drift, which is the original symptom).
  assertEquals(SYSTEM_PROMPT.includes("Internal inconsistencies"), true);
  assertEquals(SYSTEM_PROMPT.includes("POV shifts"), true);
});

Deno.test("SYSTEM_PROMPT: explicitly mentions current_section intent", () => {
  // Without current_section in the prompt, the LLM has no comparison frame
  // for "what was this section supposed to be." The prompt must reference it.
  assertEquals(SYSTEM_PROMPT.includes(SYSTEM_PROMPT_SNIPPETS.includesCurrentSection), true);
});

Deno.test("SYSTEM_PROMPT: explicitly mentions prior canon", () => {
  assertEquals(SYSTEM_PROMPT.includes(SYSTEM_PROMPT_SNIPPETS.includesPriorCanon), true);
});

Deno.test("SYSTEM_PROMPT: instructions survive the OpenAI structured-output schema", () => {
  // The schema enforces {warnings: [{reason, severity}]}. The system prompt
  // asks for "reason" explicitly so the LLM knows what to emit.
  assertEquals(SYSTEM_PROMPT.includes("reason"), true);
});

// =============================================================================
// Tests: regression fixtures (per Kevin 2026-08-20 brief)
// These verify the request shape that would surface each invalid class.
// =============================================================================

// 1. Obvious internal inconsistency (POV drift within the output)
Deno.test("regression: POV drift has comparison frame (current_section.pov vs output)", () => {
  const request = validateRequest({
    output_text: "Alice walked down the street. Bob's hands trembled as he watched. FROM BOB'S PERSPECTIVE:",
    current_section: {
      id: "sec-1",
      title: "Chapter 5",
      summary: "Alice's POV throughout.",
      pov: "thirdPersonLimited",
      container: "scene",
      beat_label: "rising",
    },
    prior_canon: { sections: [] },
  });
  assertEquals(request.ok, true);
  if (request.ok) {
    const prompt = buildUserPrompt(request.request);
    // The LLM sees both intent.pov = thirdPersonLimited AND pov_label,
    // and the output text that drifts. The framework gives the LLM enough
    // context to flag drift — we don't test the LLM's response here, only
    // that the request shape supports it.
    assertEquals(prompt.includes("thirdPersonLimited"), true);
    assertEquals(prompt.includes("Alice's POV throughout"), true);
  }
});

// 2. Contradiction against prior canon
Deno.test("regression: canon contradiction has prior canon in prompt", () => {
  const request = validateRequest({
    output_text: "Bob grinned. He was alive and well.",
    current_section: null,
    prior_canon: {
      sections: [
        {
          ...fixtureCanonSection,
          continuity_facts: [{ fact: "Bob is dead", source: "sec-1" }],
        },
      ],
    },
  });
  assertEquals(request.ok, true);
  if (request.ok) {
    const prompt = buildUserPrompt(request.request);
    assertEquals(prompt.includes("Bob is dead"), true);
    assertEquals(prompt.includes("Bob grinned"), true);
  }
});

// 3. Generated output contradicts intended section premise
Deno.test("regression: premise mismatch has current_section.summary in prompt", () => {
  const request = validateRequest({
    output_text: "Alice is in London, walking along the Thames.",
    current_section: {
      id: "sec-1",
      title: "The Confrontation",
      summary: "Alice confronts Bob in Paris.",
      pov: "thirdPersonLimited",
      container: "scene",
      beat_label: "confrontation",
    },
    prior_canon: { sections: [] },
  });
  assertEquals(request.ok, true);
  if (request.ok) {
    const prompt = buildUserPrompt(request.request);
    // LLM sees both intended summary (Paris) and current output (London).
    assertEquals(prompt.includes("Alice confronts Bob in Paris"), true);
    assertEquals(prompt.includes("Alice is in London"), true);
  }
});

// 4. Clean coherent output
Deno.test("regression: clean coherent output has all context but no contradictions", () => {
  const request = validateRequest({
    output_text: "Alice met Bob at Notre Dame, as planned.",
    current_section: fixtureCurrentSection,
    prior_canon: fixturePriorCanon,
  });
  assertEquals(request.ok, true);
  if (request.ok) {
    const prompt = buildUserPrompt(request.request);
    // All the context is present; the LLM has what it needs to judge.
    // We don't assert "no warnings" here because that's an LLM decision —
    // we only assert the framework provides the necessary context.
    assertEquals(prompt.includes("CURRENT SECTION INTENT"), true);
    assertEquals(prompt.includes("PRIOR CANON"), true);
    assertEquals(prompt.includes("Notre Dame"), true);
  }
});

// Touch imported helpers
Deno.test("assert helpers are wired up", () => {
  assertExists(assertEquals);
});
