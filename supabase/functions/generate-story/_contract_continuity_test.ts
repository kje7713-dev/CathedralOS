import {
  assertEquals,
  assertStringIncludes,
  assertThrows,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  buildContractRepairPrompt,
  contractsEqual,
  detectPotentialContractCanonConflict,
  parseCanonicalCharacterStates,
  parseContractRepairResult,
} from "./_contract_continuity.ts";

const canon =
  `## Project State\nCharacters:\n- **Ilya**: {"location":"the long hut at Willow Refuge","injuries":"shoulder wound being treated","character_name":"Ilya","status":"alive"}`;
const stale = {
  title: "The final count",
  summary: "Miran learns that Ilya is missing from the final convoy count.",
  entryState: "The convoy reaches the marsh landing.",
  dramaticEvent: "Miran discovers Ilya never completed the crossing.",
  resultingChange: "The count remains unresolved.",
  terminalState: "Ilya is missing.",
};

Deno.test("continuity: parses canonical character rows emitted by Project State", () => {
  const states = parseCanonicalCharacterStates(canon);
  assertEquals(states.length, 1);
  assertEquals(states[0].name, "Ilya");
  assertEquals(states[0].location, "the long hut at Willow Refuge");
});

Deno.test("continuity: marks a generic backward concrete-state assertion as a candidate", () => {
  const candidate = detectPotentialContractCanonConflict(canon, stale);
  assertEquals(candidate?.characters, ["Ilya"]);
  assertStringIncludes(candidate?.reason ?? "", "backward-looking");
});

Deno.test("continuity: compatible current action is not a candidate", () => {
  const compatible = {
    ...stale,
    summary:
      "Ilya argues with Miran about returning to work despite his injury.",
    dramaticEvent: "Ilya chooses to rest in the long hut.",
    terminalState: "Ilya remains at the refuge.",
  };
  assertEquals(detectPotentialContractCanonConflict(canon, compatible), null);
});

Deno.test("continuity: alive-to-death during the current scene is not a candidate", () => {
  const transition = {
    ...stale,
    summary: "Enemy raiders attack the refuge and Ilya is killed defending it.",
    dramaticEvent: "Ilya dies defending the long hut.",
    terminalState: "Ilya is dead after the attack.",
  };
  assertEquals(detectPotentialContractCanonConflict(canon, transition), null);
});

Deno.test("continuity: repair response requires conflict decision and nested contract", () => {
  const parsed = parseContractRepairResult(JSON.stringify({
    conflict: true,
    reason: "The planned absence contradicts the established location.",
    contract: { ...stale, summary: "Miran confirms Ilya's safe arrival." },
  }));
  assertEquals(parsed.conflict, true);
  assertEquals(parsed.contract.summary, "Miran confirms Ilya's safe arrival.");
  assertEquals(contractsEqual(stale, parsed.contract), false);
});

Deno.test("continuity: no-conflict repair edits are rejected by deterministic equality", () => {
  const parsed = parseContractRepairResult(JSON.stringify({
    conflict: false,
    reason: "No contradiction.",
    contract: { ...stale, summary: "Modified despite no contradiction." },
  }));
  assertEquals(contractsEqual(stale, parsed.contract), false);
  assertThrows(() => {
    if (!contractsEqual(stale, parsed.contract)) {
      throw new Error("changed contract");
    }
  });
});

Deno.test("continuity: repair prompt carries immutable invariants and future trajectory", () => {
  const candidate = detectPotentialContractCanonConflict(canon, stale)!;
  const prompt = buildContractRepairPrompt(
    canon,
    stale,
    {
      container: "scene",
      terminalBeat: "The count is reconciled.",
      storyArcName: "Return",
    },
    "## Future Outline Obligations\n- The refuge stabilizes",
    candidate,
  );
  assertStringIncludes(
    prompt,
    "You may change only the six Section Contract fields.",
  );
  assertStringIncludes(prompt, "container");
  assertStringIncludes(prompt, "The refuge stabilizes");
});
