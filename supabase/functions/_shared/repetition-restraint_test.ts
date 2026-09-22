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
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "Section Contract remains authoritative");
  assertEquals(block.includes("raw_text"), false);
});
