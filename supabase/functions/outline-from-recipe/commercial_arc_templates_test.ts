import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { arcRoleContract } from "./index.ts";

const templates: Array<[string, string]> = [
  ["Romance / HEA", "grand_choice"],
  ["Psychological / Domestic Thriller", "final_confrontation"],
  ["Romantasy", "final_battle_and_choice"],
  ["Suspense / Countdown Thriller", "showdown"],
  ["Science-Fiction Problem / Survival", "final_solution"],
  ["Dystopian Rebellion", "confrontation"],
  ["Dark Romance", "chosen_terms"],
  ["Epic Fantasy Quest", "final_objective"],
  ["Seven-Point Story Structure", "resolution"],
  ["Horror / Escalating Dread", "survival_confrontation"],
  ["Sports Romance", "game_day_choice"],
  ["Romantic Suspense", "joint_showdown"],
  ["Conspiracy / Artifact Thriller", "confrontation_and_truth"],
  ["Progression Fantasy / LitRPG", "tier_climax"],
  ["Historical War / Survival", "decisive_event"],
  ["Coming-of-Age / Bildungsroman", "adult_choice"],
  ["Revenge", "reckoning"],
  ["Heist / Caper", "escape_or_capture"],
  ["Redemption / Rebirth", "redemptive_act"],
  ["Family Saga / Generational", "reckoning_across_generations"],
];

const catalog: Array<[string, string]> = [
  ["A0000001-0000-0000-0000-000000000008", "Romance / HEA"],
  ["A0000001-0000-0000-0000-000000000009", "Psychological / Domestic Thriller"],
  ["A0000001-0000-0000-0000-000000000010", "Romantasy"],
  ["A0000001-0000-0000-0000-000000000011", "Suspense / Countdown Thriller"],
  ["A0000001-0000-0000-0000-000000000012", "Science-Fiction Problem / Survival"],
  ["A0000001-0000-0000-0000-000000000013", "Dystopian Rebellion"],
  ["A0000001-0000-0000-0000-000000000014", "Dark Romance"],
  ["A0000001-0000-0000-0000-000000000015", "Epic Fantasy Quest"],
  ["A0000001-0000-0000-0000-000000000016", "Seven-Point Story Structure"],
  ["A0000001-0000-0000-0000-000000000017", "Horror / Escalating Dread"],
  ["A0000001-0000-0000-0000-000000000018", "Sports Romance"],
  ["A0000001-0000-0000-0000-000000000019", "Romantic Suspense"],
  ["A0000001-0000-0000-0000-000000000020", "Conspiracy / Artifact Thriller"],
  ["A0000001-0000-0000-0000-000000000021", "Progression Fantasy / LitRPG"],
  ["A0000001-0000-0000-0000-000000000022", "Historical War / Survival"],
  ["A0000001-0000-0000-0000-000000000023", "Coming-of-Age / Bildungsroman"],
  ["A0000001-0000-0000-0000-000000000024", "Revenge"],
  ["A0000001-0000-0000-0000-000000000025", "Heist / Caper"],
  ["A0000001-0000-0000-0000-000000000026", "Redemption / Rebirth"],
  ["A0000001-0000-0000-0000-000000000027", "Family Saga / Generational"],
];

Deno.test("commercial arc catalog is mirrored in Swift and migration", async () => {
  const swift = await Deno.readTextFile("./CathedralOSApp/Models/StoryArcTemplate.swift");
  const migration = await Deno.readTextFile("./supabase/migrations/20260926160000_add_twenty_commercial_story_arc_templates.sql");
  for (const [id, name] of catalog) {
    assertEquals(swift.includes(id), true, `Swift catalog missing ${name}`);
    assertEquals(swift.includes(name), true, `Swift catalog missing name ${name}`);
    assertEquals(migration.toLowerCase().includes(id.toLowerCase()), true, `migration missing ${name}`);
    assertEquals(migration.includes(name.replaceAll("'", "''")) || migration.includes(name), true, `migration missing name ${name}`);
  }
});

Deno.test("all 20 commercial arcs have explicit climactic role contracts", () => {
  for (const [templateName, role] of templates) {
    const resolved = arcRoleContract({ role, label: role }, templateName);
    assertEquals(resolved.allowedFunctions.includes("climax"), true, `${templateName} / ${role} must allow climax`);
  }
});
