import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { buildAllocationPrompt, buildEnrichmentPrompt, buildPrompt } from "./index.ts";
import { RECIPE_CREATIVE_AUTHORITY_DIRECTIVE } from "./_prompt_context.ts";

// A deliberately plot-open recipe: the selected arc, not an invented transaction,
// should shape the events and distinctive reader experience.
const recipe = {
  schema: "cathedralos.story_packet",
  version: 1,
  project: {
    id: "plot-open-project",
    name: "Three People",
    summary: "Three difficult companions have complicated dependencies. The plot and ending are open.",
    audienceNotes: "Dark, funny, emotionally volatile.",
  },
  setting: { included: false },
  selectedCharacters: [
    { id: "one", name: "One", goals: ["Win their companion's loyalty"], flaws: ["Reckless"] },
    { id: "two", name: "Two", goals: ["Keep their freedom"], flaws: ["Deceptive"] },
  ],
  selectedRelationships: [],
  selectedThemeQuestions: [],
  selectedMotifs: [],
  selectedStorySpark: null,
  selectedAftertaste: null,
  storyNonNegotiables: [],
  promptPack: { id: "pack", name: "Testing", notes: "", instructionBias: "" },
};

const arcCases = [
  { name: "Romantic Suspense", role: "midpoint_reveal", description: "A secret changes the danger and a relationship." },
  { name: "Horror / Escalating Dread", role: "full_manifestation", description: "The threat becomes unavoidable and terrible." },
  { name: "Conspiracy / Artifact Thriller", role: "first_clue", description: "Uncover evidence of a conspiracy." },
  { name: "Heist / Caper", role: "plan_and_prep", description: "Prepare and carry out a heist." },
  { name: "An Unfamiliar User-Written Arc", role: "turn", description: "A personal choice changes everything." },
];

function requestFor(arc: typeof arcCases[number]) {
  return {
    recipe,
    requestedFormat: "novel",
    arcTemplate: {
      id: arc.name,
      name: arc.name,
      description: arc.description,
      beats: [{ id: "beat-a", role: arc.role, label: "Turning Point", description: arc.description }],
    },
    existingSections: [],
  } as any;
}

Deno.test("shared dramatic-engine prompts apply to every genre without adding stages or schema", () => {
  assertStringIncludes(RECIPE_CREATIVE_AUTHORITY_DIRECTIVE, "NOT an independent requirement to invent that machinery");
  for (const arc of arcCases) {
    const req = requestFor(arc);
    const enrichment = buildEnrichmentPrompt(req).system;
    const allocation = buildAllocationPrompt(req).system;
    const outline = buildPrompt(req, new Map()).system;
    assertStringIncludes(enrichment, "Story possibilities before procedural apparatus", arc.name);
    assertStringIncludes(allocation, "Choose a distinctive dramatic engine, not the first workable plot", arc.name);
    assertStringIncludes(outline, "Dramatic events over procedural narration", arc.name);
    assertStringIncludes(allocation, "Within THIS EXISTING planning response", arc.name);
    assertStringIncludes(allocation, "not a new validity gate or failure path", arc.name);
    assertStringIncludes(outline, "without additional stages, sections, or repair", arc.name);
    // The author and arc can still choose a genuine investigation or operation.
    assertStringIncludes(allocation, "A procedurally driven genre remains completely valid", arc.name);
    assertStringIncludes(allocation, "NEVER which kind of plot is chosen", arc.name);
    assertStringIncludes(allocation, "planner-invented supporting character", arc.name);
    assertStringIncludes(allocation, "deepen THAT story with genuinely different consequences", arc.name);
    assertStringIncludes(enrichment, "investigation, conspiracy, crime, legal dispute", arc.name);
    assertStringIncludes(outline, "selected architecture, accepted history, allocated slots", arc.name);
  }
});

Deno.test("all 27 seeded arc templates are audited and only canonical text is updated", async () => {
  const swift = await Deno.readTextFile("./CathedralOSApp/Models/StoryArcTemplate.swift");
  const migration = await Deno.readTextFile("./supabase/migrations/20261105130434_debias_all_default_story_arc_beats.sql");
  assertEquals((swift.match(/static let \w+ = StoryArcTemplate\(/g) ?? []).length, 27);
  const changedTemplateIDs = [
    "000000000001", // Three Act
    "000000000004", // Save the Cat
    "000000000005", // Story Circle
    "000000000006", // Freytag
    "000000000007", // Kishotenketsu
    "000000000010", // Romantasy
    "000000000011", // Countdown
    "000000000016", // Seven-Point
    "000000000017", // Horror
    "000000000019", // Romantic Suspense
    "000000000027", // Family Saga
  ];
  for (const suffix of changedTemplateIDs) {
    assertStringIncludes(migration, "a0000001-0000-0000-0000-" + suffix);
  }
  assertStringIncludes(swift, "Reveal a truth that changes both the danger and the relationship");
  assertEquals(swift.includes("changes both the investigation and the relationship"), false);
  assertStringIncludes(swift, "without requiring a solvable rule");
  assertStringIncludes(swift, "no moral lesson is required");
  assertStringIncludes(swift, "without requiring harmony");
  // Genre-relevant roles remain stable, while historical mechanism-heavy labels no longer steer the LLM.
  assertStringIncludes(swift, 'role: "final_battle_and_choice", label: "Defining Stakes and Choice"');
  assertStringIncludes(swift, 'role: "quest_and_bond", label: "Fantasy Pressure and Bond"');
  assertStringIncludes(swift, 'role: "rules_discovered", label: "Threat Pattern"');
  assertStringIncludes(swift, 'role: "first_pursuit", label: "Threat Tightens"');
  assertStringIncludes(swift, 'role: "inherited_truth_revealed", label: "Inheritance Reframed"');
  assertStringIncludes(migration, "r.original_label = beat->>'label'");
  assertStringIncludes(migration, "r.original_text = beat->>'description'");
  assertStringIncludes(migration, "never user-authored story_arc customizations");
  // Keep the genre's defining processes. The shared policy must not erase them.
  assertStringIncludes(swift, "The detective/protagonist takes the case and starts gathering evidence.");
  assertStringIncludes(swift, "Build the operation, gather tools and intelligence, and expose likely failure points.");
  assertStringIncludes(swift, "Complete the insight that reveals what must happen next and why.");
});
