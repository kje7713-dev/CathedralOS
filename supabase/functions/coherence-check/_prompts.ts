// =============================================================================
// coherence-check/_prompts.ts
//
// System prompt, Structured Outputs schema, and user-prompt builder for the
// coherence-check edge function. Pulled out of index.ts so index_test.ts can
// import the real implementation (kevbot-brain: mirror tests hide regressions).
// =============================================================================

import type {
  CoherenceCheckRequest,
  CurrentSection,
  PriorCanon,
} from "./_validation.ts";

// OpenAI Structured Outputs schema — strict, no additional properties.
// The shared billable LLM runner passes this through to the provider when
// responseFormat is set on the request.
export const COHERENCE_RESPONSE_FORMAT = {
  type: "json_schema",
  json_schema: {
    name: "coherence_warnings",
    strict: true,
    schema: {
      type: "object",
      properties: {
        warnings: {
          type: "array",
          items: {
            type: "object",
            properties: {
              reason: { type: "string" },
              severity: {
                type: "string",
                enum: ["warn", "high"],
              },
            },
            required: ["reason", "severity"],
            additionalProperties: false,
          },
        },
      },
      required: ["warnings"],
      additionalProperties: false,
    },
  },
} as const;

export const SYSTEM_PROMPT =
  `You are a story-coherence checker. The user generated output text for a section. Your job is to identify real inconsistencies in the generated output.

CONTEXT YOU WILL RECEIVE:
- CURRENT SECTION INTENT: what this section was supposed to be (title, summary, POV, container, beat_label). If null, the section has no current intent.
- PRIOR CANON: structured memory from previously accepted sections, ordered by recency (newest first). Each entry is a section with its identity, summary, POV, container, and structured layers.
- GENERATED OUTPUT: the prose the user wrote for this section.

FIND INCONSISTENCIES. Categories include but are not limited to:
- Contradictions with prior canon (character states, locations, plot events, continuity facts)
- Output contradicts the current section\'s intended premise/summary/POV/container
- Internal inconsistencies within the output itself (POV shifts, character/name confusion, impossible sequencing, factual self-contradictions)
- Unresolved plot threads being silently dropped, or open threads being prematurely closed
- Tone/voice continuity breaks (NOT surface-level style)

FOR EACH FINDING, write \`reason\` as a one-sentence plain-English explanation. Cite the contradicting canon element when the inconsistency is canon-related. When the inconsistency is entirely inside the output (no canon element to cite), state that explicitly.

SEVERITY:
- "high" — clear factual contradiction, premise mismatch, or POV drift
- "warn" — softer concern (anachronism, lesser inconsistency)

If there are no real inconsistencies, return {"warnings": []}.`;

export function buildUserPrompt(
  output_text: string,
  current_section: CurrentSection | null,
  prior_canon: PriorCanon,
): string {
  const parts: string[] = [
    "GENERATED OUTPUT:",
    output_text,
    "",
    "CURRENT SECTION INTENT:",
    current_section
      ? `Title: ${current_section.title}\nSummary: ${current_section.summary}\nPOV: ${
        current_section.pov ?? "(unspecified)"
      }\nContainer: ${
        current_section.container ?? "(unspecified)"
      }\nTerminal Beat: ${current_section.beat_label ?? "(unspecified)"}`
      : "(none)",
    "",
    "PRIOR CANON (ordered by recency, newest first):",
  ];
  if (prior_canon.sections.length === 0) {
    parts.push("(no prior accepted sections)");
  } else {
    const sectionBlocks = prior_canon.sections.map((s, i) =>
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
}

export function buildMessages(
  request: CoherenceCheckRequest,
): { system: string; user: string } {
  return {
    system: SYSTEM_PROMPT,
    user: buildUserPrompt(
      request.output_text,
      request.current_section,
      request.prior_canon,
    ),
  };
}
