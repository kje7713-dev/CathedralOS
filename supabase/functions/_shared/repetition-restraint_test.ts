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
} from "./repetition-restraint.ts";

Deno.test("repetition restraint uses recent-section lookback and ignores one-section repetition", () => {
  assertEquals(
    deriveRepeatedOpenings(["The door opened. The door closed."]),
    [],
  );
  assertEquals(
    deriveRepeatedPhrases([
      "She held the radio and watched the rain.",
      "She held the radio and watched the fire.",
    ]).length > 0,
    true,
  );
});

Deno.test("repetition restraint saturates recent motifs but preserves required contract motifs", () => {
  const motifs = [{ label: "radio", examples: ["radio"] }, { label: "seams" }];
  const required = new Set(["radio"]);
  assertEquals(
    deriveAvoidMotifs(
      motifs,
      ["The radio hissed.", "The radio hissed again."],
      required,
    ),
    [],
  );
  const guidance = analyzeRecentRepetition({
    recentRawText: ["The radio hissed.", "The radio hissed again."],
    selectedMotifs: motifs,
    currentContract: { summary: "The radio must carry the warning." },
  });
  assertEquals(guidance.requiredMotifs, ["radio"]);
  assertEquals(guidance.avoidMotifs, []);
});

Deno.test("repetition restraint detects repeated openings and strong phrases across sections", () => {
  const guidance = analyzeRecentRepetition({
    recentRawText: [
      "She turned toward the window. The old house waited.",
      "She turned toward the window. The old house watched.",
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

Deno.test("repetition restraint emits rhythm only above the explicit threshold", () => {
  assertEquals(
    deriveRhythmGuidance([
      "One.\n\nTwo.\n\nThree.\n\nFour.\n\nA longer paragraph. It continues.",
    ]) !== undefined,
    true,
  );
  assertEquals(
    deriveRhythmGuidance([
      "One. Two.\n\nThree. Four.\n\nFive. Six.",
    ]),
    undefined,
  );
});

Deno.test("repetition restraint render is bounded, volatile guidance and never includes raw prose", () => {
  const block = renderRecentRepetitionBlock({
    requiredMotifs: ["radio"],
    avoidMotifs: ["signals"],
    avoidSentenceOpenings: ["she turned toward the"],
    avoidPhrases: ["held the radio"],
    repeatedDescriptors: ["crimson"],
    rhythmGuidance: "Use fuller paragraph development where natural.",
  });
  assertStringIncludes(block, "## Recent Repetition Restraint");
  assertStringIncludes(block, "radio");
  assertStringIncludes(block, "signals");
  assertEquals(block.includes("raw_text"), false);
  assertStringIncludes(block, "Section Contract remains authoritative");
});
