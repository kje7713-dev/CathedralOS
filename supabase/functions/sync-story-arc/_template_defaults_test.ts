import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  canonicalizeUnmodifiedBeatDetails,
  canonicalizeLegacyArcTemplate,
} from "./_template_defaults.ts";

const old = "Make the cost of the conflict personal and irreversible.";
const current = old + " Creative progression: Inflict a singular personal loss whose consequences drive the next conflict, not recurring anonymous casualties.";
const catalog = {
  name: "Historical War / Survival",
  description: "A bolder, genre-faithful survival story with Wild dust.",
  beats: [{ role: "first_loss", label: "First Loss", description: current }],
};

Deno.test("server upgrades exact old beat defaults, not author edits", () => {
  const beat = { role: "first_loss", label: "First Loss", details: old };
  assertEquals(canonicalizeUnmodifiedBeatDetails(beat, catalog.beats), current);
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, details: current }, catalog.beats), current);
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, details: "Different personal loss" }, catalog.beats), "Different personal loss");
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, details: "" }, catalog.beats), "");
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, label: "Author's loss" }, catalog.beats), old);
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, role: "" }, catalog.beats), old);
  assertEquals(canonicalizeUnmodifiedBeatDetails({ ...beat, role: "other_beat" }, catalog.beats), old);
  assertEquals(canonicalizeUnmodifiedBeatDetails(beat, [{ ...catalog.beats[0], description: old }]), old);
});

Deno.test("fresh outline input upgrades only exact defaults and keeps selected beat identity", () => {
  const input = {
    id: "a0000001-0000-0000-0000-000000000022",
    name: "Historical War / Survival",
    description: "Old genre summary.",
    beats: [
      { id: "beat-4", role: "first_loss", label: "First Loss", description: old },
      { id: "beat-5", role: "deepening_conflict", label: "A customized label", description: "Custom theme" },
      { id: "added", role: "", label: "My own beat", description: "My own story" },
    ],
  };
  const updated = canonicalizeLegacyArcTemplate(input, catalog);
  assertEquals(updated.description, catalog.description);
  assertEquals(updated.beats.map((b) => b.id), input.beats.map((b) => b.id));
  assertEquals(updated.beats.length, 3);
  assertEquals(updated.beats[0].description, current);
  assertEquals(updated.beats[1], input.beats[1]);
  assertEquals(updated.beats[2], input.beats[2]);
  assertEquals(input.beats[0].description, old, "do not mutate original payload");
  assertEquals(canonicalizeLegacyArcTemplate(input, { ...catalog, name: "Different template" }), input);
});
