import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  analyzeRecentRepetition,
  deriveAvoidMotifs,
  deriveRepeatedOpenings,
  deriveRepeatedPhrases,
  deriveRhythmGuidance,
  deriveSaturatedResponseFamilies,
  normalizeOpeningKey,
  RECENT_REPETITION_LOOKBACK,
  renderRecentRepetitionBlock,
  sectionMatchesMotif,
  sectionsMentioningMotif,
} from "./repetition-restraint.ts";

Deno.test("motif matching is case and punctuation normalized but boundary safe", () => {
  assertEquals(
    sectionMatchesMotif("THREE-SHORT/ONE-LONG!", "three short one long"),
    true,
  );
  assertEquals(
    sectionMatchesMotif(
      "A three—short, one-long signal.",
      "three-short/one-long",
    ),
    true,
  );
  assertEquals(sectionMatchesMotif("The radios flickered.", "radio"), false);
  assertEquals(sectionMatchesMotif("A radio signal appeared.", "radio"), true);
});

Deno.test("repeated motif occurrences in one section count as one section use", () => {
  const result = sectionsMentioningMotif(
    ["The radio hissed; the radio answered; the radio died."],
    { label: "radio" },
  );
  assertEquals(result.sectionIndices, [0]);
});

Deno.test("required motifs are recognized across every authoritative contract field", () => {
  for (
    const field of [
      "dramaticEvent",
      "resultingChange",
      "terminalState",
      "terminalBeat",
    ] as const
  ) {
    const guidance = analyzeRecentRepetition({
      recentRawText: ["The radio hissed.", "The radio hissed again."],
      selectedMotifs: [{ label: "radio" }],
      currentContract: { [field]: "The radio carries the warning." },
    });
    assertEquals(guidance.requiredMotifs, ["radio"]);
    assertEquals(guidance.avoidMotifs, []);
  }
});

Deno.test("a saturated motif absent from the contract remains avoidable", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: ["The radio hissed.", "The radio hissed again."],
    selectedMotifs: [{ label: "radio" }],
    currentContract: { title: "The Empty Room", summary: "No signal appears." },
  });
  assertEquals(guidance.requiredMotifs, []);
  assertEquals(guidance.avoidMotifs, ["radio"]);
});

Deno.test("repetition restraint detects cross-section openings and phrases, not one-section repetition", () => {
  assertEquals(
    deriveRepeatedOpenings(["The door opened. The door closed."]),
    [],
  );
  assertEquals(
    deriveRepeatedPhrases(["She held the radio and watched the rain."]).length,
    0,
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "She turned toward the window. She held the radio and watched the rain.",
      "She turned toward the window. She held the radio and watched the fire.",
    ],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.avoidSentenceOpenings.includes("she turned toward the"),
    true,
  );
  assertEquals(guidance.avoidPhrases.length > 0, true);
});

Deno.test("common trivial phrases stay filtered and guidance caps remain bounded", () => {
  const sections = Array.from(
    { length: 6 },
    (_, i) =>
      `The and of to. She turned toward the window ${i}. She held the radio and watched the rain.`,
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: Array.from(
      { length: 8 },
      (_, i) => ({ label: `motif-${i}` }),
    ),
    currentContract: null,
  });
  assertEquals(guidance.avoidPhrases.includes("the and of"), false);
  assertEquals(guidance.avoidSentenceOpenings.length <= 3, true);
  assertEquals(guidance.avoidPhrases.length <= 3, true);
});

Deno.test("repetition restraint uses only the latest five sections and motif cooldown is recent", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "The radio appeared in an old section.",
      "A quiet room.",
      "Another quiet room.",
      "A third quiet room.",
      "A fourth quiet room.",
      "A fifth quiet room.",
      "The radio appeared in the latest section.",
    ],
    selectedMotifs: [{ label: "radio" }],
    currentContract: null,
  });
  assertEquals(guidance.avoidMotifs, ["radio"]);
});

Deno.test("repetition restraint emits rhythm only above the explicit threshold", () => {
  assertEquals(
    deriveRhythmGuidance([
      "One.\n\nTwo.\n\nThree.\n\nFour.\n\nA longer paragraph. It continues.",
    ]) !== undefined,
    true,
  );
  assertEquals(
    deriveRhythmGuidance(["One. Two.\n\nThree. Four.\n\nFive. Six."]),
    undefined,
  );
});

Deno.test("rendered restraint is bounded guidance and never includes raw prose or descriptors", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: ["radio"],
    avoidMotifs: ["signals"],
    avoidSentenceOpenings: ["she turned toward the"],
    avoidPhrases: ["held the radio"],
    saturatedResponseFamilies: [],
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Section Contract remains authoritative");
  assertEquals(block.includes("raw_text"), false);
});

Deno.test("repetition restraint lookback is exactly five sections", () => {
  assertEquals(RECENT_REPETITION_LOOKBACK, 5);
  // Helper slices the input to the last 5 entries.
  const longer = Array.from(
    { length: 9 },
    (_, i) => `Opening ${i}. Sentence ${i}. Tail ${i}.`,
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: longer,
    selectedMotifs: [],
    currentContract: null,
  });
  // Sections 4..8 are the last five. If the helper had read more
  // than five, it could see indices 0..3; since it can only see the
  // last 5, no opening key should recur across the lookback window
  // because every sentence varies by its `${i}` index.
  assertEquals(guidance.avoidSentenceOpenings.length, 0);
});

Deno.test("saturated response families are detected when present in multiple recent sections", () => {
  const sections = [
    "Brody looked at Mike across the room.",
    "Mike stared at Eleven by the door.",
    "Lucas glanced toward Max at the window.",
    "An entirely different scene with no gaze reaction.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedResponseFamilies.includes("gaze/orientation reactions"),
    true,
  );
});

Deno.test("isolated reactions in a single section do not trigger family guidance", () => {
  const sections = [
    "Brody looked at Mike across the room.",
    "An entirely different scene with no reactions at all.",
    "Yet another distinct scene with nothing repeated.",
    "A final different scene with no overlapping reaction patterns.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  // gaze reaction appears in only one section, below the 3-section
  // threshold for the gaze/orientation family.
  assertEquals(
    guidance.saturatedResponseFamilies.includes("gaze/orientation reactions"),
    false,
  );
});

Deno.test("different response families are detected independently", () => {
  const sections = [
    "Brody looked at Mike. His throat tightened. His heart pounded.",
    "Mike looked at Eleven. His throat constricted. His heart hammered.",
    "Lucas glanced toward Max. His stomach dropped.",
    "A different scene with no overlapping reactions.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedResponseFamilies.includes("gaze/orientation reactions"),
    true,
  );
  assertEquals(
    guidance.saturatedResponseFamilies.includes("swallowing/throat reactions"),
    true,
  );
  assertEquals(
    guidance.saturatedResponseFamilies.includes("heart/pulse reactions"),
    true,
  );
  // stomach/gut only appears in one section here - must NOT yet fire.
  assertEquals(
    guidance.saturatedResponseFamilies.includes("stomach/gut reactions"),
    false,
  );
});

Deno.test("saturated families list is capped to three entries", () => {
  const sections = [
    "Brody looked at Mike. His throat tightened. His heart pounded. His stomach dropped.",
    "Mike stared at Eleven. Her throat closed. Her pulse raced. Her gut wrenched.",
    "Lucas glanced toward Max. He swallowed. His heart hammered. His stomach churned.",
    "A different scene with overlapping reaction patterns.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(guidance.saturatedResponseFamilies.length <= 3, true);
});

Deno.test("character-name substitution recognizes repeated gaze openings", () => {
  // "Brody looked at", "Mike looked at", "Eleven looked at" — names
  // differ but the opening construction is the same.
  const sections = [
    "Brody looked at Mike across the room. Then he turned away.",
    "Mike looked at Eleven by the door. He swallowed.",
    "Eleven looked at the window. Her throat tightened.",
    "Some other scene to round out the lookback window.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.avoidSentenceOpenings.includes("[character] looked at"),
    true,
  );
  // The literal "brody looked at" must NOT leak in as a separate entry —
  // the normalization collapses the name away.
  assertEquals(
    guidance.avoidSentenceOpenings.includes("brody looked at"),
    false,
  );
});

Deno.test("normalizeOpeningKey only fires for non-stopword name + gaze verb", () => {
  // "She looked at" — first token is a stopword; NOT normalized.
  assertEquals(normalizeOpeningKey(["she", "looked", "at", "him"]), null);
  // First non-stopword + gaze verb: normalized.
  assertEquals(
    normalizeOpeningKey(["brody", "looked", "at", "mike"]),
    "[character] looked at",
  );
  // Verb-then-name pattern: not normalized (we don't generalize).
  assertEquals(
    normalizeOpeningKey(["looked", "brody", "in", "the"]),
    null,
  );
  // Non-gaze verb: not normalized.
  assertEquals(
    normalizeOpeningKey(["brody", "shrugged", "and", "walked"]),
    null,
  );
  // Single token: not normalized.
  assertEquals(normalizeOpeningKey(["brody"]), null);
});

Deno.test("rendered saturated-family guidance discourages synonym swapping", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: [],
    avoidMotifs: [],
    avoidSentenceOpenings: [],
    avoidPhrases: [],
    saturatedResponseFamilies: [
      "gaze/orientation reactions",
      "swallowing/throat reactions",
    ],
    rhythmGuidance: undefined,
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Recent reaction habits are saturated:");
  assertStringIncludes(block, "gaze/orientation reactions");
  assertStringIncludes(block, "swallowing/throat reactions");
  assertStringIncludes(block, "Do not merely synonym-swap these reactions");
  assertStringIncludes(block, "subordinate to the Section Contract");
  // Raw prose must never appear in the prompt block.
  assertEquals(block.includes("raw_text"), false);
  assertEquals(block.includes("Brody looked"), false);
});

Deno.test("existing motif/phrase/rhythm behavior remains intact alongside response families", () => {
  const sections = [
    "The radio hissed. Brody looked at Mike.",
    "The radio hissed again. Brody looked at Eleven.",
    "The radio answered. Lucas glanced toward Max.",
    "The radio faded. Eleven watched the window.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [{ label: "radio" }],
    currentContract: null,
  });
  // Motif behavior still fires.
  assertEquals(guidance.avoidMotifs.includes("radio"), true);
  // Opening normalization still fires.
  assertEquals(
    guidance.avoidSentenceOpenings.includes("[character] looked at") ||
      guidance.avoidSentenceOpenings.includes("[character] stared at"),
    true,
  );
  // Response-family behavior now also fires.
  assertEquals(
    guidance.saturatedResponseFamilies.includes("gaze/orientation reactions"),
    true,
  );
  // Rhythm guidance is still absent when not dominant.
  assertEquals(guidance.rhythmGuidance, undefined);
});

Deno.test("rendered restraint block is bounded guidance and never includes raw prose", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: ["radio"],
    avoidMotifs: ["signals"],
    avoidSentenceOpenings: ["she turned toward the"],
    avoidPhrases: ["held the radio"],
    saturatedResponseFamilies: [],
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Section Contract remains authoritative");
  // Raw prose or internal identifiers must never appear.
  assertEquals(block.includes("raw_text"), false);
  assertEquals(block.includes("recentRawText"), false);
  assertEquals(block.includes("saturatedResponseFamilies"), false);
});
