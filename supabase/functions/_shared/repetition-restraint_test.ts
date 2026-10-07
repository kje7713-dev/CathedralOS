import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  analyzeRecentRepetition,
  classifySectionEntryFamily,
  deriveAvoidMotifs,
  deriveRepeatedOpenings,
  deriveRepeatedPhrases,
  deriveRhythmGuidance,
  deriveSaturatedResponseFamilies,
  deriveSaturatedSectionEntryFamilies,
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
  assertEquals(guidance.avoidSentenceOpenings.length <= 5, true);
  assertEquals(guidance.avoidPhrases.length <= 5, true);
});

Deno.test("repetition restraint uses only the latest eight sections and motif cooldown is recent", () => {
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

Deno.test("section-entry classifier collapses subject plus auxiliary variants", () => {
  for (
    const sentence of [
      "Miran had reached the eastern quay before sunrise.",
      "Miran had taken the ledger from the shelf.",
      "Miran was already waiting beside the ferry.",
      "Miran could hear the bells across the river.",
      "Anika had crossed before him.",
    ]
  ) {
    assertEquals(
      classifySectionEntryFamily(sentence),
      "subject + auxiliary openings",
    );
  }
});

Deno.test("section-entry classifier gives definite article precedence", () => {
  assertEquals(
    classifySectionEntryFamily("The ferry was empty when Miran arrived."),
    "definite-article subject openings",
  );
});

Deno.test("section-entry classifier gives temporal openings precedence", () => {
  assertEquals(
    classifySectionEntryFamily("By dawn, Miran had crossed the lower ward."),
    "temporal/transition openings",
  );
  assertEquals(
    classifySectionEntryFamily(
      "When Miran reached the quay, the boats were gone.",
    ),
    "temporal/transition openings",
  );
  assertEquals(
    classifySectionEntryFamily("At first light, the carts began moving."),
    "temporal/transition openings",
  );
});

Deno.test("section-entry classifier recognizes dialogue openings", () => {
  assertEquals(
    classifySectionEntryFamily('"Move the ledger," Anika said.'),
    "dialogue openings",
  );
});

Deno.test("structural section-entry variants saturate across sections", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "Miran had reached the eastern quay.",
      "Miran was standing beside the ferry.",
      "Miran could hear the bells across the river.",
      "A different opening begins here.",
      "Another distinct entry begins here.",
      "The final scene uses another entry.",
      "A last distinct entry begins here.",
      "One more different entry begins here.",
    ],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedSectionEntryFamilies,
    ["subject + auxiliary openings"],
  );
});

Deno.test("section-entry families do not saturate below their thresholds", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "Miran had reached the quay.",
      "Miran could hear the bells.",
      "The ferry was empty.",
      "The council chamber was quiet.",
      "By dawn, the boats were gone.",
      "When Miran arrived, nobody moved.",
      '"Move the ledger," Anika said.',
      "Miran crossed the courtyard.",
    ],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(guidance.saturatedSectionEntryFamilies, []);
});

Deno.test("definite-article section entries saturate at four sections", () => {
  assertEquals(
    deriveSaturatedSectionEntryFamilies([
      "The ferry was empty.",
      "The clerk waited.",
      "The road narrowed.",
      "The council gathered.",
      "Miran crossed the courtyard.",
    ]),
    ["definite-article subject openings"],
  );
});

Deno.test("section-entry saturation uses only the latest eight sections", () => {
  const oldSaturated = [
    "Miran had reached the quay.",
    "Miran was standing beside the ferry.",
    "Miran could hear the bells.",
  ];
  const latestEight = Array.from(
    { length: 8 },
    (_, i) => `A distinct action begins in section ${i}.`,
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: [...oldSaturated, ...latestEight],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(guidance.saturatedSectionEntryFamilies, []);
});

function sentenceWithTokens(count: number): string {
  return `${Array.from({ length: count }, (_, i) => `word${i}`).join(" ")}.`;
}

Deno.test("sentence-length guidance detects short, medium, and long saturation", () => {
  assertStringIncludes(
    deriveRhythmGuidance(
      Array.from({ length: 20 }, () => sentenceWithTokens(4)),
    ) ?? "",
    "heavily favor short sentences",
  );
  assertStringIncludes(
    deriveRhythmGuidance(
      Array.from({ length: 20 }, () => sentenceWithTokens(12)),
    ) ?? "",
    "heavily favor medium-length sentences",
  );
  assertStringIncludes(
    deriveRhythmGuidance(
      Array.from({ length: 20 }, () => sentenceWithTokens(22)),
    ) ?? "",
    "heavily favor long sentences",
  );
});

Deno.test("sentence-length guidance stays quiet for balanced or tiny samples", () => {
  const balanced = [
    ...Array.from({ length: 8 }, () => sentenceWithTokens(4)),
    ...Array.from({ length: 6 }, () => sentenceWithTokens(12)),
    ...Array.from({ length: 6 }, () => sentenceWithTokens(22)),
  ].join(" ");
  assertEquals(deriveRhythmGuidance([balanced]), undefined);
  const tinyGuidance = deriveRhythmGuidance(
    Array.from({ length: 19 }, () => sentenceWithTokens(12)),
  );
  assertEquals(
    tinyGuidance?.includes("heavily favor medium-length sentences") ?? false,
    false,
  );
});

Deno.test("paragraph and sentence-length rhythm guidance combine", () => {
  const sections = Array.from(
    { length: 20 },
    () => sentenceWithTokens(12),
  ).join("\n\n");
  const guidance = deriveRhythmGuidance([sections]);
  assertStringIncludes(guidance ?? "", "isolated one-sentence paragraphs");
  assertStringIncludes(guidance ?? "", "medium-length sentences");
});

Deno.test("rhythm guidance uses only the latest eight sections", () => {
  const oldUniform = Array.from(
    { length: 20 },
    () => sentenceWithTokens(4),
  ).join(" ");
  const balancedLatest = Array.from(
    { length: 8 },
    () =>
      [sentenceWithTokens(4), sentenceWithTokens(12), sentenceWithTokens(22)]
        .join(" "),
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: [...Array(20).fill(oldUniform), ...balancedLatest],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(guidance.rhythmGuidance, undefined);
});

Deno.test("rendered section-entry guidance preserves authority and soft restraint", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: [],
    avoidMotifs: [],
    avoidSentenceOpenings: [],
    avoidPhrases: [],
    saturatedResponseFamilies: [],
    saturatedSectionEntryFamilies: [
      "subject + auxiliary openings",
      "definite-article subject openings",
    ],
    rhythmGuidance: undefined,
  });
  assertStringIncludes(block, "Recent section-entry habits are saturated");
  assertStringIncludes(block, "subject + auxiliary openings");
  assertStringIncludes(block, "definite-article subject openings");
  assertStringIncludes(block, "Do not mechanically invert sentences");
  assertStringIncludes(block, "Section Contract remains authoritative");
});

Deno.test("empty section-entry guidance remains absent from the prompt block", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: [],
    avoidMotifs: [],
    avoidSentenceOpenings: [],
    avoidPhrases: [],
    saturatedResponseFamilies: [],
    saturatedSectionEntryFamilies: [],
    rhythmGuidance: undefined,
  });
  assertEquals(
    block.includes("Recent section-entry habits are saturated"),
    false,
  );
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
    saturatedSectionEntryFamilies: [],
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Section Contract remains authoritative");
  assertEquals(block.includes("raw_text"), false);
});

Deno.test("repetition restraint lookback is exactly eight sections", () => {
  assertEquals(RECENT_REPETITION_LOOKBACK, 8);
  // Helper slices the input to the last 8 entries.
  const longer = Array.from(
    { length: 9 },
    (_, i) => `Opening ${i}. Sentence ${i}. Tail ${i}.`,
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: longer,
    selectedMotifs: [],
    currentContract: null,
  });
  // Sections 1..8 are the last eight. If the helper had read more
  // than eight, it could see index 0; since it can only see the
  // last 8, no opening key should recur across the lookback window
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

Deno.test("character-name substitution recognizes repeated physical-action openings", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "Mara raised the bell above the table.",
      "Bram raised the bell above the threshold.",
      "A distinct scene with no matching action.",
    ],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.avoidSentenceOpenings.includes("[character] raised the bell"),
    true,
  );
});

Deno.test("grip and hand-tension reactions saturate across sections", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "Mara tightened her grip on the bell.",
      "Bram clutched the rail until his knuckles whitened.",
      "A distinct scene with no hand reaction.",
    ],
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedResponseFamilies.includes("grip/hand-tension reactions"),
    true,
  );
});

Deno.test("normalizeOpeningKey only fires for non-stopword name + recognized opening verb", () => {
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
  // Recognized physical-action verbs are normalized with a longer tail.
  assertEquals(
    normalizeOpeningKey(["mara", "raised", "the", "bell"]),
    "[character] raised the bell",
  );
  // Unrecognized verbs are not normalized.
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
    saturatedSectionEntryFamilies: [],
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
    saturatedSectionEntryFamilies: [],
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Section Contract remains authoritative");
  // Raw prose or internal identifiers must never appear.
  assertEquals(block.includes("raw_text"), false);
  assertEquals(block.includes("recentRawText"), false);
  assertEquals(block.includes("saturatedResponseFamilies"), false);
});

Deno.test("saturated families are ranked by section-count frequency, not declaration order", () => {
  // 5 sections. Frequencies:
  //   gaze/orientation   → 5
  //   heart/pulse        → 3
  //   dry-mouth          → 2
  //   stomach/gut        → 2
  // All four families qualify against their minSectionUses thresholds.
  // The top-3 cap must pick by descending sectionCount, NOT by
  // declaration order in RESPONSE_FAMILIES.
  const sections = [
    "Brody looked at Mike. His mouth went dry.",
    "Mike looked at Eleven. His mouth went dry.",
    "Lucas glanced toward Max. His heart pounded.",
    "Eleven looked at the window. His heart raced. His stomach dropped.",
    "Another character looked at the door. His heart hammered. His stomach clenched.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedResponseFamilies.length,
    3,
    "cap must remain MAX_SATURATED_RESPONSE_FAMILIES (=3)",
  );
  assertEquals(
    guidance.saturatedResponseFamilies[0],
    "gaze/orientation reactions",
    "sectionCount=5 must rank first regardless of declaration order",
  );
  assertEquals(
    guidance.saturatedResponseFamilies[1],
    "heart/pulse reactions",
    "sectionCount=3 must rank second",
  );
  // dry-mouth and stomach/gut both have sectionCount=2; deterministic
  // ascending-name tie-break picks "dry-mouth" over "stomach/gut reactions".
  assertEquals(
    guidance.saturatedResponseFamilies[2],
    "dry-mouth",
    "deterministic ascending-name tie-break must apply at sectionCount=2",
  );
});

Deno.test("saturated-family tie behavior is deterministic across repeated calls", () => {
  const sections = [
    "Brody looked at Mike. His mouth went dry. His stomach dropped.",
    "Mike looked at Eleven. His mouth went dry. His stomach clenched.",
    "Lucas glanced toward Max. His heart pounded.",
    "Eleven looked at the window. His heart raced.",
    "Another character looked at the door. His heart hammered.",
  ];
  const a = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  const b = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(a.saturatedResponseFamilies, b.saturatedResponseFamilies);
});

Deno.test("broad throat / breathing / exhaled / inhaled mentions do NOT trigger saturation", () => {
  const sections = [
    "She had a sore throat and was breathing heavily.",
    "He checked his throat in the mirror and inhaled deeply.",
    "She breathed out slowly and her throat felt fine.",
    "He examined his throat and exhaled with relief.",
    "She mentioned her throat casually during conversation.",
  ];
  const guidance = analyzeRecentRepetition({
    recentRawText: sections,
    selectedMotifs: [],
    currentContract: null,
  });
  assertEquals(
    guidance.saturatedResponseFamilies.includes("swallowing/throat reactions"),
    false,
    "bare 'throat' / 'sore throat' / 'his throat' must NOT trigger swallowing/throat reactions",
  );
  assertEquals(
    guidance.saturatedResponseFamilies.includes("breath reactions"),
    false,
    "ordinary 'breathing' / 'breathed' / 'inhaled' / 'exhaled' must NOT trigger breath reactions",
  );
});

Deno.test("conservative throat and breath reaction constructions DO trigger saturation", () => {
  const sections = [
    "His throat tightened as he spoke.",
    "Her throat constricted when she heard the news.",
    "She swallowed hard in the dark.",
    "He caught his breath and waited.",
    "She held her breath in the silence.",
    "They let out a breath together.",
  ];
  // Helper slices to the bounded recent window; these matches survive there.
  const guidance = analyzeRecentRepetition({
    recentRawText: sections.slice(-5),
    selectedMotifs: [],
    currentContract: null,
  });
  // throat: constricted (s1), swallowed hard (s2) — 2 sections → SATURATED (min=2).
  // breath: caught his breath (s3), held her breath (s4), let out a breath
  // (s5) — 3 sections → SATURATED (min=3).
  assertEquals(
    guidance.saturatedResponseFamilies.includes("swallowing/throat reactions"),
    true,
    "throat tightened / constricted / swallowed hard must trigger swallowing/throat reactions",
  );
  assertEquals(
    guidance.saturatedResponseFamilies.includes("breath reactions"),
    true,
    "caught / held / let out a breath must trigger breath reactions",
  );
});
