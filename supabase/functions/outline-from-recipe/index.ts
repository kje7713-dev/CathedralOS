import { createClient } from "jsr:@supabase/supabase-js@2";
import { BillableLLMError, runBillableLLM } from "../_shared/billable-llm.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { availableCredits, type UserEntitlement } from "../generate-story/_credits.ts";
import { normalizeIntimacyRating, validateAudienceCompatibility } from "../generate-story/_audience.ts";
import {
  inputTokenLimitDetails,
  estimateTokensFromMessages,
  computeMaxChargeCredits,
  snapshotPricing,
  SupabaseGenerationModelStore,
  type GenerationModel,
} from "../generate-story/_generation_models.ts";
import {
  type LLMMessage,
  getProviderBillingUnavailableUpstream,
  isProviderBillingUnavailable,
  OpenAIProvider,
  supportsCustomTemperature,
} from "../generate-story/_provider.ts";
import {
  buildCompactPlanningView,
  buildArchitecturePlanningView,
  authorFirstMaterialIndex,
  compactArcNarrativeText,
  compactExistingSections,
  compactText,
  compactMaterial,
  compactMaterialForOutline,
  compactObligations,
  RECIPE_CREATIVE_AUTHORITY_DIRECTIVE,
  stableJSONStringify,
  promptMetrics,
} from "./_prompt_context.ts";
import {
  type RecipeObligation,
  type PremiseComponent,
  deriveRecipeObligations,
  obligationCoverage,
  renderRecipeObligations,
  renderStoryNonNegotiableMustDos,
} from "./_recipe_obligations.ts";
import {
  notifyProviderBillingUnavailable,
  type ProviderBillingUnavailableContext,
} from "../_shared/_operator_alert.ts";

// =============================================================================
// index.ts — outline-from-recipe Edge Function
//
// Takes a canonical PromptPackExportPayload + arc template (StoryArcTemplate-shaped),
// returns the validated per-beat set of suggested OutlineSection payloads.
//
// Phase 2 of novel-building per docs/novel-building.md. Suggestions are not
// persisted — the user accepts/edits before locking in.
//
// Secrets required (set via `supabase secrets set`):
//   OPENAI_API_KEY            — OpenAI secret key
//   OPENAI_MODEL_DEFAULT      — legacy override; Suggest Sections defaults to GPT-5.4 Mini
//   SUPABASE_URL              — Supabase project URL (auto-injected)
//   SUPABASE_ANON_KEY         — Supabase anon key (auto-injected)
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Rate limiting: 5/min, 30/hour per user (uses generation_request_logs).
// Credits: each material LLM call is charged using actual token usage.
// The request itself is a durable background job so app suspension is safe.
//
// Request:
//   POST {
//     "recipe": <canonical PromptPackExportPayload>,
//     "arcTemplate": { id, name, description?, beats[] },
//     "hint": "optional user prompt"
//   }
//
// Response:
//   POST 202 { "run_id": "...", "status": "pending" }
//   GET  200 { "run_id": "...", "status": "completed", "suggestions": [...],
//              "warnings": [...optional] }
//   400 invalid_request — malformed body
//   401 not_authenticated — missing or invalid JWT
//   429 rate_limited — Retry-After header set
//   500 not_configured — server-side OPENAI_API_KEY missing
//   502 provider_error / invalid_response — LLM call failed or returned bad JSON
// =============================================================================

const OPENAI_API_URL = "https://api.openai.com/v1/chat/completions";
// Requests that omit modelID use the fixed Suggest Sections default.
// Persisted runs with an explicit modelID retain that identity during recovery.
export const LEGACY_PLANNING_MODEL_ID = "gpt-6-luna";
const OPENAI_MODEL = LEGACY_PLANNING_MODEL_ID;

/** Maps every physical outline action to one logical billing/cache stage. */
export function outlineLogicalStageFamily(action: string): string {
  if (action.startsWith("story-material-enrichment")) return "enrichment";
  if (action.startsWith("outline-plan")) return "allocation";
  if (action.startsWith("outline-suggestions")) return "suggestions";
  if (action.startsWith("outline-expansion-")) return "expansion";
  return action;
}

export const DRAMATIC_FUNCTIONS = [
  "setup", "incitement", "commitment", "escalation", "complication",
  "reversal", "crisis", "climax", "consequence", "resolution",
  "aftermath", "transformation",
] as const;
export type DramaticFunction = typeof DRAMATIC_FUNCTIONS[number];
export type ArcPhaseDirection = "establish" | "escalate" | "turn" | "resolve" | "settle";
export type ArcSemanticField = "dramaticEvent" | "resultingChange" | "terminalState";
export interface ArcSemanticObligation {
  id: string;
  instruction: string;
  requiredFields: ArcSemanticField[];
}
export interface ArcRoleContract {
  allowedFunctions: DramaticFunction[];
  requiredFunctions: DramaticFunction[];
  forbidsNewPrimaryConflict: boolean;
  allowsMajorEscalation: boolean;
  closureExpectation: "none" | "partial" | "strong";
  phaseDirection: ArcPhaseDirection;
  semanticObligations: ArcSemanticObligation[];
}

const contract = (
  allowedFunctions: DramaticFunction[],
  options: Partial<Omit<ArcRoleContract, "allowedFunctions">> = {},
): ArcRoleContract => ({
  allowedFunctions,
  requiredFunctions: [],
  forbidsNewPrimaryConflict: false,
  allowsMajorEscalation: true,
  closureExpectation: "none",
  phaseDirection: "escalate",
  semanticObligations: [],
  ...options,
});

const ROMANTIC_SUSPENSE_OBLIGATIONS: Record<string, ArcSemanticObligation[]> = {
  intimacy_under_pressure: [{
    id: "relationship_deepens_under_pressure",
    instruction: "Show a concrete change in trust, vulnerability, desire, or mutual dependence caused by the active danger; do not merely restate that attraction exists.",
    requiredFields: ["dramaticEvent", "resultingChange"],
  }],
  joint_showdown: [
    {
      id: "coordinated_danger_resolution",
      instruction: "Resolve the central danger through a specific coordinated action by both leads; do not make the showdown a generic confrontation or a solo victory.",
      requiredFields: ["dramaticEvent", "resultingChange"],
    },
    {
      id: "emotional_commitment_in_action",
      instruction: "Make emotional commitment materially affect the decisive action or its cost, rather than appearing only as a label or closing sentiment.",
      requiredFields: ["dramaticEvent", "resultingChange", "terminalState"],
    },
  ],
  safety_and_commitment: [
    {
      id: "threat_is_settled",
      instruction: "State what happens to the central threat and why it can no longer continue; aftermath alone is not resolution.",
      requiredFields: ["resultingChange", "terminalState"],
    },
    {
      id: "earned_romantic_future",
      instruction: "Establish the specific earned romantic future created by the leads' prior choices, not merely that they are happy or together.",
      requiredFields: ["resultingChange", "terminalState"],
    },
  ],
};

const CONTRACTS: Record<string, ArcRoleContract> = {
  setup: contract(["setup"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "establish" }),
  incitement: contract(["incitement", "setup"], { phaseDirection: "escalate" }),
  commitment: contract(["commitment", "incitement", "escalation"], { phaseDirection: "escalate" }),
  escalation: contract(["escalation", "complication", "reversal", "consequence"], { phaseDirection: "escalate" }),
  reversal: contract(["reversal", "escalation", "complication"], { closureExpectation: "partial", phaseDirection: "turn" }),
  crisis: contract(["crisis", "reversal", "consequence"], { closureExpectation: "partial", phaseDirection: "turn" }),
  climax: contract(["climax", "crisis", "transformation", "reversal"], { requiredFunctions: ["climax"], closureExpectation: "partial", phaseDirection: "turn" }),
  consequence: contract(["consequence", "resolution", "aftermath", "transformation"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "partial", phaseDirection: "resolve" }),
  resolution: contract(["resolution", "aftermath", "transformation", "consequence"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
};

const BUILTIN_ROLE_CONTRACTS: Record<string, Record<string, ArcRoleContract>> = {
  "three-act": {
    setup: CONTRACTS.setup, inciting_incident: CONTRACTS.incitement, first_plot_point: CONTRACTS.commitment,
    rising_action: CONTRACTS.escalation, midpoint: CONTRACTS.reversal, crisis: CONTRACTS.crisis,
    climax: CONTRACTS.climax, resolution: CONTRACTS.resolution,
  },
  "heros-journey": {
    ordinary_world: CONTRACTS.setup, call_to_adventure: CONTRACTS.incitement,
    refusal_of_call: contract(["setup", "consequence"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "establish" }),
    meeting_mentor: contract(["setup", "transformation"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "establish" }),
    crossing_threshold: CONTRACTS.commitment, tests_allies_enemies: CONTRACTS.escalation,
    approach_inmost_cave: contract(["escalation", "complication", "crisis"], { phaseDirection: "escalate" }),
    ordeal: contract(["crisis", "climax", "transformation"], { phaseDirection: "turn" }),
    reward: contract(["consequence", "transformation", "aftermath"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "resolve" }),
    road_back: contract(["consequence", "aftermath", "transformation"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "resolve" }),
    resurrection: contract(["climax", "crisis", "transformation"], { requiredFunctions: ["climax"], phaseDirection: "turn" }),
    return_with_elixir: contract(["resolution", "aftermath", "transformation"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  mystery: {
    the_crime: contract(["setup", "incitement"], { phaseDirection: "establish" }), investigation_begins: contract(["commitment", "escalation"], { phaseDirection: "escalate" }),
    first_suspect: contract(["complication", "reversal"], { phaseDirection: "turn" }), rising_tension: CONTRACTS.escalation,
    key_revelation: contract(["reversal", "consequence"], { phaseDirection: "turn" }), false_solution: contract(["reversal", "complication"], { phaseDirection: "turn" }),
    real_clue: contract(["reversal", "consequence"], { phaseDirection: "turn" }),
    confrontation: contract(["climax", "crisis"], { requiredFunctions: ["climax"], phaseDirection: "turn" }),
    resolution: contract(["resolution", "aftermath", "transformation"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "save-the-cat": {
    opening_image: CONTRACTS.setup, theme_stated: CONTRACTS.setup, setup: CONTRACTS.setup, catalyst: CONTRACTS.incitement,
    debate: contract(["crisis", "consequence", "setup"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "turn" }),
    break_into_two: CONTRACTS.commitment, b_story: contract(["setup", "transformation", "complication"], { phaseDirection: "establish" }),
    fun_and_games: CONTRACTS.escalation, midpoint: CONTRACTS.reversal, bad_guys_close_in: CONTRACTS.escalation,
    all_is_lost: CONTRACTS.crisis, dark_night_of_the_soul: CONTRACTS.crisis, break_into_three: CONTRACTS.commitment,
    finale: contract(["climax", "consequence", "transformation"], { requiredFunctions: ["climax"], phaseDirection: "turn" }),
    final_image: contract(["resolution", "aftermath", "transformation"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "story-circle": {
    you: CONTRACTS.setup, need: CONTRACTS.incitement, go: CONTRACTS.commitment, search: CONTRACTS.escalation,
    find: contract(["consequence", "reversal", "transformation"], { phaseDirection: "turn" }), take: contract(["crisis", "consequence"], { phaseDirection: "turn" }),
    return: contract(["consequence", "aftermath", "transformation"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "resolve" }),
    change: contract(["transformation", "resolution", "aftermath"], { requiredFunctions: ["transformation"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "freytags-pyramid": {
    exposition: CONTRACTS.setup, rising_action: CONTRACTS.escalation,
    climax: CONTRACTS.climax,
    falling_action: contract(["consequence", "aftermath", "transformation", "resolution"], { forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, phaseDirection: "resolve" }),
    denouement: contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "kishotenketsu": {
    ki: contract(["setup", "incitement"], { phaseDirection: "establish" }),
    sho: contract(["setup", "escalation", "complication", "consequence", "transformation"], { allowsMajorEscalation: false, phaseDirection: "escalate" }),
    ten: contract(["reversal", "transformation", "consequence"], { phaseDirection: "turn" }),
    ketsu: contract(["resolution", "aftermath", "transformation"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "romance-hea": {
    "ordinary_life": CONTRACTS.setup,
    "meet_attraction": CONTRACTS.incitement,
    "resistance": CONTRACTS.escalation,
    "connection_deepens": CONTRACTS.escalation,
    "midpoint_intimacy": CONTRACTS.commitment,
    "pressure_test": CONTRACTS.escalation,
    "rupture": CONTRACTS.crisis,
    "realization": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "grand_choice": CONTRACTS.climax,
    "hea_hfn": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "psychological-domestic-thriller": {
    "normal_surface": CONTRACTS.setup,
    "destabilizing_incident": CONTRACTS.incitement,
    "suspicion_grows": CONTRACTS.escalation,
    "first_reveal": CONTRACTS.reversal,
    "isolation": CONTRACTS.escalation,
    "midpoint_truth_shift": CONTRACTS.reversal,
    "apparent_answer": CONTRACTS.consequence,
    "deeper_betrayal": CONTRACTS.crisis,
    "final_confrontation": CONTRACTS.climax,
    "aftermath": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "romantasy": {
    "ordinary_world": CONTRACTS.setup,
    "magical_disruption": CONTRACTS.incitement,
    "dangerous_attraction": CONTRACTS.escalation,
    "binding_choice": CONTRACTS.commitment,
    "quest_and_bond": CONTRACTS.escalation,
    "midpoint_revelation": CONTRACTS.reversal,
    "divided_loyalties": CONTRACTS.escalation,
    "catastrophic_break": CONTRACTS.crisis,
    "united_choice": CONTRACTS.commitment,
    "final_battle_and_choice": CONTRACTS.climax,
    "new_order_together": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "suspense-countdown-thriller": {
    "threat_appears": CONTRACTS.incitement,
    "clock_starts": CONTRACTS.commitment,
    "first_pursuit": CONTRACTS.escalation,
    "narrowing_options": CONTRACTS.escalation,
    "midpoint_reversal": CONTRACTS.reversal,
    "major_loss": CONTRACTS.crisis,
    "final_lead": CONTRACTS.commitment,
    "race_to_deadline": CONTRACTS.escalation,
    "showdown": CONTRACTS.climax,
    "aftermath": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "science-fiction-problem-survival": {
    "baseline_world": CONTRACTS.setup,
    "impossible_problem": CONTRACTS.incitement,
    "first_hypothesis": CONTRACTS.commitment,
    "failed_solution": CONTRACTS.reversal,
    "deeper_discovery": CONTRACTS.reversal,
    "resource_collapse": CONTRACTS.crisis,
    "breakthrough": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "sacrifice_choice": CONTRACTS.commitment,
    "final_solution": CONTRACTS.climax,
    "changed_world": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "dystopian-rebellion": {
    "controlled_normal": CONTRACTS.setup,
    "crack_in_system": CONTRACTS.incitement,
    "awakening": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "first_defiance": CONTRACTS.commitment,
    "resistance_builds": CONTRACTS.escalation,
    "regime_retaliates": CONTRACTS.crisis,
    "betrayal_or_loss": CONTRACTS.reversal,
    "uprising_choice": CONTRACTS.commitment,
    "confrontation": CONTRACTS.climax,
    "new_order_cost": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "dark-romance": {
    "dangerous_encounter": CONTRACTS.incitement,
    "boundary_drawn": CONTRACTS.setup,
    "entanglement": CONTRACTS.escalation,
    "power_shift": CONTRACTS.reversal,
    "vulnerability_revealed": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "moral_pressure": CONTRACTS.escalation,
    "betrayal_or_rupture": CONTRACTS.crisis,
    "reckoning": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "chosen_terms": CONTRACTS.climax,
    "earned_resolution": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "epic-fantasy-quest": {
    "threatened_home": CONTRACTS.setup,
    "call_or_mission": CONTRACTS.incitement,
    "fellowship_forms": CONTRACTS.commitment,
    "first_threshold": CONTRACTS.commitment,
    "trials_and_world": CONTRACTS.escalation,
    "midpoint_revelation": CONTRACTS.reversal,
    "catastrophic_setback": CONTRACTS.crisis,
    "regroup_and_sacrifice": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "final_objective": CONTRACTS.climax,
    "return_or_new_age": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "seven-point-story-structure": {
    "hook": CONTRACTS.setup,
    "plot_turn_one": CONTRACTS.commitment,
    "pinch_point_one": CONTRACTS.escalation,
    "midpoint": CONTRACTS.reversal,
    "pinch_point_two": CONTRACTS.crisis,
    "plot_turn_two": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "resolution": contract(["climax", "resolution", "transformation", "aftermath"], { requiredFunctions: ["climax"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: true, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "horror-escalating-dread": {
    "normal_with_crack": CONTRACTS.setup,
    "first_intrusion": CONTRACTS.incitement,
    "denial_or_misread": CONTRACTS.escalation,
    "confirmation": CONTRACTS.reversal,
    "isolation": CONTRACTS.escalation,
    "rules_discovered": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "false_safety": CONTRACTS.consequence,
    "full_manifestation": CONTRACTS.crisis,
    "survival_confrontation": CONTRACTS.climax,
    "final_image": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "sports-romance": {
    "season_setup": CONTRACTS.setup,
    "meet_or_rivalry": CONTRACTS.incitement,
    "forced_proximity": CONTRACTS.commitment,
    "chemistry_builds": CONTRACTS.escalation,
    "first_commitment": CONTRACTS.commitment,
    "public_private_pressure": CONTRACTS.escalation,
    "athletic_setback": CONTRACTS.reversal,
    "relationship_rupture": CONTRACTS.crisis,
    "game_day_choice": CONTRACTS.climax,
    "hea_hfn": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "romantic-suspense": {
    "danger_hook": CONTRACTS.incitement,
    "forced_alliance": CONTRACTS.commitment,
    "distrust": CONTRACTS.escalation,
    "intimacy_under_pressure": contract(CONTRACTS.escalation.allowedFunctions, { semanticObligations: ROMANTIC_SUSPENSE_OBLIGATIONS.intimacy_under_pressure }),
    "threat_escalates": CONTRACTS.escalation,
    "midpoint_reveal": CONTRACTS.reversal,
    "betrayal_or_misread": CONTRACTS.crisis,
    "trust_choice": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "joint_showdown": contract(CONTRACTS.climax.allowedFunctions, { requiredFunctions: ["climax"], closureExpectation: "partial", phaseDirection: "turn", semanticObligations: ROMANTIC_SUSPENSE_OBLIGATIONS.joint_showdown }),
    "safety_and_commitment": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle", semanticObligations: ROMANTIC_SUSPENSE_OBLIGATIONS.safety_and_commitment }),
  },
  "conspiracy-artifact-thriller": {
    "discovery": CONTRACTS.incitement,
    "pursuit_begins": CONTRACTS.commitment,
    "first_clue": CONTRACTS.escalation,
    "conspiracy_expands": CONTRACTS.reversal,
    "ally_or_betrayal": CONTRACTS.reversal,
    "hidden_history_reveal": CONTRACTS.reversal,
    "apparent_defeat": CONTRACTS.crisis,
    "final_decoding": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "race_to_prevent": CONTRACTS.escalation,
    "confrontation_and_truth": CONTRACTS.climax,
    "aftermath": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "progression-fantasy-litrpg": {
    "weak_start": CONTRACTS.setup,
    "system_discovered": CONTRACTS.incitement,
    "first_gain": CONTRACTS.commitment,
    "training_and_trials": CONTRACTS.escalation,
    "first_boss": CONTRACTS.reversal,
    "new_tier": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "stronger_rival": CONTRACTS.escalation,
    "major_defeat": CONTRACTS.crisis,
    "breakthrough": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "tier_climax": CONTRACTS.climax,
    "next_horizon": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "historical-war-survival": {
    "life_before": CONTRACTS.setup,
    "war_arrives": CONTRACTS.incitement,
    "adaptation": CONTRACTS.commitment,
    "first_loss": CONTRACTS.consequence,
    "deepening_conflict": CONTRACTS.escalation,
    "impossible_choice": CONTRACTS.reversal,
    "major_loss_or_betrayal": CONTRACTS.crisis,
    "final_endurance": CONTRACTS.commitment,
    "decisive_event": CONTRACTS.climax,
    "aftermath_and_memory": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "coming-of-age-bildungsroman": {
    "sheltered_identity": CONTRACTS.setup,
    "first_disruption": CONTRACTS.incitement,
    "experimentation": CONTRACTS.escalation,
    "belonging_and_conflict": CONTRACTS.escalation,
    "first_consequence": CONTRACTS.reversal,
    "disillusionment": CONTRACTS.crisis,
    "self_recognition": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "adult_choice": CONTRACTS.climax,
    "leaving_or_returning": CONTRACTS.consequence,
    "integrated_identity": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "revenge": {
    "injury": CONTRACTS.incitement,
    "vow": CONTRACTS.commitment,
    "preparation": CONTRACTS.escalation,
    "first_retribution": CONTRACTS.escalation,
    "cost_revealed": CONTRACTS.consequence,
    "counterstrike": CONTRACTS.crisis,
    "moral_crossroads": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "final_hunt": CONTRACTS.commitment,
    "reckoning": CONTRACTS.climax,
    "consequence": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "heist-caper": {
    "target": CONTRACTS.setup,
    "motive": CONTRACTS.incitement,
    "crew_assembled": CONTRACTS.commitment,
    "plan_and_prep": CONTRACTS.escalation,
    "first_complication": CONTRACTS.escalation,
    "execution_begins": CONTRACTS.commitment,
    "plan_breaks": CONTRACTS.crisis,
    "betrayal_or_twist": CONTRACTS.reversal,
    "improvisation": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "escape_or_capture": CONTRACTS.climax,
    "division_and_aftermath": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "redemption-rebirth": {
    "broken_state": CONTRACTS.setup,
    "chance_to_change": CONTRACTS.incitement,
    "refusal_or_old_pattern": CONTRACTS.escalation,
    "first_good_choice": CONTRACTS.commitment,
    "progress": CONTRACTS.escalation,
    "relapse": CONTRACTS.crisis,
    "truth_faced": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "sacrifice": CONTRACTS.commitment,
    "redemptive_act": CONTRACTS.climax,
    "changed_life": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
  "family-saga-generational": {
    "founding_choice": CONTRACTS.setup,
    "first_inheritance": CONTRACTS.incitement,
    "family_expands": CONTRACTS.escalation,
    "buried_conflict": CONTRACTS.escalation,
    "generational_turn": CONTRACTS.reversal,
    "fracture": CONTRACTS.crisis,
    "inherited_truth_revealed": CONTRACTS.reversal,
    "reckoning_across_generations": CONTRACTS.climax,
    "reconciliation_or_repeat": contract(["transformation", "reversal", "consequence"], { phaseDirection: "turn" }),
    "legacy": contract(["resolution", "aftermath", "transformation", "consequence"], { requiredFunctions: ["resolution"], forbidsNewPrimaryConflict: true, allowsMajorEscalation: false, closureExpectation: "strong", phaseDirection: "settle" }),
  },
};

function normalizedTemplateName(name: string): string {
  return name.toLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/[’']/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function fallbackRoleFamily(role: string): string {
  const value = role.toLowerCase().replace(/[’']/g, "");
  if (/exposition|ordinary_world|opening_image|setup|theme_stated/.test(value)) return "setup";
  if (/inciting|catalyst|call_to_adventure|crime|hook/.test(value)) return "incitement";
  if (/first_plot|break_into_two|crossing_threshold|commitment/.test(value)) return "commitment";
  if (/rising|tests_allies|fun_and_games|bad_guys_close_in|investigation|development/.test(value)) return "escalation";
  if (/midpoint|reversal|revelation|false_solution|real_clue|ten/.test(value)) return "reversal";
  if (/crisis|ordeal|all_is_lost|dark_night/.test(value)) return "crisis";
  if (/climax|confrontation|finale|resurrection/.test(value)) return "climax";
  if (/falling_action|road_back|consequence/.test(value)) return "consequence";
  if (/denouement|resolution|return_with_elixir|final_image|ketsu/.test(value)) return "resolution";
  return "escalation";
}

export function arcRoleContract(beat: { role?: string; label?: string; description?: string }, templateName = ""): ArcRoleContract {
  const template = BUILTIN_ROLE_CONTRACTS[normalizedTemplateName(templateName)];
  const role = beat.role ?? "";
  const base = template?.[role] ?? CONTRACTS[fallbackRoleFamily(role)] ?? CONTRACTS.escalation;
  const authoredRequirement = beat.description?.trim() ?? "";
  if (!authoredRequirement) return base;
  return {
    ...base,
    semanticObligations: [
      {
        id: "authored_beat_requirement",
        instruction: `Satisfy the complete authored narrative requirement for this beat: ${authoredRequirement}`,
        requiredFields: ["dramaticEvent", "resultingChange", "terminalState"],
      },
      ...base.semanticObligations,
    ],
  };
}

export const REQUIRED_RESOLUTION_OUTCOME_OBLIGATION: ArcSemanticObligation = {
  id: "required_resolution_outcome",
  instruction: "Determine whether the central dramatic question or commitment has received a definite outcome consistent with the complete authored recipe and preceding story. An attempted action, incidental loss, atmospheric aftermath, or postponed confrontation does not constitute resolution. Definite failure, destruction, abandonment, tragedy, or morally ambiguous consequences are valid when they conclusively answer the relevant dramatic question. Wider mysteries may remain open.",
  requiredFields: ["resultingChange", "terminalState"],
};

/** Keep resolution semantic review local to the independent verifier. */
export function verificationObligationsForBeat(
  beat: { role?: string; label?: string; description?: string },
  templateName: string,
): ArcSemanticObligation[] {
  const contract = arcRoleContract(beat, templateName);
  return contract.requiredFunctions.includes("resolution")
    ? [...contract.semanticObligations, REQUIRED_RESOLUTION_OUTCOME_OBLIGATION]
    : contract.semanticObligations;
}

export function arcRoleContracts(template: Pick<ArcTemplateBlob, "beats" | "name">): Map<string, ArcRoleContract> {
  return new Map(template.beats.map((beat) => [beat.id, arcRoleContract(beat, template.name)]));
}

// Base schema for one generated section. The response schema below wraps this
// per Story Arc beat so minimum coverage is enforced by structured outputs.
const SECTION_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string", minLength: 1, maxLength: 120 },
    summary: { type: "string", minLength: 1, maxLength: 2000 },
    container: { type: "string", enum: ["beat", "moment", "vignette", "microScene", "scene", "developedScene", "setPiece", "sceneSequence", "shortStory", "chapter", "episode"] },
    pov: { type: "string", enum: ["firstPerson", "secondPerson", "thirdPersonLimited", "thirdPersonOmniscient"] },
    terminalBeat: { type: "string", minLength: 1, maxLength: 500, description: "The concrete closing dramatic action or moment of this section; never a Story Arc ID, beat label, or END." },
    entryState: { type: "string", minLength: 1, maxLength: 1200 },
    dramaticEvent: { type: "string", minLength: 1, maxLength: 2000 },
    resultingChange: { type: "string", minLength: 1, maxLength: 1200 },
    terminalState: { type: "string", minLength: 1, maxLength: 1200 },
    dramaticFunction: { type: "string", enum: DRAMATIC_FUNCTIONS },
    // Optional grounded evidence. The server verifies every quote against the
    // actual Section Contract field; this can never certify itself.
    arcObligationEvidence: { type: "object", additionalProperties: { type: "array", items: { type: "object", properties: { field: { type: "string", enum: ["dramaticEvent", "resultingChange", "terminalState"] }, quote: { type: "string", minLength: 1, maxLength: 1200 } }, required: ["field", "quote"], additionalProperties: false } } },
  },
  required: ["title", "summary", "container", "pov", "terminalBeat", "entryState", "dramaticEvent", "resultingChange", "terminalState", "dramaticFunction"],
  additionalProperties: false,
} as const;

export const NOVEL_LEAF_CONTAINERS = ["scene", "developedScene", "setPiece", "sceneSequence", "chapter"] as const;

export function validateNovelLeafContainers(
  suggestions: Array<{ container?: string | null }>,
  format: StoryMaterialFormat = "novel",
): void {
  if (format !== "novel") return;
  for (const suggestion of suggestions) {
    if (!NOVEL_LEAF_CONTAINERS.includes(suggestion.container as typeof NOVEL_LEAF_CONTAINERS[number])) {
      throw new Error(`new novel planning does not allow generation-bearing leaf container ${String(suggestion.container)}`);
    }
  }
}

/** Interleave a beat's planned containers rather than grouping similar
 * sizes together. Counts and slot names remain deterministic on replay. */
export function plannedNovelContainerSlots(counts: NovelContainerCounts): Array<typeof NOVEL_LEAF_CONTAINERS[number]> {
  const total = NOVEL_LEAF_CONTAINERS.reduce((sum, type) => sum + counts[type], 0);
  const used = Object.fromEntries(NOVEL_LEAF_CONTAINERS.map((type) => [type, 0])) as NovelContainerCounts;
  const slots: Array<typeof NOVEL_LEAF_CONTAINERS[number]> = [];
  for (let i = 0; i < total; i++) {
    const choices = NOVEL_LEAF_CONTAINERS.filter((type) => used[type] < counts[type]);
    const chosen = choices.reduce((best, type) =>
      (i + 1) * counts[type] / total - used[type] >
        (i + 1) * counts[best] / total - used[best] ? type : best);
    slots.push(chosen);
    used[chosen]++;
  }
  return slots;
}
function plannedNovelSlotKey(index: number): string {
  return `section_${String(index + 1).padStart(3, "0")}`;
}

export function buildSuggestionResponseSchema(
  beats: Array<{ id: string; role?: string; label?: string; description?: string }>,
  allocation: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  templateName = "",
  requestedFormat: StoryMaterialFormat = "other",
) {
  const properties: Record<string, unknown> = {};
  const required: string[] = [];
  const allowedContainers = requestedFormat === "novel" ? [...NOVEL_LEAF_CONTAINERS] : SECTION_SCHEMA.properties.container.enum;
  const sectionSchema = obligations.length > 0
    ? {
      ...SECTION_SCHEMA,
      properties: {
        ...SECTION_SCHEMA.properties,
        container: { type: "string", enum: allowedContainers },
        recipeRequirementIDs: {
          type: "array",
          minItems: 1,
          maxItems: 50,
          items: { type: "string", enum: obligations.map((obligation) => obligation.id) },
        },
      },
      required: [...SECTION_SCHEMA.required, "recipeRequirementIDs"],
    }
    : { ...SECTION_SCHEMA, properties: { ...SECTION_SCHEMA.properties, container: { type: "string", enum: allowedContainers } } };
  for (const beat of beats) {
    const minimum = allocation.get(beat.id)?.minSections ?? 0;
    const contract = arcRoleContract(beat, templateName);
    const beatSectionSchema = {
      ...sectionSchema,
      properties: {
        ...sectionSchema.properties,
        dramaticFunction: { type: "string", enum: contract.allowedFunctions },
        ...(contract.semanticObligations.length > 0 ? {
          arcObligationEvidence: {
            type: "object",
            properties: Object.fromEntries(contract.semanticObligations.map((obligation) => [obligation.id, { type: "array", items: { type: "object", properties: { field: { type: "string", enum: ["dramaticEvent", "resultingChange", "terminalState"] }, quote: { type: "string", minLength: 1, maxLength: 1200 } }, required: ["field", "quote"], additionalProperties: false } }])),
            required: contract.semanticObligations.map((obligation) => obligation.id),
            additionalProperties: false,
          },
        } : {}),
      },
      required: contract.semanticObligations.length > 0
        ? [...sectionSchema.required, "arcObligationEvidence"]
        : sectionSchema.required,
    };
    const planned = requestedFormat === "novel" ? allocation.get(beat.id)?.containerCounts : undefined;
    if (planned) {
      // A per-beat array can restrict the allowed types but CANNOT enforce
      // their quantities. Fixed named slots give each section its own strict
      // container enum, so first-pass size is priced BEFORE the provider call.
      // The flattened app payload remains the same ordered Suggestion[].
      const slots = plannedNovelContainerSlots(planned);
      const slotProperties = Object.fromEntries(slots.map((container, index) => {
        const key = plannedNovelSlotKey(index);
        const propertiesForSlot = { ...beatSectionSchema.properties };
        // OpenAI strict objects must require every declared property. Omit
        // optional evidence metadata when this arc beat has no obligation.
        if (contract.semanticObligations.length === 0) {
          delete (propertiesForSlot as Record<string, unknown>).arcObligationEvidence;
        }
        return [key, {
          ...beatSectionSchema,
          properties: {
            ...propertiesForSlot,
            container: { type: "string", enum: [container] },
          },
        }];
      }));
      properties[beat.id] = {
        type: "object", properties: slotProperties,
        required: Object.keys(slotProperties),
        additionalProperties: false,
      };
    } else {
      // Legacy persisted allocations and non-novel formats use their original
      // array schema without changing recovery, billing or acceptance.
      properties[beat.id] = {
        type: "array",
        minItems: minimum,
        maxItems: requestedFormat === "novel" ? minimum : MAX_PLANNED_SECTIONS,
        items: beatSectionSchema,
      };
    }
    required.push(beat.id);
  }
  return {
    type: "object",
    properties: { beats: { type: "object", properties, required, additionalProperties: false } },
    required: ["beats"],
    additionalProperties: false,
  };
}

/** Convert the structured per-beat response into the app-facing flat payload.
 * The server, not the model, owns Story Arc identity and canonical ordering. */
export function flattenSuggestionResponse(
  parsed: unknown,
  beats: Array<{ id: string }>,
): { suggestions: Suggestion[] } {
  if (!parsed || typeof parsed !== "object") throw new Error("response missing beats object");
  const beatObject = (parsed as { beats?: unknown }).beats;
  if (!beatObject || typeof beatObject !== "object") throw new Error("response missing beats object");
  const suggestions: Suggestion[] = [];
  for (const beat of beats) {
    const rawSections = (beatObject as Record<string, unknown>)[beat.id];
    // New novel plans use named, container-typed slots. Legacy persisted
    // checkpoints and all non-novel plans still return arrays.
    const sections = Array.isArray(rawSections)
      ? rawSections
      : rawSections && typeof rawSections === "object"
      ? Object.entries(rawSections as Record<string, unknown>)
        .filter(([slot]) => /^section_\d{3}$/.test(slot))
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([, value]) => value)
      : null;
    if (!sections) throw new Error(`response missing beat ${beat.id}`);
    for (const raw of sections) {
      if (!raw || typeof raw !== "object") throw new Error(`beat ${beat.id} contains an invalid section`);
      const { storyArcBeatID: _ignored, ...section } = raw as Partial<Suggestion>;
      suggestions.push({ ...(section as Omit<Suggestion, "storyArcBeatID">), storyArcBeatID: beat.id });
    }
  }
  return { suggestions };
}

// Literary planning ranges, deliberately separate from generate-story's provider
// hard caps. These are only used to estimate whether a novel plan has enough
// distinct dramatic material; they are never sent as completion ceilings.
const CONTAINER_EXPECTED_RANGES: Record<string, [number, number]> = {
  beat: [75, 250], moment: [200, 500], vignette: [300, 900],
  microScene: [400, 900], scene: [800, 1800], developedScene: [1500, 3000],
  setPiece: [2000, 5000], sceneSequence: [3000, 7000], shortStory: [2500, 8000],
  chapter: [3000, 8000], episode: [5000, 15000],
};
export const NOVEL_TARGET_WORDS: [number, number] = [115000, 125000];
export const NOVEL_PREFERRED_MIN_WORDS = 115000;
export const NOVEL_MAX_WORDS = 125000;
// Keep the nominal planning ceiling at 125,000 words, but allow a bounded
// final projection grace range for unavoidable midpoint estimation drift.
export const NOVEL_MAX_GRACE_WORDS = 5000;
export const NOVEL_ACCEPTED_MAX_WORDS = NOVEL_MAX_WORDS + NOVEL_MAX_GRACE_WORDS;
const TOKENS_PER_WORD = 1.3;
// A 2% under-target projection is acceptable for completion. Keep the
// 115,000-word planning goal and the 125,000-word nominal maximum; the bounded
// accepted grace ceiling is defined separately below.
export const NOVEL_LENGTH_TOLERANCE = 0.02;
export const NOVEL_EXPANSION_MIN_WORDS = Math.ceil(NOVEL_PREFERRED_MIN_WORDS * (1 - NOVEL_LENGTH_TOLERANCE));
const NOVEL_MIN_PROJECTED_TOKENS = NOVEL_PREFERRED_MIN_WORDS * TOKENS_PER_WORD;
const NOVEL_MAX_PROJECTED_TOKENS = NOVEL_MAX_WORDS * TOKENS_PER_WORD;
const NOVEL_ACCEPTED_MAX_PROJECTED_TOKENS = NOVEL_ACCEPTED_MAX_WORDS * TOKENS_PER_WORD;
const MAX_PLANNED_SECTIONS = 200;
export const MAX_EXPANSION_ROUNDS = 3;

const ALLOWED_CONTAINERS = new Set([
  "beat",
  "moment",
  "vignette",
  "microScene",
  "scene",
  "developedScene",
  "setPiece",
  "sceneSequence",
  "shortStory",
  "chapter",
  "episode",
]);

const ALLOWED_POVS = new Set([
  "firstPerson",
  "secondPerson",
  "thirdPersonLimited",
  "thirdPersonOmniscient",
]);

const RATE_LIMIT_PER_MINUTE = 5;
const RATE_LIMIT_PER_HOUR = 30;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

const CANONICAL_RECIPE_SCHEMA = "cathedralos.story_packet";

/** The subset of the canonical PromptPackExportPayload validated or addressed
 * directly here. The complete object is forwarded unchanged to both LLM calls.
 */
interface CanonicalRecipeEnvelope {
  schema: string;
  version: number;
  project: { id: string; summary?: string; readingLevel?: string; contentRating?: string; intimacyRating?: string; audienceNotes?: string };
  setting: { included: boolean };
  selectedCharacters: unknown[];
  selectedStorySpark: unknown | null;
  selectedAftertaste: unknown | null;
  selectedRelationships: unknown[];
  storyNonNegotiables?: unknown[];
  selectedThemeQuestions: unknown[];
  selectedMotifs: unknown[];
  promptPack: {
    id: string;
    name: string;
    includeProjectSetting?: boolean;
    notes?: string;
    instructionBias?: string;
  };
}

type StoryArcRelationshipFocus = "none" | "supporting" | "primary";
type IntimacyMilestoneRating = "romantic" | "fade_to_black" | "open_door" | "explicit";

interface ArcTemplateBlob {
  id: string;
  name: string;
  description?: string;
  beats: Array<
    { id: string; role: string; label: string; description?: string }
  >;
  /** Optional for old callers; absence conservatively means no romance obligation. */
  relationshipFocus?: StoryArcRelationshipFocus;
  /** Authoritative template roles where a whole-arc intimacy milestone may occur. */
  intimacyMilestoneRoles?: string[];
}

interface OutlineFromRecipeRequest {
  recipe: CanonicalRecipeEnvelope;
  arcTemplate: ArcTemplateBlob;
  hint?: string;
  existingSections?: ExistingSectionBlob[]; // iOS-side outline state at request time
  storyMaterialEnrichment?: StoryMaterialEnrichment; // candidate reuse from a prior planning pass
  requestedFormat?: StoryMaterialFormat;
  /** Explicit MVP model selection; persisted in request_json for resume. */
  modelID?: string;
  /** Optional GPT-6-family reasoning level selected in the iOS picker. */
  reasoningEffort?: "low" | "medium" | "high";
  outline_id?: string;
  // PR 4: canonical planning identity. Server-validated pre-billable so a
  // stale Outline reference (delete + restore, sync race) cannot survive
  // into a paid LLM call.
  project_lineage_id?: string;
  idempotencyKey?: string;
  /** Non-billable planning estimate request; never creates a durable run. */
  estimate_only?: boolean;
}

export interface OutlinePlanningEstimate {
  estimatedCredits: number;
  lowerBoundCredits: number;
  upperBoundCredits: number;
  availableCredits: number;
  projectedBalance: number;
  allowed: boolean;
  model: string;
  expectedStages: number;
}

/**
 * Project the complete outline pipeline without calling an LLM or reserving
 * credits. The range is deliberately labelled as an estimate: enrichment,
 * allocation, first-pass suggestions, and variable expansion calls are all
 * priced with the canonical GenerationModel snapshot and the same token
 * accounting used by the billable runner.
 */
export function estimateOutlinePlanningCost(
  request: OutlineFromRecipeRequest,
  model: GenerationModel,
  entitlement: UserEntitlement,
): OutlinePlanningEstimate {
  const inputTokens = Math.max(1_500, estimateTokensFromMessages([
    { content: JSON.stringify(request.recipe) },
    { content: JSON.stringify(request.arcTemplate) },
    { content: JSON.stringify(request.existingSections ?? []) },
  ]));
  const pricing = snapshotPricing(model);
  const stage = (input: number, output: number) => computeMaxChargeCredits({
    uncachedInputTokens: input,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: output,
    toolCostUsd: 0,
  }, pricing);
  const beatCount = Math.max(1, request.arcTemplate.beats.length);
  const expansionCalls = Math.max(1, Math.ceil(beatCount / 4) * MAX_EXPANSION_ROUNDS);
  const baseStages = [
    stage(inputTokens, 12_000), // story-material enrichment
    stage(inputTokens, 2_048), // allocation
    stage(inputTokens, OUTLINE_OUTPUT_TOKEN_BUDGET), // first-pass suggestions
  ];
  const lowerBoundCredits = baseStages.reduce((sum, value) => sum + value, 0);
  const upperBoundCredits = lowerBoundCredits + expansionCalls * stage(inputTokens, OUTLINE_OUTPUT_TOKEN_BUDGET);
  const available = availableCredits(entitlement);
  return {
    estimatedCredits: upperBoundCredits,
    lowerBoundCredits,
    upperBoundCredits,
    availableCredits: available,
    projectedBalance: available - upperBoundCredits,
    allowed: available >= upperBoundCredits,
    model: model.id,
    expectedStages: 3 + expansionCalls,
  };
}

interface ExistingSectionBlob {
  title?: string;
  summary?: string;
  container?: string;
  pov?: string;
  terminalBeat?: string;
  storyArcBeatID?: string; // null for manual/free-form sections
  recipeRequirementIDs?: string[]; // server-assigned obligations already covered
}

export type StoryMaterialSource = "recipe" | "planner";
export type StoryMaterialFormat = "novel" | "shortStory" | "other";

interface StoryMaterialProvenance {
  sourceRecipeHash: string;
  sourceRecipeVersion: number;
  sourcePromptPackID: string;
  sourcePromptPackName: string;
}

export interface StoryMaterialItem {
  id: string;
  source: StoryMaterialSource;
  sourceReference: string | null;
  label: string;
  description: string;
}

export interface StoryMaterialEnrichment {
  schema: "cathedralos.story_material_enrichment";
  version: 2;
  format: StoryMaterialFormat;
  sourceRecipeHash: string;
  sourceRecipeVersion: number;
  sourcePromptPackID: string;
  sourcePromptPackName: string;
  rationale: string;
  /** Independent, exact-quote-backed commitments extracted from the author's summary. */
  premiseComponents?: PremiseComponent[]; // absent in already-paid legacy checkpoints
  characters: StoryMaterialItem[];
  antagonisticForces: StoryMaterialItem[];
  locations: StoryMaterialItem[];
  institutionsAndGroups: StoryMaterialItem[];
  conflictSources: StoryMaterialItem[];
  escalationLadder: StoryMaterialItem[];
  reversals: StoryMaterialItem[];
  consequences: StoryMaterialItem[];
  relationships: StoryMaterialItem[];
  discoveries: StoryMaterialItem[];
  unresolvedQuestions: StoryMaterialItem[];
  thematicPressures: StoryMaterialItem[];
}

export const STORY_MATERIAL_CATEGORIES = [
  "characters", "antagonisticForces", "locations", "institutionsAndGroups",
  "conflictSources", "escalationLadder", "reversals", "consequences",
  "relationships", "discoveries", "unresolvedQuestions", "thematicPressures",
] as const;

const STORY_MATERIAL_ITEM_SCHEMA = {
  type: "object",
  properties: {
    id: { type: "string", minLength: 1, maxLength: 120 },
    source: { type: "string", enum: ["recipe", "planner"] },
    sourceReference: { type: ["string", "null"], maxLength: 500 },
    label: { type: "string", minLength: 1, maxLength: 160 },
    description: { type: "string", minLength: 1, maxLength: 2000 },
  },
  required: ["id", "source", "sourceReference", "label", "description"],
  additionalProperties: false,
} as const;

const PREMISE_COMPONENT_SCHEMA = {
  type: "object",
  properties: {
    sourceQuote: { type: "string", minLength: 3, maxLength: 550 },
    requirement: { type: "string", minLength: 5, maxLength: 650 },
  },
  required: ["sourceQuote", "requirement"],
  additionalProperties: false,
} as const;

export const STORY_MATERIAL_ENRICHMENT_SCHEMA = {
  type: "object",
  properties: {
    schema: { type: "string", enum: ["cathedralos.story_material_enrichment"] },
    version: { type: "integer", enum: [2] },
    format: { type: "string", enum: ["novel", "shortStory", "other"] },
    // Server-owned provenance is attached after the model response. It is
    // intentionally absent from this strict provider schema; OpenAI requires
    // every declared property to appear in `required`.
    rationale: { type: "string", minLength: 1, maxLength: 2000 },
    premiseComponents: { type: "array", maxItems: 16, items: PREMISE_COMPONENT_SCHEMA },
    ...Object.fromEntries(STORY_MATERIAL_CATEGORIES.map((category) => [category, { type: "array", maxItems: 50, items: STORY_MATERIAL_ITEM_SCHEMA }])),
  },
  required: ["schema", "version", "format", "rationale", "premiseComponents", ...STORY_MATERIAL_CATEGORIES],
  additionalProperties: false,
} as const;

function stableJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  return `{${Object.keys(value as Record<string, unknown>).sort().map((key) => `${JSON.stringify(key)}:${stableJson((value as Record<string, unknown>)[key])}`).join(",")}}`;
}

export async function recipeProvenance(recipe: CanonicalRecipeEnvelope): Promise<StoryMaterialProvenance> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(stableJson(recipe)));
  const sourceRecipeHash = Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return { sourceRecipeHash, sourceRecipeVersion: recipe.version, sourcePromptPackID: recipe.promptPack.id, sourcePromptPackName: recipe.promptPack.name };
}

function recipeMaterialHandles(recipe: CanonicalRecipeEnvelope): Map<string, string> {
  // PR8: this is the single authority for canonical recipe-backed references.
  // It must handle sparse / partially-populated recipes defensively so that
  // repairStoryMaterialFromRecipe can call it on any input without crashing.
  // Production callers (validateRequest → outline-from-recipe POST handler)
  // already enforce the full canonical schema; this guard covers the
  // repair path which receives legacy / partial / blank recipes.
  const handles = new Map<string, string>();
  if (recipe?.project && typeof recipe.project.summary === "string" && recipe.project.summary.trim()) {
    handles.set("project.summary", recipe.project.summary);
  }
  const add = (prefix: string, values: unknown[], fallback: string) => {
    if (!Array.isArray(values)) return;
    values.forEach((value, index) => {
      if (!value || typeof value !== "object") return;
      const row = value as Record<string, unknown>;
      const id = typeof row.id === "string" && row.id.trim() ? row.id : `${fallback}-${index + 1}`;
      const handle = `${prefix}:${id}`;
      handles.set(handle, typeof row.name === "string" ? row.name : typeof row.label === "string" ? row.label : JSON.stringify(row));
    });
  };
  add("character", recipe.selectedCharacters, "character");
  add("relationship", recipe.selectedRelationships, "relationship");
  add("theme", recipe.selectedThemeQuestions, "theme");
  add("motif", recipe.selectedMotifs, "motif");
  if (recipe.selectedStorySpark) handles.set("storySpark", JSON.stringify(recipe.selectedStorySpark));
  if (recipe.selectedAftertaste) handles.set("aftertaste", JSON.stringify(recipe.selectedAftertaste));
  return handles;
}

export function requestedStoryMaterialFormat(req: Pick<OutlineFromRecipeRequest, "requestedFormat">): StoryMaterialFormat {
  return req.requestedFormat ?? "novel";
}

/**
 * Provider item IDs are package-local bookkeeping, not provenance. Models
 * occasionally repeat an ID across categories or omit it entirely. Repair
 * only those structural defects deterministically so one malformed response
 * does not turn an otherwise usable enrichment into a 500; provenance remains
 * guarded separately by the validator below.
 */
/**
 * Legacy/provider material can mark an item as recipe-backed while carrying
 * a local item id instead of a canonical recipe handle. Keep its authored
 * prose, but downgrade the provenance claim before reuse validation.
 */
export function downgradeUnverifiedProviderRecipeReferences(
  value: unknown,
  recipe: CanonicalRecipeEnvelope,
): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const candidate = value as Record<string, unknown>;
  const handles = recipeMaterialHandles(recipe);
  const normalized: Record<string, unknown> = { ...candidate };
  for (const category of STORY_MATERIAL_CATEGORIES) {
    const items = candidate[category];
    if (!Array.isArray(items)) continue;
    normalized[category] = items.map((item) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return item;
      const row = item as Record<string, unknown>;
      if (row.source === "recipe" && (typeof row.sourceReference !== "string" || !handles.has(row.sourceReference))) {
        return { ...row, source: "planner", sourceReference: null };
      }
      return item;
    });
  }
  return normalized;
}

export function normalizeProviderStoryMaterialItemIDs(value: unknown): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const candidate = value as Record<string, unknown>;
  const ids = new Set<string>();
  const normalized: Record<string, unknown> = { ...candidate };
  for (const category of STORY_MATERIAL_CATEGORIES) {
    const items = candidate[category];
    if (!Array.isArray(items)) continue;
    normalized[category] = items.map((item, index) => {
      if (!item || typeof item !== "object" || Array.isArray(item)) return item;
      const row = item as Record<string, unknown>;
      const originalID = typeof row.id === "string" ? row.id.trim() : "";
      if (originalID && !ids.has(originalID)) {
        ids.add(originalID);
        return originalID === row.id ? item : { ...row, id: originalID };
      }
      let repairedID = `provider-${category}-${index + 1}`;
      let suffix = 2;
      while (ids.has(repairedID)) repairedID = `provider-${category}-${index + 1}-${suffix++}`;
      ids.add(repairedID);
      return { ...row, id: repairedID };
    });
  }
  return normalized;
}

/** Enforce source-literal premise extraction rather than hallucinated requirements. */
export function validatePremiseComponents(raw: unknown, projectSummary: string): PremiseComponent[] {
  if (!Array.isArray(raw) || raw.length > 16) throw new Error("premiseComponents must contain at most 16 items");
  const summary = projectSummary.trim();
  if (!summary && raw.length > 0) throw new Error("premiseComponents cannot invent a premise without an authored summary");
  if (summary && raw.length === 0) throw new Error("premiseComponents omitted the authored summary");
  const occupied = new Set<string>();
  const covered = new Uint8Array(summary.length);
  const components: PremiseComponent[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error("invalid premise component");
    const row = item as Record<string, unknown>;
    const sourceQuote = typeof row.sourceQuote === "string" ? row.sourceQuote.trim() : "";
    const requirement = typeof row.requirement === "string" ? row.requirement.trim() : "";
    if (sourceQuote.length < 3 || sourceQuote.length > 550 || requirement.length < 5 || requirement.length > 650 ||
        !summary.includes(sourceQuote) || occupied.has(sourceQuote)) {
      throw new Error("premise component has a duplicate, missing, or invented source quote or invalid requirement");
    }
    occupied.add(sourceQuote);
    const offset = summary.indexOf(sourceQuote);
    for (let i = offset; i < offset + sourceQuote.length; i++) covered[i] = 1;
    components.push({ sourceQuote, requirement });
  }
  if (summary.length >= 180 && components.length < 2) {
    throw new Error("multi-part project summary cannot be represented by one premise obligation");
  }
  // Prevent a partial extraction from quietly erasing a major promise.
  // Ignore whitespace/punctuation between contiguous authored phrases.
  const materialChars = [...summary].map((letter, i) => /[\p{L}\p{N}]/u.test(letter) ? i : -1).filter((i) => i >= 0);
  const coverage = materialChars.length ? materialChars.filter((i) => covered[i]).length / materialChars.length : 1;
  if (coverage < 0.7) throw new Error("premiseComponents failed to cover the authored project summary");
  // Whole-paragraph coverage can still conceal an omitted final promise. Require
  // every substantive sentence, not merely the average, to survive extraction.
  const sentences = [...summary.matchAll(/[^.!?]+[.!?]?/g)];
  for (const sentence of sentences) {
    const start = sentence.index ?? 0;
    const text = sentence[0];
    const positions = [...text].map((letter, offset) => /[\p{L}\p{N}]/u.test(letter) ? start + offset : -1).filter((i) => i >= 0);
    if (positions.length < 12) continue;
    if (positions.filter((i) => covered[i]).length / positions.length < 0.7) {
      throw new Error("premiseComponents left a substantive sentence or ending promise uncovered");
    }
    if (text.length >= 130 && /,\s*(?:and|but|while|though)\b/i.test(text)) {
      const distinct = components.filter((component) => {
        const at = summary.indexOf(component.sourceQuote);
        return at < start + text.length && at + component.sourceQuote.length > start;
      });
      if (distinct.length < 2) throw new Error("compound premise sentence was not decomposed into distinct commitments");
    }
  }
  return components;
}

export function validateStoryMaterialEnrichment(value: unknown, options: { allowMissingProvenance?: boolean; recipe?: CanonicalRecipeEnvelope } = {}): StoryMaterialEnrichment {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("story material enrichment must be an object");
  const candidate = value as Record<string, unknown>;
  if (candidate.schema !== "cathedralos.story_material_enrichment" || candidate.version !== 2) throw new Error("story material enrichment has an unsupported schema or version");
  if (!["novel", "shortStory", "other"].includes(String(candidate.format))) throw new Error("story material enrichment has an invalid format");
  if (typeof candidate.rationale !== "string" || candidate.rationale.trim() === "") throw new Error("story material enrichment requires a rationale");
  const provenanceFields = ["sourceRecipeHash", "sourceRecipeVersion", "sourcePromptPackID", "sourcePromptPackName"];
  if (!options.allowMissingProvenance && provenanceFields.some((field) => typeof candidate[field] !== "string" && field !== "sourceRecipeVersion" || field === "sourceRecipeVersion" && !Number.isInteger(candidate[field]))) throw new Error("story material enrichment is missing server-owned recipe provenance");
  // A missing field belongs to a pre-change checkpoint: keep its paid IDs.
  if (candidate.premiseComponents !== undefined) {
    if (options.recipe) validatePremiseComponents(candidate.premiseComponents, String(options.recipe.project?.summary ?? ""));
    else if (!Array.isArray(candidate.premiseComponents) || candidate.premiseComponents.some((item: any) =>
      !item || typeof item.sourceQuote !== "string" || typeof item.requirement !== "string")) {
      throw new Error("premiseComponents is malformed");
    }
  }
  const handles = options.recipe ? recipeMaterialHandles(options.recipe) : null;
  const ids = new Set<string>();
  for (const category of STORY_MATERIAL_CATEGORIES) {
    const items = candidate[category];
    if (!Array.isArray(items)) throw new Error(`story material enrichment category ${category} must be an array`);
    for (const item of items) {
      if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error(`story material enrichment category ${category} contains an invalid item`);
      const row = item as Record<string, unknown>;
      if (typeof row.id !== "string" || row.id.trim() === "" || ids.has(row.id)) throw new Error("story material enrichment contains a duplicate or missing item id");
      if (row.source !== "recipe" && row.source !== "planner") throw new Error(`story material enrichment item ${row.id} has an invalid source`);
      if (row.source === "recipe") {
        if (typeof row.sourceReference !== "string" || row.sourceReference.trim() === "") throw new Error(`recipe story material item ${row.id} requires a source reference`);
        if (handles && !handles.has(row.sourceReference)) throw new Error(`recipe story material item ${row.id} has an unverified source reference`);
        if (row.label === row.sourceReference || row.description === row.sourceReference) throw new Error(`recipe story material item ${row.id} has no authored description`);
      } else if (row.sourceReference !== null) throw new Error(`planner story material item ${row.id} must not claim a recipe reference`);
      if (row.sourceReference !== null && typeof row.sourceReference !== "string") throw new Error(`story material enrichment item ${row.id} has an invalid source reference`);
      if (typeof row.label !== "string" || row.label.trim() === "" || typeof row.description !== "string" || row.description.trim() === "") throw new Error(`story material enrichment item ${row.id} is missing label or description`);
      ids.add(row.id);
    }
  }
  return value as StoryMaterialEnrichment;
}

export function storyMaterialSufficiency(material: StoryMaterialEnrichment, recipe: CanonicalRecipeEnvelope, format: StoryMaterialFormat = "novel") {
  const counts = Object.fromEntries(STORY_MATERIAL_CATEGORIES.map((category) => [category, material[category].length])) as Record<string, number>;
  const recipeCount = STORY_MATERIAL_CATEGORIES.reduce((n, category) => n + material[category].filter((item) => item.source === "recipe").length, 0);
  const supporting = counts.locations + counts.institutionsAndGroups + counts.relationships + counts.discoveries + counts.unresolvedQuestions;
  const change = counts.reversals + counts.consequences;
  const reasons: string[] = [];
  if (format === "novel") {
    if (!recipe.project.summary && counts.characters === 0) reasons.push("no protagonist or core supplied material represented");
    if (counts.antagonisticForces === 0 && counts.conflictSources === 0) reasons.push("no meaningful opposition or conflict source");
    if (counts.escalationLadder < 3) reasons.push("escalation ladder is too thin for novel-scale development");
    if (change < 2) reasons.push("not enough reversals or consequences");
    if (supporting < 2) reasons.push("insufficient supporting concrete material");
    if (counts.characters + counts.conflictSources + counts.escalationLadder + change < 6) reasons.push("package remains too abstract to support extended dramatic development");
    if (recipeCount === 0) reasons.push("no canonical recipe material was preserved");
  } else if (counts.characters + counts.conflictSources + counts.escalationLadder === 0) reasons.push("package contains no concrete dramatic material");
  return { sufficient: reasons.length === 0, reasons, counts, recipeDerivedItemCount: recipeCount, plannerInventedItemCount: countStoryMaterialItems(material) - recipeCount };
}

export function attachRecipeProvenance(material: StoryMaterialEnrichment, provenance: StoryMaterialProvenance): StoryMaterialEnrichment {
  return { ...material, ...provenance, version: 2 };
}

export function isCompatibleStoryMaterialEnrichment(material: StoryMaterialEnrichment, provenance: StoryMaterialProvenance, format: StoryMaterialFormat): boolean {
  return material.sourceRecipeHash === provenance.sourceRecipeHash && material.sourceRecipeVersion === provenance.sourceRecipeVersion && material.sourcePromptPackID === provenance.sourcePromptPackID && material.sourcePromptPackName === provenance.sourcePromptPackName && material.format === format;
}

export function buildEnrichmentPrompt(
  req: OutlineFromRecipeRequest,
  candidate?: StoryMaterialEnrichment,
  repairReason?: string,
): { system: string; user: string } {
  const format = requestedStoryMaterialFormat(req);
  const repairInstruction = repairReason
    ? `\n\nThe previous enrichment package was rejected: ${repairReason}. Return one corrected complete enrichment package.`
    : "";
  return {
    system: `${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}

You are CathedralOS's story-material enrichment planner. Create a concrete package of development possibilities before outline planning, not prose or a final outline. The canonical recipe, its creative identity, intended reader experience, genre, tone, intensity, absurdity, and explicit non-negotiables are authoritative. Preserve supplied material and deepen it rather than replacing it.

## Character-first invention
Invent enough distinctive supporting people to make the story feel inhabited, volatile, and worth reading. Do not suppress supporting-character invention merely to make the package smaller or tidier, and do not consolidate genuinely different people because they occupy the same functional category. There is no cast quota: add a person when their agency materially creates pressure, opportunity, surprise, humor, danger, conflict, betrayal, intimacy, or momentum. Each invented character should have a personality, independent desire, flaw or contradiction, unpredictable behavior, relationship-specific tension, and a reason they make choices rather than merely deliver information. Give them agency that can derail the protagonists' plans, force compromises, expose vulnerabilities, create reversals, or produce consequences. Every invented character must be more than a job title or plot function: give them a distinctive personal identity, independent motivations, and choices that materially change events. If a character could be replaced by an anonymous role without changing the story, deepen the character or omit them.

## Entertainment, Audacity, and Creative Intensity
Actively seek the most compelling, original, entertaining, and dramatically exciting realization of the author's premise. Do not default to the safest, most restrained, respectable, conventional, administratively plausible, or morally reassuring choice. When supported by the authored genre, tone, and intended reader experience, favor wild, eccentric, larger-than-life supporting characters with outrageous personalities, unusual desires, dangerous flaws, unpredictable behavior, and relationships that create trouble. Favor absurd situations, spectacular mistakes, escalating disasters, reckless decisions, dangerous encounters, betrayals, confrontations, unexpected reversals, dark humor, grotesque absurdity, shocking developments, chaotic action, surreal experiences, and memorable set pieces.

Characters' addictions, appetites, obsessions, moral corruption, impulsivity, cruelty, selfishness, sexuality, and psychological contradictions may actively generate the story when the recipe makes them part of the creative identity. Invent situations that make those characteristics consequential rather than merely listing them as traits. Let surprising situations escalate beyond what characters intended and become progressively harder to control. When multiple options fit the recipe, favor greater originality, dramatic energy, surprise, interpersonal conflict, and reader entertainment. Do not automatically transform morally compromised protagonists into responsible heroes. Do not impose redemption arcs, moral lessons, institutional reform, orderly solutions, or reassuring conclusions unless the author requests them.

Do not unnecessarily sanitize or dilute authored adult intensity. If the recipe specifies explicit adult sexual content, drug use, grotesque violence, depravity, moral corruption, or disturbing subject matter, treat that intensity as part of the creative identity, subject to applicable content constraints. Characters may be deeply flawed, irrational, destructive, cruel, depraved, frightening, or unredeemable when appropriate to the story. Do not routinely replace explicit adult themes with vague implications, tame descriptions, sanitized relationships, or conventional moral commentary.

## Invent distinctive experiences
Give the reader the on-page encounters, actions, emotional consequences, absurdities, and discoveries promised by the author's recipe. Events should follow from choices and relationships, not from the convenience of a plot device. Let information matter through what it makes people do. Quiet, intricate, realistic, or investigative experiences remain entirely valid when the author actually wants them; intensity and originality come from the recipe, not a universal genre preference.

## Decompose the AUTHOR'S project summary before inventing
The premiseComponents array is not speculative enrichment: extract every independent factual setup, causal event, character transformation, and consequential promise from recipe.project.summary. Use the author's exact contiguous words as sourceQuote (a substring of the original summary) and a concise, faithful requirement statement for each component. Split compound sentences into independent commitments; do not collapse a national/social or humanity-scale consequence into one generic "danger" or "survival" obligation. Cover the substantive meaning of the ENTIRE summary, including its last clause, rather than just its first incident. Do not add invented claims, force an unrequested ending, or elevate a prompt-pack title into an authored event. A multi-book-scale promise must be materially advanced in the current book, not necessarily fully resolved: that choice belongs to architecture and book planning. Keep authored components separate from optional source=planner categories. Return [] when there is no authored summary.

## Build a Distinctive Narrative Engine
Before inventing supporting developments, identify the particular experiences, tensions, surprises, and unresolved questions promised by the author's recipe. Build from characters' desires, contradictions, relationships, decisions, and interactions with the world. When the authored story is grotesque, surreal, absurdist, or character-driven, invent a WIDE RANGE of personally consequential, non-institutional encounters instead of filling every category with variants of one invented government program, raid, security contractor, detention scheme, or crowd-control operation. The existence of a conspiracy is not itself a request to make its administrative machinery the plot. Escalation means their choices produce increasingly consequential and distinctive experiences, not merely a larger version of the same obstacle. Support a full ${format}-scale story with substantially different dramatic developments, rather than expanding one incident into a chain of logistical steps.

## Keep enrichment genuinely exploratory
The enrichment categories are ways to describe possible material, not a directive to construct one complete and coordinated plot apparatus. Antagonistic forces, institutions, locations, discoveries, reversals, and the escalation ladder do not all need to describe the same invented opposition or operation. Create room for independent characters, conflicting agendas, accidental encounters, intimate betrayals, self-inflicted catastrophes, and different kinds of consequences as warranted by the recipe. Some ideas may connect; others can be alternatives that the outliner will choose between. Do not prematurely make one invented device responsible for every danger, revelation, and climax. A planner-invented mechanism is an optional candidate, not a required plot path. Specifically, avoid defaulting to a government contractor, audit, custody transfer, compliance program, or surveillance apparatus merely as a convenient engine for a conspiracy or climax. Those mechanisms are valid when the author requests them or distinctive character decisions genuinely make them the strongest story choice; otherwise explore threats arising from character ambition, relationships, accidents, and independent agendas instead of a single procedural operation.

Treat Story Arc templates as structural progression, not a source of genre conventions or an instruction to select a familiar causal storyline. Preserve the author's specific narrative experience, including when the author actually wants a meticulous investigation, institutional drama, or other specialized form. Causality and continuity matter; a mechanically complete operation is not a substitute for dramatic development.

## Package discipline without creative suppression
Start with the author's premise, defining conflicts, supplied characters, relationships, themes, motifs, content requirements, and intended ending. Then create interconnected people, situations, escalation, reversals, consequences, relationships, discoveries, locations, and mechanisms in the order above. Sparse input still carries a larger invention burden; it does not mean a shorter or simpler story. For a novel, support the approximately 115,000-word planning target with connected conflicts, consequences, reversals, discoveries, relationships, and state changes: substantive connected dramatic material, not a large inventory of disconnected concepts, filler, fixed item counts, or unrelated subplots. Do not minimize candidate count as an objective. Instead, remove only interchangeable, redundant, purely explanatory, or non-dramatic entries; retain distinct people and situations when they create different choices, pressures, relationships, reversals, or consequences. The schema and existing sufficiency requirements remain authoritative, but they are not a reason to starve the supporting cast.

The selected Story Arc describes dramatic progression, not a required sequence of plot devices. Interpret its beats through the author's characters, genre, and intended reader experience. Do not turn an invented institution, location, or conflict device into the inevitable explanation for every event.

Rich input means preserve, connect, and deepen supplied material before inventing replacements. Treat defining traits, behaviors, moral complexity, tonal intensity, absurdity, and narrative uncertainty as creative commitments. Do not soften, explain away, or replace them with a generic central conflict. Every planner-invented item is a replaceable development candidate, not a new authorial obligation or canon fact. Emit source=planner only for every returned item and always use null sourceReference. Do not reproduce or relabel authored recipe material; the server deterministically extracts canonical recipe-backed material. Return only JSON matching the existing enrichment schema.${repairInstruction}`,
    user: JSON.stringify({
      recipe: req.recipe,
      recipeMaterialHandles: Object.fromEntries(recipeMaterialHandles(req.recipe)),
      priorEnrichment: candidate ?? null,
      arcTemplate: req.arcTemplate,
      hint: req.hint ?? null,
      requestedFormat: format,
    }, null, 2),
  };
}

export class OutlineOutputExhaustedError extends Error {
  readonly code = "provider_output_exhausted";

  constructor() {
    super("outline provider output exhausted the configured completion limit before a complete JSON response was returned");
    this.name = "OutlineOutputExhaustedError";
  }
}

/** Parse provider JSON without allowing a length-truncated response to pass. */
export function parseOutlineJSON<T = unknown>(content: string, finishReason?: string): T {
  if (finishReason === "length") throw new OutlineOutputExhaustedError();
  return JSON.parse(content) as T;
}

interface SuggestionLLMResult {
  content: string;
  creditCostCharged: number;
  remainingCredits: number;
  finishReason?: string;
  recordProviderAttemptMetadata?: (metadata: Record<string, unknown>) => Promise<void>;
}

type SuggestionLLMCall = (
  system: string,
  user: string,
  maxOutputTokens: number,
  responseFormat: unknown,
  action: string,
  validateResponse?: (content: string, finishReason?: string) => unknown | Promise<unknown>,
) => Promise<SuggestionLLMResult>;

interface Suggestion {
  title: string;
  summary: string;
  container: string;
  pov: string;
  terminalBeat: string;
  /** Additive planning contract; legacy callers are normalized from summary/terminalBeat. */
  entryState?: string;
  dramaticEvent?: string;
  resultingChange?: string;
  terminalState?: string;
  dramaticFunction?: DramaticFunction;
  plannedWordRange?: { minWords: number; maxWords: number };
  storyArcBeatID: string;
  recipeRequirementIDs?: string[];
  arcObligationEvidence?: Record<string, Array<{ field: "dramaticEvent" | "resultingChange" | "terminalState"; quote: string }>>;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function corsResponse(body: string, init: ResponseInit = {}): Response {
  return new Response(body, {
    ...init,
    headers: { ...CORS_HEADERS, ...(init.headers || {}) },
  });
}

function errorResponse(
  code: string,
  message: string,
  status: number,
): Response {
  return corsResponse(JSON.stringify({ errorCode: code, message }), { status });
}

/**
 * PR8 (Fix the Shit cycle 8): reconstruct a valid StoryMaterialEnrichment
 * from the live canonical recipe, with every item carrying `source: "recipe"`
 * and a CANONICAL `sourceReference` produced by recipeMaterialHandles(). The
 * previous implementation emitted references like `selectedCharacters[<id>]`
 * which never existed as canonical handles — the repaired material failed
 * validateStoryMaterialEnrichment when anyone tried to re-validate it.
 *
 * Canonical handle → StoryMaterialEnrichment category mapping:
 *   project.summary       → discoveries[0]
 *   character:<id>        → characters
 *   storySpark            → antagonisticForces[0]    (single object, not array)
 *   relationship:<id>     → relationships
 *   theme:<id>            → thematicPressures
 *   motif:<id>            → thematicPressures       (no dedicated motif category)
 *   aftertaste            → unresolvedQuestions[0]   (single object, not array)
 *
 * Self-validates via validateStoryMaterialEnrichment before returning; throws
 * if the structural contract is violated. Call sites are responsible for
 * running storyMaterialSufficiency and failing closed if the canonical
 * recipe cannot satisfy sufficiency. Pure JS: no LLM call, no credit charge.
 */
export function repairStoryMaterialFromRecipe(
  recipe: unknown,
  provenance: StoryMaterialProvenance,
  // PR8 (revised): format parameter so the helper does not re-repair forever
  // when callers request a format other than "novel". Defaults to "novel"
  // which preserves every existing call site.
  format: StoryMaterialFormat = "novel",
): StoryMaterialEnrichment {
  const r = (recipe ?? {}) as CanonicalRecipeEnvelope;
  // recipeMaterialHandles() is the canonical sourceReference authority: it
  // produces the exact "category:<id>" handle strings we emit, and a sparse
  // recipe cannot manufacture handles it did not produce. We use it as the
  // single source of canonical handle strings.
  //
  // PR8 (revised): label/description are read from the ACTUAL recipe
  // objects (recipe.selectedCharacters[i].summary, recipe.selectedMotifs[i]
  // .description, recipe.selectedThemeQuestions[i].description, etc.) — NOT
  // from the recipeMaterialHandles map value. The map value is a canonical
  // short identifier (name || label || JSON.stringify(row)); when a row has
  // both `name` and `summary`, reading the map value discards summary and
  // authored character/motif/relationship descriptions are lost. Reading
  // directly from the recipe preserves them.
  const handles = recipeMaterialHandles(r);

  const idPortionOf = (handle: string): string => handle.replace(/^[a-zA-Z]+:/, "");
  const itemFromHandle = (handle: string, label: string, description: string): StoryMaterialItem => {
    // validateStoryMaterialEnrichment rejects label === sourceReference and
    // description === sourceReference. Canonical extractors above guarantee
    // both values are non-empty, so this fallback only fires when a recipe
    // field literally repeats the handle (e.g. an aftertaste whose label is
    // the string "aftertaste"). The synthesized fallback is a deterministic
    // structural marker, not a content placeholder.
    const idPortion = idPortionOf(handle);
    const fallback = `${idPortion || handle} (recipe handle)`;
    const safeLabel = (label && label !== handle) ? label : fallback;
    const safeDescription = (description && description !== handle) ? description : safeLabel;
    return {
      id: `recipe-${handle.replace(/[.:]/g, "-")}`,
      source: "recipe" as const,
      sourceReference: handle,
      label: safeLabel,
      description: safeDescription,
    };
  };

  const pickStr = (row: Record<string, unknown> | null | undefined, ...keys: string[]): string => {
    if (!row) return "";
    for (const key of keys) {
      const v = row[key];
      if (typeof v === "string" && v.trim()) return v.trim();
    }
    return "";
  };

  // Canonical recipe-field extractors. The PromptPackExportPayload schema
  // (CathedralOSApp/Models/PromptPackExportPayload.swift) defines the
  // authoritative authored fields per story-material category. Reading from
  // the real schema preserves actual user content rather than collapsing to
  // the recipe handle. Synthesized prose is reserved as a final structural
  // fallback when a canonical row exists but every authored field is empty.
  const asString = (value: unknown): string => {
    if (typeof value !== "string") return "";
    return value.trim();
  };

  const asStringArray = (value: unknown): string[] => {
    if (!Array.isArray(value)) return [];
    return value
      .filter((entry): entry is string => typeof entry === "string")
      .map((entry) => entry.trim())
      .filter((entry) => entry.length > 0);
  };

  // joinNonEmpty drops empty entries and appends a terminal period to any
  // fragment that doesn't already end in terminal punctuation. Used by
  // aftertasteText and storySparkText, which build their descriptions as a
  // flat array of pre-formatted fragments rather than going through
  // partsPush. Same readability contract as partsPush.
  const joinNonEmpty = (parts: string[]): string => {
    return parts
      .filter((p) => p.length > 0)
      .map((p) => /[.!?]$/.test(p) ? p : p + ".")
      .join(" ");
  };

  const aftertasteText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.label);
    const description = joinNonEmpty([
      asString(row.note),
      asString(row.emotionalResidue) && `Emotional residue: ${asString(row.emotionalResidue)}`,
      asString(row.endingTexture) && `Ending texture: ${asString(row.endingTexture)}`,
      asString(row.desiredAmbiguityLevel) && `Desired ambiguity: ${asString(row.desiredAmbiguityLevel)}`,
      asString(row.readerQuestionLeftOpen) && `Reader question left open: ${asString(row.readerQuestionLeftOpen)}`,
      asString(row.lastImageFeeling) && `Last image feeling: ${asString(row.lastImageFeeling)}`,
    ]);
    return {
      label: label || "Aftertaste",
      description: description || "Aftertaste with no authored content supplied",
    };
  };

  const storySparkText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.title);
    const description = joinNonEmpty([
      asString(row.situation) && `Situation: ${asString(row.situation)}`,
      asString(row.stakes) && `Stakes: ${asString(row.stakes)}`,
      asString(row.twist) && `Twist: ${asString(row.twist)}`,
      asString(row.urgency) && `Urgency: ${asString(row.urgency)}`,
      asString(row.threat) && `Threat: ${asString(row.threat)}`,
      asString(row.opportunity) && `Opportunity: ${asString(row.opportunity)}`,
      asString(row.complication) && `Complication: ${asString(row.complication)}`,
      asString(row.clock) && `Clock: ${asString(row.clock)}`,
      asString(row.triggerEvent) && `Trigger event: ${asString(row.triggerEvent)}`,
      asString(row.initialImbalance) && `Initial imbalance: ${asString(row.initialImbalance)}`,
      asString(row.falseResolution) && `False resolution: ${asString(row.falseResolution)}`,
      asString(row.reversalPotential) && `Reversal potential: ${asString(row.reversalPotential)}`,
    ]);
    return {
      label: label || "Story Spark",
      description: description || "Story spark with no authored content supplied",
    };
  };

  const characterText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.name);
    const parts: string[] = [];
    const roles = asStringArray(row.roles); if (roles.length > 0) partsPush(parts, `Roles: ${roles.join(", ")}`);
    const goals = asStringArray(row.goals); if (goals.length > 0) partsPush(parts, `Goals: ${goals.join(", ")}`);
    const preferences = asStringArray(row.preferences); if (preferences.length > 0) partsPush(parts, `Preferences: ${preferences.join(", ")}`);
    const resources = asStringArray(row.resources); if (resources.length > 0) partsPush(parts, `Resources: ${resources.join(", ")}`);
    const failurePatterns = asStringArray(row.failurePatterns); if (failurePatterns.length > 0) partsPush(parts, `Failure patterns: ${failurePatterns.join(", ")}`);
    const fears = asStringArray(row.fears); if (fears.length > 0) partsPush(parts, `Fears: ${fears.join(", ")}`);
    const flaws = asStringArray(row.flaws); if (flaws.length > 0) partsPush(parts, `Flaws: ${flaws.join(", ")}`);
    const secrets = asStringArray(row.secrets); if (secrets.length > 0) partsPush(parts, `Secrets: ${secrets.join(", ")}`);
    const wounds = asStringArray(row.wounds); if (wounds.length > 0) partsPush(parts, `Wounds: ${wounds.join(", ")}`);
    const contradictions = asStringArray(row.contradictions); if (contradictions.length > 0) partsPush(parts, `Contradictions: ${contradictions.join(", ")}`);
    const needs = asStringArray(row.needs); if (needs.length > 0) partsPush(parts, `Needs: ${needs.join(", ")}`);
    const obsessions = asStringArray(row.obsessions); if (obsessions.length > 0) partsPush(parts, `Obsessions: ${obsessions.join(", ")}`);
    const attachments = asStringArray(row.attachments); if (attachments.length > 0) partsPush(parts, `Attachments: ${attachments.join(", ")}`);
    const notes = asString(row.notes); if (notes) partsPush(parts, `Notes: ${notes}`);
    const instructionBias = asString(row.instructionBias); if (instructionBias) partsPush(parts, `Instruction bias: ${instructionBias}`);
    const selfDeceptions = asStringArray(row.selfDeceptions); if (selfDeceptions.length > 0) partsPush(parts, `Self-deceptions: ${selfDeceptions.join(", ")}`);
    const identityConflicts = asStringArray(row.identityConflicts); if (identityConflicts.length > 0) partsPush(parts, `Identity conflicts: ${identityConflicts.join(", ")}`);
    const moralLines = asStringArray(row.moralLines); if (moralLines.length > 0) partsPush(parts, `Moral lines: ${moralLines.join(", ")}`);
    const breakingPoints = asStringArray(row.breakingPoints); if (breakingPoints.length > 0) partsPush(parts, `Breaking points: ${breakingPoints.join(", ")}`);
    const virtues = asStringArray(row.virtues); if (virtues.length > 0) partsPush(parts, `Virtues: ${virtues.join(", ")}`);
    const publicMask = asString(row.publicMask); if (publicMask) partsPush(parts, `Public mask: ${publicMask}`);
    const privateLogic = asString(row.privateLogic); if (privateLogic) partsPush(parts, `Private logic: ${privateLogic}`);
    const speechStyle = asString(row.speechStyle); if (speechStyle) partsPush(parts, `Speech style: ${speechStyle}`);
    const arcStart = asString(row.arcStart); if (arcStart) partsPush(parts, `Arc start: ${arcStart}`);
    const arcEnd = asString(row.arcEnd); if (arcEnd) partsPush(parts, `Arc end: ${arcEnd}`);
    const coreLie = asString(row.coreLie); if (coreLie) partsPush(parts, `Core lie: ${coreLie}`);
    const coreTruth = asString(row.coreTruth); if (coreTruth) partsPush(parts, `Core truth: ${coreTruth}`);
    const reputation = asString(row.reputation); if (reputation) partsPush(parts, `Reputation: ${reputation}`);
    const status = asString(row.status); if (status) partsPush(parts, `Status: ${status}`);
    return {
      label: label || "Character",
      description: parts.length > 0 ? parts.join(" ") : "Character with no authored content supplied",
    };
  };

  const relationshipText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.name);
    const parts: string[] = [];
    const relationshipType = asString(row.relationshipType); if (relationshipType) partsPush(parts, `Type: ${relationshipType}`);
    const tension = asString(row.tension); if (tension) partsPush(parts, `Tension: ${tension}`);
    const loyalty = asString(row.loyalty); if (loyalty) partsPush(parts, `Loyalty: ${loyalty}`);
    const fear = asString(row.fear); if (fear) partsPush(parts, `Fear: ${fear}`);
    const desire = asString(row.desire); if (desire) partsPush(parts, `Desire: ${desire}`);
    const dependency = asString(row.dependency); if (dependency) partsPush(parts, `Dependency: ${dependency}`);
    const history = asString(row.history); if (history) partsPush(parts, `History: ${history}`);
    const powerBalance = asString(row.powerBalance); if (powerBalance) partsPush(parts, `Power balance: ${powerBalance}`);
    const resentment = asString(row.resentment); if (resentment) partsPush(parts, `Resentment: ${resentment}`);
    const misunderstanding = asString(row.misunderstanding); if (misunderstanding) partsPush(parts, `Misunderstanding: ${misunderstanding}`);
    const unspokenTruth = asString(row.unspokenTruth); if (unspokenTruth) partsPush(parts, `Unspoken truth: ${unspokenTruth}`);
    const whatEachWantsFromTheOther = asString(row.whatEachWantsFromTheOther); if (whatEachWantsFromTheOther) partsPush(parts, `What each wants from the other: ${whatEachWantsFromTheOther}`);
    const whatWouldBreakIt = asString(row.whatWouldBreakIt); if (whatWouldBreakIt) partsPush(parts, `What would break it: ${whatWouldBreakIt}`);
    const whatWouldTransformIt = asString(row.whatWouldTransformIt); if (whatWouldTransformIt) partsPush(parts, `What would transform it: ${whatWouldTransformIt}`);
    const notes = asString(row.notes); if (notes) partsPush(parts, notes);
    return {
      label: label || "Relationship",
      description: parts.length > 0 ? parts.join(" ") : "Relationship with no authored content supplied",
    };
  };

  const themeText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.question);
    const parts: string[] = [];
    const coreTension = asString(row.coreTension); if (coreTension) partsPush(parts, `Core tension: ${coreTension}`);
    const valueConflict = asString(row.valueConflict); if (valueConflict) partsPush(parts, `Value conflict: ${valueConflict}`);
    const moralFaultLine = asString(row.moralFaultLine); if (moralFaultLine) partsPush(parts, `Moral fault line: ${moralFaultLine}`);
    const endingTruth = asString(row.endingTruth); if (endingTruth) partsPush(parts, `Ending truth: ${endingTruth}`);
    const notes = asString(row.notes); if (notes) partsPush(parts, notes);
    return {
      label: label || "Theme Question",
      description: parts.length > 0 ? parts.join(" ") : "Theme question with no authored content supplied",
    };
  };

  const motifText = (row: Record<string, unknown>): { label: string; description: string } => {
    const label = asString(row.label);
    const parts: string[] = [];
    const category = asString(row.category); if (category) partsPush(parts, `Category: ${category}`);
    const meaning = asString(row.meaning); if (meaning) partsPush(parts, `Meaning: ${meaning}`);
    const examples = asStringArray(row.examples); if (examples.length > 0) partsPush(parts, `Examples: ${examples.join(", ")}`);
    const notes = asString(row.notes); if (notes) partsPush(parts, `Notes: ${notes}`);
    return {
      label: label || "Motif",
      description: parts.length > 0 ? parts.join(" ") : "Motif with no authored content supplied",
    };
  };

  // Inline helper: only push non-empty fragments so description strings
  // stay deterministic. Append a period when the value doesn't already end
  // in terminal punctuation so joined output reads like a sequence of
  // sentences (e.g. "Roles: detective. Notes: Disgraced detective ...")
  // without doubling punctuation when the source text already ends a
  // sentence.
  const partsPush = (parts: string[], value: string): void => {
    if (!value) return;
    parts.push(/[.!?]$/.test(value) ? value : value + ".");
  };

  const handleFor = (prefix: string, row: Record<string, unknown>, index: number): string | null => {
    const id = typeof row.id === "string" && row.id.trim()
      ? row.id.trim()
      : `${prefix}-${index + 1}`;
    const handle = `${prefix}:${id}`;
    // Skip rows whose id does not appear in the canonical handle set —
    // recipeMaterialHandles is the single authority for handle strings.
    // For canonical recipes every row produces a handle; this guard covers
    // legacy/sparse recipes with malformed rows.
    return handles.has(handle) ? handle : null;
  };

  // characters: character:<id> → characters[i]. Reads canonical
  // CharacterPayload fields (name + roles/goals/fears/flaws/etc.). The
  // previous `pickStr(rowObj, "summary", "description")` produced an empty
  // description for canonical rows — CharacterPayload has neither field —
  // which collapsed to the handle and tripped the validator.
  const characters: StoryMaterialItem[] = [];
  if (Array.isArray(r.selectedCharacters)) {
    r.selectedCharacters.forEach((row, index) => {
      if (!row || typeof row !== "object") return;
      const rowObj = row as Record<string, unknown>;
      const handle = handleFor("character", rowObj, index);
      if (!handle) return;
      const text = characterText(rowObj);
      characters.push(itemFromHandle(handle, text.label, text.description));
    });
  }

  // relationships: relationship:<id> → relationships[i]. Reads canonical
  // RelationshipPayload fields (name + relationshipType + tension/loyalty/
  // fear/desire/dependency/history/powerBalance/etc.).
  const relationships: StoryMaterialItem[] = [];
  if (Array.isArray(r.selectedRelationships)) {
    r.selectedRelationships.forEach((row, index) => {
      if (!row || typeof row !== "object") return;
      const rowObj = row as Record<string, unknown>;
      const handle = handleFor("relationship", rowObj, index);
      if (!handle) return;
      const text = relationshipText(rowObj);
      relationships.push(itemFromHandle(handle, text.label, text.description));
    });
  }

  // thematicPressures: theme:<id> + motif:<id> (no dedicated motif category)
  const thematicPressures: StoryMaterialItem[] = [];
  if (Array.isArray(r.selectedThemeQuestions)) {
    r.selectedThemeQuestions.forEach((row, index) => {
      if (typeof row === "string") return; // recipeMaterialHandles skips strings; match.
      if (!row || typeof row !== "object") return;
      const rowObj = row as Record<string, unknown>;
      const handle = handleFor("theme", rowObj, index);
      if (!handle) return;
      const text = themeText(rowObj);
      thematicPressures.push(itemFromHandle(handle, text.label, text.description));
    });
  }
  if (Array.isArray(r.selectedMotifs)) {
    r.selectedMotifs.forEach((row, index) => {
      if (typeof row === "string") return; // recipeMaterialHandles skips strings; match.
      if (!row || typeof row !== "object") return;
      const rowObj = row as Record<string, unknown>;
      const handle = handleFor("motif", rowObj, index);
      if (!handle) return;
      const text = motifText(rowObj);
      thematicPressures.push(itemFromHandle(handle, text.label, text.description));
    });
  }

  // discoveries: project.summary → discoveries[0]
  const discoveries: StoryMaterialItem[] = [];
  if (handles.has("project.summary") && r.project && typeof r.project.summary === "string" && r.project.summary.trim()) {
    discoveries.push(itemFromHandle("project.summary", "Project Premise", r.project.summary.trim()));
  }

  // antagonisticForces: storySpark → antagonisticForces[0] (single object).
  // Reads canonical StorySparkPayload fields (title + situation/stakes/twist/
  // urgency/threat/opportunity/complication/clock/triggerEvent/etc.).
  const antagonisticForces: StoryMaterialItem[] = [];
  if (handles.has("storySpark") && r.selectedStorySpark && typeof r.selectedStorySpark === "object") {
    const spark = r.selectedStorySpark as Record<string, unknown>;
    const text = storySparkText(spark);
    antagonisticForces.push(itemFromHandle("storySpark", text.label, text.description));
  }

  // unresolvedQuestions: aftertaste → unresolvedQuestions[0] (single object).
  // Reads canonical AftertastePayload fields (label + note/emotionalResidue/
  // endingTexture/desiredAmbiguityLevel/readerQuestionLeftOpen/lastImageFeeling).
  const unresolvedQuestions: StoryMaterialItem[] = [];
  if (handles.has("aftertaste") && r.selectedAftertaste && typeof r.selectedAftertaste === "object") {
    const a = r.selectedAftertaste as Record<string, unknown>;
    const text = aftertasteText(a);
    unresolvedQuestions.push(itemFromHandle("aftertaste", text.label, text.description));
  }

  const material: StoryMaterialEnrichment = {
    schema: "cathedralos.story_material_enrichment",
    version: 2,
    format,
    rationale:
      "Recovered from canonical recipe handles; legacy run pre-dates story-material provenance (PR8 of the recipe-to-acceptance recovery arc).",
    characters,
    antagonisticForces,
    locations: [],
    institutionsAndGroups: [],
    conflictSources: [],
    escalationLadder: [],
    reversals: [],
    consequences: [],
    relationships,
    discoveries,
    unresolvedQuestions,
    thematicPressures,
    sourceRecipeHash: provenance.sourceRecipeHash,
    sourceRecipeVersion: provenance.sourceRecipeVersion,
    sourcePromptPackID: provenance.sourcePromptPackID,
    sourcePromptPackName: provenance.sourcePromptPackName,
  };

  // Self-validate: throw if the structural contract is violated. Call sites
  // run storyMaterialSufficiency on the returned material and fail closed
  // when the canonical recipe cannot satisfy sufficiency.
  validateStoryMaterialEnrichment(material, { recipe: r });
  return material;
}

/**
 * Merge deterministic canonical recipe material into a provider response.
 *
 * The provider is allowed to invent planner material, but it is not allowed
 * to erase authored recipe material. A model can satisfy the JSON schema while
 * omitting every source=recipe item, which later fails novel sufficiency with
 * the unhelpful "no canonical recipe material was preserved" error. The
 * server already knows the canonical handles, so repair that omission before
 * evaluating sufficiency. Sparse recipes still fail closed if the merged
 * package cannot meet the format contract.
 */
function dedupeMaterialBySourceReference<T extends { id: string; source?: string; sourceReference?: string | null }>(items: T[]): T[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    const key = item.source === "recipe" && item.sourceReference
      ? `recipe:${item.sourceReference}`
      : `planner:${item.id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function mergeCanonicalRecipeMaterial(
  candidate: StoryMaterialEnrichment,
  recipe: CanonicalRecipeEnvelope,
  provenance: StoryMaterialProvenance,
  format: StoryMaterialFormat,
): StoryMaterialEnrichment {
  const canonical = repairStoryMaterialFromRecipe(recipe, provenance, format);
  const canonicalIDs = new Set(
    STORY_MATERIAL_CATEGORIES.flatMap((category) => (canonical[category] as StoryMaterialItem[]).map((item) => item.id)),
  );
  const merged = { ...candidate, ...provenance, version: 2, format } as StoryMaterialEnrichment;

  for (const category of STORY_MATERIAL_CATEGORIES) {
    const existing = (candidate[category] as StoryMaterialItem[]).filter((item) => !canonicalIDs.has(item.id));
    const canonicalItems = (canonical[category] as StoryMaterialItem[]).filter((item) => item.source === "recipe");
    (merged[category] as StoryMaterialItem[]) = dedupeMaterialBySourceReference([
      ...existing,
      ...canonicalItems,
    ]);
  }

  validateStoryMaterialEnrichment(merged, { recipe });
  return merged;
}

/**
 * PR8 (revised): resume story material from a claimed run, repairing it
 * via the live canonical recipe if it fails validation or sufficiency.
 *
 * The helper PERSISTS the (possibly repaired) material and the repair
 * audit fields BEFORE returning, so a downstream expandNovel failure or
 * worker interruption cannot lose the completed repair. On the next
 * resume, the persisted material validates cleanly and this helper
 * returns the same material with audit=null — no second repair attempt,
 * no second persist.
 *
 * Pure (no Deno.serve, no global DB), dependency-injected `updateRun`,
 * fully unit-testable.
 */
export async function resumeOrRepairStoryMaterial(options: {
  claimedMaterial: unknown;
  recipe: CanonicalRecipeEnvelope;
  provenance: StoryMaterialProvenance;
  format: StoryMaterialFormat;
  updateRun: (patch: Record<string, unknown>) => Promise<unknown>;
}): Promise<{ material: StoryMaterialEnrichment; audit: Record<string, unknown> | null }> {
  let material: StoryMaterialEnrichment;
  let priorCompatibility: boolean | undefined;
  let priorSufficiency: boolean | undefined;
  let priorValidationError: string | undefined;
  let audit: Record<string, unknown> | null = null;

  try {
    material = validateStoryMaterialEnrichment(options.claimedMaterial, { recipe: options.recipe });
    priorCompatibility = isCompatibleStoryMaterialEnrichment(material, options.provenance, options.format);
    const sufficiency = storyMaterialSufficiency(material, options.recipe, options.format);
    priorSufficiency = sufficiency.sufficient;
  } catch (error) {
    // Persisted material failed structural validation (legacy shape, wrong
    // schema/version, or duplicate ids). Treat as incompatible; the repair
    // block below assigns material.
    priorValidationError = error instanceof Error ? error.message : "validation_failed";
    priorCompatibility = false;
    priorSufficiency = false;
    material = repairStoryMaterialFromRecipe(options.recipe, options.provenance, options.format);
  }

  if (priorCompatibility === false || priorSufficiency === false) {
    // PR8 (revised): repair via canonical recipe handles.
    // repairStoryMaterialFromRecipe self-validates and throws on structural
    // failure; this block also runs sufficiency on the repair output and
    // fails closed if the canonical recipe cannot supply enough material.
    const repairSufficiency = storyMaterialSufficiency(material, options.recipe, options.format);
    if (!repairSufficiency.sufficient) {
      // Fail closed: do NOT persist anything if the repair cannot satisfy
      // sufficiency. Throwing here keeps the run row in its pre-repair
      // state; the next resume will retry with the same recipe
      // (deterministic) and we do not leak a partial repair.
      throw new StoryMaterialSufficiencyError(repairSufficiency.reasons);
    }
    audit = {
      repairedAt: new Date().toISOString(),
      repairedFromRecipeHash: options.provenance.sourceRecipeHash,
      priorCompatibility,
      priorSufficiency,
      priorValidationError,
      repairSufficiencyRecipeDerivedItemCount: repairSufficiency.recipeDerivedItemCount,
      repairSufficiencyPlannerInventedItemCount: repairSufficiency.plannerInventedItemCount,
      repairSufficiencyCounts: repairSufficiency.counts,
    };
    // Persist the repaired material + audit BEFORE returning so a
    // downstream expandNovel failure or worker interruption cannot lose
    // the completed repair. The next resume will validate this persisted
    // material and skip the repair block above (no second persist).
    await options.updateRun({
      story_material: material,
      diagnostics: { storyMaterialRepair: audit, stage: "story_material_repaired" },
    });
  }

  return { material, audit };
}

export function recoverablePlanningModelID(
  requestJSON: unknown,
  recoveredProviderModel?: unknown,
): string | undefined {
  const requestModel = requestJSON && typeof requestJSON === "object"
    ? (requestJSON as Record<string, unknown>).modelID
    : undefined;
  if (typeof requestModel === "string" && requestModel.trim()) {
    return requestModel.trim();
  }
  if (typeof recoveredProviderModel === "string" && recoveredProviderModel.trim()) {
    return recoveredProviderModel.trim();
  }
  // There is no safe universal fallback for historical jobs. A legacy row
  // without a model and without a provider attempt must fail closed rather
  // than silently becoming a newer model.
  return undefined;
}

export function canonicalizeNewPlanningRequest(
  body: OutlineFromRecipeRequest,
): OutlineFromRecipeRequest {
  // Suggest Sections is intentionally Luna Fast. Ignore stale client model
  // preferences so an older app cannot route planner work to GPT-5.4 mini.
  return { ...body, modelID: LEGACY_PLANNING_MODEL_ID };
}

export function isLegacyPlanningRequest(requestJSON: unknown): boolean {
  return !(requestJSON && typeof requestJSON === "object" &&
    typeof (requestJSON as Record<string, unknown>).modelID === "string" &&
    ((requestJSON as Record<string, unknown>).modelID as string).trim());
}

export interface PlanningIdentityResolution {
  canonicalBody: OutlineFromRecipeRequest;
  rawIdentity: { key: string; fingerprint: string };
  canonicalIdentity: { key: string; fingerprint: string };
  identity: { key: string; fingerprint: string };
  lookupKeys: string[];
  acceptedFingerprints: Set<string>;
}

export async function resolvePlanningRequestIdentity(
  body: OutlineFromRecipeRequest,
  existing?: { request_json?: unknown } | null,
): Promise<PlanningIdentityResolution> {
  const canonicalBody = canonicalizeNewPlanningRequest(body);
  const rawIdentity = await logicalSuggestionIdentity(body);
  const canonicalIdentity = await logicalSuggestionIdentity(canonicalBody);
  const persistedModelID = existing
    ? recoverablePlanningModelID(existing.request_json)
    : undefined;
  const reconnectIdentity = body.modelID === undefined && persistedModelID
    ? await logicalSuggestionIdentity({ ...body, modelID: persistedModelID })
    : null;
  const identity = reconnectIdentity ?? canonicalIdentity;
  const acceptedFingerprints = new Set([
    body.modelID === undefined ? rawIdentity.fingerprint : canonicalIdentity.fingerprint,
    ...(reconnectIdentity ? [reconnectIdentity.fingerprint] : []),
  ]);
  return {
    canonicalBody,
    rawIdentity,
    canonicalIdentity,
    identity,
    lookupKeys: Array.from(new Set([rawIdentity.key, canonicalIdentity.key])),
    acceptedFingerprints,
  };
}

/**
 * Rebuild the worker body from the durable run, never from a reconnect's
 * current preferences. Provider attempts are the only older durable record
 * of the model when request_json predates modelID.
 */
export async function recoverPersistedPlanningBody(
  db: any,
  run: { id: string; request_json?: unknown },
): Promise<OutlineFromRecipeRequest> {
  const stored = run.request_json && typeof run.request_json === "object"
    ? { ...(run.request_json as Record<string, unknown>) }
    : {};
  let recoveredProviderModel: string | undefined;
  if (isLegacyPlanningRequest(stored)) {
    const attempt = await db.from("generation_provider_attempts")
      .select("model_name")
      .eq("feature_run_id", run.id)
      .order("started_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    recoveredProviderModel = typeof attempt?.data?.model_name === "string"
      ? attempt.data.model_name
      : undefined;
  }
  const recoveredModel = recoverablePlanningModelID(
    stored,
    recoveredProviderModel,
  );
  if (recoveredModel) {
    if (recoveredProviderModel && recoveredModel === recoveredProviderModel) {
      // Map the recorded provider name to the canonical catalog ID without
      // requiring the historical row to remain enabled. The worker will then
      // reject an ineligible row instead of substituting another model.
      const catalog = await db.from("generation_models").select("id")
        .eq("provider", "openai")
        .eq("provider_model", recoveredProviderModel)
        .maybeSingle();
      stored.modelID = typeof catalog?.data?.id === "string"
        ? catalog.data.id
        : recoveredModel;
    } else {
      stored.modelID = recoveredModel;
    }
  }
  return stored as unknown as OutlineFromRecipeRequest;
}

export function validateRequest(req: unknown): string | null {
  if (!req || typeof req !== "object") return "request must be an object";
  const r = req as Partial<OutlineFromRecipeRequest>;
  const recipe = r.recipe;
  if (!recipe || typeof recipe !== "object") {
    return "canonical recipe payload required";
  }
  if (recipe.schema !== CANONICAL_RECIPE_SCHEMA) {
    return `recipe.schema must be ${CANONICAL_RECIPE_SCHEMA}`;
  }
  if (
    !recipe.project || typeof recipe.project.id !== "string" ||
    recipe.project.id.trim() === ""
  ) {
    return "recipe.project.id required";
  }
  if (
    !recipe.promptPack || typeof recipe.promptPack.id !== "string" ||
    recipe.promptPack.id.trim() === "" ||
    typeof recipe.promptPack.name !== "string" ||
    recipe.promptPack.name.trim() === ""
  ) {
    return "recipe.promptPack.id and recipe.promptPack.name required";
  }
  if (
    !r.arcTemplate || typeof r.arcTemplate.id !== "string" ||
    r.arcTemplate.id.trim() === "" || !Array.isArray(r.arcTemplate.beats) ||
    r.arcTemplate.beats.length === 0
  ) {
    return "arcTemplate.id and non-empty arcTemplate.beats required";
  }
  for (const field of [
    "selectedCharacters",
    "selectedRelationships",
    "selectedThemeQuestions",
    "selectedMotifs",
  ] as const) {
    const values = recipe[field];
    if (!Array.isArray(values)) return `recipe.${field} must be an array`;
    if (values.some((value) => !value || typeof value !== "object" || Array.isArray(value))) {
      return `recipe.${field} contains a missing or invalid selected entity`;
    }
  }
  if (r.requestedFormat !== undefined && !["novel", "shortStory", "other"].includes(r.requestedFormat)) return "requestedFormat must be novel, shortStory, or other";
  if (r.modelID !== undefined && (typeof r.modelID !== "string" || r.modelID.trim() === "")) return "modelID must be a non-empty catalog model ID";
  if (r.reasoningEffort !== undefined && !["low", "medium", "high"].includes(r.reasoningEffort as string)) return "reasoningEffort must be low, medium, or high";
  if (
    r.reasoningEffort !== undefined &&
    (typeof r.modelID !== "string" ||
      !["gpt-6-luna", "gpt-6.1-sol", "gpt-6-astra"].includes(r.modelID.trim().toLowerCase()))
  ) return "reasoningEffort is only supported for GPT-6 Luna, GPT-6.1 Sol, or GPT-6 Astra";
  if (r.idempotencyKey !== undefined && (typeof r.idempotencyKey !== "string" || r.idempotencyKey.trim() === "" || r.idempotencyKey.length > 512)) return "idempotencyKey must be a non-empty string of at most 512 characters";
  if (r.storyMaterialEnrichment) {
    try {
      validateStoryMaterialEnrichment(
        normalizeProviderStoryMaterialItemIDs(
          downgradeUnverifiedProviderRecipeReferences(r.storyMaterialEnrichment, r.recipe as CanonicalRecipeEnvelope),
        ),
        { allowMissingProvenance: true },
      );
    } catch (error) {
      return error instanceof Error ? error.message : "invalid story material enrichment";
    }
  }
  if (
    r.arcTemplate.beats.some((beat) =>
      !beat || typeof beat.id !== "string" || beat.id.trim() === ""
    )
  ) {
    return "arcTemplate.beats must have non-empty ids";
  }
  // PR 4: format-level check for canonical identity fields. The actual
  // ownership/lineage validation runs in the POST handler with a DB lookup,
  // pre-billable, because validateRequest is pure.
  if (r.outline_id !== undefined) {
    if (typeof r.outline_id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(r.outline_id)) {
      return "outline_id must be a UUID string when present";
    }
  }
  if (r.project_lineage_id !== undefined) {
    if (typeof r.project_lineage_id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(r.project_lineage_id)) {
      return "project_lineage_id must be a UUID string when present";
    }
  }
  return null;
}

export function projectedTokenRange(suggestions: Array<{ container: string }>): [number, number] {
  return suggestions.reduce<[number, number]>((range, suggestion) => {
    const [min, max] = CONTAINER_EXPECTED_RANGES[suggestion.container] ?? [800, 1800];
    return [range[0] + min, range[1] + max];
  }, [0, 0]);
}

export type PlannedSectionLike = { container?: string | null };

export function projectedExpectedTokens(suggestions: PlannedSectionLike[]): number {
  return suggestions.reduce((total, suggestion) => {
    const [min, max] = CONTAINER_EXPECTED_RANGES[suggestion.container ?? ""] ?? [800, 1800];
    return total + (min + max) / 2;
  }, 0);
}

export interface NovelScaleEvaluation {
  projectedTokens: number;
  projectedWords: number;
  minimumWords: number;
  preferredMinimumWords: number;
  maximumWords: number;
  deficitTokens: number;
  meetsMinimum: boolean;
  meetsPreferredMinimum: boolean;
  exceedsMaximum: boolean;
}

/**
 * The single authoritative novel-scale evaluator. It evaluates the complete
 * planned outline: persisted/accepted sections plus newly generated delta.
 * Every planning and terminal completion decision must use this result rather
 * than section-count guesses.
 */
export function evaluateNovelScale(
  suggestions: PlannedSectionLike[],
  existingSections: PlannedSectionLike[] = [],
): NovelScaleEvaluation {
  const projectedTokens = projectedExpectedTokens([...existingSections, ...suggestions]);
  const deficitTokens = Math.max(0, NOVEL_MIN_PROJECTED_TOKENS - projectedTokens);
  return {
    projectedTokens,
    projectedWords: projectedTokens / TOKENS_PER_WORD,
    minimumWords: NOVEL_PREFERRED_MIN_WORDS,
    preferredMinimumWords: NOVEL_PREFERRED_MIN_WORDS,
    maximumWords: NOVEL_MAX_WORDS,
    deficitTokens,
    meetsMinimum: deficitTokens === 0,
    meetsPreferredMinimum: projectedTokens / TOKENS_PER_WORD >= NOVEL_PREFERRED_MIN_WORDS,
    exceedsMaximum: projectedTokens > NOVEL_ACCEPTED_MAX_PROJECTED_TOKENS,
  };
}

export function needsNovelExpansion(
  suggestions: PlannedSectionLike[],
  existingSections: PlannedSectionLike[] = [],
): boolean {
  return evaluateNovelScale(suggestions, existingSections).projectedWords < NOVEL_EXPANSION_MIN_WORDS;
}

const EXPANSION_SCHEMA = {
  type: "object",
  properties: {
    suggestions: {
      // Beat-local passes may legitimately have no distinct material to add.
      type: "array", minItems: 0, maxItems: MAX_PLANNED_SECTIONS,
      items: {
        type: "object", additionalProperties: false,
        properties: {
          title: { type: "string", minLength: 1, maxLength: 120 },
          summary: { type: "string", minLength: 1, maxLength: 2000 },
          container: { type: "string", enum: ["beat", "moment", "vignette", "microScene", "scene", "developedScene", "setPiece", "sceneSequence", "shortStory", "chapter", "episode"] },
          pov: { type: "string", enum: ["firstPerson", "secondPerson", "thirdPersonLimited", "thirdPersonOmniscient"] },
          terminalBeat: { type: "string", minLength: 1, maxLength: 500, description: "The concrete closing dramatic action or moment of this added section; never a Story Arc ID, beat label, or END." },
          entryState: { type: "string", minLength: 1, maxLength: 1200 },
          dramaticEvent: { type: "string", minLength: 1, maxLength: 2000 },
          resultingChange: { type: "string", minLength: 1, maxLength: 1200 },
          terminalState: { type: "string", minLength: 1, maxLength: 1200 },
          dramaticFunction: { type: "string", enum: DRAMATIC_FUNCTIONS },
          arcObligationEvidence: { type: "object", additionalProperties: { type: "array", items: { type: "object", properties: { field: { type: "string", enum: ["dramaticEvent", "resultingChange", "terminalState"] }, quote: { type: "string", minLength: 1, maxLength: 1200 } }, required: ["field", "quote"], additionalProperties: false } } },
          storyArcBeatID: { type: "string" },
          insertAfterTitle: { type: ["string", "null"] },
          recipeRequirementIDs: { type: "array", minItems: 0, maxItems: 50, items: { type: "string", minLength: 1 } },
        },
        required: ["title", "summary", "container", "pov", "terminalBeat", "entryState", "dramaticEvent", "resultingChange", "terminalState", "dramaticFunction", "storyArcBeatID", "insertAfterTitle", "recipeRequirementIDs"],
      },
    },
  },
  required: ["suggestions"], additionalProperties: false,
} as const;

/** Beat-local expansion uses the same server-owned contract as first-pass generation. */
export function buildExpansionResponseSchema(
  contract?: ArcRoleContract,
  requestedFormat: StoryMaterialFormat = "other",
  obligations: RecipeObligation[] = [],
) {
  const dramaticFunction = contract?.allowedFunctions ?? [...DRAMATIC_FUNCTIONS];
  const allowedContainers = requestedFormat === "novel" ? [...NOVEL_LEAF_CONTAINERS] : EXPANSION_SCHEMA.properties.suggestions.items.properties.container.enum;
  const recipeRequirementIDs = obligations.length > 0
    ? {
      ...EXPANSION_SCHEMA.properties.suggestions.items.properties.recipeRequirementIDs,
      items: {
        type: "string",
        minLength: 1,
        enum: obligations.map((obligation) => obligation.id),
      },
    }
    : EXPANSION_SCHEMA.properties.suggestions.items.properties.recipeRequirementIDs;
  const { arcObligationEvidence: _ignoredExpansionEvidence, ...expansionProperties } =
    EXPANSION_SCHEMA.properties.suggestions.items.properties;
  return {
    ...EXPANSION_SCHEMA,
    properties: {
      suggestions: {
        ...EXPANSION_SCHEMA.properties.suggestions,
        items: {
          ...EXPANSION_SCHEMA.properties.suggestions.items,
          properties: {
            ...expansionProperties,
            dramaticFunction: { type: "string", enum: dramaticFunction },
            container: { type: "string", enum: allowedContainers },
            recipeRequirementIDs,
          },
          required: EXPANSION_SCHEMA.properties.suggestions.items.required,
        },
      },
    },
  };
}

export type ExpansionAddition = Suggestion & { insertAfterTitle: string | null };

export interface ExpansionAttemptDiagnostic {
  beatID?: string;
  round: number;
  sectionCountBefore: number;
  projectedTokensBefore: number;
  returnedCount: number;
  acceptedCount?: number;
  rejectedCount?: number;
  candidateTitles: string[];
  candidateContainers: string[];
  projectedTokensAfter: number;
  status: "accepted" | "rejected";
  budgetTruncated?: boolean;
  error?: string;
}

export class ExpansionValidationError extends Error {
  readonly attempt?: ExpansionAttemptDiagnostic;

  constructor(message: string, attempt?: ExpansionAttemptDiagnostic) {
    super(message);
    this.name = "ExpansionValidationError";
    this.attempt = attempt;
  }
}

export function fitExpansionAdditionsToBudget(
  current: Suggestion[],
  additions: ExpansionAddition[],
  existingSections: PlannedSectionLike[],
  context: { round: number; beatID?: string },
): { additions: ExpansionAddition[]; attempt: ExpansionAttemptDiagnostic } {
  let accepted: ExpansionAddition[] = [];
  let merged = current;
  for (const addition of additions) {
    const candidate = mergeExpansionAdditions(merged, [addition]);
    if (candidate.length > MAX_PLANNED_SECTIONS || evaluateNovelScale(candidate, existingSections).exceedsMaximum) break;
    accepted = [...accepted, addition];
    merged = candidate;
  }
  const rejectedCount = Math.max(0, additions.length - accepted.length);
  const attempt: ExpansionAttemptDiagnostic = {
    round: context.round,
    beatID: context.beatID,
    sectionCountBefore: current.length,
    projectedTokensBefore: evaluateNovelScale(current, existingSections).projectedTokens,
    returnedCount: additions.length,
    acceptedCount: accepted.length,
    rejectedCount,
    candidateTitles: additions.slice(0, 50).map((addition) => addition.title),
    candidateContainers: additions.slice(0, 50).map((addition) => addition.container),
    projectedTokensAfter: evaluateNovelScale(merged, existingSections).projectedTokens,
    status: accepted.length > 0 ? "accepted" : "rejected",
    ...(rejectedCount > 0 ? {
      budgetTruncated: true,
      error: `budget truncated ${rejectedCount} expansion addition${rejectedCount === 1 ? "" : "s"} at the ${NOVEL_MAX_WORDS.toLocaleString()}-word hard cap`,
    } : {}),
  };
  if (accepted.length === 0 && additions.length > 0) {
    const fullMerged = mergeExpansionAdditions(current, additions);
    const error = fullMerged.length > MAX_PLANNED_SECTIONS
      ? `global ${MAX_PLANNED_SECTIONS}-section safety cap reached`
      : `projected novel scale exceeded ${NOVEL_MAX_WORDS.toLocaleString()}-word hard cap`;
    throw new ExpansionValidationError(error, {
      ...attempt,
      rejectedCount: additions.length,
      projectedTokensAfter: evaluateNovelScale(fullMerged, existingSections).projectedTokens,
      error,
    });
  }
  return { additions: accepted, attempt };
}

export type NovelPlanningFailureCode = "failed_under_target" | "failed_over_target" | "failed_expansion";

export class RecipeObligationValidationError extends Error {
  readonly code = "missing_recipe_obligations";
}

const OBLIGATION_REPAIR_SECTION_PROPERTIES = {
  title: { type: "string", minLength: 1, maxLength: 120 },
  summary: { type: "string", minLength: 1, maxLength: 2000 },
  container: { type: "string", enum: ["beat", "moment", "vignette", "microScene", "scene", "developedScene", "setPiece", "sceneSequence", "shortStory", "chapter", "episode"] },
  pov: { type: "string", enum: ["firstPerson", "secondPerson", "thirdPersonLimited", "thirdPersonOmniscient"] },
  terminalBeat: { type: "string", minLength: 1, maxLength: 500, description: "The concrete closing dramatic action or moment of this repaired section; never a Story Arc ID, beat label, or END." },
  entryState: { type: "string", minLength: 1, maxLength: 1200 },
  dramaticEvent: { type: "string", minLength: 1, maxLength: 2000 },
  resultingChange: { type: "string", minLength: 1, maxLength: 1200 },
  terminalState: { type: "string", minLength: 1, maxLength: 1200 },
  dramaticFunction: { type: "string", enum: [...DRAMATIC_FUNCTIONS] },
  storyArcBeatID: { type: "string" },
  recipeRequirementIDs: { type: "array", minItems: 1, maxItems: 50, items: { type: "string", minLength: 1 } },
} as const;

export function buildObligationRepairResponseSchema(
  beatIds: Set<string>,
  obligations: RecipeObligation[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
) {
  const allowedFunctions = [...new Set(template.beats.flatMap((beat) => arcRoleContract(beat, template.name).allowedFunctions))];
  return {
    type: "object",
    properties: {
      operations: {
        type: "array",
        minItems: 1,
        maxItems: 3,
        items: {
          type: "object",
          properties: {
            action: { type: "string", enum: ["add", "replace"] },
            replaceIndex: { type: ["integer", "null"], minimum: 0 },
            section: {
              type: "object",
              properties: {
                ...OBLIGATION_REPAIR_SECTION_PROPERTIES,
                dramaticFunction: { type: "string", enum: allowedFunctions },
                storyArcBeatID: { type: "string", enum: [...beatIds] },
                recipeRequirementIDs: {
                  type: "array",
                  minItems: 1,
                  maxItems: 50,
                  items: { type: "string", enum: obligations.map((obligation) => obligation.id) },
                },
              },
              required: Object.keys(OBLIGATION_REPAIR_SECTION_PROPERTIES),
              additionalProperties: false,
            },
          },
          required: ["action", "replaceIndex", "section"],
          additionalProperties: false,
        },
      },
    },
    required: ["operations"],
    additionalProperties: false,
  } as const;
}

export const OBLIGATION_REPAIR_SCHEMA = buildObligationRepairResponseSchema(
  new Set(["beat"]),
  [{ id: "obligation", classification: "required" } as unknown as RecipeObligation],
  { name: "repair", beats: [{ id: "beat", role: "setup", label: "Beat", description: "Beat" }] },
);

export function mergeObligationRepairOperations(
  current: Suggestion[],
  parsed: any,
  beatIds: Set<string>,
  obligations: RecipeObligation[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): Suggestion[] {
  if (!parsed || !Array.isArray(parsed.operations)) throw new RecipeObligationValidationError("missing_recipe_obligations: repair response missing operations");
  const result = current.map((section) => ({ ...section }));
  for (const operation of parsed.operations) {
    const index = operation.action === "replace" ? operation.replaceIndex : -1;
    if (operation.action === "replace" && (!Number.isInteger(index) || index < 0 || index >= result.length)) {
      throw new RecipeObligationValidationError("missing_recipe_obligations: repair target section index out of range");
    }
    if (operation.action === "replace" && operation.section?.storyArcBeatID !== result[index].storyArcBeatID) {
      throw new RecipeObligationValidationError("missing_recipe_obligations: replacement must preserve the target section's story arc beat");
    }
    const validated = validateSuggestions({ suggestions: [operation.section] }, beatIds, undefined, obligations, template).suggestions[0];
    if (!validated) throw new RecipeObligationValidationError("missing_recipe_obligations: repair returned no valid section");
    if (operation.action === "add") {
      if (result.some((section) => section.title === validated.title)) throw new RecipeObligationValidationError("missing_recipe_obligations: repair added duplicate section");
      result.push(validated);
    } else result[index] = validated;
  }
  const normalized = mergeSuggestionsByBeatOrder(template.beats.map((beat) => beat.id), result, []);
  try {
    // Operation sections are obligation-validated individually above. Re-run
    // only the structural contract here because persisted first-pass sections
    // may legitimately carry an omitted/empty recipeRequirementIDs field.
    validateSuggestions({ suggestions: normalized }, beatIds, allocation, [], template);
    return normalized;
  } catch (error) {
    throw new RecipeObligationValidationError(`missing_recipe_obligations: repair violated the structural plan: ${error instanceof Error ? error.message : String(error)}`);
  }
}

export function buildObligationRepairPrompt(req: OutlineFromRecipeRequest, current: Suggestion[], existing: ExistingSectionBlob[], missing: RecipeObligation[]) {
  return {
    system: `${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}\n\nRepair only the missing required recipe obligations. Add one focused section or replace one appropriate section by its zero-based replaceIndex; never delete, move unrelated sections, drop covered obligations, use unknown IDs, replace by title, or violate Story Arc contracts.`,
    user: JSON.stringify({ recipe: req.recipe, arc: req.arcTemplate, existingAcceptedSections: existing, currentSuggestions: current.map((section, replaceIndex) => ({ replaceIndex, section })), missingRequiredObligations: missing }),
  };
}

export async function repairRequiredRecipeObligations(current: Suggestion[], req: OutlineFromRecipeRequest, obligations: RecipeObligation[], billableCall: SuggestionLLMCall, allocation?: Map<string, Allocation>): Promise<{ suggestions: Suggestion[]; missing: RecipeObligation[] }> {
  const before = obligationCoverage([...(req.existingSections ?? []), ...current], obligations);
  if (!before.missingRequired.length) return { suggestions: current, missing: [] };
  const prompt = buildObligationRepairPrompt(req, current, req.existingSections ?? [], before.missingRequired);
  const responseSchema = buildObligationRepairResponseSchema(new Set(req.arcTemplate.beats.map((beat) => beat.id)), obligations, req.arcTemplate);
  const raw = await billableCall(prompt.system, prompt.user, 8000, { type: "json_schema", json_schema: { name: "outline_required_obligation_repair", strict: true, schema: responseSchema } }, "outline-obligation-repair", (content, finishReason) => {
    const repaired = mergeObligationRepairOperations(current, parseOutlineJSON(content, finishReason), new Set(req.arcTemplate.beats.map((beat) => beat.id)), obligations, req.arcTemplate, allocation);
    if (repaired.length > MAX_PLANNED_SECTIONS) throw new RecipeObligationValidationError("missing_recipe_obligations: repair exceeded section safety cap");
    return content;
  });
  const repaired = mergeObligationRepairOperations(current, parseOutlineJSON(raw.content, raw.finishReason), new Set(req.arcTemplate.beats.map((beat) => beat.id)), obligations, req.arcTemplate, allocation);
  return { suggestions: repaired, missing: obligationCoverage([...(req.existingSections ?? []), ...repaired], obligations).missingRequired };
}

export class NovelScalePlanningError extends Error {
  readonly code: NovelPlanningFailureCode;

  constructor(code: NovelPlanningFailureCode, message: string) {
    super(message);
    this.name = "NovelScalePlanningError";
    this.code = code;
  }
}

export interface ExpansionRoundDiagnostic {
  round: number;
  sectionCountBefore: number;
  projectedTokensBefore: number;
  projectedWordsBefore: number;
  additionsReturned: number;
  sectionCountAfter: number;
  projectedTokensAfter: number;
  projectedWordsAfter: number;
  remainingEstimatedDeficitTokens: number;
  status: "completed" | "invalid" | "capped";
  error?: string;
  attempts?: ExpansionAttemptDiagnostic[];
}

export interface ProgressiveExpansionResult {
  suggestions: Suggestion[];
  warnings: string[];
  diagnostics: ExpansionRoundDiagnostic[];
}

export interface ExpansionAdditionsResult {
  additions: ExpansionAddition[];
  attempt?: ExpansionAttemptDiagnostic;
}

export interface ExpansionBeatContext {
  beatID: string;
  beatLabel?: string;
  beatDescription?: string;
  currentSections: Suggestion[];
  projectedTokens: number;
  projectedWords: number;
}

export interface ProgressiveExpansionOptions {
  existingSections?: PlannedSectionLike[];
  startRound?: number;
  startBeatIndex?: number;
  priorDiagnostics?: ExpansionRoundDiagnostic[];
  /** Required structural coverage is a hard gate, not optional quality work. */
  coverageGate?: (suggestions: Suggestion[]) => boolean;
  qualityGate?: (suggestions: Suggestion[]) => boolean;
  beats?: Array<{ id: string; label?: string; description?: string }>;
  onBeat?: (
    round: number,
    nextBeatIndex: number,
    current: Suggestion[],
    diagnostics: ExpansionRoundDiagnostic[],
  ) => Promise<void> | void;
}

export interface ExpansionCheckpoint {
  stage: "expansion";
  nextRound: number;
  nextBeatIndex: number;
  scale: NovelScaleEvaluation;
  expansionRounds: ExpansionRoundDiagnostic[];
}

export function buildExpansionCheckpoint(
  suggestions: Suggestion[],
  existingSections: PlannedSectionLike[],
  expansionRounds: ExpansionRoundDiagnostic[],
  cursor: { nextRound?: number; nextBeatIndex?: number } = {},
): ExpansionCheckpoint {
  const completedRounds = expansionRounds
    .filter((diagnostic) => diagnostic.status === "completed")
    .map((diagnostic) => diagnostic.round);
  const lastCompletedRound = completedRounds.length > 0
    ? Math.max(...completedRounds)
    : 0;
  return {
    stage: "expansion",
    nextRound: cursor.nextRound ?? Math.max(1, lastCompletedRound + 1),
    nextBeatIndex: cursor.nextBeatIndex ?? 0,
    scale: evaluateNovelScale(suggestions, existingSections),
    expansionRounds,
  };
}

export interface ExpansionResumeState {
  suggestions: Suggestion[];
  startRound: number;
  startBeatIndex: number;
  priorDiagnostics: ExpansionRoundDiagnostic[];
}

/**
 * A failed expansion may be resumed after credits are added. The durable
 * expansion checkpoint proves earlier paid stages are complete, so retrying
 * this identity does not replay or double-charge them.
 */
export function isRetryableInsufficientCreditFailure(run: {
  status?: unknown;
  error_code?: unknown;
  credit_cost_charged?: unknown;
  planning_state?: unknown;
}): boolean {
  if (run.status !== "failed" || run.error_code !== "insufficient_credits") return false;
  if (!(Number(run.credit_cost_charged ?? 0) > 0)) return false;
  const planningState = run.planning_state;
  if (!planningState || typeof planningState !== "object" || Array.isArray(planningState)) return false;
  const nextAction = (planningState as { nextAction?: unknown }).nextAction;
  return typeof nextAction === "string" && nextAction.length > 0;
}

export function isRetryableExpansionFailure(run: {
  status?: unknown;
  error_code?: unknown;
  suggestions?: unknown;
  diagnostics?: unknown;
  planning_state?: unknown;
}): boolean {
  const planningState = run.planning_state;
  if (planningState && typeof planningState === "object" &&
      (planningState as { phase?: unknown; nextAction?: unknown }).phase === "failed" &&
      (planningState as { nextAction?: unknown }).nextAction === "allocation-repair-exhausted") return false;
  if (run.diagnostics && typeof run.diagnostics === "object" &&
      (run.diagnostics as { failureStage?: unknown }).failureStage === "allocation_repair_exhausted") return false;
  return run.status === "failed" &&
    (run.error_code === "failed_expansion" || run.error_code === "insufficient_credits") &&
    Array.isArray(run.suggestions) && run.suggestions.length > 0 &&
    expansionResumeState(run) !== null;
}

export function expansionResumeState(run: {
  suggestions?: unknown;
  diagnostics?: unknown;
}): ExpansionResumeState | null {
  if (!Array.isArray(run.suggestions) || !run.diagnostics || typeof run.diagnostics !== "object") return null;
  const checkpoint = (run.diagnostics as { expansionCheckpoint?: unknown }).expansionCheckpoint;
  if (!checkpoint || typeof checkpoint !== "object" || (checkpoint as { stage?: unknown }).stage !== "expansion") return null;
  const rawRounds = (checkpoint as { expansionRounds?: unknown }).expansionRounds;
  const priorDiagnostics = Array.isArray(rawRounds)
    ? rawRounds.filter((diagnostic): diagnostic is ExpansionRoundDiagnostic =>
      Boolean(diagnostic) && typeof diagnostic === "object" &&
      ["completed", "capped"].includes(String((diagnostic as { status?: unknown }).status))
    )
    : [];
  const requestedStartRound = Number((checkpoint as { nextRound?: unknown }).nextRound);
  const startRound = Number.isInteger(requestedStartRound) && requestedStartRound > 0
    ? requestedStartRound
    : Math.max(1, priorDiagnostics.reduce((max, diagnostic) => Math.max(max, diagnostic.round + 1), 1));
  return {
    suggestions: run.suggestions as Suggestion[],
    startRound,
    startBeatIndex: Number.isInteger(Number((checkpoint as { nextBeatIndex?: unknown }).nextBeatIndex))
      ? Math.max(0, Number((checkpoint as { nextBeatIndex?: unknown }).nextBeatIndex))
      : 0,
    priorDiagnostics,
  };
}

export async function progressivelyExpandOutline(
  initial: Suggestion[],
  beatIds: Set<string>,
  expand: (current: Suggestion[], context: ExpansionPromptContext, beat?: ExpansionBeatContext) => Promise<ExpansionAddition[] | ExpansionAdditionsResult>,
  onRound?: (diagnostic: ExpansionRoundDiagnostic, all: ExpansionRoundDiagnostic[], current: Suggestion[]) => Promise<void> | void,
  options: ProgressiveExpansionOptions = {},
): Promise<ProgressiveExpansionResult> {
  let suggestions = [...initial];
  const existingSections = options.existingSections ?? [];
  const diagnostics: ExpansionRoundDiagnostic[] = [...(options.priorDiagnostics ?? [])];
  const warnings: string[] = [];
  const startRound = Math.max(1, options.startRound ?? 1);
  const shouldContinueDevelopment = (current: Suggestion[]) => {
    const scale = evaluateNovelScale(current, existingSections);
    return !scale.exceedsMaximum && (
      needsNovelExpansion(current, existingSections) ||
      options.coverageGate?.(current) === true ||
      options.qualityGate?.(current) === true
    );
  };
  for (let round = startRound; round <= MAX_EXPANSION_ROUNDS && shouldContinueDevelopment(suggestions); round++) {
    const projectedTokensBefore = evaluateNovelScale(suggestions, existingSections).projectedTokens;
    const before: ExpansionPromptContext = {
      round,
      projectedTokens: projectedTokensBefore,
      projectedWords: projectedTokensBefore / TOKENS_PER_WORD,
      desiredWords: NOVEL_TARGET_WORDS,
      remainingDeficitTokens: evaluateNovelScale(suggestions, existingSections).deficitTokens,
    };
    let roundSuggestions = suggestions;
    const roundStartSuggestions = suggestions;
    let additionsReturned = 0;
    let hitCap = false;
    const attempts: ExpansionAttemptDiagnostic[] = [];
    try {
      const targetBeats = options.beats?.length
        ? options.beats
        : [undefined];
      const firstBeatIndex = round === startRound ? Math.max(0, options.startBeatIndex ?? 0) : 0;
      for (let beatIndex = firstBeatIndex; beatIndex < targetBeats.length; beatIndex++) {
        const beat = targetBeats[beatIndex];
        if (!shouldContinueDevelopment(roundSuggestions)) break;
        const beatContext = beat
          ? {
            beatID: beat.id,
            beatLabel: beat.label,
            beatDescription: beat.description,
            currentSections: roundSuggestions.filter((section) => section.storyArcBeatID === beat.id),
            projectedTokens: projectedExpectedTokens(roundSuggestions.filter((section) => section.storyArcBeatID === beat.id)),
            projectedWords: projectedExpectedTokens(roundSuggestions.filter((section) => section.storyArcBeatID === beat.id)) / TOKENS_PER_WORD,
          }
          : undefined;
        const expansionResult = await expand(roundSuggestions, {
          ...before,
          projectedTokens: evaluateNovelScale(roundSuggestions, existingSections).projectedTokens,
          projectedWords: evaluateNovelScale(roundSuggestions, existingSections).projectedWords,
          remainingDeficitTokens: evaluateNovelScale(roundSuggestions, existingSections).deficitTokens,
        }, beatContext);
        const additions = Array.isArray(expansionResult) ? expansionResult : expansionResult.additions;
        if (!Array.isArray(expansionResult) && expansionResult.attempt) attempts.push(expansionResult.attempt);
        if (beatContext && additions.some((addition) => addition.storyArcBeatID !== beatContext.beatID)) {
          throw new ExpansionValidationError(`beat-local expansion returned a section for another beat; expected ${beatContext.beatID}`);
        }
        const merged = mergeExpansionAdditions(roundSuggestions, additions);
        if (merged.length > MAX_PLANNED_SECTIONS || evaluateNovelScale(merged, existingSections).exceedsMaximum) {
          hitCap = true;
          break;
        }
        if (Array.isArray(expansionResult)) attempts.push({
          beatID: beat?.id,
          round,
          sectionCountBefore: roundSuggestions.length,
          projectedTokensBefore: evaluateNovelScale(roundSuggestions, existingSections).projectedTokens,
          returnedCount: additions.length,
          acceptedCount: additions.length,
          candidateTitles: additions.slice(0, 50).map((addition) => addition.title),
          candidateContainers: additions.slice(0, 50).map((addition) => addition.container),
          projectedTokensAfter: evaluateNovelScale(merged, existingSections).projectedTokens,
          status: "accepted",
        });
        roundSuggestions = merged;
        suggestions = roundSuggestions;
        additionsReturned += additions.length;
        await options.onBeat?.(round, beatIndex + 1, roundSuggestions, diagnostics);
      }
      const overCap = hitCap || roundSuggestions.length > MAX_PLANNED_SECTIONS;
      const accepted = overCap ? suggestions : roundSuggestions;
      const projectedTokensAfter = evaluateNovelScale(accepted, existingSections).projectedTokens;
      const diagnostic: ExpansionRoundDiagnostic = {
        round, sectionCountBefore: roundStartSuggestions.length, projectedTokensBefore,
        projectedWordsBefore: projectedTokensBefore / TOKENS_PER_WORD,
        additionsReturned: overCap ? 0 : additionsReturned, sectionCountAfter: accepted.length,
        projectedTokensAfter, projectedWordsAfter: projectedTokensAfter / TOKENS_PER_WORD,
        remainingEstimatedDeficitTokens: evaluateNovelScale(accepted, existingSections).deficitTokens,
        status: overCap || accepted.length >= MAX_PLANNED_SECTIONS ? "capped" : "completed",
        attempts,
        ...(overCap ? { error: `global ${MAX_PLANNED_SECTIONS}-section safety cap reached` } : {}),
      };
      suggestions = accepted;
      diagnostics.push(diagnostic);
      await onRound?.(diagnostic, diagnostics, suggestions);
      if (overCap || roundSuggestions.length >= MAX_PLANNED_SECTIONS) {
        warnings.push(`Outline expansion stopped at the global ${MAX_PLANNED_SECTIONS}-section safety cap.`);
        break;
      }
      if (additionsReturned === 0) break;
    } catch (error) {
      if (!(error instanceof ExpansionValidationError)) throw error;
      const recordedAttempts = [
        ...attempts,
        ...(error.attempt ? [error.attempt] : []),
      ];
      const diagnostic: ExpansionRoundDiagnostic = {
        round, sectionCountBefore: roundStartSuggestions.length, projectedTokensBefore,
        projectedWordsBefore: projectedTokensBefore / TOKENS_PER_WORD,
        additionsReturned: recordedAttempts.reduce((total, attempt) => total + attempt.returnedCount, 0),
        sectionCountAfter: roundSuggestions.length,
        projectedTokensAfter: evaluateNovelScale(roundSuggestions, existingSections).projectedTokens,
        projectedWordsAfter: evaluateNovelScale(roundSuggestions, existingSections).projectedWords,
        remainingEstimatedDeficitTokens: evaluateNovelScale(roundSuggestions, existingSections).deficitTokens,
        status: "invalid", error: error.message.slice(0, 500),
        attempts: recordedAttempts,
      };
      suggestions = roundSuggestions;
      diagnostics.push(diagnostic);
      await onRound?.(diagnostic, diagnostics, suggestions);
      if (!needsNovelExpansion(suggestions, existingSections)) {
        warnings.push("Optional novel expansion was skipped after a validation mismatch; the durable outline is within the 2% length tolerance.");
        break;
      }
      throw new NovelScalePlanningError(
        "failed_expansion",
        `Novel expansion failed validation in round ${round}; the outline remains below the 2% tolerance for the ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word preferred planning target.`,
      );
    }
  }
  const finalScale = evaluateNovelScale(suggestions, existingSections);
  if (needsNovelExpansion(suggestions, existingSections)) {
    throw new NovelScalePlanningError(
      "failed_under_target",
      `Novel outline remains below the 2% tolerance for the ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word preferred planning target after ${diagnostics.length} expansion round${diagnostics.length === 1 ? "" : "s"}.`,
    );
  }
  if (finalScale.exceedsMaximum) {
    throw new NovelScalePlanningError(
      "failed_over_target",
      `Novel outline exceeds the ${NOVEL_ACCEPTED_MAX_WORDS.toLocaleString()}-word accepted ceiling after ${diagnostics.length} expansion round${diagnostics.length === 1 ? "" : "s"}.`,
    );
  }
  return { suggestions, warnings: [...new Set(warnings)], diagnostics };
}


export interface ExpansionPromptContext {
  round: number;
  projectedTokens: number;
  projectedWords: number;
  desiredWords: [number, number];
  remainingDeficitTokens: number;
  beat?: ExpansionBeatContext;
}


export function plannedWordRangeForContainer(container: string): { minWords: number; maxWords: number } {
  const [minTokens, maxTokens] = CONTAINER_EXPECTED_RANGES[container] ?? [800, 1800];
  return {
    minWords: Math.max(1, Math.round(minTokens / TOKENS_PER_WORD)),
    maxWords: Math.max(1, Math.round(maxTokens / TOKENS_PER_WORD)),
  };
}

export function findUnusedStoryMaterial(
  current: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
  materialIDs?: string[],
): StoryMaterialItem[] {
  if (!storyMaterial) return [];
  const usedText = current.map(contractText).join(" ");
  const allowed = materialIDs ? new Set(materialIDs) : null;
  return STORY_MATERIAL_CATEGORIES.flatMap((category) => storyMaterial[category])
    .filter((item) => {
      if (allowed && !allowed.has(item.id)) return false;
      const labelTokens = contentTokens(item.label);
      if (labelTokens.size === 0) return true;
      return !Array.from(labelTokens).some((token) => usedText.includes(token));
    });
}

export function buildExpansionPrompt(
  req: OutlineFromRecipeRequest,
  current: Suggestion[],
  context?: ExpansionPromptContext,
  obligations: RecipeObligation[] = [],
): { system: string; user: string } {
  const projectedTokens = context?.projectedTokens ?? projectedExpectedTokens(current);
  const projectedWords = context?.projectedWords ?? projectedTokens / TOKENS_PER_WORD;
  const remainingDeficitTokens = context?.remainingDeficitTokens ?? Math.max(
    0,
    NOVEL_MIN_PROJECTED_TOKENS - projectedTokens,
  );
  const round = context?.round ?? 1;
  // Expansion must use the SAME author-first candidate boundary as the
  // initial outline; an unused optional escalation ladder is not a license
  // to write new procedural scenes to fill the length budget.
  const allowedCandidateIDs = new Set(authorFirstMaterialIndex(req.storyMaterialEnrichment).map(
    (item) => String(item.id ?? ""),
  ));
  const unusedStoryMaterial = findUnusedStoryMaterial(
    current,
    req.storyMaterialEnrichment,
  ).filter((item) => allowedCandidateIDs.has(item.id));
  const beatContext = context?.beat;
  const targetBeat = beatContext ? req.arcTemplate.beats.find((beat) => beat.id === beatContext.beatID) : undefined;
  const targetContract = targetBeat ? arcRoleContract(targetBeat, req.arcTemplate.name) : undefined;
  const unsatisfiedRequiredFunctions = targetContract?.requiredFunctions.filter((required) => !beatContext?.currentSections.some((section) => section.dramaticFunction === required)) ?? [];
  const semanticContract = targetContract
    ? `Authoritative semantic contract for this beat: allowedFunctions=${targetContract.allowedFunctions.join(", ")}; requiredFunctionsStillUnsatisfied=${unsatisfiedRequiredFunctions.join(", ") || "none"}; forbidsNewPrimaryConflict=${targetContract.forbidsNewPrimaryConflict}; allowsMajorEscalation=${targetContract.allowsMajorEscalation}; closureExpectation=${targetContract.closureExpectation}; phaseDirection=${targetContract.phaseDirection}; semanticObligations=${targetContract.semanticObligations.map((obligation) => `${obligation.id} (${obligation.instruction})`).join(" | ") || "none"}. The server is the source of truth.`
    : "No beat-local semantic contract applies to this global repair call; preserve each existing section's contract.";
  const beatDirective = beatContext
    ? `This is beat-local expansion for Story Arc beat ${beatContext.beatID}${beatContext.beatLabel ? ` (${beatContext.beatLabel})` : ""}. Develop only this beat; every returned section must use storyArcBeatID ${beatContext.beatID}. The beat currently contains approximately ${Math.round(beatContext.projectedWords).toLocaleString()} projected words. Its description is: ${beatContext.beatDescription ?? "(not supplied)"}. ${semanticContract}`
    : "Expand across the supplied outline while preserving each section's Story Arc beat.";
  return {
    system: `${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}

The current outline is compressed for a ${requestedStoryMaterialFormat(req)}. This is bounded progressive expansion round ${round} of ${MAX_EXPANSION_ROUNDS}. The current projection is approximately ${Math.round(projectedWords).toLocaleString()} words (${Math.round(projectedTokens).toLocaleString()} tokens), versus the preferred broad ${requestedStoryMaterialFormat(req)} range of ${NOVEL_TARGET_WORDS[0].toLocaleString()}-${NOVEL_TARGET_WORDS[1].toLocaleString()} words. The remaining estimated deficit is approximately ${Math.round(remainingDeficitTokens).toLocaleString()} tokens. ${beatDirective} Return ONLY ADDITIONAL section suggestions; never return, rewrite, reorder, or omit existing sections. The current sections and the supplied recipe together form a used-event ledger: do not replay an existing title, revelation, confrontation, relationship turn, solution, or resulting state under another Story Arc beat. Every addition must advance the recipe's authored premise, character/relationship material, tone, and ending intent when applicable—not merely increase word-count. Planner-generated enrichment is provisional: do not prefer an unused item over richer development of the author's characters and conflicts, and do not fill length with generic institutional or procedural steps. Fresh developments are allowed when they remain consistent with the recipe. Add distinct events, consequences, decisions, reversals, tests, discoveries, and aftermath where the current outline is compressed. Develop additional dramatic material in this priority order: (1) deepen the authored recipe's premise, characters, relationships, conflicts, themes, and intended narrative experience; (2) extend established causal developments through new consequences, complications, reversals, decisions, and discoveries; (3) use planner-generated enrichment where it meaningfully strengthens the authored story; (4) invent fresh supporting material when necessary. Planner-generated enrichment is optional. Its presence or non-use does not create a requirement to include it. Do not introduce unused enrichment simply to fill allocated length. Preserve required Story Arc functions while interpreting them through the recipe. Do not add a new section for the same dramatic state. Every Story Non-Negotiable is a must-do acceptance criterion. Preserve and materially realize any unmet must-do before adding optional expansion; if a must-do contains a number, produce that many distinct realized events. Never attach a must-do ID to an unrelated section. Each addition must use the same container semantics: scene = one continuous dramatic event (800-1,800 expected tokens); developedScene = escalation with multiple tactics (1,500-3,000); setPiece = major action/confrontation/reveal (2,000-5,000); sceneSequence = several connected scenes pursuing one objective (3,000-7,000). These are literary planning ranges only, not provider ceilings. Do not inflate containers to satisfy the size check by converting smaller containers into larger containers. Every addition must explicitly include entryState, dramaticEvent, resultingChange, terminalState, and a terminalBeat naming the concrete closing dramatic action or moment, plus a plannedWordRange as a soft literary target subordinate to the container and natural stopping point. Never use a Story Arc UUID, beat label, or END as terminalBeat; storyArcBeatID is the separate structural identity. Every addition must reference a valid beat and include insertAfterTitle for an existing section, or null to append within its beat. Assign only applicable recipeRequirementIDs from the supplied obligation list; additions may contain an empty list. Return JSON matching the expansion schema.

## Recipe obligations
The JSON request contains the authoritative obligations exactly once.`,
    user: JSON.stringify({
      global: {
        project: req.recipe?.project ? { id: req.recipe.project.id ?? null, name: compactText((req.recipe.project as any).name, 200), summary: compactText(req.recipe.project.summary, 1200) } : null,
        recipe: req.recipe,
        arc: {
          name: req.arcTemplate.name,
          description: compactArcNarrativeText(req.arcTemplate.description),
          beats: req.arcTemplate.beats.map((b: any) => ({
            id: b.id,
            label: compactText(b.label, 180),
            description: compactArcNarrativeText(b.description),
          })),
        },
      },
      mustDos: compactObligations(obligations.filter((o) => o.classification === "story_non_negotiable")),
      targetBeat: beatContext ? { ...beatContext, currentSections: compactExistingSections(beatContext.currentSections ?? []), unmetObligations: compactObligations(obligations.filter((o) => o.required && !beatContext.currentSections?.some((s) => (s.recipeRequirementIDs ?? []).includes(o.id)))) } : null,
      unusedStoryMaterial: compactMaterial({ relevant: unusedStoryMaterial }),
      neighbors: { previous: [], next: [] },
      expansion: { round, projectedTokens, projectedWords, desiredWords: context?.desiredWords ?? NOVEL_TARGET_WORDS, remainingDeficitTokens },
    }, null, 2),
  };
}

export function validateExpansionAdditions(
  parsed: any,
  beatIds: Set<string>,
  original: Suggestion[],
  obligations: RecipeObligation[] = [],
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
): ExpansionAddition[] {
  if (!parsed || !Array.isArray(parsed.suggestions)) throw new Error("expansion response missing suggestions array");
  const originalTitles = new Set(original.map((s) => s.title));
  const additions: ExpansionAddition[] = [];
  const fingerprints = new Set(original.map((s) => `${s.title}|${s.summary}|${s.storyArcBeatID}`));
  const titles = new Set(original.map((s) => s.title.trim().replace(/\s+/g, " ").toLocaleLowerCase()));
  for (const raw of parsed.suggestions) {
    const { insertAfterTitle, arcObligationEvidence: _ignoredArcObligationEvidence, ...expansionSection } = raw ?? {};
    // Optional expansion predates the Story Arc semantic-role contract. Keep
    // its structural/duplicate/placement validation, but do not apply the
    // first-pass beat-role gate here; that gate turned valid enrichment into
    // a hard failure when a provider described an addition differently.
    // Expansion creates new story sections; it does not create or reassert
    // Story Arc obligations. Ignore provider-supplied evidence metadata here
    // so an invented obligation ID cannot invalidate an otherwise valid
    // addition or the whole expansion round.
    const validated = validateSuggestions({ suggestions: [expansionSection] }, beatIds, undefined, obligations).suggestions[0];
    if (!validated) throw new Error("expansion returned an invalid addition");
    if (insertAfterTitle !== null && typeof insertAfterTitle !== "string") throw new Error("expansion placement must be a title or null");
    let resolvedInsertAfterTitle = insertAfterTitle;
    if (resolvedInsertAfterTitle !== null && !originalTitles.has(resolvedInsertAfterTitle)) {
      resolvedInsertAfterTitle = null;
    }
    if (resolvedInsertAfterTitle !== null) {
      const anchor = original.find((s) => s.title === resolvedInsertAfterTitle);
      // The provider may reuse a stale or cross-beat title as an insertion
      // anchor. Placement is server-owned: preserve the addition and append it
      // within its validated beat rather than rejecting the whole expansion.
      if (!anchor || anchor.storyArcBeatID !== validated.storyArcBeatID) {
        resolvedInsertAfterTitle = null;
      }
    }
    const fingerprint = `${validated.title}|${validated.summary}|${validated.storyArcBeatID}`;
    if (fingerprints.has(fingerprint)) throw new Error("expansion introduced a duplicate section contract");
    fingerprints.add(fingerprint);
    const titleKey = validated.title.trim().replace(/\s+/g, " ").toLocaleLowerCase();
    if (titles.has(titleKey)) throw new Error(`expansion introduced a duplicate outline title: ${validated.title}`);
    titles.add(titleKey);
    additions.push({ ...validated, insertAfterTitle: resolvedInsertAfterTitle });
  }
  return additions;
}

export function parseExpansionResponse(
  content: string,
  beatIds: Set<string>,
  original: Suggestion[],
  obligations: RecipeObligation[] = [],
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
  finishReason?: string,
): ExpansionAddition[] {
  try {
    return validateExpansionAdditions(parseOutlineJSON(content, finishReason), beatIds, original, obligations, template);
  } catch (error) {
    if (error instanceof OutlineOutputExhaustedError) throw error;
    throw new ExpansionValidationError(error instanceof Error ? error.message : String(error));
  }
}

export function mergeExpansionAdditions(original: Suggestion[], additions: ExpansionAddition[]): Suggestion[] {
  const result: Suggestion[] = [...original];
  for (const addition of additions) {
    const index = addition.insertAfterTitle === null
      ? result.map((s) => s.storyArcBeatID).lastIndexOf(addition.storyArcBeatID)
      : result.findIndex((s) => s.title === addition.insertAfterTitle);
    if (index < 0) throw new Error("expansion placement could not be resolved");
    result.splice(index + 1, 0, addition);
  }
  return result.map((suggestion) => {
    const clean = { ...suggestion } as Suggestion;
    delete (clean as Suggestion & { insertAfterTitle?: string | null }).insertAfterTitle;
    return clean;
  });
}

export function calculateRepairAllocation(
  allocation: Map<string, Allocation>,
  partial: Suggestion[],
): Map<string, Allocation> {
  const counts = new Map<string, number>();
  for (const suggestion of partial) {
    counts.set(
      suggestion.storyArcBeatID,
      (counts.get(suggestion.storyArcBeatID) ?? 0) + 1,
    );
  }
  return new Map(
    Array.from(allocation.entries()).map(([beatID, plan]) => {
      const actual = counts.get(beatID) ?? 0;
      return [beatID, {
        // Satisfied beats are explicitly locked to zero so the repair model
        // focuses only on actual minimum-coverage shortages.
        minSections: Math.max(0, plan.minSections - actual),
        rationale: `repair missing sections for ${beatID}`,
      }];
    }),
  );
}


export const SELECTED_INTIMACY_LEVEL_OBLIGATION = "selected_intimacy_level";
export const CREATIVE_FIDELITY_OBLIGATION = "creative_fidelity";

function hasCreativeFidelityDirectives(recipe?: CanonicalRecipeEnvelope): boolean {
  const project = recipe?.project as Record<string, unknown> | undefined;
  const setting = recipe?.setting as Record<string, unknown> | undefined;
  const populated = (value: unknown): boolean => Array.isArray(value) ? value.length > 0 : typeof value === "string" ? value.trim() !== "" : Boolean(value && typeof value === "object");
  const characterDirective = (recipe?.selectedCharacters ?? []).some((character) => {
    const row = character as Record<string, unknown>;
    return ["instructionBias", "failurePatterns", "contradictions", "goals", "flaws", "desires", "notes", "coreLie", "coreTruth", "moralLines"].some((key) => populated(row[key]));
  });
  return Boolean(
    populated(project?.audienceNotes) ||
    populated(setting?.instructionBias) ||
    populated(setting?.worldRules) ||
    populated(setting?.constraints) ||
    characterDirective ||
    populated(recipe?.selectedRelationships) ||
    populated(recipe?.selectedStorySpark) ||
    populated(recipe?.selectedThemeQuestions) ||
    populated(recipe?.selectedMotifs) ||
    populated(recipe?.selectedAftertaste),
  );
}

export function intimacyRequirement(
  req: Pick<OutlineFromRecipeRequest, "recipe" | "arcTemplate">,
): { level: IntimacyMilestoneRating; roles: string[]; instruction: string } | null {
  const rating = normalizeIntimacyRating(req.recipe?.project?.intimacyRating) as string;
  const focus = req.arcTemplate.relationshipFocus ?? "none";
  if (focus !== "primary" || rating === "unspecified") return null;
  if (!["romantic", "fade_to_black", "open_door", "explicit"].includes(rating)) return null;
  const roles = Array.isArray(req.arcTemplate.intimacyMilestoneRoles)
    ? req.arcTemplate.intimacyMilestoneRoles.filter((role) => typeof role === "string" && role.trim() !== "")
    : [];
  if (roles.length === 0) return null;
  const instruction = rating === "romantic"
    ? "The relationship must cross an unmistakable romantic or physical threshold; attraction, affection, or kissing can satisfy this, and sexual activity is not required."
    : rating === "fade_to_black"
    ? "The outline must contain an earned consensual adult sexual-intimacy event. The Section Contract must make consummation/sexual activity clear, while the prose treatment transitions away before explicit activity is rendered."
    : rating === "open_door"
    ? "The outline must contain an earned consensual adult sexual-intimacy event that occurs on-page."
    : "The outline must contain at least one earned consensual adult sexual-intimacy event that the Section Contract explicitly requires to occur on-page. Kissing, implication, rumpled sheets, an oversized shirt, waking together, erotic tension, or nudity without sexual activity do not satisfy this obligation.";
  return {
    level: rating as IntimacyMilestoneRating,
    roles,
    instruction,
  };
}

function intimacyEligibleBeats(req: Pick<OutlineFromRecipeRequest, "arcTemplate">) {
  const roles = new Set(req.arcTemplate.intimacyMilestoneRoles ?? []);
  return req.arcTemplate.beats.filter((beat) => roles.has(beat.role));
}

export function intimacyPlanningDirective(req: OutlineFromRecipeRequest): string {
  const rating = normalizeIntimacyRating(req.recipe?.project?.intimacyRating);
  const requirement = intimacyRequirement(req);
  if (rating === "unspecified" && !requirement) return "";
  if (!requirement) {
    return `## Intimacy level\nThe selected intimacy level is ${rating}, but the Story Arc template declares no primary relationship focus. Treat intimacy as a rendering permission/ceiling only. Do not invent romance or sexual content solely because of this setting.`;
  }
  const beats = intimacyEligibleBeats(req);
  return `## Whole-arc intimacy obligation\nThe template declares relationshipFocus=primary and the frozen project selects intimacy level ${requirement.level}. This is a hard whole-arc semantic obligation with synthetic ID ${SELECTED_INTIMACY_LEVEL_OBLIGATION}; it is not satisfied by a model-authored claim or by every section containing intimacy. Use only the template's eligible milestone roles. ${requirement.instruction}\nEligible milestone beats: ${beats.map((beat) => `${beat.label} (${beat.role})`).join(", ") || "none"}. If no eligible beat can carry the milestone, the outline is unresolved rather than silently accepted. Never plan sexual content for a character established as under 18.`;
}

export function buildPrompt(
  req: OutlineFromRecipeRequest,
  allocation: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  storyMaterial?: StoryMaterialEnrichment,
  storyArchitecture?: StoryArchitecture,
): { system: string; user: string } {
  const isNovel = requestedStoryMaterialFormat(req) === "novel";
  // A recipe-grounded causal architecture now precedes allocation; its selected
  // beat rationales are intentionally passed to the global outline generator.
  const allocationLines = Array.from(allocation.entries())
    .map(([beatId, info]) => {
      const beat = req.arcTemplate.beats.find((b) => b.id === beatId);
      const sectionLabel = isNovel
        ? `complete first-pass allocation: ${info.minSections} section${info.minSections === 1 ? "" : "s"}`
        : `minimum ${info.minSections} section${info.minSections === 1 ? "" : "s"}`;
      const typePlan = isNovel && info.containerCounts
        ? `; planned containers: ${NOVEL_LEAF_CONTAINERS.filter((type) => info.containerCounts![type] > 0).map((type) => `${type}=${info.containerCounts![type]}`).join(", ")}; ordered slots: ${plannedNovelContainerSlots(info.containerCounts).map((type, index) => `${plannedNovelSlotKey(index)}=${type}`).join(", ")}`
        : "";
      const narrativeCommitment = storyArchitecture && info.rationale
        ? `; planned dramatic movement: ${compactArcNarrativeText(info.rationale)}`
        : "";
      return `- ${beat?.label ?? beatId}: ${sectionLabel}${typePlan}${narrativeCommitment}`;
    })
    .join("\n");
  const allocationDirective = isNovel
    ? `## Complete first-pass allocation\n\nThe allocation above constrains section counts, ordered container types, and Story Arc beat placement, and carries recipe-grounded narrative commitments selected BEFORE sizing. Follow those commitments unless they conflict with the canonical recipe or already accepted story; planner-generated enrichment alone is not canon. The allocation is the intended complete first-pass distribution for this novel, not a minimum-only Story Arc coverage floor. Plan substantial, distinct dramatic development for every allocated section before selecting its container. Match the planned section container and narrative scale for each ordered named slot. When typed slots are present, return a JSON object of sections per beat keyed by those slot names; every slot has exactly one allowed container type. The allocator already priced each planned section at its actual midpoint. Give each unit genuinely appropriate dramatic development; do not merely relabel a small event as a long chapter. Routine book-length development belongs in the first pass, not later expansion. Existing accepted sections already contribute to the complete projection; the allocation is residual new work, and a beat with sufficient existing coverage remains at zero.`
    : `## Use the minimum-only allocation\n\nFor each beat, generate at least the stated minimum number of distinct sections while respecting the format's length policy. The minimum is a coverage floor, not permission to exceed the format's constraints. A beat with minimum 0 is already covered for this pass and must produce no new suggestion. Never pad with paraphrases.`;
  const contractLines = req.arcTemplate.beats.map((beat) => {
    const contract = arcRoleContract(beat, req.arcTemplate.name);
    const obligations = contract.semanticObligations.length > 0
      ? `; semantic obligations=${contract.semanticObligations.map((obligation) => obligation.id).join(", ")}`
      : "";
    return `- ${beat.label} (${beat.role}): authored requirement=${compactArcNarrativeText(beat.description) || "(none supplied)"}; required functions=${contract.requiredFunctions.join(", ") || "(none)"}; allowed functions=${contract.allowedFunctions.join(", ")}; phase=${contract.phaseDirection}; ${contract.forbidsNewPrimaryConflict ? "do not introduce a new primary conflict" : "major escalation is allowed"}${obligations}`;
  }).join("\n");
  const semanticObligationLines = req.arcTemplate.beats.flatMap((beat) => {
    const contract = arcRoleContract(beat, req.arcTemplate.name);
    return contract.semanticObligations.map((obligation) =>
      `- ${beat.label} / ${obligation.id}: ${obligation.instruction} If supplied, ground arcObligationEvidence.${obligation.id} with exact quotes from dramaticEvent, resultingChange, or terminalState; make the required fields materially express it.`,
    );
  }).join("\n");

  const system =
    `You are an expert ${requestedStoryMaterialFormat(req)} outliner. Use the complete canonical recipe/project payload below, including its premise, selected characters and their populated fields, selected relationships, themes, motifs, story spark, aftertaste, recipe instructions, and included setting. Treat supplied facts as authoritative; do not infer personality traits from a character name alone. Given the story arc, produce one complete section-by-section outline in this single pass.

## Narrative-state continuity
Before returning the outline, evaluate the complete proposed sequence in canonical order. Each section must begin from a state that plausibly follows the previous section's terminal state. Preserve established character locations, relationships, physical conditions, consequential object custody, deaths, departures, and irreversible events. When successive sections require materially different states, establish a credible transition; do not silently relocate principal characters, reverse completed events, resurrect the dead, or transfer a critical object without explanation. Apply the same continuity expectations across Story Arc boundaries: a new beat does not reset location, chronology, or established events. Prefer correcting the ordering, location, or dramatic sequence when successive sections establish incompatible narrative states. For example, if a character must participate in an event at one location but has already departed for another, establish a credible transition or reorder the events to preserve causality. Do not invent implausible explanations merely to preserve the original sequence. Legitimate offscreen travel, elapsed time, flashbacks, parallel action, perspective changes, and intentional ambiguity remain allowed; require plausible causality, not mechanical matching of location strings. Preserve recipe requirements, authored Story Arc obligations, necessary developments, and length constraints; do not delete essential material or add filler.

Every section must commit to one canonical event. Never use unresolved alternatives such as "X or Y", "someone", "a friend", "somewhere", or multiple possible versions of the event. Choose the specific person, place, object, and action.

## Novel length policy
For a novel, plan toward 115,000 words, with a 115,000-word minimum and a 125,000-word hard cap. The cap applies to the complete outline projection, not only to later expansion. Allocate the available word budget across the Story Arc beats before choosing sections. Cover every authored obligation, essential character arc, major conflict, reversal, consequence, and ending commitment within that budget. Combine related events into fuller sections; do not create one section per enrichment item. Fit the complete story package into the budget. When material competes for space, combine related events into fuller sections, deepen shared sections, and adjust the level of detail; do not drop story material merely to meet the cap. Never treat the length policy as permission to omit a required story element. Use the chapter container for substantial units and the server's expected container ranges as planning estimates; keep the complete projected outline at or below 125,000 words.

Selected motifs are supporting material, not a quota. Use a motif in a section only when the section contract, causality, physical continuity, or a meaningful transformation requires it; do not repeat a motif merely to prove that the outline remembers it. Prefer concrete scene-specific images when no selected motif is needed.

Each section must produce a materially new resulting state. Do not create another section merely to restate or reconfirm a relationship change, realization, warning, or trust shift already achieved. Revisit an arc only when a new event escalates, reverses, costs, or transforms it.

## Section distinctness and necessity
Every section must make a distinct irreversible contribution: reveal new information, force a consequential choice, alter a relationship, or materially change the tactical situation. If two proposed sections primarily accomplish the same function, make the later one advance the consequence, introduce a materially different cost, reversal, decision, relationship change, information change, power shift, or tactical state rather than repeating the earlier function. Preserve the amount of story; increase the amount of distinct story.

Before assigning separate sections to related events, determine whether each creates a genuinely new causal development. Reconsidering an established dilemma, approaching the same confrontation through successive obstacles, or observing the same aftermath from another angle does not by itself constitute new dramatic work. These may be movements within one substantial section. A separate section must introduce a consequential new action, discovery, reversal, cost, commitment, or changed relationship that alters what can happen next. When allocated sections would otherwise duplicate dramatic work, redesign them around distinct developments rather than splitting or rephrasing the same event.
Preserve legitimate slow-burn storytelling, character reflection, suspense, callbacks, and multi-stage confrontations where those elements materially develop the narrative.
Do not impose an arbitrary requirement that every section contain action or spectacle.

Evaluate the WHOLE proposed novel — including sections in other Story Arc beats — when deciding whether a section adds new dramatic value. Dramatic novelty is determined primarily by the dramaticEvent, resultingChange, and terminalState fields; it is NOT established by different characters, locations, imagery, or surface spectacle alone. Two sections with different surface events can still be dramatically redundant if they produce essentially the same story change.

Avoid redundant patterns such as: the group pushes the same threat back twice as two separate victories; the same breach or conflict is effectively closed twice; a character resolves the same belonging or identity question twice; the same relationship realization receives another "final" resolution; or a later climax restages the earlier climax with greater spectacle but substantially the same result.

Do not solve redundant dramatic work by adding sections. Allocation, minimum section coverage, and the novel length policy remain authoritative. When multiple planned sections would otherwise perform similar dramatic work, combine or redesign them so the complete outline remains within the 125,000-word cap while still fulfilling its Story Arc role and recipe obligations. Preserve required story content; remove padding and optional repetition.

A later section may revisit the same characters, antagonist, conflict, location, or thematic question, but must advance it through a genuinely new development: a new consequence; an increased or different cost; a reversal; changed knowledge; changed power; transferred agency; a harder decision; resolution of a different thread; a changed relationship; a transformed meaning of the earlier event; or a materially different tactical state. Each section should earn its place by changing something the previous sections have not already changed.

Author-supplied names and facts, and identities established by previously accepted story sections, are canonical: preserve them exactly for continuity. Enrichment entries marked source=planner are provisional candidates, not established entities. A planner-created location, institution, antagonist, clue, object, or mechanism may be used when it serves the recipe, adapted, replaced by a better recipe-faithful idea, or discarded entirely. Never rename, merge, abbreviate, or invent a variant of an author-supplied or previously accepted named entity.

A revelation, discovery, confession, or relationship change may occur only once as the primary dramatic event. Later sections may build on its consequences, but must not rediscover or restate the same fact as a new revelation.

Maintain the established narrative POV mode across the outline unless the supplied recipe explicitly requires a POV change. Do not switch between first person and third person as a stylistic experiment.

## Container semantics for planning

Choose a container for the scale of one dramatic unit, not to fake novel length:
- scene: one focused dramatic event that genuinely develops and resolves within a relatively compact unit, expected 800-1,800 tokens
- developedScene: prefer this for a substantial reader-facing novel section where one objective requires multiple tactics, meaningful resistance, escalation, reversal, emotional development, or a consequential relationship change, 1,500-3,000
- setPiece: a major confrontation, action, ceremony, revelation, or complex high-stakes event, 2,000-5,000
- sceneSequence: several connected scenes, locations, or times pursuing one coherent objective, 3,000-7,000
- chapter: a publishing unit containing multiple substantial movements that belong together, 3,000-8,000+

${isNovel ? `For novel planning, follow the allocator's per-beat container counts and keep the actual midpoint projection near 115,000 words without exceeding 125,000. Treat every container as its real narrative scale: chapters can hold coherent multi-movement developments, while scenes, developed scenes, set pieces, and scene sequences must earn their individual shape. Preserve distinct irreversible developments without padding, relabeling small scenes as chapters, or splitting one continuous objective into redundant leaves. This first-pass allocation already reflects the different container sizes.` : `Use the container whose range fits the material. Preserve the existing format's allocation semantics and do not use containers to inflate or fragment the outline.`}
For a new novel, prefer the chapter container: each chapter-scale section targets the existing chapter minimum of 3,000 planned tokens. Use scene, developedScene, setPiece, or sceneSequence only when the material genuinely requires a smaller or differently shaped dramatic unit; never use them to fragment one chapter or inflate section counts. Do not create moment, vignette, microScene, beat, shortStory, or episode leaves. Do not split one continuous dramatic objective into several short sections merely because each tactic can be named as its own event: setup → attempt → resistance → changed tactic → consequence usually belongs in one developedScene. A brief final image, kiss, gesture, or emotional beat should normally close the preceding substantive scene rather than become an isolated tiny novel section. Favor more developed story, never padding; preserve distinct state change, no duplicate revelations or resolutions, and no filler sections.
The expected ranges are literary targets; runtime/provider headroom is not a desired length.

${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}

## Recipe realization priority
The recipe is the governing creative brief, not metadata to distribute as section tags. Required recipe obligations outrank generic outline habits, filler, and even the desire for evenly balanced Story Arc coverage. Materially dramatize the premise, selected characters, relationships, story spark, themes, setting, tone/audience guidance, and ending intent wherever the recipe supplies them. A section may carry a recipe ID only when its Section Contract actually advances that requirement; never tag a section merely to make coverage counts pass. Planner-generated material may be rejected or replaced when it creates genre drift or contradicts the recipe; unused planner material is not a narrative quota. A character can transform without becoming morally better; a quest can remain chaotic, accidental, selfish, or destructive; a revelation need not provide neat explanatory closure; and a resolution settles the relevant dramatic question without requiring every mystery or conflict to be resolved. Before finalizing, audit the whole outline against every required obligation and redesign weak or generic sections until the recipe visibly drives the plot, escalation, relationship movement, and payoff.
Every defining behavior, event, or conflict explicitly specified by the author must have a concrete realization somewhere in the outline. At least one relevant Section Contract must require that realization through its dramaticEvent, resultingChange, or terminalState. Mentioning it in a summary, labeling a character with the trait, or assigning a recipe requirement ID does not constitute realization. Preserve creative freedom over how and when the requirement is realized.

## First-pass whole-book obligations (no narrative repair later)
The planningContext.premiseComponents are independently extracted AUTHOR-BASED commitments, not commands to resolve a whole series in book one. Establish each component at the scope required by the current book: introduce, foreshadow, complicate, advance, or resolve it as warranted by the author's explicit book/series intent. A long-range country-scale or humanity-scale payoff may be seeded through credible stakes and character-caused consequences without prematurely producing a national showdown. Do not claim that an unrelated local rescue fulfills the ultimate promise, and do not manufacture an institutional mission merely to turn a long-range promise into a completed current-volume event. Preserve the components even when optional planner material suggests a narrower, easier plot.
Before writing any sections, assign each author-required behavior, event, and story non-negotiable to an appropriate concrete dramatic development across the COMPLETE outline. Story-wide requirements cannot be met by repeating descriptive labels in the opening beat: distribute recurring behaviors and relationships across different chapter movements as the recipe warrants. For every selected requirement, construct the actual on-page action and its consequence in dramaticEvent and resultingChange or terminalState, not solely summary or tags. Ground adult tone and intensity in the author's recipe without imposing it on unrelated genres. Verify internally that every requirement has at least one material section-contract realization (and that recurring or quantified requirements have multiple distinct realizations). For any required climax or resolution function, explicitly declare that dramaticFunction on the correct Story Arc beat and give it an irreversible terminal state. All of this must be right in the FIRST provider response; there is no subsequent automatic narrative repair pass.

## Character-Driven Dramatic Selection
When multiple developments satisfy the recipe, Story Arc, continuity, and section contract, choose the most entertaining, original, surprising, and dramatically compelling option. Let authored and invented characters' distinctive personalities, desires, flaws, obsessions, relationships, and unpredictable decisions generate events: supporting characters should create complications, change relationships, trigger reversals, and produce lasting consequences rather than serving as informants, exposition, transportation, or other functional devices. When the authored genre and tone support it, favor outrageous encounters, reckless decisions, dark humor, grotesque absurdity, dangerous confrontations, unexpected reversals, and escalating chaos over conventional investigations, administrative discoveries, tactical missions, or procedural problem-solving. Preserve intended adult intensity without sanitizing it; make the climax emerge from the protagonists' distinctive choices and behavior and deliver the premise's consequential outcome rather than merely completing a generic tactical objective. Do not force randomness, spectacle, or artificial chaos into restrained stories. Preserve causality, continuity, and authorial intent.

## Character-caused story selection before plot construction
First choose the story's causal drivers, BEFORE deciding on its central apparatus, tactical objective, climax method, or beat-by-beat plot. Read the authored protagonists' motives and relationships and the planningContext.characterDecisionCandidates. Identify the distinct desires and compromised choices that could make this story happen specifically to THESE people. Select the strongest optional supporting characters for their independent decisions, conflicting agendas, betrayals, selfish gambles, outrageous mistakes, and effects on the protagonists. For each selected character, work out privately what they want, the distinctive choice they make, whose plan it derails, and a later consequence that would not happen without that choice. Their choices and the protagonists' reactions must supply the causal spine; a preselected institutional mission, pursuit, technical device, or generic threat must not be the spine with characters added afterward. If the recipe calls for a system-driven procedural story, preserve it, but still let authored character agency determine its crucial turns.

Do not force every generated character into the outline. A candidate whose choices cannot earn a consequence may be dropped; do not add cameos, exposition couriers, or filler scenes to satisfy an invented cast quota. Equally, do not replace a distinctive, consequential candidate with a nameless official, contact, or contractor merely because a functional role makes the plot easier. Before finalizing the sequence, test each retained supporting character: if substituting an interchangeable job title would leave the important events unchanged, give that character a genuinely consequential personal decision or omit them. Keep the Story Arc as the ordered dramatic progression AFTER selecting the story, not the source of a generic sequence of missions. Preserve the author's tone, adult intensity, ambiguity, restrained genres, and all continuity and output contracts.

## Premise outcome and ending causality
Before drafting sections, determine the whole story's cause-and-effect trajectory, including the decisive climax, the irreversible change it causes, and an ending that inherits that change. Plan the final outcome before distributing distinct events across Story Arc beats. The protagonists' specific traits, choices, and relationships must materially cause or complicate that outcome; an interchangeable tactical or institutional solution must not replace their agency. Across the entire sequence, preserve irreversible events: a threat stopped in one section stays stopped unless a new and expressly caused event changes that state; deaths, departures, promises, discoveries, and destroyed objects persist. Do not let a subsequent section restart the same countdown, restage a resolved confrontation, or resolve the central conflict a second time. Check the complete resultingChange and terminalState sequence before returning the first-pass outline. The ending can be ambiguous, tragic, grotesque, destructive, morally compromised, or only partly understood; it need not answer every question, but must deliver the premise's consequential promise.

## Selected causal architecture from the allocation call
${storyArchitecture ? JSON.stringify(storyArchitecture) : "Legacy checkpoint: no prior story architecture was persisted. Choose a recipe-faithful causal story and definitive outcome before creating sections."}
When present, carry forward these selected causal decisions, NOT merely the chapter counts. The decisiveClimax is the decisive completed event, not another attempt, approach, or unresolved cliffhanger; the endingConsequence must inherit its irreversible state. In a template with separate climax and resolution roles, the decisive outcome must be achieved in the climax role, and the resolution may only dramatize its consequences. Do not use later final-image chapters to start another primary rescue, re-open the central threat, or invent a new ending. Keep the intentionally unresolved mysteries open without leaving the CENTRAL dramatic question unanswered. This architecture is provisional ONLY relative to the authoritative recipe and already accepted story: it may not override authored facts, tone, relationships, world rules, or required Story Arc obligations. The per-beat planned dramatic movements below are causal commitments rather than detachable ideas or new authored mandates.

## Recipe obligations
The JSON planning context contains the authoritative obligations exactly once.

## STORY NON-NEGOTIABLE MUST-DOS (acceptance criteria)
${renderStoryNonNegotiableMustDos(obligations)}
These are mandatory acceptance criteria, not descriptive tags. Reserve concrete sections/events for every must-do. If a must-do contains a number, treat that number as the minimum count of distinct realized events, not prose flavor. Only assign a must-do ID when the section's dramaticEvent, resultingChange, or terminalState materially realizes the stated requirement; never attach the ID to an unrelated section to make coverage appear complete. Before finalizing, audit every must-do against the actual section contracts and redesign the relevant section BEFORE returning this single response. If one is still unrealized, never falsely label an unrelated section to pass validation.

## Compact planning context
Use the deterministic, provenance-preserving planning view below. Items marked source=recipe are authored facts; source=planner are development candidates and must not be treated as authored facts. The server retains the full canonical recipe for validation. Planner categories are possible story ingredients, not an already chosen plot. The outliner may use, combine, adapt, or discard any invented candidate, including recurring invented groups and mechanisms; frequency across categories does not make it canon. Let the authored recipe and the characters' distinctive choices select the causal trajectory. Prefer a concrete recipe-backed or already-accepted detail over a generic phrase, but do not promote a planner proposal to canon merely because it is specific.

${allocationDirective}

## Character arc and plot integration
Whenever practical, relationship and character-arc turns should cause or complicate plot events rather than occurring as isolated character-development scenes.

## Novel-ready section titles

Write each section title as a concise, specific, evocative working title suitable for a ${requestedStoryMaterialFormat(req)} outline or ${requestedStoryMaterialFormat(req)}-ready table of contents. The title should name the concrete dramatic event, decision, reversal, discovery, confrontation, or consequence that this section actually dramatizes. Titles should read like evocative fiction headings, not outline summaries. Prefer images, objects, locations, threats, fragments, or memorable phrases. Avoid the repeated “Character + verb + outcome” construction and stock phrases such as “takes the hit,” “draws the line,” “holds the line,” “finally,” “chooses,” or “is accepted.” Use a character’s name only when it makes the title stronger. Do not restate or lightly rephrase the premise, Story Arc beat label, terminal beat, or section summary. Avoid generic placeholders such as "Setup," "Conflict," "Events," or "Scene"; each title must distinguish its section from the others in the same beat.

## Memorable event and title quality
Favor specific, memorable events and evocative section titles over functional briefing, regrouping, mapping, or explanatory scenes. Titles should suggest image, tension, place, or dramatic irony rather than summarize the section's purpose.

## Generation-ready section contract
For every section, explicitly state entryState, dramaticEvent, resultingChange, and terminalState. Also return exactly one server-validated dramaticFunction from the allowed functions for that beat; the function must agree with the event and resulting change, not merely repeat the beat label. The dramaticEvent must be a specific objective, confrontation, discovery, decision, reversal, or consequence; resultingChange must alter the protagonist, opposition, relationship, information, resources, or stakes. The terminalState is the concrete condition handed to the next section. The terminalBeat is the concrete closing dramatic action or moment of this section, consistent with those contract fields. Never use the Story Arc UUID, beat label, or END as terminalBeat; storyArcBeatID is the separate structural identity assigned by the server. Do not copy an arc-beat label into these fields. Do not provide plannedWordRange; the server derives it deterministically from container; it never overrides the Section Contract, container, or natural stopping point.

Canonical dramatic event responsibility: each section must commit to one canonical dramatic realization of what happens. The outline planner owns plot decisions; the later prose generator owns execution. When needed to make the section generation-ready, choose the concrete location, participating characters, triggering action, confrontation, discovery, failure or reversal, and immediate consequence. Do not leave those decisions as interchangeable possibilities for the prose generator. Avoid unresolved planner alternatives such as “at the school or arcade,” “a road, bridge, school, or home,” “a chase or near-miss,” “an object or sound,” “someone is attacked,” “something happens,” “may/could/might reveal,” or “such as X or Y.” Do not mechanically ban words such as “or,” “may,” or “could”: they remain valid when uncertainty or choice is itself part of the canonical dramatic event, such as “Brody must decide whether to confess or keep lying.” The prohibited case is the planner leaving multiple interchangeable plot realizations undecided. As a useful standard, two prose generators following the same section contract should dramatize substantially the same plot event, even though dialogue, prose, blocking, sensory detail, pacing, and moment-to-moment execution may differ. Make entryState, resultingChange, and terminalState similarly concrete enough to constrain continuity, without turning them into prose or over-specifying incidental details. The outline should define the event and its continuity consequences, not pre-write the novel.

${allocationLines}

## Semantic Story Arc contracts
${contractLines}

${intimacyPlanningDirective(req)}

## Beat-specific semantic obligations
${semanticObligationLines || "No beat-specific semantic obligations are defined for this template."}

The Resurrection must not replay the Ordeal at greater scale. The Ordeal must create a cost, revelation, failure, or changed condition that materially alters how the final confrontation works. The Resurrection must depend on that changed condition and must develop or resolve the conflict in a materially different way — not simply replay the Ordeal's essential conflict and solution at greater scale.

A Story Arc beat transition does NOT reset dramatic novelty. The later beat must inherit the changed conditions created by the earlier one. Apply the same principle generally: a climax should not merely repeat crisis at greater intensity; consequence should dramatize what the climax changed; resolution should develop the consequences of victory or loss rather than stage another miniature victory.

Before finalizing the outline, compare the proposed sequence of resultingChange and terminalState values across the whole outline. If two non-adjacent sections produce substantially the same resultingChange or terminalState, redesign the later one so the later section performs distinct dramatic work.

Respond with structured JSON matching the schema. This is the only provider call for Suggest Sections; do not return a plan for another model or defer plot decisions.`;
  const planningView = buildCompactPlanningView(
    { ...req, storyMaterialEnrichment: storyMaterial },
    obligations,
    storyMaterial,
  );
  // Keep the original recipe and selected architecture authoritative. The
  // broader enrichment pool remains saved but must not reintroduce the plot
  // packages intentionally excluded from the architecture call.
  planningView.materialIndex = authorFirstMaterialIndex(storyMaterial).map((item) => {
    if (item.source !== "recipe") return item;
    const { label: _label, description: _description, ...sourceIdentity } = item;
    return sourceIdentity;
  });
  // Put decision-capable supporting people in front of the outliner as an
  // explicit selection pool, rather than burying them among plot machinery.
  // This is not a cast quota or an additional canon/validation contract.
  planningView.characterDecisionCandidates = (storyMaterial?.characters ?? [])
    .filter((item) => item.source === "planner")
    .map((item) => ({
      id: item.id,
      label: item.label,
      description: item.description,
    }));
  const user = JSON.stringify({
    planningContext: planningView,
    // A selected recipe-grounded architecture and each beat's planned dramatic
    // movement now cross into generation. Pure allocation quantities still
    // constrain chapter slots, and older checkpoints can omit architecture.
    allocation: Array.from(allocation.entries(), ([beatId, info]) => [beatId, {
      minSections: info.minSections,
      ...(info.coverageMinimum !== undefined ? { coverageMinimum: info.coverageMinimum } : {}),
      ...(info.allocationMinimum !== undefined ? { allocationMinimum: info.allocationMinimum } : {}),
      ...(info.containerCounts ? { containerCounts: info.containerCounts } : {}),
    }]),
    allocationContract: isNovel
      ? "Complete first-pass novel distribution; each allocation is substantial new work and shorter containers count at their actual midpoint."
      : "Minimum section coverage for this non-novel format; preserve existing format semantics.",
    hint: req.hint ?? null,
  }, null, 2);

  return { system, user };
}

// One existing planning call now chooses an authored-recipe-grounded causal
// architecture BEFORE sizing the chapters. The architecture survives the
// allocator→outliner handoff; enrichment remains optional creative material.
export type StoryArchitecture = {
  centralQuestion: string;
  characterCausality: string;
  decisiveClimax: string;
  endingConsequence: string;
  deliberatelyOpenThreads: string;
};

const STORY_ARCHITECTURE_SCHEMA = {
  type: "object",
  properties: {
    centralQuestion: { type: "string", minLength: 1, maxLength: 650 },
    characterCausality: { type: "string", minLength: 1, maxLength: 850 },
    decisiveClimax: { type: "string", minLength: 1, maxLength: 850 },
    endingConsequence: { type: "string", minLength: 1, maxLength: 650 },
    deliberatelyOpenThreads: { type: "string", minLength: 1, maxLength: 650 },
  },
  required: ["centralQuestion", "characterCausality", "decisiveClimax", "endingConsequence", "deliberatelyOpenThreads"],
  additionalProperties: false,
} as const;

// A single strict response contains causal decisions AND chapter sizing.
const ALLOCATION_SCHEMA = {
  type: "object",
  properties: {
    storyArchitecture: STORY_ARCHITECTURE_SCHEMA,
    allocations: {
      type: "array",
      minItems: 0,
      maxItems: MAX_PLANNED_SECTIONS,
      items: {
        type: "object",
        properties: {
          beatIndex: { type: "integer", minimum: 0 },
          minSections: { type: "integer", minimum: 0, maximum: 20 },
          containerCounts: {
            type: "object", additionalProperties: false,
            properties: {
              scene: { type: "integer", minimum: 0, maximum: 20 },
              developedScene: { type: "integer", minimum: 0, maximum: 20 },
              setPiece: { type: "integer", minimum: 0, maximum: 20 },
              sceneSequence: { type: "integer", minimum: 0, maximum: 20 },
              chapter: { type: "integer", minimum: 0, maximum: 20 },
            },
            required: ["scene", "developedScene", "setPiece", "sceneSequence", "chapter"],
          },
          rationale: { type: "string", minLength: 1, maxLength: 500 },
        },
        required: ["beatIndex", "minSections", "containerCounts", "rationale"],
        additionalProperties: false,
      },
    },
  },
  required: ["storyArchitecture", "allocations"],
  additionalProperties: false,
} as const;

type Allocation = {
  minSections: number;
  /** At least one new section is required for every previously uncovered beat. */
  coverageMinimum?: number;
  /** The planner's requested minimum, retained when budgeting scales extras. */
  allocationMinimum?: number;
  /** The container-aware budget chosen by the novel planner. */
  containerCounts?: NovelContainerCounts;
  rationale: string;
};

type NovelContainerCounts = Record<typeof NOVEL_LEAF_CONTAINERS[number], number>;

export class AllocationBudgetConstraintError extends Error {
  readonly code = "allocation_budget_constraint";

  constructor(message: string) {
    super(message);
    this.name = "AllocationBudgetConstraintError";
  }
}

// Novel scale is evaluated using the midpoint of a known container's literary
// range, not its floor. When no reliable container mix is available, planning
// uses the observed mixed-section estimate below; typed allocations remain
// subject to their actual container midpoints.
export const NOVEL_MIXED_SECTION_ESTIMATE_TOKENS = 3500;
// Typed container midpoints are planning estimates. Allow a narrow 5,000-word
// recovery tolerance so a near-boundary mix is repaired instead of hard-failing;
// normal planning and final acceptance remain bounded by 125,000 words.
export function maximumBudgetedNewSections(req: OutlineFromRecipeRequest): number {
  if (requestedStoryMaterialFormat(req) !== "novel") return MAX_PLANNED_SECTIONS;
  const existingTokens = projectedExpectedTokens(req.existingSections ?? []);
  return Math.max(
    0,
    Math.min(
      MAX_PLANNED_SECTIONS,
      Math.floor(Math.max(0, NOVEL_MAX_PROJECTED_TOKENS - existingTokens) / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS),
    ),
  );
}

/** Unknown-mix planning uses the observed typical mixed-section estimate.
 * Typed allocations are priced separately by their actual container mix. */
export function maximumContainerPlannedNewSections(req: OutlineFromRecipeRequest): number {
  if (requestedStoryMaterialFormat(req) !== "novel") return MAX_PLANNED_SECTIONS;
  const remaining = NOVEL_MAX_PROJECTED_TOKENS - projectedExpectedTokens(req.existingSections ?? []);
  return Math.max(0, Math.min(MAX_PLANNED_SECTIONS, Math.floor(Math.max(0, remaining) / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS)));
}

function projectedPlannedContainerTokens(allocation: Map<string, Allocation>): number {
  return Array.from(allocation.values()).reduce((total, plan) =>
    total + NOVEL_LEAF_CONTAINERS.reduce((sum, container) =>
      sum + (plan.containerCounts?.[container] ?? 0) * projectedExpectedTokens([{ container }]), 0), 0);
}

/** Keep every beat's coverage floor, but never let allocator floors make the
 * novel cap mathematically impossible. Relative allocation priority is
 * preserved through largest-remainder scaling; later stages can still combine
 * events inside each fuller section. */
export function fitAllocationToNovelBudget(
  allocation: Map<string, Allocation>,
  req: OutlineFromRecipeRequest,
): Map<string, Allocation> {
  if (requestedStoryMaterialFormat(req) !== "novel") return allocation;

  // Novel planning never drops container metadata or fails because the planner
  // estimated too many words. Complete missing counts with a deterministic
  // substantial mix, then trim the largest planned units until the accepted projection fits. This keeps every beat represented and keeps the
  // generation schema constrained to named container slots.
  const normalized = new Map<string, Allocation>();
  for (const [beatID, plan] of allocation.entries()) {
    const counts: NovelContainerCounts = {
      scene: 0,
      developedScene: 0,
      setPiece: 0,
      sceneSequence: 0,
      chapter: 0,
    };
    for (const container of NOVEL_LEAF_CONTAINERS) {
      counts[container] = Math.max(0, Math.floor(plan.containerCounts?.[container] ?? 0));
    }
    let countTotal = NOVEL_LEAF_CONTAINERS.reduce((sum, container) => sum + counts[container], 0);
    const requestedMinimum = Math.max(0, Math.floor(plan.minSections));
    while (countTotal < requestedMinimum) {
      // A missing slot is completed with a deterministic substantial mix
      // rather than an unbounded provider choice: scene + developedScene
      // averages almost exactly the established mixed-section estimate.
      const nextContainer = countTotal % 2 === 0 ? "scene" : "developedScene";
      counts[nextContainer]++;
      countTotal++;
    }
    normalized.set(beatID, {
      ...plan,
      minSections: countTotal,
      coverageMinimum: plan.coverageMinimum ?? 1,
      containerCounts: counts,
    });
  }

  const positiveBeats = Array.from(normalized.values()).filter((plan) => plan.minSections > 0).length;
  const existingTokens = projectedExpectedTokens(req.existingSections ?? []);
  const acceptedTokens = Math.max(0, NOVEL_ACCEPTED_MAX_PROJECTED_TOKENS - existingTokens);
  const projected = () => Array.from(normalized.values()).reduce((total, plan) =>
    total + NOVEL_LEAF_CONTAINERS.reduce((sum, container) =>
      sum + plan.containerCounts![container] * projectedExpectedTokens([{ container }]), 0), 0);

  while (projected() > acceptedTokens) {
    const candidates = Array.from(normalized.entries()).flatMap(([beatID, plan]) =>
      NOVEL_LEAF_CONTAINERS.filter((container) => plan.containerCounts![container] > 1).map((container) => ({
        beatID,
        plan,
        container,
        cost: projectedExpectedTokens([{ container }]),
      })));
    if (candidates.length === 0 || Array.from(normalized.values()).reduce((sum, plan) => sum + plan.minSections, 0) <= positiveBeats) break;
    const selected = candidates.sort((left, right) => right.cost - left.cost)[0];
    selected.plan.containerCounts![selected.container]--;
    selected.plan.minSections--;
  }

  return new Map(Array.from(normalized.entries()).map(([beatID, plan]) => {
    const original = allocation.get(beatID)!;
    const changed = original.minSections !== plan.minSections ||
      JSON.stringify(original.containerCounts ?? null) !== JSON.stringify(plan.containerCounts);
    return [beatID, changed
      ? { ...plan, rationale: `${plan.rationale} Budget-normalized to the accepted ${NOVEL_ACCEPTED_MAX_WORDS.toLocaleString()}-word ceiling while preserving container slots.` }
      : plan] as [string, Allocation];
  }));
}

export class AllocationRetryRequired extends Error {
  constructor(public readonly reason: string) {
    super(`allocation planner requires one bounded retry: ${reason}`);
    this.name = "AllocationRetryRequired";
  }
}

export function suggestionContractFingerprint(suggestion: Suggestion): string {
  // Beat identity is deliberately excluded: replaying the same section under
  // another Story Arc beat is still the same section contract.
  return [
    suggestion.title,
    suggestion.summary,
    suggestion.dramaticEvent ?? "",
    suggestion.resultingChange ?? "",
    suggestion.terminalState ?? "",
  ].map((value) => String(value).trim().replace(/\s+/g, " ").toLocaleLowerCase()).join("|");
}

/**
 * A title is not the whole dramatic contract, but repeating an exact title
 * across Story Arc beats is a reliable hard signal that the planner replayed
 * an event under a new beat. Keep this separate from repair validation, where
 * duplicate titles are temporarily allowed while a stable index is replaced.
 */
export function assertDistinctOutlineTitles(suggestions: Suggestion[]): void {
  const seen = new Map<string, number>();
  suggestions.forEach((suggestion, index) => {
    const key = suggestion.title.trim().replace(/\s+/g, " ").toLocaleLowerCase();
    const prior = seen.get(key);
    if (prior !== undefined) {
      throw new Error(`duplicate outline title across sections: ${suggestion.title} (sections ${prior + 1} and ${index + 1})`);
    }
    seen.set(key, index);
  });
}

export function removeDuplicateOutlineSections(
  suggestions: Suggestion[],
): { suggestions: Suggestion[]; removed: Array<{ title: string; index: number }> } {
  const seenContracts = new Set<string>();
  const seenTitles = new Set<string>();
  const kept: Suggestion[] = [];
  const removed: Array<{ title: string; index: number }> = [];
  for (const [index, suggestion] of suggestions.entries()) {
    const contract = suggestionContractFingerprint(suggestion);
    const title = suggestion.title.trim().replace(/\s+/g, " ").toLocaleLowerCase();
    if (seenContracts.has(contract) || seenTitles.has(title)) {
      removed.push({ title: suggestion.title, index });
      continue;
    }
    seenContracts.add(contract);
    seenTitles.add(title);
    kept.push(suggestion);
  }
  return { suggestions: kept, removed };
}

export function mergeSuggestionsByBeatOrder(
  beatOrder: string[],
  firstPass: Suggestion[],
  repaired: Suggestion[],
  dedupeDuplicates = false,
): Suggestion[] {
  const beatSet = new Set(beatOrder);
  const seen = new Set<string>();
  const byBeat = new Map<string, { firstPass: Suggestion[]; repaired: Suggestion[] }>();
  for (const beatID of beatOrder) {
    byBeat.set(beatID, { firstPass: [], repaired: [] });
  }

  for (const [source, suggestions] of [["first-pass", firstPass], ["repair", repaired]] as const) {
    for (const suggestion of suggestions) {
      if (!beatSet.has(suggestion.storyArcBeatID)) {
        throw new Error(`${source} suggestion references unknown beat ${suggestion.storyArcBeatID}`);
      }
      const fingerprint = suggestionContractFingerprint(suggestion);
      if (seen.has(fingerprint)) {
        if (dedupeDuplicates) continue;
        throw new Error(`duplicate section contract returned by ${source}: ${fingerprint}`);
      }
      seen.add(fingerprint);
      byBeat.get(suggestion.storyArcBeatID)![source === "first-pass" ? "firstPass" : "repaired"].push(suggestion);
    }
  }

  return beatOrder.flatMap((beatID) => {
    const grouped = byBeat.get(beatID)!;
    return [...grouped.firstPass, ...grouped.repaired];
  });
}

export function mergeRepairedSuggestions(
  beatOrder: string[],
  beatIds: Set<string>,
  allocation: Map<string, Allocation>,
  firstPass: Suggestion[],
  repaired: Suggestion[],
): Suggestion[] {
  const merged = mergeSuggestionsByBeatOrder(beatOrder, firstPass, repaired);
  return validateSuggestions({ suggestions: merged }, beatIds, allocation).suggestions;
}

export function parseAndValidateAllocation(
  raw: string,
  beats: Array<{ id: string }>,
  finishReason?: string,
  onArchitecture?: (architecture: StoryArchitecture) => void,
): Map<string, Allocation> {
  let parsed: unknown;
  try {
    parsed = parseOutlineJSON(raw, finishReason);
  } catch (error) {
    if (error instanceof OutlineOutputExhaustedError) throw error;
    throw new Error("allocation planner returned invalid JSON");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("allocation planner response must be an object");
  }
  const allocations = (parsed as { allocations?: unknown }).allocations;
  if (!Array.isArray(allocations)) {
    throw new Error("allocation planner response missing allocations array");
  }

  const validBeatIDs = new Set(beats.map((beat) => beat.id));
  const seen = new Set<string>();
  const out = new Map<string, Allocation>();
  for (const item of allocations) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("allocation contains a malformed item");
    }
    const candidate = item as Record<string, unknown>;
    const unexpectedKeys = Object.keys(candidate).filter((key) =>
      !["beatIndex", "minSections", "containerCounts", "rationale"].includes(key)
    );
    if (unexpectedKeys.length > 0) {
      throw new Error(
        `allocation contains unexpected field(s): ${unexpectedKeys.join(", ")}`,
      );
    }
    const beatIndex = candidate.beatIndex;
    const minSections = candidate.minSections;
    const rationale = candidate.rationale;
    if (!Number.isInteger(beatIndex) || Number(beatIndex) < 0 || Number(beatIndex) >= beats.length) {
      throw new Error(`allocation contains unknown beatIndex: ${String(beatIndex)}`);
    }
    // The model returns only an ordinal. The server resolves it to the exact
    // canonical supplied beat ID; UUID spelling is never model-authored.
    const beatID = beats[Number(beatIndex)].id;
    if (seen.has(beatID)) {
      throw new Error(`allocation contains duplicate beatIndex: ${String(beatIndex)}`);
    }
    if (!Number.isInteger(minSections) || Number(minSections) < 0 || Number(minSections) > 20) {
      throw new Error(`allocation has invalid minSections for beat ${beatID}`);
    }
    if (typeof rationale !== "string" || rationale.trim() === "") {
      throw new Error(`allocation has missing rationale for beat ${beatID}`);
    }
    // Legacy tests/checkpoints may omit this additive field; strict live
    // planner responses include all five numeric keys.
    const rawCounts = candidate.containerCounts;
    let containerCounts: NovelContainerCounts | undefined;
    if (rawCounts && typeof rawCounts === "object" && !Array.isArray(rawCounts) &&
      Object.keys(rawCounts).length === NOVEL_LEAF_CONTAINERS.length &&
      NOVEL_LEAF_CONTAINERS.every((container) =>
        Object.hasOwn(rawCounts, container) &&
        Number.isInteger((rawCounts as Record<string, unknown>)[container]) &&
        Number((rawCounts as Record<string, unknown>)[container]) >= 0 &&
        Number((rawCounts as Record<string, unknown>)[container]) <= 20)) {
      const counts = Object.fromEntries(NOVEL_LEAF_CONTAINERS.map((container) =>
        [container, Number((rawCounts as Record<string, number>)[container])])) as NovelContainerCounts;
      if (NOVEL_LEAF_CONTAINERS.reduce((sum, container) => sum + counts[container], 0) === Number(minSections)) {
        containerCounts = counts;
      }
    }
    // A mistaken sum or incomplete mix is not a reason to fail a usable
    // outline run. The budget fitter detects any missing/partial mix and
    // conservatively falls back to the previous chapter-equivalent plan.
    seen.add(beatID);
    out.set(beatID, {
      minSections: Number(minSections),
      coverageMinimum: Number(minSections) > 0 ? 1 : 0,
      allocationMinimum: Number(minSections),
      ...(containerCounts ? { containerCounts } : {}),
      rationale,
    });
  }
  if (out.size !== validBeatIDs.size) {
    const missing = beats.filter((beat) => !seen.has(beat.id)).map((beat) =>
      beat.id
    );
    throw new Error(`allocation is missing beat(s): ${missing.join(", ")}`);
  }
  // Legacy saved provider fixtures/checkpoints contain allocations only.
  // Live strict-schema responses include storyArchitecture; reject malformed
  // content rather than silently promoting a half-formed plan.
  const rawArchitecture = (parsed as Record<string, unknown>).storyArchitecture;
  if (rawArchitecture !== undefined) {
    const keys = STORY_ARCHITECTURE_SCHEMA.required;
    if (!rawArchitecture || typeof rawArchitecture !== "object" || Array.isArray(rawArchitecture) ||
        Object.keys(rawArchitecture).length !== keys.length) {
      throw new Error("allocation contains malformed storyArchitecture");
    }
    const values = rawArchitecture as Record<string, unknown>;
    const architecture = {} as StoryArchitecture;
    for (const key of keys) {
      const value = values[key];
      const maxLength = STORY_ARCHITECTURE_SCHEMA.properties[key].maxLength;
      if (typeof value !== "string" || !value.trim() || value.length > maxLength) {
        throw new Error(`allocation contains invalid storyArchitecture.${key}`);
      }
      architecture[key] = value.trim();
    }
    onArchitecture?.(architecture);
  }
  return new Map(beats.map((beat) => [beat.id, out.get(beat.id)!]));
}

export function buildAllocationPrompt(
  req: OutlineFromRecipeRequest,
  obligations: RecipeObligation[] = [],
): { system: string; user: string } {
  const isNovel = requestedStoryMaterialFormat(req) === "novel";
  const maxBudgetedSections = isNovel ? maximumContainerPlannedNewSections(req) : maximumBudgetedNewSections(req);
  const containerBudgetInstructions = isNovel
    ? `When no reliable container mix is available, use approximately ${NOVEL_MIXED_SECTION_ESTIMATE_TOKENS.toLocaleString()} tokens per typical mixed section; this gives an upper planning estimate of about ${Math.round(NOVEL_PREFERRED_MIN_WORDS * TOKENS_PER_WORD / NOVEL_MIXED_SECTION_ESTIMATE_TOKENS)} sections at the preferred target and about ${maxBudgetedSections} at the hard maximum, not a quota. When choosing a reliable mix, budget the story's real section sizes instead. Return containerCounts on each beat: scene=1,300 midpoint tokens, developedScene=2,250, setPiece=3,500, sceneSequence=5,000, chapter=5,500. minSections MUST equal the sum of its five containerCounts. Total proposed token midpoints PLUS existing section midpoints, divided by 1.3, should approach 115,000 projected words and must never exceed 125,000. Do not treat a scene as a chapter. Include enough causally distinct story to reach the goal without padding or relabeling scenes as chapters. The 125,000-word cap is absolute.`
    : "Allocate the number of format-appropriate sections needed for complete Story Arc coverage without the novel-only word or container budget.";
  const system =
    `You are an expert outliner. Given a complete canonical recipe/project payload, a verified story-material enrichment package, and a story arc template (ordered beats), decide how many outline sections each beat deserves in this particular ${requestedStoryMaterialFormat(req)}.

## Choose the story BEFORE allocating its chapters (same model call)
First derive the causal story architecture from the AUTHOR'S RECIPE, including its actual protagonist motives, genre, tone, relationships, world rules, and ending promise. The recipe is authoritative. The context deliberately withholds planner-invented institutional apparatus, tactical escalation ladders, and ready-made event locations until the author-driven story is selected. Choose a narrative trajectory that could only arise from these characters' particular appetites, humiliations, obsessions, mistakes and competing desires; do not fill a national or humanity-scale premise with a single bounded security operation just because that is easy to resolve. Treat enrichment as optional candidate characters, reversals, antagonists, and locations; use only ideas that make the authored premise more specific and compelling. An invented institutional operation, government contractor, screening campaign, investigation, or technical gadget is NOT an implicit canon fact. Never allow repetition of a planner-invented apparatus across categories to make it the automatic plot engine; such mechanisms remain valid when the recipe calls for them or when character-caused events make them compelling.

Return a compact storyArchitecture: centralQuestion (the premise's concrete dramatic question), characterCausality (the specific protagonist/supporting-person decisions driving distinct reversals), decisiveClimax (what irreversibly HAPPENS to settle the central threat), endingConsequence (the definite changed world/relationships AFTER that completed confrontation), and deliberatelyOpenThreads (mysteries left open without withholding the central outcome). Choose the decisive outcome first. For a Story Arc with a required climax beat, commit the actual resolution of the central confrontation to that beat; final-image/aftermath beats must inherit the achieved outcome, not start another rescue, larger confrontation, or cliffhanger. Tragedy, ambiguity, partial victories, and morally compromised endings are welcome when the CENTRAL outcome is definite. If there are accepted existing sections, honor their established events and do not rewrite their history.

THEN choose the beat-by-beat causal movements, using each allocation rationale as a short, specific commitment explaining the contribution to that selected story, not simply the reason for a chapter count. Ensure the climax and ending rationale correspond to the chosen architecture. THEN budget and assign containerCounts and minSections; the quantities serve the story, not the reverse. All decisions belong in this ONE outline-plan response, not another planning stage.

This request is for a ${requestedStoryMaterialFormat(req)}. For a novel, plan the complete first-pass book at approximately 115,000 projected words while staying below the 125,000-word maximum. Use each known container's midpoint as the authoritative estimate; when the container mix is unknown, use the named 3,500-token mixed-section planning estimate rather than treating every section as a chapter. Consider the author's recipe and explicit requirements, enriched story material, the selected Story Arc and the relative dramatic weight of each beat, and the projected contribution of existing sections. Distribute distinct, substantial chapter-scale units according to the narrative material each movement requires; do not evenly distribute a quota or create filler. Every additional section must introduce meaningful events, consequences, decisions, discoveries, reversals, or changes in tactical or emotional state. Preserve the complete author-specified story, and never allocate duplicate or unnecessary sections merely to reach the word target. ${containerBudgetInstructions}

Allocate sections according to distinct dramatic developments, not the number of steps, conversations, or locations involved in one development. Base the size and distribution on the dramatic developments already selected in storyArchitecture and each beat's narrative commitment. Consecutive preparations for the same confrontation, repeated consideration of the same decision, and multiple observations of one outcome generally belong within a larger section unless each independently changes the narrative state. Prefer appropriately substantial containers over fragmenting a single causal unit to meet the projected length target.

${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}

## Recipe realization priority
Treat planningContext.premiseComponents as DISTINCT, authored commitments, not optional enrichment. Map them to the current book at the scale the author actually requested. Series-level consequences can be seeded, foreshadowed or advanced through character-driven choices; do not invent a forced national or humanity-saving operation to discharge them now. A chapter-level local victory is neither a substitute for a series promise nor grounds to claim that promise has already been fulfilled. Preserve each component without dictating its final-series payoff.
Treat the supplied recipe as the governing creative brief. Required obligations must materially drive the events, escalation, relationships, tone, and ending; do not satisfy them by attaching IDs to otherwise generic sections. In each beat rationale, reserve appropriate, DISTINCT dramatic developments for recipe story non-negotiables, including recurring experiences and adult intensity where authored. Do not pack all story-wide obligations into the first beat or treat them as decorative labels; chapter generation will NOT have a narrative repair pass. Allocate enough distinct dramatic space for the recipe's premise and populated character/relationship material before adding generic scale. Do not let the arc's conventional genre associations dictate the kinds of scenes being allocated.

## Recipe obligations
The JSON request contains the authoritative obligations exactly once.

Output a single storyArchitecture FIRST (all five short text fields), THEN exactly one allocation for every Story Arc beat using beatIndex, the zero-based ordinal from the ordered beat list below. Never output UUIDs or beat IDs in allocations. The server maps beatIndex to the canonical beat identity. Include every beat exactly once. For a fresh novel with no accepted sections, minSections is the intended complete first-pass allocation for that beat, not merely a minimum coverage estimate; the allocations together must plan the complete book at approximately 115,000 projected words and below 125,000. Account for the supplied existingSections before allocating new work: when accepted sections already contribute to a beat, minSections is only the additional sections still required, and a beat with sufficient existing coverage must remain at 0. Every allocated section must represent distinct substantive material supported by the recipe, enrichment, and arc. Do not add sections to a sufficiently covered beat, invent padding, or leave routine book-length development to later expansion. Each allocation rationale records the selected beat's causal movement, especially the decisive clash and its later consequences. Do not output any other root key. ${isNovel ? "Provide all five containerCounts keys for every beat, including zeros." : "Do not return novel-only containerCounts."}

Output JSON only. No commentary, no prose.`;

  const planningView = buildArchitecturePlanningView(
    { ...req, storyMaterialEnrichment: req.storyMaterialEnrichment },
    obligations,
    req.storyMaterialEnrichment,
  );
  const existingSectionsByBeat = Object.fromEntries(req.arcTemplate.beats.map((beat) => [
    beat.id,
    (req.existingSections ?? []).filter((section) => section.storyArcBeatID === beat.id).map((section) => ({
      id: (section as any).id ?? null,
      title: section.title ?? null,
      summary: section.summary ?? null,
      terminalState: (section as any).terminalState ?? section.terminalBeat ?? null,
      recipeRequirementIDs: section.recipeRequirementIDs ?? [],
    })),
  ]));
  const existingUnlinkedSections = (req.existingSections ?? [])
    .filter((section) => !section.storyArcBeatID || !req.arcTemplate.beats.some((beat) => beat.id === section.storyArcBeatID))
    .map((section) => ({ title: section.title ?? null, summary: section.summary ?? null }));
  const user = JSON.stringify({
    planningContext: planningView,
    existingSectionsByBeat,
    existingUnlinkedSections,
    allocation: isNovel
      ? "Choose containerCounts first; minSections equals their sum, and their actual midpoints should project about 115,000 words. Accepted existing work counts once."
      : "For non-novels, return format-appropriate residual minSections per beat without novel containerCounts.",
    ...(isNovel ? { containerMidpointTokens: Object.fromEntries(
      NOVEL_LEAF_CONTAINERS.map((container) => [container, projectedExpectedTokens([{ container }])]),
    ) } : {}),
    hint: req.hint ?? null,
  }, null, 2);
  return { system, user };
}

/** Non-novel allocations retain their existing three-field strict contract. */
function allocationSchemaForFormat(req: OutlineFromRecipeRequest) {
  if (requestedStoryMaterialFormat(req) === "novel") return ALLOCATION_SCHEMA;
  const { containerCounts: _novelOnly, ...properties } = ALLOCATION_SCHEMA.properties.allocations.items.properties;
  return {
    ...ALLOCATION_SCHEMA,
    properties: { allocations: {
      ...ALLOCATION_SCHEMA.properties.allocations,
      items: {
        ...ALLOCATION_SCHEMA.properties.allocations.items,
        properties,
        required: ["beatIndex", "minSections", "rationale"],
      },
    } },
  };
}

export async function planSectionAllocation(
  req: OutlineFromRecipeRequest,
  apiKey: string,
  billableCall?: SuggestionLLMCall,
  obligations: RecipeObligation[] = [],
  options: { retryOnly?: boolean; deferRetry?: boolean; onArchitecture?: (architecture: StoryArchitecture) => void } = {},
): Promise<Map<string, Allocation>> {
  const { system, user } = buildAllocationPrompt(req, obligations);
  const allocationSchema = allocationSchemaForFormat(req);
  const responseFormat = {
    type: "json_schema",
    json_schema: {
      name: "outline_section_allocations",
      strict: true,
      schema: allocationSchema,
    },
  };

  const call = async (correction: boolean): Promise<string> => {
    const callSystem = correction
      ? `${system}\n\nThe previous allocation was invalid. Return a complete corrected allocation for every beat; never omit, duplicate, or invent a beat.`
      : system;
    const rawResult = billableCall
      ? await billableCall(
        callSystem,
        user,
        3600,
        responseFormat,
        correction ? "outline-plan-retry" : "outline-plan",
        (content, finishReason) => parseAndValidateAllocation(content, req.arcTemplate.beats, finishReason),
      )
      : {
        content: await callOpenAI(callSystem, user, apiKey, {
          maxTokens: 3600,
          useJsonSchema: true,
          jsonSchemaName: "outline_section_allocations",
          jsonSchema: allocationSchema,
        }),
        creditCostCharged: 0,
        remainingCredits: 0,
      };
    return rawResult.content;
  };

  let firstError: Error | undefined;
  const corrections = options.retryOnly ? [true] : [false, true];
  for (const correction of corrections) {
    try {
      let architecture: StoryArchitecture | undefined;
      const parsed = parseAndValidateAllocation(
        await call(correction), req.arcTemplate.beats, undefined,
        (value) => { architecture = value; },
      );
      const fitted = fitAllocationToNovelBudget(parsed, req);
      if (architecture) options.onArchitecture?.(architecture);
      return fitted;
    } catch (error) {
      if (error instanceof SuggestionWorkerYield) throw error;
      if (error instanceof OutlineOutputExhaustedError) throw error;
      if (error instanceof AllocationBudgetConstraintError) throw error;
      if (isProviderBillingUnavailable(error)) throw error;
      if (!(error instanceof Error)) throw error;
      firstError = error;
      if (!correction && options.deferRetry) throw new AllocationRetryRequired(error.message);
    }
  }
  throw new Error(
    `allocation planner failed validation after retry: ${
      firstError?.message ?? "unknown error"
    }`,
  );
}

export async function checkRateLimit(
  supabase: ReturnType<typeof makeSupabase>,
  userId: string,
): Promise<{ allowed: boolean; retryAfterSeconds?: number }> {
  const now = Date.now();
  const oneMinAgo = new Date(now - 60_000).toISOString();
  const oneHourAgo = new Date(now - 3_600_000).toISOString();

  const { count: perMinute } = await supabase
    .from("generation_request_logs")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("action", "outline-from-recipe")
    .gte("created_at", oneMinAgo);

  if ((perMinute ?? 0) >= RATE_LIMIT_PER_MINUTE) {
    return { allowed: false, retryAfterSeconds: 60 };
  }

  const { count: perHour } = await supabase
    .from("generation_request_logs")
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("action", "outline-from-recipe")
    .gte("created_at", oneHourAgo);

  if ((perHour ?? 0) >= RATE_LIMIT_PER_HOUR) {
    return { allowed: false, retryAfterSeconds: 3600 };
  }

  return { allowed: true };
}

export async function logRequest(
  supabase: ReturnType<typeof makeSupabase>,
  userId: string,
  status: string,
  errorCode?: string,
  selectedModel?: { id: string; provider_model: string },
): Promise<void> {
  // Record the resolved catalog identity, not the legacy environment default.
  // This is observability only; provider calls and pricing are unchanged.
  const { error } = await supabase.from("generation_request_logs").insert({
    request_id: crypto.randomUUID(),
    user_id: userId,
    action: "outline-from-recipe",
    generation_length_mode: "outline",
    output_budget: 0,
    status,
    error_code: errorCode ?? null,
    model_name: selectedModel?.provider_model ?? OPENAI_MODEL,
    selected_model_id: selectedModel?.id ?? null,
    provider_model: selectedModel?.provider_model ?? null,
    created_at: new Date().toISOString(),
  });
  if (error) {
    // Supabase returns insert failures via the resolved value rather than
    // throwing, so an `await insert(...)` swallows them. Throw here so the
    // caller's try/catch (or any direct caller) actually sees the failure
    // — production logging depends on this visibility because
    // generation_request_logs is service-role INSERT-only and a silently
    // dropped error would leave the rate limiter blind to new requests.
    throw new Error(
      `logRequest failed: ${error.message ?? JSON.stringify(error)}`,
    );
  }
}

async function callOpenAI(
  system: string,
  user: string,
  apiKey: string,
  options?: {
    maxTokens?: number;
    useJsonSchema?: boolean;
    jsonSchemaName?: string;
    jsonSchema?: Record<string, unknown>;
  },
): Promise<string> {
  const inputLimit = inputTokenLimitDetails(
    estimateTokensFromMessages([
      { content: system },
      { content: user },
    ]),
  );
  if (inputLimit) {
    throw new Error(
      `input_token_limit_exceeded: estimated input is ${inputLimit.estimatedInputTokens} tokens; ` +
        `Cathedral's hard limit is ${inputLimit.limit} tokens`,
    );
  }
  const ac = new AbortController();
  const timeout = setTimeout(() => ac.abort(), 115_000);
  try {
    const response = await fetch(OPENAI_API_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        messages: [
          { role: "system", content: system },
          { role: "user", content: user },
        ],
        max_completion_tokens: options?.maxTokens ?? 4096,
        response_format: options?.useJsonSchema === false
          ? { type: "json_object" }
          : {
            type: "json_schema",
            json_schema: {
              name: options?.jsonSchemaName ?? "outline_suggestions",
              strict: true,
              schema: options?.jsonSchema ?? { type: "object" },
            },
          },
        ...(supportsCustomTemperature(OPENAI_MODEL) ? { temperature: 0.7 } : {}),
      }),
      signal: ac.signal,
    });
    if (!response.ok) {
      const errText = await response.text();
      throw new Error(
        `OpenAI API error ${response.status}: ${errText.slice(0, 500)}`,
      );
    }
    const data = await response.json();
    return data.choices?.[0]?.message?.content ?? "";
  } finally {
    clearTimeout(timeout);
  }
}

export function countStoryMaterialItems(material: StoryMaterialEnrichment): number {
  return STORY_MATERIAL_CATEGORIES.reduce((total, category) => total + material[category].length, 0);
}

export function countSuggestionsByBeat(suggestions: Suggestion[]): Record<string, number> {
  return suggestions.reduce<Record<string, number>>((counts, suggestion) => {
    counts[suggestion.storyArcBeatID] = (counts[suggestion.storyArcBeatID] ?? 0) + 1;
    return counts;
  }, {});
}

export class AllocationCoverageValidationError extends Error {
  readonly code = "missing_story_arc_coverage";
}

export function allocationDeficits(
  suggestions: Suggestion[],
  allocation: Map<string, Allocation>,
): Array<{ beatID: string; required: number; actual: number; missing: number }> {
  const counts = countSuggestionsByBeat(suggestions);
  return Array.from(allocation.entries())
    .map(([beatID, plan]) => {
      const actual = counts[beatID] ?? 0;
      // `minSections` is the budget-normalized hard floor for new sections.
      // `allocationMinimum` retains the planner's original advisory request.
      const required = plan.minSections;
      return { beatID, required, actual, missing: Math.max(0, required - actual) };
    })
    .filter((entry) => entry.missing > 0);
}

export function allocationShortfalls(
  suggestions: Suggestion[],
  allocation: Map<string, Allocation>,
): Array<{ beatID: string; intended: number; actual: number; shortfall: number }> {
  const counts = countSuggestionsByBeat(suggestions);
  return Array.from(allocation.entries())
    .map(([beatID, plan]) => {
      const intended = plan.allocationMinimum ?? plan.minSections;
      const actual = counts[beatID] ?? 0;
      return { beatID, intended, actual, shortfall: Math.max(0, intended - actual) };
    })
    .filter((entry) => entry.shortfall > 0);
}

export function allocationRepairExhausted(
  deficits: Array<{ beatID: string; required: number; actual: number; missing: number }>,
  rounds: ExpansionRoundDiagnostic[] = [],
): boolean {
  return deficits.length > 0 && rounds.some((round) => round.round >= MAX_EXPANSION_ROUNDS);
}

export function assertAllocationCoverage(
  suggestions: Suggestion[],
  allocation: Map<string, Allocation>,
  phase = "outline",
): void {
  const deficits = allocationDeficits(suggestions, allocation);
  if (deficits.length > 0) {
    throw new AllocationCoverageValidationError(
      `${phase}: ${deficits.map((entry) => `beat ${entry.beatID} returned ${entry.actual} section${entry.actual === 1 ? "" : "s"}; minimum is ${entry.required}`).join("; ")}`,
    );
  }
}

const STRUCTURAL_TERMINAL_BEAT_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Structural identifiers are not usable closing actions. Keep the outline
 * usable by deriving the field from the already-authoritative Section Contract
 * instead of rejecting or re-calling the provider. */
export function normalizeTerminalBeat(
  suggestion: Partial<Suggestion>,
  beatIds: Set<string>,
): string {
  const terminalBeat = typeof suggestion.terminalBeat === "string" ? suggestion.terminalBeat.trim() : "";
  const isStructural = terminalBeat.length === 0 ||
    terminalBeat.toUpperCase() === "END" ||
    STRUCTURAL_TERMINAL_BEAT_UUID.test(terminalBeat) ||
    beatIds.has(terminalBeat);
  if (!isStructural) return terminalBeat.slice(0, 1000);
  const fallback = [
    suggestion.terminalState,
    suggestion.resultingChange,
    suggestion.dramaticEvent,
    suggestion.summary,
  ].find((value): value is string => typeof value === "string" && value.trim().length > 0);
  return (fallback ?? terminalBeat).trim().slice(0, 1000);
}

export function validateSuggestions(
  parsed: any,
  beatIds: Set<string>,
  allocation?: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  template?: Pick<ArcTemplateBlob, "name" | "beats" | "relationshipFocus" | "intimacyMilestoneRoles">,
): { suggestions: Suggestion[]; warnings: string[] } {
  const warnings: string[] = [];
  if (!parsed || !Array.isArray(parsed.suggestions)) {
    throw new Error("response missing suggestions array");
  }
  const used = new Set<string>();
  const valid: Suggestion[] = [];
  for (const s of parsed.suggestions) {
    if (!s?.title || !s?.summary) {
      warnings.push("dropped suggestion with missing title/summary");
      continue;
    }
    if (!ALLOWED_CONTAINERS.has(s.container)) {
      warnings.push(
        `dropped suggestion with invalid container: ${s.container}`,
      );
      continue;
    }
    if (!ALLOWED_POVS.has(s.pov)) {
      warnings.push(`dropped suggestion with invalid pov: ${s.pov}`);
      continue;
    }
    if (!s.terminalBeat || String(s.terminalBeat).trim() === "") {
      warnings.push("dropped suggestion with empty terminalBeat");
      continue;
    }
    if (!beatIds.has(s.storyArcBeatID)) {
      warnings.push(
        `dropped suggestion with unknown beat id: ${s.storyArcBeatID}`,
      );
      continue;
    }
    if (template) {
      if (typeof s.dramaticFunction !== "string" || !DRAMATIC_FUNCTIONS.includes(s.dramaticFunction)) {
        throw new Error(`section ${String(s.title).slice(0, 120)} is missing or has an invalid dramatic function`);
      }
      const beat = template.beats.find((candidate) => candidate.id === s.storyArcBeatID);
      const roleContract = beat ? arcRoleContract(beat, template.name) : undefined;
      if (roleContract && !roleContract.allowedFunctions.includes(s.dramaticFunction)) {
        throw new Error(`section ${String(s.title).slice(0, 120)} declares ${s.dramaticFunction}, not allowed in beat ${s.storyArcBeatID}`);
      }
    }
    const requirementIDs = s.recipeRequirementIDs;
    if (obligations.length > 0 && !Array.isArray(requirementIDs)) {
      throw new Error(`section ${String(s.title).slice(0, 120)} is missing recipeRequirementIDs`);
    }
    const validRequirementIDs = Array.isArray(requirementIDs)
      ? requirementIDs.filter((id: unknown): id is string => typeof id === "string" && obligations.some((obligation) => obligation.id === id))
      : [];
    if (obligations.length > 0 && validRequirementIDs.length !== requirementIDs.length) {
      throw new Error(`section ${String(s.title).slice(0, 120)} references an unknown recipe requirement`);
    }
    const beatForEvidence = template?.beats.find((beat) => beat.id === s.storyArcBeatID);
    const semanticObligations = beatForEvidence ? arcRoleContract(beatForEvidence, template?.name).semanticObligations : [];
    const isEligibleWholeArcIntimacyBeat = Boolean(
      beatForEvidence &&
      template?.relationshipFocus === "primary" &&
      Array.isArray(template?.intimacyMilestoneRoles) &&
      template.intimacyMilestoneRoles.includes(beatForEvidence.role),
    );
    const allowedObligationIDs = new Set([
      ...semanticObligations.map((obligation) => obligation.id),
      ...(isEligibleWholeArcIntimacyBeat ? [SELECTED_INTIMACY_LEVEL_OBLIGATION] : []),
    ]);
    const groundedEvidence = validateGroundedArcEvidence(s.arcObligationEvidence, s, allowedObligationIDs);
    if (groundedEvidence.error) throw new Error(`section ${String(s.title).slice(0, 120)} has invalid arcObligationEvidence: ${groundedEvidence.error}`);

    valid.push({
      title: String(s.title).slice(0, 200),
      summary: String(s.summary).slice(0, 4000),
      container: s.container,
      pov: s.pov,
      terminalBeat: normalizeTerminalBeat(s, beatIds),
      // Preserve legacy payload shape when older callers omit the additive
      // contract; new structured responses retain all four explicit fields.
      ...(typeof s.entryState === "string" ? { entryState: s.entryState.slice(0, 1200) } : {}),
      ...(typeof s.dramaticEvent === "string" ? { dramaticEvent: s.dramaticEvent.slice(0, 2000) } : {}),
      ...(typeof s.resultingChange === "string" ? { resultingChange: s.resultingChange.slice(0, 1200) } : {}),
      ...(typeof s.terminalState === "string" ? { terminalState: s.terminalState.slice(0, 1200) } : {}),
      ...(DRAMATIC_FUNCTIONS.includes(s.dramaticFunction) ? { dramaticFunction: s.dramaticFunction as DramaticFunction } : {}),
      ...(groundedEvidence.value ? { arcObligationEvidence: groundedEvidence.value } : {}),
      plannedWordRange: plannedWordRangeForContainer(s.container),
      storyArcBeatID: s.storyArcBeatID,
      ...(validRequirementIDs.length > 0 ? { recipeRequirementIDs: validRequirementIDs } : {}),
    });
    used.add(s.storyArcBeatID);
  }
  if (allocation) {
    assertAllocationCoverage(valid, allocation, "provider outline");
  } else {
    // Backward-compatible validation for callers that do not have a plan.
    for (const bid of beatIds) {
      if (!used.has(bid)) warnings.push(`no suggestion references beat ${bid}`);
    }
  }
  return { suggestions: valid, warnings };
}


export interface PlannerCharacterIntegration {
  // Advisory evidence only. Name/contract anchoring does not prove agency.
  absent: string[];
  mentionedWithoutCausalAnchor: string[];
  withCausalAnchor: string[];
}

export interface OutlineQualityDiagnostic {
  distinctnessIssues: string[];
  causalScaleIssues: string[];
  semanticArcIssues: string[];
  supportingEntities: string[];
  unusedStoryMaterialItems: number;
  plannerCharacterIntegration: PlannerCharacterIntegration;
  advisoryValidationError?: string;
}

function contractText(suggestion: Suggestion): string {
  return [
    suggestion.entryState ?? suggestion.summary,
    suggestion.dramaticEvent ?? suggestion.summary,
    suggestion.resultingChange ?? suggestion.terminalBeat,
    suggestion.terminalState ?? suggestion.terminalBeat,
  ].join(" ").toLowerCase();
}

// Character integration is an advisory, deliberately conservative name test.
// Unlike unused-material heuristics, it never credits generic label words such
// as "attention" or "security" as evidence that a character was selected.
function characterIsNamed(text: string, label: string): boolean {
  const fullName = label.split(",")[0].trim().replace(/^(?:Dr|Mr|Mrs|Ms)\.?\s+/i, "");
  if (!fullName) return false;
  const escaped = (value: string) => value.replace(/[.*+?^$\{\}()|[\]\\]/g, "\\$&");
  if (new RegExp(`\\b${escaped(fullName)}\\b`, "i").test(text)) return true;
  const parts = fullName.split(/\s+/);
  // Proper first names or surnames may be used alone in section contracts.
  // Case-sensitive matching avoids counting ordinary lowercase label words
  // such as "being", "attention", or "security" as character references.
  return [parts[0], parts[parts.length - 1]]
    .filter((name) => name.length >= 3 && /^[A-Z]/.test(name))
    .some((name) => new RegExp(`\\b${escaped(name)}\\b`).test(text));
}

export function analyzePlannerCharacterIntegration(
  suggestions: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
): PlannerCharacterIntegration {
  const result: PlannerCharacterIntegration = {
    absent: [],
    mentionedWithoutCausalAnchor: [],
    withCausalAnchor: [],
  };
  for (const item of storyMaterial?.characters ?? []) {
    if (item.source !== "planner") continue;
    const mentioned = suggestions.some((section) =>
      characterIsNamed([section.title, section.summary, section.entryState, section.dramaticEvent, section.resultingChange, section.terminalState].join(" "), item.label)
    );
    if (!mentioned) {
      result.absent.push(item.id);
      continue;
    }
    const causal = suggestions.some((section) =>
      characterIsNamed([section.dramaticEvent, section.resultingChange].join(" "), item.label)
    );
    (causal ? result.withCausalAnchor : result.mentionedWithoutCausalAnchor).push(item.id);
  }
  return result;
}

function contentTokens(value: string): Set<string> {
  return new Set((value.toLowerCase().match(/[a-z0-9]{4,}/g) ?? []).filter((token) => !["that", "with", "from", "into", "this", "then", "they", "their", "will", "must"].includes(token)));
}

function tokenSimilarity(left: string, right: string): number {
  const a = contentTokens(left);
  const b = contentTokens(right);
  if (a.size === 0 || b.size === 0) return 0;
  let intersection = 0;
  for (const token of a) if (b.has(token)) intersection++;
  return intersection / (a.size + b.size - intersection);
}

/** Detects repeated dramatic work without deleting sections. The caller can
 * request a bounded repair; the editor's job is differentiation first. */
export function findDramaticDistinctnessIssues(suggestions: Suggestion[]): string[] {
  const issues: string[] = [];
  for (let index = 0; index < suggestions.length; index++) {
    const current = suggestions[index];
    for (let otherIndex = Math.max(0, index - 1); otherIndex < index; otherIndex++) {
      const other = suggestions[otherIndex];
      if (other.storyArcBeatID !== current.storyArcBeatID) continue;
      const eventSimilarity = tokenSimilarity(
        current.dramaticEvent ?? current.summary,
        other.dramaticEvent ?? other.summary,
      );
      const changeSimilarity = tokenSimilarity(
        current.resultingChange ?? current.terminalBeat,
        other.resultingChange ?? other.terminalBeat,
      );
      if (eventSimilarity >= 0.92 && changeSimilarity >= 0.75) {
        issues.push(`sections "${other.title}" and "${current.title}" perform substantially the same dramatic job; differentiate event, opponent, location, objective, consequence, relationship, or information`);
      }
    }
  }
  return issues;
}

/** General causal-scale gate. It intentionally reports a planning defect rather
 * than enforcing a Brody-specific vocabulary or deleting sections. */
export function findCausalScaleIssues(
  suggestions: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
  format: StoryMaterialFormat = "novel",
): string[] {
  if (format !== "novel" || suggestions.length === 0) return [];
  const issues: string[] = [];
  const escalationCount = storyMaterial?.escalationLadder.length ?? 0;
  const eventText = suggestions.map(contractText).join(" ");
  const globalClaim = /\b(world|global|nation|empire|entire|everyone|civilization|planetary|political)\b/i.test(eventText);
  const intermediateSignals = /\b(local|neighborhood|town|city|regional|district|network|institution|alliance|route|supply|countermeasure|aftermath|consequence|reversal|discovery)\b/i.test(eventText);
  if (globalClaim && escalationCount < 3) issues.push("large-scale outcome lacks a three-step enrichment escalation ladder");
  if (globalClaim && !intermediateSignals) issues.push("large-scale outcome lacks concrete intermediate consequences");
  return issues;
}


function semanticText(suggestion: Suggestion): string {
  return [suggestion.title, suggestion.summary, suggestion.dramaticEvent, suggestion.resultingChange, suggestion.terminalState, suggestion.terminalBeat]
    .filter(Boolean).join(" ").toLowerCase();
}

/**
 * Beat roles describe broad structure; semantic obligations describe the
 * concrete dramatic work that makes a role real. Evidence is required from
 * the provider, but the server still checks that the obligated state-change
 * fields are present rather than trusting a role label alone.
 */
export function normalizeEvidenceText(value: string): string {
  let normalized = value.replace(/\s+/g, " ").trim();
  const wrappers: Array<[string, string]> = [["\"", "\""], ["“", "”"], ["'", "'"], ["‘", "’"]];
  for (const [opening, closing] of wrappers) {
    if (normalized.startsWith(opening) && normalized.endsWith(closing) && normalized.length >= opening.length + closing.length) {
      normalized = normalized.slice(opening.length, normalized.length - closing.length).trim();
      break;
    }
  }
  return normalized.replace(/\s+/g, " ").trim();
}

export function findGroundedSemanticField(
  section: Partial<Suggestion> | undefined,
  quote: string,
  allowedFields: ArcSemanticField[],
): ArcSemanticField | undefined {
  const normalizedQuote = normalizeEvidenceText(quote);
  if (!section || !normalizedQuote) return undefined;
  return allowedFields.find((candidate) =>
    normalizeEvidenceText(String((section as any)[candidate] ?? "")).toLocaleLowerCase().includes(normalizedQuote.toLocaleLowerCase())
  );
}

/**
 * Ground an independent verifier's claimed quote against the actual Section
 * Contracts. Correct case and a mistaken section index only when the source
 * text appears in one permitted section. Never search another Story Arc beat
 * for a beat-scoped obligation, and never infer semantic satisfaction.
 */
export function resolveSemanticEvidenceCitation(
  suggestions: Suggestion[],
  claimedIndex: number,
  quote: string,
  allowedFields: ArcSemanticField[],
  permittedIndexes: number[],
): { sectionIndex: number; field: ArcSemanticField; quote: string } | undefined {
  const needle = normalizeEvidenceText(quote);
  if (!needle) return undefined;
  const permitted = new Set(permittedIndexes);
  const locate = (sectionIndex: number) => {
    if (!permitted.has(sectionIndex)) return undefined;
    const section = suggestions[sectionIndex];
    if (!section) return undefined;
    for (const field of allowedFields) {
      const actual = normalizeEvidenceText(String(section[field] ?? ""));
      const offset = actual.toLocaleLowerCase().indexOf(needle.toLocaleLowerCase());
      if (offset >= 0) {
        return { sectionIndex, field, quote: actual.slice(offset, offset + needle.length) };
      }
    }
    return undefined;
  };
  // The claimed index wins if its quotation is grounded in an allowed field.
  const atClaimed = locate(claimedIndex);
  if (atClaimed) return atClaimed;
  const matches = permittedIndexes.map(locate).filter((hit) => hit !== undefined);
  // Duplicate text across two sections is ambiguous, not permission to guess.
  return matches.length === 1 ? matches[0] : undefined;
}

export function isSemanticEvidenceGroundingFailure(reason: string): boolean {
  return reason.startsWith("provider evidence quote was not grounded") ||
    reason.startsWith("creative-fidelity evidence quote was not grounded");
}

export function validateGroundedArcEvidence(
  raw: unknown,
  section: Partial<Suggestion>,
  allowedObligationIDs: Set<string>,
): { value?: Record<string, Array<{ field: "dramaticEvent" | "resultingChange" | "terminalState"; quote: string }>>; error?: string } {
  if (raw == null) return {};
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "evidence must be an object" };
  const out: Record<string, Array<{ field: "dramaticEvent" | "resultingChange" | "terminalState"; quote: string }>> = {};
  for (const [obligationID, entries] of Object.entries(raw as Record<string, unknown>)) {
    if (!allowedObligationIDs.has(obligationID)) return { error: `unknown obligation ${obligationID}` };
    // Evidence is optional. A strict-schema provider may still emit an empty
    // array for an obligation it could not ground; treat that as no evidence
    // and let the independent semantic verifier decide whether repair is
    // needed instead of failing the entire outline structurally.
    if (!Array.isArray(entries)) return { error: `obligation ${obligationID} has malformed evidence` };
    if (entries.length === 0) continue;
    out[obligationID] = [];
    for (const entry of entries) {
      if (!entry || typeof entry !== "object") return { error: `obligation ${obligationID} has malformed evidence` };
      const field = (entry as any).field;
      const quote = typeof (entry as any).quote === "string" ? normalizeEvidenceText((entry as any).quote) : "";
      if (!["dramaticEvent", "resultingChange", "terminalState"].includes(field)) return { error: `obligation ${obligationID} references an invalid field` };
      const actual = normalizeEvidenceText(String((section as any)[field] ?? ""));
      // Evidence is a provider-supplied hint, not the semantic gate. A model
      // may paraphrase a field even when the independent verifier can still
      // validate the obligation from the Section Contract fields.
      if (!quote || !actual.includes(quote)) continue;
      out[obligationID].push({ field, quote });
    }
    if (out[obligationID].length === 0) delete out[obligationID];
  }
  return { value: out };
}

/** Authored obligations are beat-level. A single appropriate Section Contract
 * may satisfy the obligation; neighboring plot/aftermath sections need not
 * manufacture evidence. Grounded evidence is only a reference, never proof
 * by itself. The independent verifier below is the semantic hard gate. */
export function validateArcSemanticObligations(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
): string[] {
  const issues: string[] = [];
  for (const beat of template.beats) {
    const obligations = arcRoleContract(beat, template.name).semanticObligations;
    if (obligations.length === 0) continue;
    const sections = suggestions.filter((section) => section.storyArcBeatID === beat.id);
    for (const obligation of obligations) {
      const satisfied = sections.some((candidate) => {
        const refs = candidate.arcObligationEvidence?.[obligation.id] ?? [];
        return refs.length > 0 && obligation.requiredFields.every((field) => typeof candidate[field] === "string" && candidate[field]!.trim().length > 0);
      });
      if (!satisfied) issues.push(`beat ${beat.label} (${beat.id}) is missing semantic obligation ${obligation.id}: ${obligation.instruction}`);
    }
  }
  return issues;
}


export type SemanticVerificationObligation = {
  obligationID: string;
  satisfied: boolean;
  sectionIndex: number;
  field: "dramaticEvent" | "resultingChange" | "terminalState";
  quote: string;
  reason: string;
};

export type SemanticVerificationResult = {
  arcWideObligations: SemanticVerificationObligation[];
  beats: Array<{ beatID: string; obligations: SemanticVerificationObligation[] }>;
  unsatisfied: Array<{ beatID: string; obligationID: string; reason: string }>;
};

/**
 * Prefer an accepted structural draft over a repair that did not objectively
 * improve verification. This is deliberately not a literary score: the only
 * comparison is the verifier's validated unresolved-obligation set.
 */
function semanticFailureIdentity(failure: { beatID: string; obligationID: string }): string {
  const { obligationID } = failure;
  const isStoryWide = obligationID === CREATIVE_FIDELITY_OBLIGATION ||
    obligationID.startsWith("premise_component_") ||
    obligationID === SELECTED_INTIMACY_LEVEL_OBLIGATION ||
    obligationID.startsWith("story_non_negotiable_");
  return isStoryWide ? `story:${obligationID}` : `beat:${failure.beatID}:${obligationID}`;
}

export function chooseBestSemanticOutline(
  original: Suggestion[],
  repaired: Suggestion[],
  originalVerification?: Pick<SemanticVerificationResult, "unsatisfied">,
  repairedVerification?: Pick<SemanticVerificationResult, "unsatisfied">,
): Suggestion[] {
  if (original.length === 0) return repaired;
  if (repaired.length === 0) return original;
  if (!originalVerification || !repairedVerification || !Array.isArray(originalVerification.unsatisfied) || !Array.isArray(repairedVerification.unsatisfied)) return original;
  const originalFailures = new Set(originalVerification.unsatisfied.map(semanticFailureIdentity));
  const repairedFailures = new Set(repairedVerification.unsatisfied.map(semanticFailureIdentity));
  const resolvesExistingFailure = [...originalFailures].some((failure) => !repairedFailures.has(failure));
  const introducesNewFailure = [...repairedFailures].some((failure) => !originalFailures.has(failure));
  return resolvesExistingFailure && !introducesNewFailure ? repaired : original;
}

const SEMANTIC_VERIFICATION_SCHEMA = {
  type: "object",
  properties: {
    arcWideObligations: {
      type: "array",
      items: {
        type: "object",
        properties: {
          obligationID: { type: "string" },
          satisfied: { type: "boolean" },
          sectionIndex: { type: "integer" },
          field: { type: "string", enum: ["dramaticEvent", "resultingChange", "terminalState"] },
          quote: { type: "string", maxLength: 1200 },
          reason: { type: "string", minLength: 1, maxLength: 1200 },
        },
        required: ["obligationID", "satisfied", "sectionIndex", "field", "quote", "reason"],
        additionalProperties: false,
      },
    },
    beats: {
      type: "array",
      items: {
        type: "object",
        properties: {
          beatID: { type: "string" },
          obligations: {
            type: "array",
            items: {
              type: "object",
              properties: {
                obligationID: { type: "string" },
                satisfied: { type: "boolean" },
                sectionIndex: { type: "integer" },
                field: { type: "string", enum: ["dramaticEvent", "resultingChange", "terminalState"] },
                quote: { type: "string", maxLength: 1200 },
                reason: { type: "string", minLength: 1, maxLength: 1200 },
              },
              required: ["obligationID", "satisfied", "sectionIndex", "field", "quote", "reason"],
              additionalProperties: false,
            },
          },
        },
        required: ["beatID", "obligations"],
        additionalProperties: false,
      },
    },
  },
  required: ["arcWideObligations", "beats"],
  additionalProperties: false,
} as const;

export function semanticVerificationInput(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats" | "relationshipFocus" | "intimacyMilestoneRoles">,
  recipe?: CanonicalRecipeEnvelope,
  premiseComponents: PremiseComponent[] = [],
): Record<string, unknown> {
  const requirement = intimacyRequirement({ arcTemplate: template as ArcTemplateBlob, recipe: recipe as CanonicalRecipeEnvelope });
  const eligible = new Set((template.intimacyMilestoneRoles ?? []));
  return {
    recipe: recipe ?? null,
    storyArcName: template.name,
    relationshipFocus: template.relationshipFocus ?? "none",
    intimacyMilestoneRoles: template.intimacyMilestoneRoles ?? [],
    selectedIntimacyLevel: requirement?.level ?? "unspecified",
    storyNonNegotiables: (Array.isArray(recipe?.storyNonNegotiables) ? recipe.storyNonNegotiables : []).map((item, index) => ({
      obligationID: `story_non_negotiable_${index}`,
      instruction: typeof item === "string" ? item : String((item as Record<string, unknown>)?.requirement ?? item),
      sections: suggestions.map((section, sectionIndex) => ({
        sectionIndex,
        beatID: section.storyArcBeatID,
        dramaticEvent: section.dramaticEvent ?? "",
        resultingChange: section.resultingChange ?? "",
        terminalState: section.terminalState ?? "",
      })),
    })),
    arcWideObligations: [...premiseComponents.map((component, index) => ({
      obligationID: `premise_component_${index}`,
      instruction: `Independently assess the authored promise "${component.sourceQuote}". Required current-book realization: ${component.requirement}. Verify that this distinct premise commitment is established at the AUTHOR'S intended scope: a book-level obligation requires a concrete dramatic realization, while a series-level payoff may be plausibly planted, foreshadowed, complicated or advanced without being resolved in this volume. Do not equate an unrelated local rescue with a world-saving victory, or demand a tactical operation to manufacture one. Ground the assessment in actual Section Contract events and consequences rather than labels. Do not require an unrequested final-series ending.`,
      sections: suggestions.map((section, sectionIndex) => ({
        sectionIndex, beatID: section.storyArcBeatID,
        dramaticEvent: section.dramaticEvent ?? "",
        resultingChange: section.resultingChange ?? "",
        terminalState: section.terminalState ?? "",
      })),
    })), ...(hasCreativeFidelityDirectives(recipe) ? [{
      obligationID: CREATIVE_FIDELITY_OBLIGATION,
      instruction: "Assess the whole outline's creative fidelity to the canonical recipe. Decide whether the sequence of actual dramatic events delivers the author's specified premise, character behavior, relationships, tone, genre, intensity, absurdity, world rules, contradictions, and intended reader experience, rather than merely mentioning those ingredients. Treat planner-generated enrichment as provisional: reject only when it materially redirects the story into a different narrative experience, and accept unusual, destructive, morally compromised, or mixed-genre events when they remain faithful to the recipe. If rejecting, identify a concrete section and quote the field that demonstrates the drift.",
      sections: suggestions.map((section, sectionIndex) => ({
        sectionIndex,
        beatID: section.storyArcBeatID,
        title: section.title ?? "",
        dramaticFunction: section.dramaticFunction ?? "",
        dramaticEvent: section.dramaticEvent ?? "",
        resultingChange: section.resultingChange ?? "",
        terminalState: section.terminalState ?? "",
      })),
    }] : []), ...(requirement ? [{
      obligationID: SELECTED_INTIMACY_LEVEL_OBLIGATION,
      instruction: requirement.instruction,
      eligibleMilestoneRoles: requirement.roles,
      sections: suggestions.flatMap((section, sectionIndex) => {
        const beat = template.beats.find((candidate) => candidate.id === section.storyArcBeatID);
        return beat && eligible.has(beat.role) ? [{ sectionIndex, beatID: beat.id, role: beat.role, label: beat.label, dramaticEvent: section.dramaticEvent ?? "", resultingChange: section.resultingChange ?? "", terminalState: section.terminalState ?? "" }] : [];
      }),
    }] : [])],
    beats: template.beats.map((beat) => ({
      beatID: beat.id,
      role: beat.role,
      label: beat.label,
      authoredDescription: beat.description ?? "",
      obligations: verificationObligationsForBeat(beat, template.name).map((obligation) => ({
        obligationID: obligation.id,
        instruction: obligation.instruction,
      })),
      sections: suggestions.flatMap((section, sectionIndex) => section.storyArcBeatID === beat.id
        ? [{ sectionIndex, dramaticEvent: section.dramaticEvent ?? "", resultingChange: section.resultingChange ?? "", terminalState: section.terminalState ?? "" }]
        : []),
    })).filter((beat) => (beat.obligations as unknown[]).length > 0),
  };
}

export async function verifyStoryArcSemantics(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats" | "relationshipFocus" | "intimacyMilestoneRoles">,
  billableCall: SuggestionLLMCall,
  recipe?: CanonicalRecipeEnvelope,
  action = "outline-semantic-verification",
  premiseComponents: PremiseComponent[] = [],
): Promise<SemanticVerificationResult> {
  const input = semanticVerificationInput(suggestions, template, recipe, premiseComponents);
  const raw = await billableCall(
    "You are an independent semantic verifier. First assess EVERY independently extracted authored premise component across the full outline. A local success cannot be declared fulfillment of a different larger promise. For a multi-book premise, an organically established credible thread or foreshadowed long-range stake can be satisfactory without a premature national or humanity-saving climax. Do not invent a required current-volume outcome when the author supplied only a series premise. Decide whether the actual Section Contract fields materially satisfy each authored Story Arc obligation and the required whole-outline creative_fidelity assessment, including whether required-resolution beats achieve a definite recipe-consistent outcome from resultingChange and terminalState. For creative_fidelity, evaluate the sequence of dramatic events against the complete canonical recipe's premise, populated character and relationship directives, tone, genre, intensity, absurdity, world rules, contradictions, and intended reader experience; do not pass merely because names or keywords appear. This is a material-drift review, not a perfection or style score: a coherent, usable outline with minor weaknesses, uneven emphasis, legitimate mixed-genre scenes, or editorial opportunities is satisfied. Planner-generated candidates are provisional and may be discarded. Accept procedural or institutional material when the recipe makes it central, and reject it only when it fundamentally redirects the authored story or omits essential creative commitments needed for a usable outline. If rejecting, provide a grounded quote from the section that demonstrates the material drift. An attempted action, incidental loss, atmospheric aftermath, or postponed confrontation is not resolution; do not accept dramaticEvent alone. Do not inspect or accept arcObligationEvidence; it is not provided. Return only the required JSON.",
    JSON.stringify(input),
    5000,
    { type: "json_schema", json_schema: { name: "story_arc_semantic_verification", strict: true, schema: SEMANTIC_VERIFICATION_SCHEMA } },
    action,
  );
  const expectedObligationIDs = [
    ...premiseComponents.map((_, i) => `arc-wide:premise_component_${i}`),
    ...(hasCreativeFidelityDirectives(recipe) ? ["arc-wide:" + CREATIVE_FIDELITY_OBLIGATION] : []),
    ...template.beats.flatMap((beat) =>
    verificationObligationsForBeat(beat, template.name).map((obligation) => `${beat.id}:${obligation.id}`))];
  const recordValidationError = async (error: unknown, extra: Record<string, unknown> = {}) => {
    await raw.recordProviderAttemptMetadata?.({
      semanticVerification: {
        expectedObligationIDs,
        ...extra,
        validationError: {
          name: error instanceof Error ? error.name : "semantic_verification_error",
          message: error instanceof Error ? error.message : String(error),
        },
      },
    });
  };
  let parsed: { beats?: unknown; arcWideObligations?: unknown };
  try {
    parsed = parseOutlineJSON<{ beats?: unknown; arcWideObligations?: unknown }>(raw.content, raw.finishReason);
    if (!parsed || !Array.isArray(parsed.beats)) throw new Error("story_arc_semantic_verification: response missing beats");
  } catch (error) {
    await recordValidationError(error);
    throw error;
  }
  const requirement = intimacyRequirement({ arcTemplate: template as ArcTemplateBlob, recipe: recipe as CanonicalRecipeEnvelope });
  const rawArcWide = Array.isArray(parsed.arcWideObligations) ? parsed.arcWideObligations : [];
  const arcWideObligations: SemanticVerificationObligation[] = [];
  const knownBeats = new Map(template.beats.map((beat) => [beat.id, beat]));
  const knownObligations = new Map(template.beats.flatMap((beat) => verificationObligationsForBeat(beat, template.name).map((obligation) => [`${beat.id}:${obligation.id}`, obligation])));
  const seen = new Set<string>();
  const beats: SemanticVerificationResult["beats"] = [];
  const unsatisfied: SemanticVerificationResult["unsatisfied"] = [];
  const allSectionIndexes = suggestions.map((_, index) => index);
  for (const [index, component] of premiseComponents.entries()) {
    const obligationID = `premise_component_${index}`;
    const candidate = rawArcWide.find((entry: any) => String(entry?.obligationID ?? "") === obligationID);
    const sectionIndex = Number(candidate?.sectionIndex);
    const quote = normalizeEvidenceText(String(candidate?.quote ?? ""));
    const grounding = resolveSemanticEvidenceCitation(
      suggestions, sectionIndex, quote,
      ["dramaticEvent", "resultingChange", "terminalState"], allSectionIndexes,
    );
    const grounded = Boolean(grounding?.field);
    const satisfied = Boolean(candidate?.satisfied) && grounded;
    const reason = candidate?.satisfied && !grounded
      ? "provider premise-component evidence quote was not grounded in a Section Contract field"
      : String(candidate?.reason ?? `premise component was not independently verified: ${component.requirement}`);
    arcWideObligations.push({
      obligationID, satisfied,
      sectionIndex: grounding?.sectionIndex ?? (Number.isInteger(sectionIndex) ? sectionIndex : -1),
      field: grounding?.field ?? "dramaticEvent", quote: grounding?.quote ?? quote, reason,
    });
    if (!satisfied) {
      unsatisfied.push({
        beatID: suggestions[grounding?.sectionIndex ?? sectionIndex]?.storyArcBeatID ?? "__story_arc__",
        obligationID, reason,
      });
    }
  }
  if (hasCreativeFidelityDirectives(recipe)) {
    const creativeRaw = rawArcWide.find((candidate: any) => String(candidate?.obligationID ?? "") === CREATIVE_FIDELITY_OBLIGATION);
    const creativeSectionIndex = Number(creativeRaw?.sectionIndex);
    const creativeSection = suggestions[creativeSectionIndex];
    const creativeQuote = normalizeEvidenceText(String(creativeRaw?.quote ?? ""));
    const creativeGrounding = resolveSemanticEvidenceCitation(
      suggestions, creativeSectionIndex, creativeQuote,
      ["dramaticEvent", "resultingChange", "terminalState"], allSectionIndexes,
    );
    const creativeGroundedField = creativeGrounding?.field;
    const creativeVerified = {
      obligationID: CREATIVE_FIDELITY_OBLIGATION,
      satisfied: Boolean(creativeRaw?.satisfied) && Boolean(creativeGroundedField),
      sectionIndex: creativeGrounding?.sectionIndex ?? (Number.isInteger(creativeSectionIndex) ? creativeSectionIndex : -1),
      field: creativeGroundedField ?? "dramaticEvent",
      quote: creativeGrounding?.quote ?? creativeQuote,
      reason: Boolean(creativeRaw?.satisfied) && !creativeGroundedField
        ? "creative-fidelity evidence quote was not grounded in a Section Contract field; creative-fidelity review required"
        : String(creativeRaw?.reason ?? "missing whole-outline creative-fidelity assessment"),
    } as SemanticVerificationObligation;
    arcWideObligations.push(creativeVerified);
    if (!creativeVerified.satisfied) {
      const repairSection = suggestions[creativeGrounding?.sectionIndex ?? creativeSectionIndex] ?? suggestions[0];
      unsatisfied.push({
        beatID: repairSection?.storyArcBeatID ?? "__story_arc__",
        obligationID: CREATIVE_FIDELITY_OBLIGATION,
        reason: creativeVerified.reason,
      });
    }
  }
  const storyNonNegotiables = (Array.isArray(recipe?.storyNonNegotiables) ? recipe.storyNonNegotiables : [])
    .map((item, index) => ({
      obligationID: `story_non_negotiable_${index}`,
      instruction: typeof item === "string" ? item : String((item as Record<string, unknown>)?.requirement ?? item),
    }));
  for (const required of storyNonNegotiables) {
    const rawObligation = rawArcWide.find((candidate: any) => String(candidate?.obligationID ?? "") === required.obligationID);
    const sectionIndex = Number(rawObligation?.sectionIndex);
    const section = suggestions[sectionIndex];
    const quote = normalizeEvidenceText(String(rawObligation?.quote ?? ""));
    const grounding = resolveSemanticEvidenceCitation(
      suggestions, sectionIndex, quote,
      ["dramaticEvent", "resultingChange", "terminalState"], allSectionIndexes,
    );
    const groundedField = grounding?.field;
    const providerClaimedSatisfied = Boolean(rawObligation?.satisfied);
    const verified = {
      obligationID: required.obligationID,
      satisfied: providerClaimedSatisfied && Boolean(groundedField),
      sectionIndex: grounding?.sectionIndex ?? sectionIndex,
      field: groundedField ?? "dramaticEvent",
      quote: grounding?.quote ?? quote,
      reason: providerClaimedSatisfied && !groundedField
        ? "provider evidence quote was not grounded in a Section Contract field; story non-negotiable review required"
        : String(rawObligation?.reason ?? `section does not unmistakably satisfy: ${required.instruction}`),
    } as SemanticVerificationObligation;
    arcWideObligations.push(verified);
    if (!verified.satisfied) unsatisfied.push({ beatID: suggestions[grounding?.sectionIndex ?? sectionIndex]?.storyArcBeatID ?? "__story_arc__", obligationID: required.obligationID, reason: verified.reason });
  }
  if (requirement) {
    const rawObligation = rawArcWide.find((candidate: any) => String(candidate?.obligationID ?? "") === SELECTED_INTIMACY_LEVEL_OBLIGATION);
    const eligibleSections = suggestions.map((section, sectionIndex) => ({ section, sectionIndex })).filter(({ section }) => {
      const beat = template.beats.find((candidate) => candidate.id === section.storyArcBeatID);
      return beat && requirement.roles.includes(beat.role);
    });
    const sectionIndex = Number(rawObligation?.sectionIndex);
    const field = rawObligation?.field;
    const quote = normalizeEvidenceText(String(rawObligation?.quote ?? ""));
    const section = eligibleSections.find((candidate) => candidate.sectionIndex === sectionIndex)?.section;
    // The model occasionally labels an exact quote with the wrong field. The
    // server still requires an exact quote, but canonicalizes the field to the
    // Section Contract field that actually contains it instead of creating a
    // false semantic failure.
    const grounding = resolveSemanticEvidenceCitation(
      suggestions, sectionIndex, quote,
      ["dramaticEvent", "resultingChange", "terminalState"],
      eligibleSections.map((candidate) => candidate.sectionIndex),
    );
    const groundedField = grounding?.field;
    const quoteGrounded = Boolean(groundedField);
    const providerClaimedSatisfied = Boolean(rawObligation?.satisfied);
    const verified = {
      obligationID: SELECTED_INTIMACY_LEVEL_OBLIGATION,
      satisfied: providerClaimedSatisfied && quoteGrounded,
      sectionIndex: grounding?.sectionIndex ?? (Number.isInteger(sectionIndex) ? sectionIndex : -1),
      field: groundedField ?? ("dramaticEvent" as const),
      quote: grounding?.quote ?? quote,
      reason: providerClaimedSatisfied && !quoteGrounded
        ? "provider evidence quote was not grounded in any Section Contract field; semantic repair required"
        : String(rawObligation?.reason ?? "missing whole-arc intimacy milestone"),
    } as SemanticVerificationObligation;
    arcWideObligations.push(verified);
    if (!verified.satisfied) {
      const repairBeat = eligibleSections[0]?.section.storyArcBeatID ?? "__story_arc__";
      unsatisfied.push({ beatID: repairBeat, obligationID: SELECTED_INTIMACY_LEVEL_OBLIGATION, reason: verified.reason });
    }
  }
  for (const rawBeat of parsed.beats as any[]) {
    const beatID = String(rawBeat?.beatID ?? "");
    if (!knownBeats.has(beatID) || seen.has(beatID)) {
      const error = new Error(`story_arc_semantic_verification: unknown or duplicate beat ${beatID}`);
      await recordValidationError(error, { returnedBeatIDs: (parsed.beats as any[]).map((candidate) => String(candidate?.beatID ?? "")) });
      throw error;
    }
    seen.add(beatID);
    const beat = knownBeats.get(beatID)!;
    const sections = suggestions.map((section, sectionIndex) => ({ section, sectionIndex })).filter(({ section }) => section.storyArcBeatID === beatID);
    const byObligation = new Map(verificationObligationsForBeat(beat, template.name).map((obligation) => [obligation.id, obligation]));
    if (!Array.isArray(rawBeat.obligations)) {
      const error = new Error(`story_arc_semantic_verification: missing obligations for ${beatID}`);
      await recordValidationError(error, {
        returnedBeatIDs: (parsed.beats as any[]).map((candidate) => String(candidate?.beatID ?? "")),
        returnedObligationIDs: (parsed.beats as any[]).flatMap((candidate) => Array.isArray(candidate?.obligations)
          ? candidate.obligations.map((obligation: any) => `${String(candidate?.beatID ?? "")}:${String(obligation?.obligationID ?? "")}`)
          : []),
      });
      throw error;
    }
    const obligations: SemanticVerificationObligation[] = [];
    for (const rawObligation of rawBeat.obligations) {
      const obligationID = String(rawObligation?.obligationID ?? "");
      const obligation = byObligation.get(obligationID);
      if (!obligation || !knownObligations.has(`${beatID}:${obligationID}`)) {
        const error = new Error(`story_arc_semantic_verification: unknown obligation ${obligationID}`);
        await recordValidationError(error, {
          returnedBeatIDs: (parsed.beats as any[]).map((candidate) => String(candidate?.beatID ?? "")),
          returnedObligationIDs: (parsed.beats as any[]).flatMap((candidate) => Array.isArray(candidate?.obligations)
            ? candidate.obligations.map((candidateObligation: any) => `${String(candidate?.beatID ?? "")}:${String(candidateObligation?.obligationID ?? "")}`)
            : []),
        });
        throw error;
      }
      const sectionIndex = Number(rawObligation.sectionIndex);
      const field = rawObligation.field;
      const quote = normalizeEvidenceText(String(rawObligation.quote ?? ""));
      const section = sections.find((candidate) => candidate.sectionIndex === sectionIndex)?.section;
      // Require an exact quote from one of the fields allowed by the
      // obligation. Correct a provider's mislabeled field rather than turning
      // an otherwise grounded obligation into a false terminal failure.
      const grounding = resolveSemanticEvidenceCitation(
        suggestions, sectionIndex, quote,
        obligation.requiredFields,
        sections.map((candidate) => candidate.sectionIndex),
      );
      const groundedField = grounding?.field;
      const quoteGrounded = Boolean(groundedField);
      const providerClaimedSatisfied = Boolean(rawObligation.satisfied);
      const verified = {
        obligationID,
        satisfied: providerClaimedSatisfied && quoteGrounded,
        sectionIndex: grounding?.sectionIndex ?? sectionIndex,
        field: groundedField ?? obligation.requiredFields[0] ?? "dramaticEvent",
        quote: grounding?.quote ?? quote,
        reason: providerClaimedSatisfied && !quoteGrounded
          ? "provider evidence quote was not grounded in any allowed Section Contract field; semantic repair required"
          : String(rawObligation.reason ?? ""),
      };
      obligations.push(verified);
      if (!verified.satisfied) unsatisfied.push({ beatID, obligationID, reason: verified.reason });
    }
    for (const obligation of byObligation.values()) {
      if (!obligations.some((candidate) => candidate.obligationID === obligation.id)) {
        const error = new Error(`story_arc_semantic_verification: missing obligation ${obligation.id}`);
        await recordValidationError(error, {
          returnedBeatIDs: (parsed.beats as any[]).map((candidate) => String(candidate?.beatID ?? "")),
          returnedObligationIDs: (parsed.beats as any[]).flatMap((candidate) => Array.isArray(candidate?.obligations)
            ? candidate.obligations.map((candidateObligation: any) => `${String(candidate?.beatID ?? "")}:${String(candidateObligation?.obligationID ?? "")}`)
            : []),
        });
        throw error;
      }
    }
    beats.push({ beatID, obligations });
  }
  for (const beat of template.beats) if (verificationObligationsForBeat(beat, template.name).length > 0 && !seen.has(beat.id)) {
    const error = new Error(`story_arc_semantic_verification: missing beat ${beat.id}`);
    await recordValidationError(error, {
      returnedBeatIDs: (parsed.beats as any[]).map((candidate) => String(candidate?.beatID ?? "")),
      returnedObligationIDs: (parsed.beats as any[]).flatMap((candidate) => Array.isArray(candidate?.obligations)
        ? candidate.obligations.map((candidateObligation: any) => `${String(candidate?.beatID ?? "")}:${String(candidateObligation?.obligationID ?? "")}`)
        : []),
    });
    throw error;
  }
  await raw.recordProviderAttemptMetadata?.({
    semanticVerification: {
      expectedObligationIDs,
      returnedBeatIDs: beats.map((beat) => beat.beatID),
      returnedObligationIDs: beats.flatMap((beat) => beat.obligations.map((obligation) => `${beat.beatID}:${obligation.obligationID}`)),
      unsatisfiedCount: unsatisfied.length,
      status: "validated",
    },
  });
  return { arcWideObligations, beats, unsatisfied };
}


const SEMANTIC_REPAIR_SCHEMA = {
  type: "object",
  properties: {
    replacements: {
      type: "array",
      minItems: 1,
      maxItems: 12,
      items: {
        type: "object",
        properties: { sectionIndex: { type: "integer" }, beatID: { type: "string" }, section: SECTION_SCHEMA },
        required: ["sectionIndex", "beatID", "section"],
        additionalProperties: false,
      },
    },
  },
  required: ["replacements"],
  additionalProperties: false,
} as const;

export async function repairStoryArcSemanticObligations(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  failures: Array<{ beatID: string; obligationID: string; reason: string }>,
  billableCall: SuggestionLLMCall,
  recipeObligations: RecipeObligation[] = [],
  recipe?: Partial<CanonicalRecipeEnvelope>,
): Promise<Suggestion[]> {
  const intimacyFailure = failures.some((failure) => failure.obligationID === SELECTED_INTIMACY_LEVEL_OBLIGATION);
  const intimacy = intimacyRequirement({ arcTemplate: template as ArcTemplateBlob, recipe: recipe as CanonicalRecipeEnvelope });
  const intimacyRepairBeat = intimacyFailure && intimacy
    ? template.beats.find((beat) => intimacy.roles.includes(beat.role) && suggestions.some((section) => section.storyArcBeatID === beat.id))?.id
    : undefined;
  const affected = new Set(failures.map((failure) => failure.beatID));
  if (intimacyRepairBeat) {
    affected.delete("__story_arc__");
    affected.add(intimacyRepairBeat);
  }
  const allowedReplacementIndexes = new Set(
    suggestions.flatMap((section, sectionIndex) =>
      affected.has(section.storyArcBeatID) ? [sectionIndex] : []),
  );
  const input = template.beats.filter((beat) => affected.has(beat.id)).map((beat) => ({
    beatID: beat.id,
    role: beat.role,
    label: beat.label,
    description: beat.description ?? "",
    failures: failures.filter((failure) => failure.beatID === beat.id),
    sections: suggestions.flatMap((section, sectionIndex) => section.storyArcBeatID === beat.id ? [{ sectionIndex, section }] : []),
  }));
  const raw = await billableCall(
    `${RECIPE_CREATIVE_AUTHORITY_DIRECTIVE}\n\nRepair only the affected Section Contracts. Preserve beat identity, recipe requirement IDs, established causal state, and the primary conflict. Rewrite the minimum number of sections so their dramaticEvent, resultingChange, and terminalState materially satisfy the failed obligations. ${intimacyFailure && intimacy ? `The whole-arc obligation ${SELECTED_INTIMACY_LEVEL_OBLIGATION} requires this selected ${intimacy.level} milestone to occur in the current eligible section; do not use implication, kissing, rumpled sheets, or a relationship label as a substitute.` : ""} Return only the required JSON.`,
    JSON.stringify({ recipe: recipe ?? null, affectedBeats: input }),
    7000,
    { type: "json_schema", json_schema: { name: "story_arc_semantic_repair", strict: true, schema: SEMANTIC_REPAIR_SCHEMA } },
    "outline-semantic-repair-batch",
  );
  const parsed = parseOutlineJSON<{ replacements?: unknown }>(raw.content, raw.finishReason);
  if (!parsed || !Array.isArray(parsed.replacements)) throw new Error("story_arc_semantic_repair: response missing replacements");
  const result = suggestions.map((section) => ({ ...section }));
  const replaced = new Set<number>();
  for (const operation of parsed.replacements as any[]) {
    const index = Number(operation?.sectionIndex);
    if (!Number.isInteger(index) || index < 0 || index >= result.length || replaced.has(index)) continue;
    // The provider may return a stale/whole-arc beat ID or mislabel the
    // target. The section index is server-owned; if that index is an allowed
    // repair target, canonicalize to the section's actual affected beat.
    if (!allowedReplacementIndexes.has(index)) continue;
    const canonicalBeatID = result[index].storyArcBeatID;
    if (!affected.has(canonicalBeatID)) continue;
    const candidate = { ...operation.section, storyArcBeatID: canonicalBeatID, recipeRequirementIDs: result[index].recipeRequirementIDs ?? [] };
    let validated: Suggestion[];
    try {
      validated = validateSuggestions(
        { suggestions: [candidate] },
        new Set([canonicalBeatID]),
        undefined,
        recipeObligations,
        { ...template, beats: template.beats.filter((beat) => beat.id === canonicalBeatID) },
      ).suggestions;
    } catch {
      // Replacement-local schema/contract failures are treated like any other
      // rejected operation: preserve the checkpoint and let reverification
      // decide whether the unchanged outline remains acceptable. Errors from
      // the surrounding repair lifecycle are intentionally not caught here.
      continue;
    }
    if (validated.length !== 1) continue;
    result[index] = validated[0];
    replaced.add(index);
  }
  // A malformed repair response must never strand a paid run with a generic
  // HTTP 500. Returning the checkpoint unchanged lets reverification produce
  // the typed semantic result and leaves the persisted run recoverable.
  return result;
}

// Ordinary expansion scenes may contain a local attack, seizure, or launch.
// Treat only explicit decisive/large-scale takeover language as evidence that
// an expansion creates a new primary conflict in a beat that forbids one.
const PRIMARY_CONFLICT_SIGNALS = /\b(?:launch(?:es|ed)?\s+(?:a|the|another)\s+(?:larger\s+)?decisive\s+assault|launch(?:es|ed)?\s+(?:a|the|another)\s+(?:citywide\s+)?takeover|mount(?:s|ed)?\s+(?:a|the)\s+decisive\s+assault|wage(?:s|d)?\s+(?:a|the)\s+war|attack(?:s|ed)?\s+(?:the|a)\s+(?:capital|city|kingdom|empire)|assault(?:s|ed)?\s+(?:the|a)\s+(?:capital|city|kingdom|empire)|invade(?:s|d)?\s+(?:the|a)\s+(?:capital|city|kingdom|empire)|conquer(?:s|ed)?\s+(?:the|a)\s+(?:capital|city|kingdom|empire)|take\s+over\s+(?:the|a)\s+(?:government|kingdom|empire)|seize(?:s|d)?\s+(?:the|a)\s+(?:government|throne|kingdom|empire)|overthrow(?:s|n)?\s+(?:the|a)\s+(?:government|regime|kingdom)|citywide\s+takeover)\b/i;
const CLOSURE_SIGNALS = /\b(settle(?:s|d)?|stabiliz(?:e|es|ed)|new normal|aftermath|mourning|rebuild(?:s|ing)?|govern(?:s|ed|ance)|peace|accept(?:s|ed)?|legacy|closing image)\b/;
function inferredFunction(suggestion: Suggestion): DramaticFunction | null {
  const text = semanticText(suggestion);
  if (/\b(resolve|resolution|settle|aftermath|new normal|closing image)\b/.test(text)) return "resolution";
  if (PRIMARY_CONFLICT_SIGNALS.test(text)) return "climax";
  if (/\b(reveal|discovers?|reversal|turns?|changes? the plan)\b/.test(text)) return "reversal";
  if (/\b(crisis|lowest|defeat|dark night|sacrifice)\b/.test(text)) return "crisis";
  if (/\b(consequence|falls apart|collapse|repercussion)\b/.test(text)) return "consequence";
  return null;
}

/** Validate both the declared function and the sequence-level macro-structure.
 * This is deliberately deterministic: UUID/role correctness alone is not
 * sufficient, but Hero's Journey Resurrection remains a legal late climax. */
export function validatePostRepairBeatCoverage(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): string[] {
  const contracts = arcRoleContracts(template);
  const counts = countSuggestionsByBeat(suggestions);
  const issues: string[] = [];
  for (const beat of template.beats) {
    const roleContract = contracts.get(beat.id);
    const minimum = Math.max(
      allocation?.get(beat.id)?.minSections ?? 0,
      roleContract?.requiredFunctions.length || roleContract?.closureExpectation === "strong" ? 1 : 0,
    );
    const actual = counts[beat.id] ?? 0;
    if (actual < minimum) issues.push(`beat ${beat.label} (${beat.id}) has ${actual} section(s); required minimum is ${minimum}`);
  }
  return issues;
}

export function validateRequiredStoryArcFunctions(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
): string[] {
  const contracts = arcRoleContracts(template);
  const issues: string[] = [];
  for (const beat of template.beats) {
    const roleContract = contracts.get(beat.id);
    if (!roleContract || roleContract.requiredFunctions.length === 0) continue;
    const sections = suggestions.filter((section) => section.storyArcBeatID === beat.id);
    const present = sections.map((section) => section.dramaticFunction ?? "(undeclared)").join(", ") || "(none)";
    for (const required of roleContract.requiredFunctions) {
      const requiredSections = sections.filter((section) => section.dramaticFunction === required);
      if (requiredSections.length === 0) {
        issues.push(`beat ${beat.label} (${beat.id}) is missing required dramatic function ${required}; present functions: ${present}`);
      }
    }
  }
  return issues;
}

/** Story Arc function gaps are diagnostic only. A localized model rewrite
 * cannot safely update downstream narrative state and must never be launched
 * as a repair of a paid, coherent first-pass outline. */
export function validateStoryArcSemantics(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): string[] {
  const issues: string[] = [
    ...validatePostRepairBeatCoverage(suggestions, template, allocation),
    ...validateRequiredStoryArcFunctions(suggestions, template),
    ...validateArcSemanticObligations(suggestions, template),
  ];
  const contracts = arcRoleContracts(template);
  const ordered = [...suggestions].sort((a, b) => {
    const ai = template.beats.findIndex((beat) => beat.id === a.storyArcBeatID);
    const bi = template.beats.findIndex((beat) => beat.id === b.storyArcBeatID);
    return ai - bi;
  });
  for (const section of ordered) {
    const roleContract = contracts.get(section.storyArcBeatID);
    if (!roleContract) continue;
    if (section.dramaticFunction && !roleContract.allowedFunctions.includes(section.dramaticFunction)) {
      issues.push(`section "${section.title}" declares ${section.dramaticFunction}, not allowed in its Story Arc role`);
    }
    // Keyword inference is only a safety signal. Only an explicit decisive
    // conflict or explicit closure signal is strong enough to affect repair.
    if (roleContract.forbidsNewPrimaryConflict && PRIMARY_CONFLICT_SIGNALS.test(semanticText(section))) {
      issues.push(`section "${section.title}" introduces a new primary conflict after the decisive phase`);
    }
  }
  const climaxIndex = ordered.reduce((last, section, index) => section.dramaticFunction === "climax" ? index : last, -1);
  if (climaxIndex >= 0) {
    for (let index = climaxIndex + 1; index < ordered.length; index++) {
      const section = ordered[index];
      const roleContract = contracts.get(section.storyArcBeatID);
      if (roleContract?.forbidsNewPrimaryConflict && PRIMARY_CONFLICT_SIGNALS.test(semanticText(section))) {
        issues.push(`primary confrontation occurs after the declared climax in section "${section.title}"`);
      }
    }
  }
  for (const beat of template.beats) {
    const roleContract = contracts.get(beat.id);
    if (roleContract?.closureExpectation !== "strong") continue;
    const sections = ordered.filter((section) => section.storyArcBeatID === beat.id);
    if (sections.length === 0) {
      issues.push(`Story Arc role "${beat.label}" has no sections for its required strong closure`);
    } else if (!sections.some((section) => CLOSURE_SIGNALS.test(semanticText(section)))) {
      issues.push(`Story Arc role "${beat.label}" has no observable closure or settled terminal state`);
    }
  }
  return [...new Set(issues)];
}

const MAX_LOCAL_REPAIR_DISTANCE = 2;

function requiredMinimumForBeat(
  beatID: string,
  contracts: Map<string, ArcRoleContract>,
  allocation?: Map<string, Allocation>,
): number {
  const roleContract = contracts.get(beatID);
  return Math.max(
    allocation?.get(beatID)?.minSections ?? 0,
    roleContract?.requiredFunctions.length || roleContract?.closureExpectation === "strong" ? 1 : 0,
  );
}

function canReassignLocally(
  section: Suggestion,
  sourceID: string,
  targetID: string,
  result: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): { safe: boolean; reason: string } {
  const contracts = arcRoleContracts(template);
  const sourceContract = contracts.get(sourceID);
  const targetContract = contracts.get(targetID);
  if (!sourceContract || !targetContract || !section.dramaticFunction) return { safe: false, reason: "missing source, target, or declared function contract" };
  const replacementFunction = inferredFunction(section) ?? section.dramaticFunction;
  if (!replacementFunction || !targetContract.allowedFunctions.includes(replacementFunction)) return { safe: false, reason: `target does not allow ${replacementFunction ?? "unknown"}` };
  const moved = result.map((candidate) => candidate === section ? { ...candidate, storyArcBeatID: targetID, dramaticFunction: inferredFunction(section) ?? candidate.dramaticFunction } : candidate);
  const sourceCount = moved.filter((candidate) => candidate.storyArcBeatID === sourceID).length;
  if (sourceCount < requiredMinimumForBeat(sourceID, contracts, allocation)) return { safe: false, reason: "source beat minimum coverage would be violated" };
  const coverageIssues = validatePostRepairBeatCoverage(moved, template, allocation);
  if (coverageIssues.some((issue) => issue.includes(`(${targetID})`) || issue.includes(`(${sourceID})`))) return { safe: false, reason: "source or destination beat minimum coverage would be violated" };
  const functionIssues = validateRequiredStoryArcFunctions(moved, template);
  if (functionIssues.some((issue) => issue.includes(`(${targetID})`) || issue.includes(`(${sourceID})`))) return { safe: false, reason: "source or destination required-function invariant would be violated" };
  return { safe: true, reason: `nearest compatible beat at canonical distance ${Math.abs(template.beats.findIndex((beat) => beat.id === sourceID) - template.beats.findIndex((beat) => beat.id === targetID))}` };
}

/** Repair only strong deterministic contradictions, and only within nearby beats. */
export function repairStoryArcMacroStructure(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): { suggestions: Suggestion[]; repaired: string[]; unresolved: string[]; diagnostics: string[] } {
  const contracts = arcRoleContracts(template);
  const repaired: string[] = [];
  const unresolved: string[] = [];
  const diagnostics: string[] = [];
  const result = suggestions.map((section) => ({ ...section }));
  const order = new Map(template.beats.map((beat, index) => [beat.id, index]));
  for (const section of result) {
    const sourceID = section.storyArcBeatID;
    const sourceContract = contracts.get(sourceID);
    const inferred = inferredFunction(section);
    const strongContradiction = Boolean(sourceContract?.forbidsNewPrimaryConflict && inferred === "climax" && PRIMARY_CONFLICT_SIGNALS.test(semanticText(section)));
    if (!sourceContract || !inferred || sourceContract.allowedFunctions.includes(inferred) || !strongContradiction) {
      if (sourceContract && inferred && !sourceContract.allowedFunctions.includes(inferred)) diagnostics.push(`${section.title}: weak or ambiguous semantic hint left unresolved`);
      continue;
    }
    const sourceIndex = order.get(sourceID) ?? -1;
    const candidates = template.beats
      .map((beat, index) => ({ beat, index, distance: Math.abs(index - sourceIndex) }))
      .filter(({ beat, distance }) => beat.id !== sourceID && distance <= MAX_LOCAL_REPAIR_DISTANCE && contracts.get(beat.id)?.allowedFunctions.includes(inferred))
      .sort((left, right) => left.distance - right.distance || left.index - right.index);
    let chosen: { beat: typeof template.beats[number]; reason: string } | undefined;
    const rejected: string[] = [];
    for (const candidate of candidates) {
      const safety = canReassignLocally(section, sourceID, candidate.beat.id, result, template, allocation);
      if (safety.safe) { chosen = { beat: candidate.beat, reason: safety.reason }; break; }
      rejected.push(`${candidate.beat.id}: ${safety.reason}`);
    }
    if (!chosen) {
      const reason = candidates.length === 0 ? "no adjacent or nearest compatible beat within the local repair boundary" : rejected.join("; ");
      unresolved.push(section.title);
      diagnostics.push(`${section.title}: unresolved; ${reason}`);
      continue;
    }
    section.storyArcBeatID = chosen.beat.id;
    section.dramaticFunction = inferred;
    repaired.push(`${section.title}: ${sourceID} → ${chosen.beat.id}`);
    diagnostics.push(`${section.title}: reassigned safely to ${chosen.beat.id}; ${chosen.reason}`);
  }
  result.sort((a, b) => (order.get(a.storyArcBeatID) ?? 999) - (order.get(b.storyArcBeatID) ?? 999));
  const postRepairIssues = validatePostRepairBeatCoverage(result, template, allocation);
  if (postRepairIssues.length > 0) {
    diagnostics.push(...postRepairIssues.map((issue) => `post-repair coverage: ${issue}`));
  }
  return { suggestions: result, repaired, unresolved, diagnostics };
}

export function validateOutlinePlanningQuality(
  suggestions: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
  format: StoryMaterialFormat = "novel",
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): OutlineQualityDiagnostic {
  const distinctnessIssues = findDramaticDistinctnessIssues(suggestions);
  const causalScaleIssues = findCausalScaleIssues(suggestions, storyMaterial, format);
  const semanticArcIssues = template ? validateStoryArcSemantics(suggestions, template, allocation) : [];
  const supportingEntities = storyMaterial
    ? findUnusedStoryMaterial(suggestions, storyMaterial).map((item) => item.id).slice(0, 50)
    : [];
  return {
    distinctnessIssues,
    causalScaleIssues,
    semanticArcIssues,
    supportingEntities,
    unusedStoryMaterialItems: supportingEntities.length,
    plannerCharacterIntegration: analyzePlannerCharacterIntegration(suggestions, storyMaterial),
  };
}

/**
 * Semantic checks are diagnostics only. A provider can produce a perfectly
 * usable outline that disagrees with a heuristic, and a heuristic itself can
 * throw as its rules evolve. Neither case may invalidate the structural
 * response or turn Suggest Sections into a server failure.
 */
export function collectAdvisoryOutlineQuality(
  suggestions: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
  format: StoryMaterialFormat = "novel",
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): OutlineQualityDiagnostic {
  try {
    return validateOutlinePlanningQuality(suggestions, storyMaterial, format, template, allocation);
  } catch (error) {
    return {
      distinctnessIssues: [],
      causalScaleIssues: [],
      semanticArcIssues: [],
      supportingEntities: [],
      unusedStoryMaterialItems: 0,
      plannerCharacterIntegration: { absent: [], mentionedWithoutCausalAnchor: [], withCausalAnchor: [] },
      advisoryValidationError: error instanceof Error ? error.message : String(error),
    };
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function logicalSuggestionIdentity(body: OutlineFromRecipeRequest): Promise<{ key: string; fingerprint: string }> {
  const { idempotencyKey: _ignored, ...withoutKey } = body;
  const fingerprint = await sha256Hex(stableJson(withoutKey));
  return { key: body.idempotencyKey?.trim() || `legacy:${fingerprint}`, fingerprint };
}

/**
 * Structural story-material failures happen before billing and are safe to
 * retry under the same idempotency identity after the server is repaired.
 * Other failed runs remain terminal so this cannot duplicate paid work.
 */
export function isRetryableStoryMaterialFailure(run: {
  status?: unknown;
  error?: unknown;
  credit_cost_charged?: unknown;
}): boolean {
  return run.status === "failed" &&
    Number(run.credit_cost_charged ?? 0) === 0 &&
    typeof run.error === "string" &&
    (run.error.startsWith("recipe story material item ") ||
      run.error === "story material enrichment contains a duplicate or missing item id");
}

export async function isSettledSemanticRepairCheckpoint(
  db: any,
  checkpoint: Record<string, unknown>,
): Promise<boolean> {
  const attemptKey = typeof checkpoint.attemptKey === "string" ? checkpoint.attemptKey : null;
  if (!attemptKey || !db?.from) return false;
  try {
    const result = await db.from("generation_provider_attempts")
      .select("status, usage_event_id, settled_charge_credits")
      .eq("attempt_key", attemptKey)
      .maybeSingle();
    if (result.error || !result.data) return false;
    return result.data.status === "settled" ||
      typeof result.data.usage_event_id === "string" ||
      Number(result.data.settled_charge_credits ?? 0) > 0;
  } catch {
    return false;
  }
}

export function isRetryableSemanticVerificationFailure(run: {
  status?: unknown;
  error_code?: unknown;
  planning_state?: any;
  diagnostics?: any;
}): boolean {
  return run.status === "failed" &&
    run.error_code === "story_arc_semantic_unresolved" &&
    run.planning_state?.nextAction === "semantic-reverification" &&
    Number(run.diagnostics?.semanticRetryCount ?? 0) < 1;
}

export function isRetryableSemanticRepairFailure(run: {
  status?: unknown;
  error?: unknown;
  error_code?: unknown;
  credit_cost_charged?: unknown;
  planning_state?: any;
  diagnostics?: any;
}): boolean {
  const recoveryAttempts = Number(run.diagnostics?.semanticRecoveryAttempts ?? 0);
  return run.status === "failed" &&
    run.error_code === "server_error" &&
    typeof run.error === "string" &&
    run.error.startsWith("story_arc_semantic_repair:") &&
    run.planning_state?.nextAction === "semantic-repair" &&
    recoveryAttempts < 1;
}

// Supabase Free-plan Edge Functions have a 150s wall-clock limit. Leave
// margin for request setup, billing settlement, and the durable checkpoint;
// a 150s provider deadline can be killed by the platform before it throws.
export const SUPABASE_FREE_WALL_CLOCK_MS = 150_000;
export const OUTLINE_PROVIDER_TIMEOUT_MS = 120_000;
// The selected GPT-5.4 mini deployment rejects larger structured completion
// budgets. Keep this at the verified 16K provider ceiling; planning scale is
// controlled by the bounded expansion stages rather than an invalid request.
export const OUTLINE_OUTPUT_TOKEN_BUDGET = 16_000;
const SUGGESTION_LEASE_MS = 3 * 60 * 1000;
export const MAX_SUGGESTION_ATTEMPTS = 5;
export const MAX_SUGGESTION_NO_PROGRESS_MS = 10 * 60 * 1000;

export class SuggestionWorkerYield extends Error {
  constructor() {
    super("outline worker slice complete");
    this.name = "SuggestionWorkerYield";
  }
}

export function assertWorkerSliceCanDispatch(providerDispatchesThisInvocation: number): void {
  if (providerDispatchesThisInvocation >= 1) throw new SuggestionWorkerYield();
}

export class SuggestionWorkerSlice {
  private dispatches = 0;

  get dispatchCount(): number {
    return this.dispatches;
  }

  beginDispatch(): void {
    assertWorkerSliceCanDispatch(this.dispatches);
    this.dispatches += 1;
  }
}

export function assertDurableUpdateSucceeded(
  result: { data?: unknown; error?: { message?: string } | null } | null | undefined,
  context = "durable run checkpoint",
): void {
  if (result?.error) {
    throw new Error(`${context} persistence failed: ${result.error.message ?? String(result.error)}`);
  }
  if (!result?.data) {
    throw new Error(`${context} persistence lost ownership or updated zero rows`);
  }
}

function completedStages(diagnostics: Record<string, unknown>): string[] {
  return Array.isArray(diagnostics.completedStages)
    ? diagnostics.completedStages.filter((value): value is string => typeof value === "string")
    : [];
}

export function markCompletedStage(
  diagnostics: Record<string, unknown>,
  stage: string,
): Record<string, unknown> {
  const stages = completedStages(diagnostics);
  return stages.includes(stage)
    ? diagnostics
    : { ...diagnostics, completedStages: [...stages, stage] };
}

/** Advance the no-progress clock only after a durable planning checkpoint. */
export function markMeaningfulProgress(
  diagnostics: Record<string, unknown>,
  checkpoint: string,
  at = new Date().toISOString(),
): Record<string, unknown> {
  const worker = diagnostics.worker && typeof diagnostics.worker === "object"
    ? diagnostics.worker as Record<string, unknown>
    : {};
  // A worker restart or replay may reach an earlier durable checkpoint after
  // other stages have run. Track the completed identity set, not only the
  // immediately preceding marker, so cross-stage rehydration cannot refresh
  // the no-progress clock. Older rows simply start recording new identities
  // when a genuinely new checkpoint is persisted.
  const completedIdentities = Array.isArray(worker.completedMeaningfulCheckpointIdentities)
    ? worker.completedMeaningfulCheckpointIdentities.filter((value): value is string => typeof value === "string")
    : [];
  if (completedIdentities.includes(checkpoint) || worker.lastMeaningfulProgressCheckpoint === checkpoint) {
    return { ...diagnostics, worker: { ...worker } };
  }
  return {
    ...diagnostics,
    worker: {
      ...worker,
      completedMeaningfulCheckpointIdentities: [...completedIdentities, checkpoint],
      lastMeaningfulProgressAt: at,
      lastMeaningfulProgressCheckpoint: checkpoint,
    },
  };
}

function leaseExpiry(): string {
  return new Date(Date.now() + SUGGESTION_LEASE_MS).toISOString();
}

function makeSupabase(url: string, anonKey: string, authHeader: string) {
  return createClient(url, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Durable background handler
// ---------------------------------------------------------------------------

const admin = () =>
  createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

async function reconcileExhaustedSuggestionBilling(
  db: any,
  run: { id: string; credit_cost_charged?: number | null },
): Promise<number | null> {
  // Recompute the durable total from provider-attempt rows before explaining
  // an exhausted run. If reconciliation is unavailable, say so explicitly.
  try {
    if (typeof db.rpc === "function") {
      const { error } = await db.rpc("reconcile_outline_provider_attempts", { p_run_id: run.id });
      if (error) {
        console.error("[outline-from-recipe] exhausted-run billing reconciliation failed", error);
        return null;
      }
      if (typeof db.from === "function") {
        const result = await db.from("outline_suggestion_runs")
          .select("credit_cost_charged")
          .eq("id", run.id)
          .maybeSingle();
        if (!result.error && result.data && typeof result.data.credit_cost_charged === "number") {
          return result.data.credit_cost_charged;
        }
      }
      // The RPC succeeded but the authoritative read did not. Do not fall back
      // to a stale run object and accidentally claim zero customer charge.
      return null;
    }
    return typeof run.credit_cost_charged === "number" ? run.credit_cost_charged : null;
  } catch (error) {
    console.error("[outline-from-recipe] exhausted-run billing reconciliation threw", error);
    return null;
  }
}

function exhaustedSuggestionBillingMessage(settledCredits: number | null): string {
  if (settledCredits === null) return "The outline planner stopped before completion. Billing reconciliation is unresolved; any settled stages were preserved. Review the run before retrying.";
  if (settledCredits > 0) return `The outline planner stopped before completion. ${settledCredits.toFixed(2)} credits were already settled for completed stages; no duplicate charge will be created. Retry after reviewing the run.`;
  return "The outline planner stopped before completion. No settled customer charge is recorded for this run; retry the request.";
}

export const SUGGESTION_RUN_RECOVERY_COLUMNS =
  "id, status, suggestions, warnings, error_code, error, diagnostics, planning_state, story_material, created_at, updated_at, completed_at, credit_cost_charged, remaining_credits, request_json, project_id, idempotency_key, request_fingerprint, attempt_count, lease_expires_at";

/** Read the persisted row after reclaim/reconciliation has completed. */
export async function loadAuthoritativeSuggestionRun(db: any, runID: string): Promise<any | null> {
  try {
    const result = await db.from("outline_suggestion_runs")
      .select(SUGGESTION_RUN_RECOVERY_COLUMNS)
      .eq("id", runID)
      .maybeSingle();
    if (result.error || !result.data) {
      if (result.error) console.error("[outline-from-recipe] authoritative recovery read failed", result.error);
      return null;
    }
    return result.data;
  } catch (error) {
    console.error("[outline-from-recipe] authoritative recovery read threw", error);
    return null;
  }
}

export function suggestionRunResponse(run: any): Record<string, unknown> {
  const billingUnresolved = run.status === "failed" &&
    typeof run.error === "string" &&
    run.error.includes("Billing reconciliation is unresolved");
  return {
    run_id: run.id,
    status: run.status,
    suggestions: run.suggestions,
    warnings: run.warnings,
    errorCode: run.error_code,
    error: run.error,
    diagnostics: run.diagnostics,
    planningState: run.planning_state,
    storyMaterialEnrichment: run.story_material,
    created_at: run.created_at,
    updated_at: run.updated_at,
    completed_at: run.completed_at,
    // Unresolved reconciliation is never presented as a confirmed amount.
    creditCostCharged: billingUnresolved ? null : run.credit_cost_charged,
    remainingCredits: billingUnresolved ? null : run.remaining_credits,
    sourceRecipe: run.request_json?.recipe ?? null,
    attemptCount: run.attempt_count ?? 0,
    updatedAt: run.updated_at,
    leaseExpiresAt: run.lease_expires_at,
  };
}

export function suggestionLifecycleFailure(_run: {
  created_at?: string | null;
  updated_at?: string | null;
  diagnostics?: Record<string, unknown> | null;
}, _now = Date.now()): null {
  // Recovery delay is not processing time. A scheduler outage, cold-start
  // delay, or long pending queue must never discard a durable checkpoint just
  // because created_at is old. Actual processing is bounded by the provider
  // deadline and lease; failed recovery is bounded by MAX_SUGGESTION_ATTEMPTS.
  return null;
}

async function markInterruptedProviderAttempts(db: any, runId: string, observedLeaseExpiry: string): Promise<void> {
  const { error } = await db.from("generation_provider_attempts").update({
    status: "provider_failed",
    provider_error_code: "worker_interrupted",
    completed_at: new Date().toISOString(),
  })
    .eq("feature_run_id", runId)
    .eq("status", "started")
    .lte("started_at", observedLeaseExpiry);
  if (error) console.error("[outline-from-recipe] orphan provider-attempt cleanup failed", error);
}

export async function reclaimExpiredSuggestionRun(db: any, run: {
  id: string;
  status?: string;
  lease_expires_at?: string | null;
  attempt_count?: number | null;
  error_code?: string | null;
  error?: string | null;
  credit_cost_charged?: number | null;
  created_at?: string | null;
  updated_at?: string | null;
  diagnostics?: Record<string, unknown> | null;
}): Promise<boolean> {
  const observedLeaseExpiry = run.lease_expires_at;
  const now = Date.now();
  const lifecycleFailure = suggestionLifecycleFailure(run, now);
  const leaseExpired = !!observedLeaseExpiry && new Date(observedLeaseExpiry).getTime() < now;

  // A valid running lease is authoritative. Wall-clock/no-progress limits do
  // not revoke it while the worker is still renewing it. Pending runs have no
  // owner, so lifecycle limits apply to them as well as running runs.
  if (run.status !== "running" && run.status !== "pending") return false;
  if (run.status === "running" && !leaseExpired) return false;
  if (!leaseExpired && !lifecycleFailure) return false;

  const nextAttemptCount = (run.attempt_count ?? 0) + 1;
  const exhausted = nextAttemptCount >= MAX_SUGGESTION_ATTEMPTS;
  const terminalCode = lifecycleFailure ?? (exhausted ? "worker_attempts_exhausted" : null);

  if (terminalCode) {
    // Fence the run before reconciling billing. The temporary owner prevents
    // a concurrent GET/POST recovery or the old worker from claiming or
    // persisting output while the authoritative attempt total is resolved.
    const fenceToken = `reclaimer:${crypto.randomUUID()}`;
    let fenceQuery = db.from("outline_suggestion_runs").update({
      status: "running",
      lease_owner: fenceToken,
      lease_expires_at: new Date(now + SUGGESTION_LEASE_MS).toISOString(),
    }).eq("id", run.id).eq("status", run.status);
    if (run.status === "running") {
      fenceQuery = observedLeaseExpiry
        ? fenceQuery.eq("lease_expires_at", observedLeaseExpiry)
        : fenceQuery.is("lease_expires_at", null);
    } else {
      fenceQuery = fenceQuery.is("lease_owner", null);
    }
    const fenced = await fenceQuery.select("id").maybeSingle();
    if (fenced.error || !fenced.data) return false;

    const settledCredits = await reconcileExhaustedSuggestionBilling(db, run);
    const terminalMessage = exhaustedSuggestionBillingMessage(settledCredits);
    const terminalized = await db.from("outline_suggestion_runs").update({
      status: "failed",
      error_code: terminalCode,
      error: terminalMessage,
      completed_at: new Date().toISOString(),
      lease_owner: null,
      lease_expires_at: null,
      attempt_count: nextAttemptCount,
    }).eq("id", run.id).eq("status", "running").eq("lease_owner", fenceToken)
      .select("id").maybeSingle();
    if (terminalized.error || !terminalized.data) return false;
    if (observedLeaseExpiry) await markInterruptedProviderAttempts(db, run.id, observedLeaseExpiry);
    run.status = "failed";
    run.attempt_count = nextAttemptCount;
    run.error_code = terminalCode;
    run.error = terminalMessage;
    return true;
  }

  // Non-terminal reclaim: atomically release only the observed expired lease.
  // A concurrent recovery can win this compare-and-set, but cannot also win
  // the pending claim inside runSuggestionJob.
  const interruptedDiagnostics = {
    ...(run.diagnostics ?? {}),
    stage: "worker_interrupted",
    recoveryState: "waiting_for_recovery",
    recoveryAttemptCount: nextAttemptCount,
    recoveryObservedAt: new Date(now).toISOString(),
  };
  let reclaimQuery = db.from("outline_suggestion_runs").update({
    status: "pending",
    lease_owner: null,
    lease_expires_at: null,
    attempt_count: nextAttemptCount,
    watchdog_failures: 0,
    watchdog_next_attempt_at: new Date().toISOString(),
    diagnostics: interruptedDiagnostics,
  }).eq("id", run.id).eq("status", "running");
  reclaimQuery = observedLeaseExpiry
    ? reclaimQuery.eq("lease_expires_at", observedLeaseExpiry)
    : reclaimQuery.is("lease_expires_at", null);
  const reclaimed = await reclaimQuery.select("id").maybeSingle();
  if (reclaimed.error || !reclaimed.data) return false;
  if (observedLeaseExpiry) await markInterruptedProviderAttempts(db, run.id, observedLeaseExpiry);
  run.status = "pending";
  run.attempt_count = nextAttemptCount;
  run.diagnostics = interruptedDiagnostics;
  return true;
}

export function continuationHeaders(authHeader: string, operatorSecret = ""): Record<string, string> {
  const headers: Record<string, string> = {
    Authorization: authHeader,
    "Content-Type": "application/json",
  };
  // Only the watchdog's explicitly supplied operator credential gets an
  // apikey header. A normal user's bearer JWT must never be repurposed as a
  // Supabase project API key.
  if (operatorSecret && authHeader === `Bearer ${operatorSecret}`) {
    headers.apikey = operatorSecret;
  }
  return headers;
}

async function scheduleSuggestionContinuation(body: OutlineFromRecipeRequest, authHeader: string): Promise<void> {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const operatorSecret = readSupabaseSecretKey(Deno.env.get("SUPABASE_SECRET_KEYS")) ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const response = await fetch(`${url}/functions/v1/outline-from-recipe`, {
    method: "POST",
    headers: continuationHeaders(authHeader, operatorSecret),
    body: JSON.stringify(body),
  });
  const responseText = await response.text();
  if (!response.ok) throw new Error(`continuation scheduling failed (${response.status}): ${responseText.slice(0, 300)}`);
}

export class StoryMaterialSufficiencyError extends Error {
  constructor(public readonly reasons: string[]) {
    super(`story material enrichment is insufficient: ${reasons.join("; ")}`);
    this.name = "StoryMaterialSufficiencyError";
  }
}

export class StoryMaterialValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StoryMaterialValidationError";
  }
}

async function persistPlanningProvenance(db: any, body: OutlineFromRecipeRequest, runId: string, material: StoryMaterialEnrichment, provenance: StoryMaterialProvenance): Promise<void> {
  if (!body.outline_id) return;
  const pack = body.recipe.promptPack as Record<string, unknown>;
  const { error } = await db.from("outlines").update({
    // A zero-section drift replan replaces the old frozen contract. Without
    // this write Accept All later compares against the stale recipe hash.
    source_recipe_json: body.recipe,
    source_recipe_hash: provenance.sourceRecipeHash,
    source_recipe_version: body.recipe.version,
    source_prompt_pack_id: String(pack.id ?? ""),
    source_prompt_pack_name: String(pack.name ?? ""),
    enrichment_schema_version: material.version,
    enrichment_source_recipe_hash: provenance.sourceRecipeHash,
    enrichment_run_id: runId,
    enrichment_planner_version: "story-material-v2",
    // Replanning invalidates any prior generation-ready claim until the
    // current canonical sections pass the readiness gate again.
    planning_status: "validating",
  }).eq("id", body.outline_id);
  if (error) throw new Error(`Could not persist outline planning provenance: ${error.message}`);
}

export type SuggestionWorkerStarter = (
  runId: string,
  body: OutlineFromRecipeRequest,
  userId: string,
  openaiKey: string,
  attemptCount: number,
  authHeader: string,
) => Promise<void>;

export async function recoverPendingSuggestionRun(
  run: any,
  userId: string,
  openaiKey: string | undefined,
  authHeader: string,
  startWorker: SuggestionWorkerStarter,
  db?: any,
): Promise<boolean> {
  if (run?.status !== "pending" || !run.request_json || !openaiKey) return false;
  const body = db
    ? await recoverPersistedPlanningBody(db, run)
    : run.request_json as OutlineFromRecipeRequest;
  await startWorker(
    run.id,
    body,
    userId,
    openaiKey,
    run.attempt_count ?? 0,
    authHeader,
  );
  return true;
}

export interface SuggestionWorkerDependencies {
  db?: any;
  model?: any;
  provider?: any;
  creditStore?: any;
  billableLLM?: typeof runBillableLLM;
  scheduleContinuation?: (body: OutlineFromRecipeRequest, authHeader: string) => Promise<void>;
  notifyProviderBillingUnavailable?: (
    context: ProviderBillingUnavailableContext,
  ) => Promise<unknown>;
  scheduleAlert?: (promise: Promise<unknown>) => void;
}

export async function returnSuggestionRunToPending(
  updateRun: (patch: Record<string, unknown>) => Promise<unknown>,
  scheduleContinuation: (body: OutlineFromRecipeRequest, authHeader: string) => Promise<void>,
  continuationBody: OutlineFromRecipeRequest,
  authHeader: string,
  diagnostics: Record<string, unknown>,
): Promise<void> {
  await updateRun({
    status: "pending",
    lease_owner: null,
    lease_expires_at: null,
    completed_at: null,
    watchdog_failures: 0,
    watchdog_next_attempt_at: new Date().toISOString(),
    diagnostics,
  });
  try {
    await scheduleContinuation(continuationBody, authHeader);
  } catch (scheduleError) {
    console.error("[outline-from-recipe] continuation scheduling failed; GET recovery remains available", scheduleError);
  }
}

export async function runSuggestionJob(
  runId: string,
  body: OutlineFromRecipeRequest,
  userId: string,
  openaiKey: string,
  priorAttemptCount = 0,
  authHeader = "",
  dependencies: SuggestionWorkerDependencies = {},
): Promise<void> {
  const continuationBody = body;
  const db = dependencies.db ?? admin();
  const scheduleContinuation = dependencies.scheduleContinuation ?? scheduleSuggestionContinuation;
  const workerToken = crypto.randomUUID();
  const claim = await db.from("outline_suggestion_runs").update({
    status: "running",
    lease_owner: workerToken,
    lease_expires_at: leaseExpiry(),
  }).eq("id", runId).eq("status", "pending")
    .select("id, credit_cost_charged, remaining_credits, story_material, suggestions, diagnostics, planning_context, planning_context_hash, planning_context_version, planning_state, planning_state_version")
    .maybeSingle();
  if (claim.error || !claim.data) return;
  const claimedRun: any = claim.data;
  let planningState: Record<string, unknown> = claimedRun.planning_state && typeof claimedRun.planning_state === "object"
    ? claimedRun.planning_state
    : { version: 2, phase: "start" };
  const priorDiagnostics = claimedRun.diagnostics && typeof claimedRun.diagnostics === "object"
    ? claimedRun.diagnostics as Record<string, unknown>
    : {};
  const priorWorker = priorDiagnostics.worker && typeof priorDiagnostics.worker === "object"
    ? priorDiagnostics.worker as Record<string, unknown>
    : {};
  const workerSliceCount = Number(priorWorker.sliceCount ?? 0) + 1;
  const wasRecovered = priorDiagnostics.recoveryState === "waiting_for_recovery" ||
    priorDiagnostics.stage === "worker_interrupted";
  let diagnostics: Record<string, unknown> = {
    ...priorDiagnostics,
    stage: wasRecovered ? "worker_resumed" : "starting",
    recoveryState: wasRecovered ? "worker_resumed" : "not_needed",
    recoveryResumedAt: wasRecovered ? new Date().toISOString() : undefined,
    worker: {
      ...priorWorker,
      sliceCount: workerSliceCount,
      lastSliceStartedAt: new Date().toISOString(),
      // A dispatch/launch is not meaningful progress. Preserve the last
      // durable checkpoint timestamp so repeated pending launches age out.
      lastMeaningfulProgressAt: typeof priorWorker.lastMeaningfulProgressAt === "string"
        ? priorWorker.lastMeaningfulProgressAt
        : (claimedRun.updated_at ?? new Date().toISOString()),
      lastYieldReason: null,
      nextAction: "resume persisted planning checkpoint",
    },
  };
  const touchLease = async () => {
    await db.from("outline_suggestion_runs").update({ lease_expires_at: leaseExpiry() }).eq("id", runId).eq("lease_owner", workerToken);
  };
  const updateRun = async (patch: Record<string, unknown>) => {
    const result = await db.from("outline_suggestion_runs")
      .update(patch)
      .eq("id", runId)
      .eq("lease_owner", workerToken)
      .select("id")
      .maybeSingle();
    assertDurableUpdateSucceeded(result);
    return result;
  };
  let plannedMinimumSections: number | null = null;
  let providerModelForAlert: string | null = null;
  let latestValidSuggestions: Suggestion[] = Array.isArray(claimedRun.suggestions)
    ? claimedRun.suggestions as Suggestion[]
    : [];
  // Keep the raw provider candidate durable before structural validation can
  // reject one malformed reference. This preserves the expensive response for
  // diagnostics/recovery without treating it as an accepted outline.
  let latestProviderCandidate: Suggestion[] | null = null;
  try {
    const modelStore = dependencies.model ? null : new SupabaseGenerationModelStore(db);
    const selectedModelID = recoverablePlanningModelID(body);
    const model = dependencies.model ?? (selectedModelID
      ? await modelStore!.getEnabledModelById(selectedModelID)
      : null);
    if (!model) {
      throw new Error(
        selectedModelID
          ? `Selected outline model is unavailable: ${selectedModelID}`
          : "planning_model_unrecoverable: historical request has no model identity or provider attempt",
      );
    }
    providerModelForAlert = model.provider_model ?? selectedModelID;
    // Fast mode is a 2x provider-price tier for GPT-6 Luna. Keep the catalog's
    // verified standard rates unchanged and apply the multiplier only to this
    // request, so preflight, settlement, and cost telemetry agree.
    const serviceTier = model.provider_model === "gpt-6-luna" ? "fast" as const : undefined;
    const billableModel = serviceTier === "fast"
      ? { ...model, billing_multiplier: model.billing_multiplier * 2 }
      : model;
    const creditStore = dependencies.creditStore ?? new SupabaseCreditStore(db);
    const provider = dependencies.provider ?? new OpenAIProvider(
      openaiKey,
      model.provider_model,
      OUTLINE_PROVIDER_TIMEOUT_MS,
    );
    const billableLLM = dependencies.billableLLM ?? runBillableLLM;
    // Reclaimed workers resume from persisted billing/material state. The
    // usage-event idempotency key is the final no-double-charge guard, while
    // reusing persisted enrichment avoids repeating a settled paid stage.
    // Billing totals are database-authoritative. The settlement RPC reconciles
    // the run from provider-attempt rows; this worker only renews its lease.
    const persistBilling = async () => {
      await updateRun({ lease_expires_at: leaseExpiry() });
    };
    const workerSlice = new SuggestionWorkerSlice();
    const billableCall: SuggestionLLMCall = async (
      system,
      user,
      maxOutputTokens,
      responseFormat,
      action,
      validateResponse,
    ) => {
      workerSlice.beginDispatch();
      const messages: LLMMessage[] = [
        { role: "system", content: system },
        { role: "user", content: user },
      ];
      const stageFamily = action.startsWith("outline-expansion-")
        ? "expansion"
        : action.startsWith("story-material-enrichment")
        ? "enrichment"
        : action.startsWith("outline-plan")
        ? "allocation"
        : action.startsWith("outline-suggestions")
        ? "suggestions"
        : action;
      const measuredPrompt = {
        ...promptMetrics(messages, {
          recipeBytes: new TextEncoder().encode(JSON.stringify(body.recipe ?? null)).byteLength,
          enrichmentBytes: new TextEncoder().encode(JSON.stringify(compactMaterial(body.storyMaterialEnrichment))).byteLength,
          existingSectionCount: body.existingSections?.length ?? 0,
        }),
        stageFamily,
        action,
      };
      diagnostics = { ...diagnostics, promptMetrics: { ...(diagnostics.promptMetrics as Record<string, unknown> ?? {}), [action]: measuredPrompt } };
      await updateRun({ diagnostics });
      const stablePrefixHash = await sha256Hex(system);
      const projectIdentity = body.recipe?.project?.id ?? body.outline_id ?? "unknown";
      const promptCacheKey = `cath:outline:${projectIdentity}:${provenance.sourceRecipeHash}:${stageFamily}:pcv2:promptv4`;
      const promptCacheKeyHash = await sha256Hex(promptCacheKey);
      await touchLease();
      const semanticRepairCheckpoint = action === "outline-semantic-repair-batch" &&
        diagnostics.semanticRepairProviderCheckpoint &&
        typeof diagnostics.semanticRepairProviderCheckpoint === "object"
        ? diagnostics.semanticRepairProviderCheckpoint as Record<string, unknown>
        : null;
      if (semanticRepairCheckpoint &&
        typeof semanticRepairCheckpoint.content === "string" &&
        await isSettledSemanticRepairCheckpoint(db, semanticRepairCheckpoint)) {
        diagnostics = { ...diagnostics, stage: "semantic_repair_checkpoint_replay" };
        return {
          content: semanticRepairCheckpoint.content,
          creditCostCharged: 0,
          remainingCredits: Number(semanticRepairCheckpoint.remainingCredits ?? 0),
          finishReason: typeof semanticRepairCheckpoint.finishReason === "string" ? semanticRepairCheckpoint.finishReason : undefined,
        };
      }
      // Provider calls can exceed the three-minute worker lease, especially
      // for worksheet enrichment. Start the heartbeat only for a live provider
      // dispatch; checkpoint replay returns above and needs no heartbeat.
      const leaseHeartbeat = setInterval(() => {
        void touchLease();
      }, 30_000);
      const providerAttemptMetadata = action === "outline-semantic-verification" || action === "outline-semantic-repair-batch"
        ? {
          telemetryVersion: 1,
          request: { messages, maxOutputTokens, responseFormat },
          expectedObligationIDs: action === "outline-semantic-verification"
            ? body.arcTemplate.beats.flatMap((beat) => arcRoleContract(beat, body.arcTemplate.name).semanticObligations.map((obligation) => `${beat.id}:${obligation.id}`))
            : [],
        }
        : undefined;
      let result: any;
      try {
        result = await billableLLM({
        userID: userId,
        purpose: "outline-suggestion",
        action,
        model: billableModel,
        messages,
        maxOutputTokens,
        providerOptions: {
          responseFormat,
          ...(supportsCustomTemperature(model) ? { temperature: 0.7 } : {}),
          reasoningEffort: body.reasoningEffort,
          serviceTier,
          cacheMode: model.cacheMode,
          promptCacheKey: model.cacheMode === "none" ? undefined : promptCacheKey,
        },
        providerAttemptMetadata,
        captureProviderResponse: action === "outline-semantic-verification",
        stablePrefixHash,
        usageContext: {
          generationLengthMode: "outline",
          outputBudget: maxOutputTokens,
          idempotencyKey: `${runId}:${action}`,
          featureRunID: runId,
          promptBytes: measuredPrompt.promptBytes,
          stablePrefixBytes: new TextEncoder().encode(system).byteLength,
          volatileBytes: new TextEncoder().encode(user).byteLength,
          logicalStageKey: `${runId}:${stageFamily}`,
          promptCacheKeyHash,
        },
        onProviderSuccess: async (providerResult) => {
          if (validateResponse) await validateResponse(providerResult.content, providerResult.finishReason);
          return providerResult.content;
        },
        beforeSettlement: action === "outline-semantic-repair-batch"
          ? async (content, providerResult, context) => {
            // The checkpoint must be parseable before settlement. Replacement
            // quality is intentionally validated after replay; malformed JSON
            // is not a usable paid checkpoint and therefore must not settle.
            const parsed = parseOutlineJSON<{ replacements?: unknown }>(content, providerResult.finishReason);
            if (!parsed || !Array.isArray(parsed.replacements)) {
              throw new Error("story_arc_semantic_repair: response missing replacements");
            }
            const checkpointDiagnostics = {
              ...diagnostics,
              stage: "semantic_repair_checkpointed",
              semanticRepairProviderCheckpoint: {
                action,
                content,
                finishReason: providerResult.finishReason ?? null,
                remainingCredits: null,
                attemptKey: context.attemptKey,
                checkpointedAt: new Date().toISOString(),
              },
            };
            // Keep the in-memory failure snapshot in lockstep with the
            // durable checkpoint. A later failure must not overwrite a
            // successfully settled repair with stale diagnostics.
            diagnostics = checkpointDiagnostics;
            await updateRun({ diagnostics: checkpointDiagnostics });
          }
          : undefined,
        }, { adminClient: db, provider, creditStore });
      } finally {
        clearInterval(leaseHeartbeat);
      }
      await persistBilling();
      return {
        content: result.featureResult,
        creditCostCharged: result.charged ? result.actualCharge : 0,
        remainingCredits: result.remainingCredits,
        finishReason: result.providerResult?.finishReason,
        recordProviderAttemptMetadata: result.recordProviderAttemptMetadata,
      };
    };

    let allocation: Map<string, Allocation> | undefined;
    // Stored alongside the existing allocationEntries for durable worker
    // resume; an older checkpoint can still complete without a blueprint.
    let storyArchitecture = planningState.storyArchitecture as StoryArchitecture | undefined;
    const sectionAllocationDeficits = (suggestions: Suggestion[]) => {
      const effectiveAllocation = allocation ?? new Map<string, Allocation>(
        Array.isArray(planningState.allocationEntries) ? planningState.allocationEntries as Array<[string, Allocation]> : [],
      );
      return allocationDeficits(suggestions, effectiveAllocation).map((entry) => ({
        ...entry,
        label: body.arcTemplate.beats.find((beat) => beat.id === entry.beatID)?.label ?? entry.beatID,
      }));
    };

    const expandNovel = async (
      initialSuggestions: Suggestion[],
      recipeObligations: RecipeObligation[],
      startRound = 1,
      startBeatIndex = 0,
      priorDiagnostics: ExpansionRoundDiagnostic[] = [],
    ): Promise<ProgressiveExpansionResult> => {
      const allocationRepairRequired = sectionAllocationDeficits(initialSuggestions).length > 0;
      diagnostics = {
        ...diagnostics,
        stage: "expansion_generation",
        expansionRounds: priorDiagnostics,
      };
      return await progressivelyExpandOutline(
        initialSuggestions,
        new Set(body.arcTemplate.beats.map((beat) => beat.id)),
        async (current, context, beat) => {
          const expansionContext = beat ? { ...context, beat } : context;
          const expansion = buildExpansionPrompt(body, current, expansionContext, recipeObligations);
          const deficits = sectionAllocationDeficits(current);
          const targetDeficit = beat ? deficits.find((entry) => entry.beatID === beat.beatID) : undefined;
          if (targetDeficit) {
            expansion.system += ` This beat is under its post-deduplication allocation floor by ${targetDeficit.missing} section${targetDeficit.missing === 1 ? "" : "s"}. Add that many distinct chapter-scale dramatic units before optional expansion; do not replay any existing section.`;
          }
          const expandedRaw = await billableCall(
            expansion.system,
            expansion.user,
            OUTLINE_OUTPUT_TOKEN_BUDGET,
            { type: "json_schema", json_schema: { name: "outline_expansion", strict: true, schema: buildExpansionResponseSchema(beat ? arcRoleContract(body.arcTemplate.beats.find((candidate) => candidate.id === beat.beatID)!, body.arcTemplate.name) : undefined, requestedStoryMaterialFormat(body), recipeObligations) } },
            `outline-expansion-${context.round}-${beat?.beatID ?? "global"}`,
            (content, finishReason) => {
              const additions = parseExpansionResponse(content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations, body.arcTemplate, finishReason);
              validateNovelLeafContainers(additions, requestedStoryMaterialFormat(body));
              return fitExpansionAdditionsToBudget(current, additions, body.existingSections ?? [], {
                round: context.round,
                beatID: beat?.beatID,
              });
            },
          );
          const parsedAdditions = parseExpansionResponse(expandedRaw.content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations, body.arcTemplate, expandedRaw.finishReason);
          validateNovelLeafContainers(parsedAdditions, requestedStoryMaterialFormat(body));
          return fitExpansionAdditionsToBudget(current, parsedAdditions, body.existingSections ?? [], {
            round: context.round,
            beatID: beat?.beatID,
          });
        },
        async (_roundDiagnostic, allDiagnostics, current) => {
          latestValidSuggestions = current;
          const checkpoint = buildExpansionCheckpoint(current, body.existingSections ?? [], allDiagnostics);
          diagnostics = {
            ...diagnostics,
            stage: "expansion_checkpoint",
            expansionRounds: allDiagnostics,
            expansionCheckpoint: checkpoint,
            novelScale: checkpoint.scale,
          };
          const expansionCheckpoint = buildExpansionCheckpoint(current, body.existingSections ?? [], allDiagnostics);
          planningState = { ...planningState, phase: "expansion", expansionCheckpoint };
          diagnostics = markMeaningfulProgress(
            { ...diagnostics, expansionCheckpoint },
            `expansion_round_checkpoint:${stableJSONStringify(expansionCheckpoint)}`,
          );
          await updateRun({
            suggestions: current,
            planning_state: planningState,
            diagnostics,
          });
        },
        {
          existingSections: body.existingSections ?? [],
          startRound,
          startBeatIndex,
          priorDiagnostics,
          // Allocation repair is beat-local because the missing section has a
          // known destination. Optional enrichment is global: unused material
          // has no canonical beat assignment, so the provider must choose the
          // beat where it belongs instead of being forced into beat zero.
          beats: allocationRepairRequired ? body.arcTemplate.beats : undefined,
          coverageGate: (current) => requestedStoryMaterialFormat(body) === "novel" && sectionAllocationDeficits(current).length > 0,
          qualityGate: (current) => {
            if (requestedStoryMaterialFormat(body) !== "novel") return false;
            const quality = collectAdvisoryOutlineQuality(
              current,
              body.storyMaterialEnrichment,
              requestedStoryMaterialFormat(body),
              body.arcTemplate,
            );
            return needsNovelExpansion(current, body.existingSections ?? []) ||
              quality.causalScaleIssues.length > 0;
          },
          onBeat: async (round, nextBeatIndex, current, allDiagnostics) => {
            // Beat-level checkpoints are validated additions too. Keep the
            // latest one available if a later provider attempt fails.
            latestValidSuggestions = current;
            const expansionCheckpoint = buildExpansionCheckpoint(
              current,
              body.existingSections ?? [],
              allDiagnostics,
              { nextRound: round, nextBeatIndex },
            );
            planningState = { ...planningState, phase: "expansion", expansionCheckpoint };
            diagnostics = {
              ...diagnostics,
              stage: "expansion_beat_checkpoint",
              expansionCheckpoint,
              expansionRounds: allDiagnostics,
              novelScale: expansionCheckpoint.scale,
            };
            diagnostics = markMeaningfulProgress(
              diagnostics,
              `expansion_beat_checkpoint:${stableJSONStringify(expansionCheckpoint)}`,
            );
            await updateRun({ suggestions: current, planning_state: planningState, diagnostics });
          },
        },
      );
    };

    const provenance = await recipeProvenance(body.recipe);
    let recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>);

    const completeValidatedOutline = async (
      completedSuggestions: Suggestion[],
      completionWarnings: string[],
      allowUnderTarget = false,
    ) => {
      const finalCoverage = obligationCoverage([...(body.existingSections ?? []), ...completedSuggestions], recipeObligations);
      diagnostics = {
        ...diagnostics,
        recipeObligationCoverage: finalCoverage.covered,
        missingRequiredRecipeObligations: finalCoverage.missingRequired.map((obligation) => obligation.id),
      };
      if (finalCoverage.missingRequired.length > 0) {
        // Requirement ID annotations are writer metadata, not the story.
        // A paid, structurally complete outline is deliverable even if its
        // non-authoritative ID index missed a premise component. Internal QA
        // retains the precise gap for product analysis, never a customer alert.
        diagnostics = {
          ...diagnostics,
          premiseCoverageAssessment: "needs_review",
          automaticNarrativeRepair: "disabled",
        };
      }
      const finalScale = evaluateNovelScale(completedSuggestions, body.existingSections ?? []);
      const belowLengthTolerance = needsNovelExpansion(completedSuggestions, body.existingSections ?? []);
      if (requestedStoryMaterialFormat(body) === "novel" && belowLengthTolerance && !allowUnderTarget) {
        throw new NovelScalePlanningError(
          "failed_under_target",
          "outline expansion did not reach plausible novel scale",
        );
      }
      if (requestedStoryMaterialFormat(body) === "novel" && belowLengthTolerance && allowUnderTarget) {
        completionWarnings.push(`Novel outline is below the preferred ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word planning target; the usable outline was preserved.`);
      }
      if (requestedStoryMaterialFormat(body) === "novel" && finalScale.exceedsMaximum) {
        throw new NovelScalePlanningError(
          "failed_over_target",
          `Novel outline exceeds the ${NOVEL_ACCEPTED_MAX_WORDS.toLocaleString()}-word accepted ceiling`,
        );
      }
      const remainingAllocationDeficits = sectionAllocationDeficits(completedSuggestions);
      const effectiveAllocation = allocation ?? new Map<string, Allocation>(
        Array.isArray(planningState.allocationEntries)
          ? planningState.allocationEntries as Array<[string, Allocation]>
          : [],
      );
      const allocationShortfallReport = allocationShortfalls(completedSuggestions, effectiveAllocation);
      diagnostics = { ...diagnostics, allocationShortfalls: allocationShortfallReport };
      if (remainingAllocationDeficits.length > 0) {
        const checkpoint = buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], diagnostics.expansionRounds as ExpansionRoundDiagnostic[] ?? []);
        const expansionRounds = diagnostics.expansionRounds as ExpansionRoundDiagnostic[] ?? [];
        if (allocationRepairExhausted(remainingAllocationDeficits, expansionRounds)) {
          // A resumed checkpoint can start at round four. Do not yield the
          // same checkpoint forever when the bounded expansion budget is gone:
          // fail recoverably and keep the paid draft available for review.
          planningState = {
            ...planningState,
            phase: "failed",
            nextAction: "allocation-repair-exhausted",
            expansionCheckpoint: checkpoint,
          };
          diagnostics = markMeaningfulProgress({
            ...diagnostics,
            stage: "allocation_repair_exhausted",
            allocationDeficits: remainingAllocationDeficits,
            expansionCheckpoint: checkpoint,
          }, `allocation_repair_exhausted:${stableJSONStringify(remainingAllocationDeficits)}`);
          latestValidSuggestions = completedSuggestions;
          throw new NovelScalePlanningError(
            "failed_expansion",
            `Outline allocation still lacks coverage for ${remainingAllocationDeficits.map((entry) => entry.beatID).join(", ")} after ${MAX_EXPANSION_ROUNDS} expansion rounds. The saved draft is preserved for review.`,
          );
        }
        planningState = { ...planningState, phase: "expansion", nextAction: "expansion", expansionCheckpoint: checkpoint };
        diagnostics = markMeaningfulProgress({
          ...diagnostics,
          stage: "allocation_repair_pending",
          allocationDeficits: remainingAllocationDeficits,
          expansionCheckpoint: checkpoint,
        }, `allocation_repair_pending:${stableJSONStringify(remainingAllocationDeficits)}`);
        await updateRun({ suggestions: completedSuggestions, planning_state: planningState, diagnostics });
        throw new SuggestionWorkerYield();
      }
      const finalWarnings = completionWarnings;
      await updateRun({
        status: "completed",
        suggestions: completedSuggestions,
        warnings: finalWarnings,
        completed_at: new Date().toISOString(),
        planning_state: { ...planningState, phase: "completed", nextAction: "completed" },
        diagnostics: {
          ...diagnostics,
          stage: "completed",
          finalSectionCounts: countSuggestionsByBeat(completedSuggestions),
          allocationDeficits: remainingAllocationDeficits,
          novelScale: finalScale,
          ...(requestedStoryMaterialFormat(body) === "novel" && belowLengthTolerance
            ? { preferredScaleWarning: `Novel plan is below the preferred ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word development target.` }
            : {}),
        },
        lease_owner: null,
        lease_expires_at: null,
      });
    };

    const postValidatedOutline = async (
      initialSuggestions: Suggestion[],
      initialWarnings: string[],
    ) => {
      // A repeated title across beats is a hard replay signal. Reject it
      // before optional expansion can amplify the bad outline.
      assertDistinctOutlineTitles(initialSuggestions);
      let completedSuggestions = initialSuggestions;
      let completionWarnings = initialWarnings;
      // Only callbacks after validation may advance this value. A provider
      // response that fails validation must never replace the last checkpoint.
      latestValidSuggestions = initialSuggestions;
      const initialScale = evaluateNovelScale(completedSuggestions, body.existingSections ?? []);
      if (requestedStoryMaterialFormat(body) === "novel" && initialScale.exceedsMaximum) {
        throw new NovelScalePlanningError(
          "failed_over_target",
          `Novel outline exceeds the ${NOVEL_ACCEPTED_MAX_WORDS.toLocaleString()}-word accepted ceiling before expansion.`,
        );
      }
      const initialQuality = collectAdvisoryOutlineQuality(
        completedSuggestions,
        body.storyMaterialEnrichment,
        requestedStoryMaterialFormat(body),
        body.arcTemplate,
      );
      const outlineNeedsExpansion = requestedStoryMaterialFormat(body) === "novel" &&
        (sectionAllocationDeficits(completedSuggestions).length > 0 ||
          needsNovelExpansion(completedSuggestions, body.existingSections ?? []) ||
          initialQuality.causalScaleIssues.length > 0);
      planningState = {
        ...planningState,
        phase: outlineNeedsExpansion ? "expansion" : "outline_complete",
        nextAction: outlineNeedsExpansion ? "expansion" : "completed",
      };
      const expansionCheckpoint = buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], []);
      // The outline has passed structural and obligation validation even when
      // a novel still needs optional expansion. Persist that checkmark before
      // dispatching expansion so the UI does not imply allocation is the last
      // completed stage.
      diagnostics = markCompletedStage(diagnostics, "outline");
      diagnostics = { ...diagnostics, stage: outlineNeedsExpansion ? "expansion_pending" : "outline_complete", expansionCheckpoint };
      diagnostics = markMeaningfulProgress(
        diagnostics,
        `validated_suggestions_persisted:${stableJSONStringify(completedSuggestions)}`,
      );
      await updateRun({ suggestions: completedSuggestions, planning_state: planningState, diagnostics });
      if (outlineNeedsExpansion) {
        try {
          const expanded = await expandNovel(completedSuggestions, recipeObligations, 1, 0, []);
          completedSuggestions = expanded.suggestions;
          completionWarnings = [...completionWarnings, ...expanded.warnings];
          diagnostics = {
            ...diagnostics,
            expansionRounds: expanded.diagnostics,
            expansionCheckpoint: buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], expanded.diagnostics),
            novelScale: evaluateNovelScale(completedSuggestions, body.existingSections ?? []),
          };
        } catch (error) {
          if (!(error instanceof NovelScalePlanningError) || !["failed_expansion", "failed_under_target"].includes(error.code)) throw error;
          // progressivelyExpandOutline invokes checkpoint callbacks only after
          // additions pass structural, beat, and length validation. Prefer
          // that newest validated state over the first-pass outline; invalid
          // or partially parsed provider output never reaches this variable.
          completedSuggestions = latestValidSuggestions.length > 0
            ? latestValidSuggestions
            : completedSuggestions;
          completionWarnings.push(`Optional novel expansion did not finish; the usable outline was preserved below the preferred ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word planning target.`);
          diagnostics = {
            ...diagnostics,
            expansionWarning: error.message,
            expansionCheckpoint: diagnostics.expansionCheckpoint ?? buildExpansionCheckpoint(
              completedSuggestions,
              body.existingSections ?? [],
              diagnostics.expansionRounds as ExpansionRoundDiagnostic[] ?? [],
            ),
            novelScale: evaluateNovelScale(completedSuggestions, body.existingSections ?? []),
          };
        }
      }
      await completeValidatedOutline(completedSuggestions, completionWarnings, true);
    };

    if (!body.storyMaterialEnrichment && claimedRun.story_material) {
      body = {
        ...body,
        storyMaterialEnrichment: normalizeProviderStoryMaterialItemIDs(
          downgradeUnverifiedProviderRecipeReferences(claimedRun.story_material, body.recipe),
        ) as StoryMaterialEnrichment,
      };
    }
    // Resume from this run's persisted authored premise decomposition.
    if (body.storyMaterialEnrichment?.premiseComponents) {
      recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>, body.storyMaterialEnrichment.premiseComponents);
    }
    const persistedSemanticSuggestions = Array.isArray(claimedRun.suggestions)
      ? claimedRun.suggestions as Suggestion[]
      : [];
    const recordSemanticWarning = (message: string) => {
      const previous = Array.isArray(diagnostics.semanticWarnings) ? diagnostics.semanticWarnings as string[] : [];
      diagnostics = { ...diagnostics, semanticWarnings: [...previous, message] };
    };
    const continueAfterSemanticVerification = async (suggestions: Suggestion[], completionWarnings: string[] = []) => {
      const requiredStoryArcIssues = validateRequiredStoryArcFunctions(suggestions, body.arcTemplate);
      // Report missing declared dramatic functions internally, but never
      // rewrite one section in isolation: that can retroactively resolve a
      // conflict that later paid sections still need to finish.
      if (requiredStoryArcIssues.length > 0) {
        diagnostics = {
          ...diagnostics,
          storyArcFunctionIssues: requiredStoryArcIssues,
          storyArcRewriteSkipped: true,
        };
      }
      const semanticCoverage = obligationCoverage([...(body.existingSections ?? []), ...suggestions], recipeObligations);
      if (semanticCoverage.missingRequired.length > 0) {
        // A missing deterministic recipe obligation is a first-pass defect,
        // never permission to invent a new chapter after the story was fixed.
        // The completion gate reports the typed failure and preserves the paid
        // first-pass suggestions for inspection; no narrative call is queued.
        diagnostics = {
          ...diagnostics,
          recipeObligationCoverage: semanticCoverage.covered,
          missingRequiredRecipeObligations: semanticCoverage.missingRequired.map((obligation) => obligation.id),
          automaticNarrativeRepair: "disabled",
        };
        await updateRun({ suggestions, diagnostics });
      }
      await postValidatedOutline(suggestions, completionWarnings);
    };
    if (planningState.nextAction === "semantic-verification") {
      let verification: SemanticVerificationResult | undefined;
      try {
        verification = await verifyStoryArcSemantics(
          persistedSemanticSuggestions, body.arcTemplate, billableCall, body.recipe,
          "outline-semantic-verification", body.storyMaterialEnrichment?.premiseComponents ?? [],
        );
      } catch (error) {
        recordSemanticWarning(`Semantic verification was unavailable; continuing with the best structural outline: ${error instanceof Error ? error.message : String(error)}`);
        planningState = { ...planningState, phase: "semantic_completion", nextAction: "semantic-completion" };
        diagnostics = { ...diagnostics, stage: "semantic_verification_warning" };
        await updateRun({ suggestions: persistedSemanticSuggestions, planning_state: planningState, diagnostics });
        await continueAfterSemanticVerification(persistedSemanticSuggestions);
        return;
      }
      diagnostics = { ...diagnostics, stage: "semantic_verified", semanticVerification: verification };
      const unresolved = verification.unsatisfied.length;
      const notice = unresolved > 0
        ? `Independent semantic review found ${unresolved} unresolved requirement(s); no automatic narrative rewrite was made.`
        : undefined;
      diagnostics = {
        ...diagnostics,
        semanticAssessment: unresolved > 0 ? "needs_review" : "passed",
        semanticUnresolvedCount: unresolved,
        premiseComponentVerification: {
          total: body.storyMaterialEnrichment?.premiseComponents?.length ?? 0,
          unresolved: verification.unsatisfied.filter((issue) => issue.obligationID.startsWith("premise_component_")).map((issue) => issue.obligationID),
        },
        automaticNarrativeRepair: "disabled",
      };
      planningState = { ...planningState, phase: "semantic_completion", nextAction: "semantic-completion" };
      if (notice) recordSemanticWarning(notice);
      await updateRun({ suggestions: persistedSemanticSuggestions, planning_state: planningState, diagnostics });
      // Verification findings are product telemetry, NOT a customer-facing
      // warning. A paid outline should be reviewable without exposing QA.
      await continueAfterSemanticVerification(persistedSemanticSuggestions);
      return;
    }
    // Compatibility only: an old paid run may already be checkpointed in
    // semantic-repair or semantic-reverification. Retire both dispatches:
    // restore its saved original narrative and its original verification,
    // rather than calling another model to rewrite or rejudge the story.
    if (planningState.nextAction === "semantic-repair" ||
        planningState.nextAction === "semantic-reverification") {
      const original = Array.isArray(planningState.semanticRepairOriginalSuggestions)
        ? planningState.semanticRepairOriginalSuggestions as Suggestion[]
        : persistedSemanticSuggestions;
      const previousVerification = diagnostics.semanticRepairOriginalVerification ??
        diagnostics.semanticVerification;
      const unsatisfied = previousVerification &&
        typeof previousVerification === "object" &&
        Array.isArray((previousVerification as SemanticVerificationResult).unsatisfied)
        ? (previousVerification as SemanticVerificationResult).unsatisfied.length
        : null;
      const notice = unsatisfied === null
        ? "Retired semantic-repair checkpoint resumed with the original paid outline; existing verification was unavailable."
        : `Retired semantic-repair checkpoint resumed with the original paid outline (${unsatisfied} semantic finding(s)); no further narrative rewrite.`;
      planningState = { ...planningState, phase: "semantic_completion", nextAction: "semantic-completion" };
      diagnostics = {
        ...diagnostics,
        ...(previousVerification ? { semanticVerification: previousVerification } : {}),
        automaticNarrativeRepair: "disabled",
        semanticAssessment: unsatisfied === null ? "unavailable" : unsatisfied > 0 ? "needs_review" : "passed",
        semanticUnresolvedCount: unsatisfied,
        legacySemanticRepairCheckpointRecovered: true,
      };
      recordSemanticWarning(notice);
      await updateRun({ suggestions: original, planning_state: planningState, diagnostics });
      await continueAfterSemanticVerification(original);
      return;
    }
    // Runs checkpointed by the old worker must remain recoverable without
    // a new provider call, including if the prior worker already saved a
    // paid narrative. Complete from exactly that saved section sequence.
    if (planningState.nextAction === "story-arc-repair" ||
        planningState.nextAction === "story-arc-repair-completion" ||
        planningState.nextAction === "semantic-completion") {
      await continueAfterSemanticVerification(persistedSemanticSuggestions);
      return;
    }
    if (planningState.nextAction === "obligation-repair") {
      // Old checkpoints still resume their already-paid first-pass outline,
      // but no longer trigger an additional creative rewrite. The existing
      // deterministic completion gate will report any missing recipe IDs.
      diagnostics = {
        ...diagnostics,
        automaticNarrativeRepair: "disabled",
        legacyObligationRepairCheckpointRecovered: true,
      };
      await updateRun({ suggestions: persistedSemanticSuggestions, diagnostics });
      await continueAfterSemanticVerification(persistedSemanticSuggestions);
      return;
    }
    const resume = expansionResumeState(claimedRun);
    if (requestedStoryMaterialFormat(body) === "novel" && resume && claimedRun.story_material) {
      // PR8 (revised): delegate validation/repair to resumeOrRepairStoryMaterial.
      // The helper persists story_material + diagnostics.storyMaterialRepair
      // BEFORE returning when a repair is required, so a downstream
      // expandNovel failure or worker interruption cannot lose the completed
      // repair. When no repair is required the helper is a no-op persist-wise
      // and we explicitly persist the validated material below.
      const { material: resumedMaterial, audit: repairAudit } = await resumeOrRepairStoryMaterial({
        claimedMaterial: claimedRun.story_material,
        recipe: body.recipe,
        provenance,
        format: requestedStoryMaterialFormat(body),
        updateRun,
      });
      body = { ...body, storyMaterialEnrichment: resumedMaterial };
      // The persisted checkpoint is already validated; it is the fallback if
      // the resumed provider attempt fails before producing another checkpoint.
      latestValidSuggestions = resume.suggestions;
      // PR8 (revised): preserve the repair audit fields through the
      // subsequent diagnostics assignment so they actually land in the
      // persisted row. The previous shape wrote audit fields into
      // diagnostics but the next spread (claimedRun.diagnostics) overwrote
      // them — they never landed in the run row.
      diagnostics = {
        ...(claimedRun.diagnostics && typeof claimedRun.diagnostics === "object" ? claimedRun.diagnostics : {}),
        ...(repairAudit ? { storyMaterialRepair: repairAudit } : {}),
        stage: "expansion_resume",
        resumedFromRound: resume.startRound,
      };
      // Recovered expansion checkpoints necessarily represent an already
      // validated outline; keep that stage visible without marking expansion
      // complete until the resumed expansion actually succeeds.
      diagnostics = markCompletedStage(diagnostics, "outline");
      // PR8 (revised): persist the (possibly repaired) story_material and
      // the resume-stage diagnostics BEFORE expandNovel so a later failure
      // or interruption cannot lose the completed repair. Idempotent with
      // any earlier persist inside resumeOrRepairStoryMaterial — the final
      // updateRun below overwrites the same fields with completed-stage
      // diagnostics on success.
      if (repairAudit) {
        diagnostics = markMeaningfulProgress(
          diagnostics,
          `story_material_repaired:${stableJSONStringify(resumedMaterial)}`,
        );
      }
      await updateRun({
        story_material: resumedMaterial,
        diagnostics,
      });
      const recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>, resumedMaterial.premiseComponents ?? []);
      let completedSuggestions = resume.suggestions;
      let completionWarnings: string[] = [];
      try {
        const expanded = await expandNovel(resume.suggestions, recipeObligations, resume.startRound, resume.startBeatIndex, resume.priorDiagnostics);
        completedSuggestions = expanded.suggestions;
        completionWarnings = expanded.warnings;
        const advisoryQuality = collectAdvisoryOutlineQuality(
          completedSuggestions,
          resumedMaterial,
          requestedStoryMaterialFormat(body),
          body.arcTemplate,
        );
        diagnostics = {
          ...diagnostics,
          advisoryQuality,
          expansionRounds: expanded.diagnostics,
          expansionCheckpoint: buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], expanded.diagnostics),
          novelScale: evaluateNovelScale(completedSuggestions, body.existingSections ?? []),
        };
      } catch (error) {
        if (isProviderBillingUnavailable(error)) throw error;
        const recoverableExpansionFailure = error instanceof NovelScalePlanningError &&
          ["failed_expansion", "failed_under_target"].includes(error.code);
        if (!recoverableExpansionFailure) throw error;
        completedSuggestions = latestValidSuggestions.length > 0
          ? latestValidSuggestions
          : resume.suggestions;
        completionWarnings.push(`Optional novel expansion did not finish; the usable outline was preserved below the preferred ${NOVEL_PREFERRED_MIN_WORDS.toLocaleString()}-word planning target.`);
        diagnostics = {
          ...diagnostics,
          expansionWarning: error.message,
          expansionCheckpoint: diagnostics.expansionCheckpoint ?? buildExpansionCheckpoint(
            completedSuggestions,
            body.existingSections ?? [],
            diagnostics.expansionRounds as ExpansionRoundDiagnostic[] ?? resume.priorDiagnostics,
          ),
          novelScale: evaluateNovelScale(completedSuggestions, body.existingSections ?? []),
        };
      }
      // Initial and resumed expansion use the same final completion gate.
      await completeValidatedOutline(completedSuggestions, completionWarnings, true);
      return;
    }
    let storyMaterial: StoryMaterialEnrichment | null = null;
    let enrichmentDiagnostics: Record<string, unknown> = { enrichmentModel: model.id, sourceRecipeHash: provenance.sourceRecipeHash, sourceRecipeVersion: provenance.sourceRecipeVersion, sourcePromptPackID: provenance.sourcePromptPackID };
    if (body.storyMaterialEnrichment) {
      try {
        const candidate = validateStoryMaterialEnrichment(body.storyMaterialEnrichment, { recipe: body.recipe });
        const compatible = isCompatibleStoryMaterialEnrichment(candidate, provenance, requestedStoryMaterialFormat(body));
        const sufficiency = storyMaterialSufficiency(candidate, body.recipe, requestedStoryMaterialFormat(body));
        if (compatible && sufficiency.sufficient) {
          storyMaterial = candidate;
          enrichmentDiagnostics = {
            ...enrichmentDiagnostics,
            generatedOrReused: priorDiagnostics.generatedOrReused === "generated" ? "generated" : "reused",
            enrichmentLoadedFromCheckpoint: true,
            enrichmentCreditCostCharged: priorDiagnostics.generatedOrReused === "generated"
              ? Number(priorDiagnostics.enrichmentCreditCostCharged ?? 0)
              : 0,
            sufficiency: sufficiency.sufficient ? "sufficient" : "insufficient", sufficiencyReasons: sufficiency.reasons, itemCountsByCategory: sufficiency.counts, recipeDerivedItemCount: sufficiency.recipeDerivedItemCount, plannerInventedItemCount: sufficiency.plannerInventedItemCount };
        } else {
          enrichmentDiagnostics = { ...enrichmentDiagnostics, reuseRejected: compatible ? "insufficient" : "recipe_provenance_mismatch", priorSourceRecipeHash: candidate.sourceRecipeHash, priorSourceRecipeVersion: candidate.sourceRecipeVersion };
        }
      } catch (error) {
        enrichmentDiagnostics = { ...enrichmentDiagnostics, reuseRejected: error instanceof Error ? error.message : "incompatible_enrichment" };
      }
    }
    if (!storyMaterial) {
      const generateEnrichment = async (action: string, prior?: StoryMaterialEnrichment, repairReason?: string) => {
        diagnostics = {
          ...diagnostics,
          stage: action === "story-material-enrichment-repair"
            ? "enrichment_repair_generation"
            : "enrichment_generation",
        };
        const enrichmentPrompt = buildEnrichmentPrompt(body, prior, repairReason);
        let parsedMaterial: StoryMaterialEnrichment | null = null;
        const enrichmentResult = await billableCall(
          enrichmentPrompt.system,
          enrichmentPrompt.user,
          12000,
          { type: "json_schema", json_schema: { name: "story_material_enrichment", strict: true, schema: STORY_MATERIAL_ENRICHMENT_SCHEMA } },
          action,
          (content, finishReason) => {
            try {
              const normalizedProviderMaterial = normalizeProviderStoryMaterialItemIDs(
                downgradeUnverifiedProviderRecipeReferences(parseOutlineJSON(content, finishReason), body.recipe),
              );
              parsedMaterial = validateStoryMaterialEnrichment(normalizedProviderMaterial, { allowMissingProvenance: true, recipe: body.recipe });
              // Preserve canonical authored material even when the provider
              // returns a schema-valid package with zero source=recipe items.
              parsedMaterial = mergeCanonicalRecipeMaterial(
                parsedMaterial,
                body.recipe,
                provenance,
                requestedStoryMaterialFormat(body),
              );
            } catch (error) {
              if (error instanceof OutlineOutputExhaustedError || error instanceof StoryMaterialSufficiencyError) throw error;
              throw new StoryMaterialValidationError(error instanceof Error ? error.message : String(error));
            }
            const sufficiency = storyMaterialSufficiency(parsedMaterial, body.recipe, requestedStoryMaterialFormat(body));
            if (!sufficiency.sufficient) throw new StoryMaterialSufficiencyError(sufficiency.reasons);
            return parsedMaterial;
          },
        );
        const material = parsedMaterial ?? validateStoryMaterialEnrichment(
          parseOutlineJSON(enrichmentResult.content, enrichmentResult.finishReason),
          { allowMissingProvenance: true, recipe: body.recipe },
        );
        return { material: attachRecipeProvenance(material, provenance), result: enrichmentResult };
      };
      let generated: { material: StoryMaterialEnrichment; result: SuggestionLLMResult };
      const repairPending = planningState.nextAction === "story-material-enrichment-repair";
      if (repairPending) {
        generated = await generateEnrichment(
          "story-material-enrichment-repair",
          undefined,
          String(planningState.enrichmentRepairReason ?? "The first enrichment package failed semantic validation."),
        );
      } else {
        try {
          generated = await generateEnrichment("story-material-enrichment");
        } catch (error) {
          if (error instanceof StoryMaterialSufficiencyError || error instanceof StoryMaterialValidationError) {
            const repairReason = error instanceof StoryMaterialSufficiencyError
              ? error.reasons.join("; ")
              : error.message;
            enrichmentDiagnostics = {
              ...enrichmentDiagnostics,
              repairPending: true,
              firstPassRepairReason: repairReason,
            };
            planningState = {
              ...planningState,
              phase: "enrichment_repair_pending",
              nextAction: "story-material-enrichment-repair",
              enrichmentRepairReason: repairReason,
            };
            await updateRun({ planning_state: planningState, diagnostics: { ...diagnostics, ...enrichmentDiagnostics, stage: "enrichment_repair_pending" } });
            throw new SuggestionWorkerYield();
          }
          throw error;
        }
      }
      storyMaterial = generated.material;
      const sufficiency = storyMaterialSufficiency(storyMaterial, body.recipe, requestedStoryMaterialFormat(body));
      enrichmentDiagnostics = { ...enrichmentDiagnostics, generatedOrReused: "generated", enrichmentCreditCostCharged: generated.result.creditCostCharged, schemaVersion: storyMaterial.version, sufficiency: sufficiency.sufficient ? "sufficient" : "insufficient", sufficiencyReasons: sufficiency.reasons, itemCountsByCategory: sufficiency.counts, recipeDerivedItemCount: sufficiency.recipeDerivedItemCount, plannerInventedItemCount: sufficiency.plannerInventedItemCount };
      planningState = {
        ...planningState,
        phase: "enrichment_complete",
        nextAction: "outline-plan",
        enrichmentRepairReason: undefined,
      };
      diagnostics = markCompletedStage(
        markMeaningfulProgress(
          { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_complete" },
          `story_material_complete:${stableJSONStringify(storyMaterial)}`,
        ),
        "enrichment",
      );
      await updateRun({ story_material: storyMaterial, planning_state: planningState, diagnostics });
    }
    if (!storyMaterial) throw new Error("story material enrichment was not produced");
    recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>, storyMaterial.premiseComponents ?? []);
    diagnostics = { ...diagnostics, premiseComponents: storyMaterial.premiseComponents ?? [], premiseComponentCount: storyMaterial.premiseComponents?.length ?? 0 };
    // Loading already persisted enrichment is rehydration, not progress.
    diagnostics = { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_ready" };
    await updateRun({
      story_material: storyMaterial,
      diagnostics,
    });
    await persistPlanningProvenance(db, body, runId, storyMaterial, provenance);
    body = { ...body, storyMaterialEnrichment: storyMaterial };
    const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
    // Freeze the deterministic compact view on the durable run so a reclaimed
    // worker cannot silently prompt against a materially different payload.
    const computedPlanningContext = {
      ...buildCompactPlanningView(body, recipeObligations, storyMaterial),
      provenance: {
        sourceRecipeHash: provenance.sourceRecipeHash,
        sourceRecipeVersion: provenance.sourceRecipeVersion,
        sourcePromptPackID: provenance.sourcePromptPackID,
        projectID: body.recipe?.project?.id ?? null,
        projectLineageID: body.project_lineage_id ?? null,
      },
    };
    // A reclaimed worker receives the original request JSON but reconstructs
    // story material from the persisted JSON column. That round trip can
    // normalize harmless representation details even when the request is the
    // same logical/idempotent request. The frozen checkpoint is authoritative;
    // verify its own hash, then reuse it instead of comparing two
    // representation-sensitive reconstructions and falsely failing before the
    // next paid stage. New runs still compute and persist the checkpoint here.
    let planningContext: Record<string, unknown> = computedPlanningContext;
    let planningContextHash = await sha256Hex(stableJSONStringify(computedPlanningContext));
    const persistedPlanningContext = claimedRun.planning_context && typeof claimedRun.planning_context === "object"
      ? claimedRun.planning_context as Record<string, unknown>
      : null;
    if (persistedPlanningContext && claimedRun.planning_context_version === 1 && claimedRun.planning_context_hash) {
      const persistedHash = await sha256Hex(stableJSONStringify(persistedPlanningContext));
      if (persistedHash !== claimedRun.planning_context_hash) {
        throw new Error("persisted planning context checkpoint is corrupted; refusing to resume the paid outline stage");
      }
      planningContext = persistedPlanningContext;
      planningContextHash = claimedRun.planning_context_hash;
    }
    if (!persistedPlanningContext) {
      diagnostics = markMeaningfulProgress(
        diagnostics,
        `planning_context_persisted:${planningContextHash}`,
      );
    }
    await updateRun({ planning_context: planningContext, planning_context_hash: planningContextHash, planning_context_version: claimedRun.planning_context_version ?? 1, diagnostics });
    // PR 5: allocation counts are residual NEW sections. Persist the validated
    // plan before the next provider boundary so continuation does not rerun a
    // settled allocation call or double-subtract existing coverage.
    const persistedAllocation = Array.isArray(planningState.allocationEntries)
      ? planningState.allocationEntries as Array<[string, Allocation]>
      : null;
    if (persistedAllocation) {
      allocation = new Map<string, Allocation>(persistedAllocation);
    } else {
      const retryOnly = planningState.nextAction === "outline-plan-retry";
      diagnostics = { ...diagnostics, stage: "allocation_generation" };
      try {
        allocation = await planSectionAllocation(
          body,
          openaiKey,
          billableCall,
          recipeObligations,
          { retryOnly, deferRetry: !retryOnly, onArchitecture: (chosen) => { storyArchitecture = chosen; } },
        );
      } catch (error) {
        if (error instanceof AllocationRetryRequired) {
          planningState = {
            ...planningState,
            phase: "allocation_retry_pending",
            nextAction: "outline-plan-retry",
            allocationRetryReason: error.reason,
          };
          await updateRun({ planning_state: planningState, diagnostics: { ...diagnostics, stage: "allocation_retry_pending", allocationRetryReason: error.reason } });
          throw new SuggestionWorkerYield();
        }
        throw error;
      }
      planningState = {
        ...planningState,
        phase: "allocation_complete",
        nextAction: "outline-suggestions",
        allocationEntries: Array.from(allocation.entries()),
        storyArchitecture,
        allocationRetryReason: undefined,
      };
      diagnostics = markCompletedStage(
        markMeaningfulProgress(
          { ...diagnostics, stage: "allocation_complete", plannerAllocationValidatedCountsByBeat: Object.fromEntries(Array.from(allocation.entries()).map(([beatID, plan]) => [beatID, plan.minSections])) },
          `allocation_validated:${stableJSONStringify(Array.from(allocation.entries()))}`,
        ),
        "allocation",
      );
      await updateRun({ planning_state: planningState, diagnostics });
    }
    const allocationCountsByBeat = Object.fromEntries(
      Array.from(allocation.entries()).map(([beatID, plan]) => [beatID, plan.minSections]),
    );
    diagnostics = {
      ...diagnostics,
      ...enrichmentDiagnostics,
      stage: "planner_complete",
      plannerAllocationFirstPassCountsByBeat: allocationCountsByBeat,
      plannerAllocationValidatedCountsByBeat: allocationCountsByBeat,
      plannerContainerCountsByBeat: Object.fromEntries(Array.from(allocation.entries())
        .map(([beatID, plan]) => [beatID, plan.containerCounts ?? null])),
      recipeObligations,
      ...(storyArchitecture ? { storyArchitecture } : {}),
    };
    const { system, user: userPrompt } = buildPrompt(body, allocation, recipeObligations, storyMaterial, storyArchitecture);
    const responseSchema = buildSuggestionResponseSchema(body.arcTemplate.beats, allocation, recipeObligations, body.arcTemplate.name, requestedStoryMaterialFormat(body));
    const responseFormat = {
      type: "json_schema",
      json_schema: { name: "outline_suggestions_by_beat", strict: true, schema: responseSchema },
    };
    let result: { suggestions: Suggestion[]; warnings: string[] } = { suggestions: [], warnings: [] };
    plannedMinimumSections = Array.from(allocation.values())
      .reduce((sum, plan) => sum + plan.minSections, 0);
    diagnostics = { ...diagnostics, stage: "outline_generation", plannedMinimumSections };
    if (plannedMinimumSections > 0) {
      const rawResponse = await billableCall(
        system,
        userPrompt,
        OUTLINE_OUTPUT_TOKEN_BUDGET,
        responseFormat,
        "outline-suggestions",
        async (content, finishReason) => {
          const flattened = flattenSuggestionResponse(parseOutlineJSON(content, finishReason), body.arcTemplate.beats);
          latestProviderCandidate = flattened.suggestions as Suggestion[];
          // Persist before validation: a recoverable structural defect must
          // not discard a paid provider response or force completed stages to
          // run again on the next recovery attempt.
          diagnostics = {
            ...diagnostics,
            stage: "outline_candidate_persisted",
            outlineCandidatePersistedBeforeValidation: true,
            firstPassParsedCounts: countSuggestionsByBeat(flattened.suggestions),
          };
          await updateRun({ suggestions: latestProviderCandidate, diagnostics });
          diagnostics = { ...diagnostics, stage: "outline_validating" };
          const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations, body.arcTemplate);
          const deduped = removeDuplicateOutlineSections(validated.suggestions);
          validateNovelLeafContainers(deduped.suggestions, requestedStoryMaterialFormat(body));
          const merged = mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), deduped.suggestions, [], true);
          if (merged.length > MAX_PLANNED_SECTIONS) {
            throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
          }
          return { ...validated, suggestions: merged };
        },
      );
      const flattened = flattenSuggestionResponse(
        parseOutlineJSON(rawResponse.content, rawResponse.finishReason),
        body.arcTemplate.beats,
      );
      const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations, body.arcTemplate);
      const deduped = removeDuplicateOutlineSections(validated.suggestions);
      validateNovelLeafContainers(deduped.suggestions, requestedStoryMaterialFormat(body));
      result = { suggestions: mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), deduped.suggestions, [], true), warnings: validated.warnings };
      // Structural replay is removed before any durable checkpoint or semantic
      // provider stage. Never surface duplicate first-pass sections.
      const firstPassActualContainerCountsByBeat = Object.fromEntries(body.arcTemplate.beats.map((beat) => [
        beat.id,
        Object.fromEntries(NOVEL_LEAF_CONTAINERS.map((container) => [
          container, result.suggestions.filter((section) =>
            section.storyArcBeatID === beat.id && section.container === container).length,
        ])),
      ]));
      diagnostics = { ...diagnostics, stage: "outline_validated", firstPassParsedCounts: countSuggestionsByBeat(result.suggestions), firstPassValidatedCounts: countSuggestionsByBeat(result.suggestions), firstPassActualContainerCountsByBeat, structuralDedupedSections: deduped.removed };
      if (result.suggestions.length > MAX_PLANNED_SECTIONS) {
        throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
      }
    }

    // Structural validation and required recipe-obligation coverage are completion invariants; literary heuristics remain advisory.
    latestValidSuggestions = result.suggestions;
    const initialQuality = collectAdvisoryOutlineQuality(
      result.suggestions,
      storyMaterial,
      requestedStoryMaterialFormat(body),
      body.arcTemplate,
      allocation,
    );
    diagnostics = {
      ...diagnostics,
      sectionContractValidated: true,
      semanticArcRepairedSections: [],
      semanticArcUnresolvedSections: [],
      dramaticDistinctnessIssues: initialQuality.distinctnessIssues,
      semanticArcIssues: initialQuality.semanticArcIssues,
      causalScaleIssues: initialQuality.causalScaleIssues,
      unusedStoryMaterialItems: initialQuality.unusedStoryMaterialItems,
      plannerCharacterIntegration: initialQuality.plannerCharacterIntegration,
      ...(initialQuality.advisoryValidationError
        ? { advisoryValidationError: initialQuality.advisoryValidationError }
        : {}),
    };

    const authoredSemanticBeatCount = body.arcTemplate.beats.filter((beat) => arcRoleContract(beat, body.arcTemplate.name).semanticObligations.length > 0).length;
    if ((authoredSemanticBeatCount > 0 || intimacyRequirement(body) !== null) && sectionAllocationDeficits(result.suggestions).length === 0) {
      // Semantic verification is its own durable provider stage. Persist the
      // validated outline before yielding so a one-dispatch worker slice never
      // replays the paid outline call or loses the verifier checkpoint.
      planningState = { ...planningState, phase: "semantic_verification_pending", nextAction: "semantic-verification" };
      diagnostics = { ...diagnostics, stage: "semantic_verification_pending" };
      await updateRun({ suggestions: result.suggestions, planning_state: planningState, diagnostics });
      throw new SuggestionWorkerYield();
    }

    await continueAfterSemanticVerification(result.suggestions, result.warnings);
  } catch (err) {
    if (err instanceof SuggestionWorkerYield) {
      const yieldedAt = new Date().toISOString();
      diagnostics = {
        ...diagnostics,
        worker: {
          ...(diagnostics.worker as Record<string, unknown>),
          lastSliceCompletedAt: yieldedAt,
          lastYieldReason: "provider_dispatch_boundary",
          lastCompletedAction: "checkpoint persisted before next provider call",
          nextAction: "resume persisted planning checkpoint",
        },
      };
      await returnSuggestionRunToPending(
        updateRun,
        scheduleContinuation,
        continuationBody,
        authHeader,
        diagnostics,
      );
      return;
    }
    const providerBillingUnavailable = isProviderBillingUnavailable(err);
    const providerErrorCode = err && typeof err === "object" && "errorCode" in err
      ? String((err as { errorCode?: unknown }).errorCode)
      : null;
    const configurationFailure = providerErrorCode === "invalid_request" ||
      providerErrorCode === "provider_rejected";
    const outputExhausted = err instanceof OutlineOutputExhaustedError ||
      providerErrorCode === "provider_output_exhausted";
    const providerRateLimited = providerErrorCode === "provider_rate_limited";
    const providerOutage = providerErrorCode === "provider_overloaded" ||
      providerErrorCode === "provider_timeout";
    const errorCode = providerBillingUnavailable
      ? "provider_billing_unavailable"
      : outputExhausted
      ? "provider_output_exhausted"
      : configurationFailure
      ? "unsupported_model_configuration"
      : providerRateLimited
      ? "provider_rate_limited"
      : providerOutage
      ? "provider_outage"
      : providerErrorCode === "story_arc_semantic_unresolved"
      ? "story_arc_semantic_unresolved"
      : providerErrorCode
      ? "provider_error"
      : err instanceof RecipeObligationValidationError
      ? err.code
      : err instanceof StoryMaterialSufficiencyError
      ? "insufficient_story_material"
      : err && typeof err === "object" && "code" in err
      ? String((err as { code?: unknown }).code)
      : (err instanceof Error &&
          /insufficient credits|requires ~|you have/i.test(err.message)
        ? "insufficient_credits"
        : (err instanceof Error && /openai|provider/i.test(err.message)
          ? "provider_error"
          : "server_error"));
    const message = err instanceof Error ? err.message : String(err);
    const publicErrorBase = providerBillingUnavailable
      ? "Temporarily unavailable — try again later."
      : outputExhausted
      ? "The outline provider exhausted its completion limit before returning complete JSON; this run was billed for the provider attempt and requires a separate retry or output-budget change."
      : configurationFailure
      ? "This selected model does not support the outline planner configuration."
      : providerRateLimited
      ? "The AI provider is rate-limiting outline planning. Wait a moment before trying again."
      : providerOutage
      ? "The AI provider is temporarily unavailable; try again later."
      : providerErrorCode === "story_arc_semantic_unresolved"
      ? "The outline could not satisfy an authored Story Arc semantic obligation after one bounded repair and re-verification."
      : providerErrorCode
      ? "The AI outline planner could not complete this request; review the run status before retrying."
      : message.slice(0, 2000);
    const settledCredits = await reconcileExhaustedSuggestionBilling(db, {
      id: runId,
      credit_cost_charged: claimedRun.credit_cost_charged,
    });
    const billingStatus = settledCredits === null
      ? "Billing reconciliation is unresolved; any settled stages were preserved."
      : settledCredits > 0
      ? `${settledCredits.toFixed(2)} credits were already settled for completed stages; no duplicate charge will be created.`
      : "No settled customer charge is recorded for this run.";
    const publicError = `${publicErrorBase} ${billingStatus}`;
    const failedDiagnostics = {
      ...diagnostics,
      billingReconciliation: settledCredits === null ? "unresolved" : settledCredits > 0 ? "settled" : "no_settled_charge",
      settledCredits,
      stage: "failed",
      failureStage: diagnostics.stage,
      runID: runId,
      selectedModel: providerModelForAlert,
      errorCode,
      ...(providerErrorCode ? { providerErrorCode } : {}),
      plannedMinimumSections,
      ...(providerBillingUnavailable || configurationFailure ? {} : { error: message.slice(0, 500) }),
      ...(requestedStoryMaterialFormat(body) === "novel"
        ? { novelScale: evaluateNovelScale(latestValidSuggestions, body.existingSections ?? []) }
        : {}),
    };
    await updateRun({
      status: "failed",
      suggestions: latestProviderCandidate ?? latestValidSuggestions,
      planning_state: planningState,
      error_code: errorCode,
      error: publicError,
      diagnostics: failedDiagnostics,
      completed_at: new Date().toISOString(),
      lease_owner: null,
      lease_expires_at: null,
    });
    if (providerBillingUnavailable) {
      const upstream = getProviderBillingUnavailableUpstream(err) ?? {};
      const context: ProviderBillingUnavailableContext = {
        stableCode: "provider_billing_unavailable",
        upstreamProviderCode: upstream.code ?? null,
        upstreamMessage: upstream.message ?? null,
        upstreamStatus: upstream.status ?? null,
        providerModel: providerModelForAlert,
        chapterRunID: runId,
        projectID: body.recipe?.project?.id ?? null,
        environment: "production",
      };
      const notify = dependencies.notifyProviderBillingUnavailable ??
        ((alertContext: ProviderBillingUnavailableContext) =>
          notifyProviderBillingUnavailable(alertContext, { rpcClient: db }));
      const alertPromise = Promise.resolve().then(() => notify(context)).catch((alertError) => {
        console.error(
          `[outline-from-recipe] operator alert failed for ${runId}: ${
            alertError instanceof Error ? alertError.message : String(alertError)
          }`,
        );
      });
      const scheduleAlert = dependencies.scheduleAlert ?? ((promise: Promise<unknown>) => {
        const runtime = (globalThis as typeof globalThis & {
          EdgeRuntime?: { waitUntil?: (task: Promise<unknown>) => void };
        }).EdgeRuntime;
        if (typeof runtime?.waitUntil === "function") runtime.waitUntil(promise);
        else void promise;
      });
      try {
        scheduleAlert(alertPromise);
      } catch (scheduleError) {
        console.error(
          `[outline-from-recipe] operator alert scheduling failed for ${runId}: ${
            scheduleError instanceof Error ? scheduleError.message : String(scheduleError)
          }`,
        );
      }
    }
  }
}

function readSupabaseSecretKey(raw: string | undefined): string {
  if (!raw) return "";
  try {
    const value = (JSON.parse(raw) as Record<string, unknown>).default;
    return typeof value === "string" ? value.trim() : "";
  } catch {
    return "";
  }
}

function isWatchdogRequest(req: Request): boolean {
  const configured = readSupabaseSecretKey(Deno.env.get("SUPABASE_SECRET_KEYS")) ||
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return Boolean(configured && req.headers.get("apikey") === configured);
}

export interface WatchdogRecoveryDependencies {
  db?: any;
  openaiKey?: string;
  authHeader?: string;
  startWorker?: SuggestionWorkerStarter;
}

export async function recoverWatchdogRun(
  req: Request,
  dependencies: WatchdogRecoveryDependencies = {},
): Promise<Response> {
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return errorResponse("invalid_request", "Body must be JSON", 400); }
  const db = dependencies.db ?? admin();
  const runID = typeof body.watchdog_run_id === "string" ? body.watchdog_run_id : null;
  let run: any = null;
  if (runID) {
    const result = await db.from("outline_suggestion_runs")
      .select("id, user_id, status, request_json, attempt_count, lease_expires_at, credit_cost_charged, created_at, updated_at, diagnostics")
      .eq("id", runID).maybeSingle();
    if (result.error) return errorResponse("db_error", "Could not read watchdog run", 500);
    run = result.data;
  } else if (typeof body.idempotencyKey === "string") {
    const result = await db.from("outline_suggestion_runs")
      .select("id, user_id, status, request_json, attempt_count, lease_expires_at, credit_cost_charged, created_at, updated_at, diagnostics")
      .eq("idempotency_key", body.idempotencyKey).maybeSingle();
    if (result.error) return errorResponse("db_error", "Could not read continuation run", 500);
    run = result.data;
  } else {
    return errorResponse("invalid_request", "watchdog_run_id or idempotencyKey required", 400);
  }
  if (!run) return errorResponse("not_found", "suggestion run not found", 404);
  if (run.status === "running") {
    const expired = run.lease_expires_at && new Date(run.lease_expires_at).getTime() < Date.now();
    if (!expired) return corsResponse(JSON.stringify({ run_id: run.id, status: run.status }), { status: 200 });
    if (!await reclaimExpiredSuggestionRun(db, run)) {
      return corsResponse(JSON.stringify({ run_id: run.id, status: run.status }), { status: 200 });
    }
  }
  if (run.status !== "pending") return corsResponse(JSON.stringify(suggestionRunResponse(run)), { status: 200 });
  const openaiKey = dependencies.openaiKey ?? Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);
  const recoveredBody = await recoverPersistedPlanningBody(db, run);
  const secret = readSupabaseSecretKey(Deno.env.get("SUPABASE_SECRET_KEYS")) || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const authHeader = dependencies.authHeader ?? `Bearer ${secret}`;
  const startWorker = dependencies.startWorker ?? (async (runID, workerBody, userID, key, attemptCount, workerAuthHeader) => {
    // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
    EdgeRuntime.waitUntil(runSuggestionJob(runID, workerBody, userID, key, attemptCount, workerAuthHeader));
  });
  await startWorker(run.id, recoveredBody, run.user_id, openaiKey, run.attempt_count ?? 0, authHeader);
  return corsResponse(JSON.stringify({ run_id: run.id, status: "pending", watchdog: true }), { status: 202 });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "GET" && req.method !== "POST") {
    return errorResponse("method_not_allowed", "GET or POST required", 405);
  }
  const authHeader = req.headers.get("Authorization");
  if (req.method === "POST" && isWatchdogRequest(req)) {
    return await recoverWatchdogRun(req);
  }
  if (!authHeader) {
    return errorResponse(
      "not_authenticated",
      "Missing Authorization header",
      401,
    );
  }
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) {
    return errorResponse("not_authenticated", "Invalid token", 401);
  }

  if (req.method === "GET") {
    const searchParams = new URL(req.url).searchParams;
    const runId = searchParams.get("run_id");
    const projectId = searchParams.get("project_id");
    const runColumns =
      "id, status, suggestions, warnings, error_code, error, diagnostics, planning_state, story_material, created_at, updated_at, completed_at, credit_cost_charged, remaining_credits, request_json, project_id, idempotency_key, request_fingerprint, attempt_count, lease_expires_at";

    let run: any = null;
    let error: any = null;
    if (runId) {
      ({ data: run, error } = await userClient.from(
        "outline_suggestion_runs",
      ).select(runColumns).eq("id", runId).single());
    } else if (projectId) {
      const idempotencyKey = searchParams.get("idempotency_key");
      let query = userClient.from("outline_suggestion_runs")
        .select(runColumns)
        .eq("project_id", projectId)
        .order("created_at", { ascending: false })
        .limit(1);
      if (searchParams.get("completed_only") === "true") query = query.eq("status", "completed");
      if (idempotencyKey) query = query.eq("idempotency_key", idempotencyKey);
      const result = await query;
      error = result.error;
      run = result.data?.[0] ?? null;
    } else {
      return errorResponse(
        "missing_param",
        "run_id or project_id query param required",
        400,
      );
    }
    if (error) {
      console.error("[outline-from-recipe] suggestion run query failed", error);
      return errorResponse("db_error", "Could not read suggestion run", 500);
    }
    if (!run) return errorResponse("not_found", "run not found", 404);

    // GET polling is a recovery backstop for suspended workers. The durable
    // pending claim inside runSuggestionJob is the final race guard.
    let recoveredRun = run;
    if (run.status === "running" || run.status === "pending") {
      const reclaimed = await reclaimExpiredSuggestionRun(admin(), run);
      if (reclaimed) {
        const authoritative = await loadAuthoritativeSuggestionRun(admin(), run.id);
        if (!authoritative) {
          return errorResponse(
            "recovery_state_unavailable",
            "Could not read the authoritative recovered suggestion state; retry polling.",
            503,
          );
        }
        recoveredRun = authoritative;
      }
    }
    if (recoveredRun.status === "pending") {
      const recoveryKey = Deno.env.get("OPENAI_API_KEY");
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(recoverPendingSuggestionRun(
        recoveredRun,
        user.id,
        recoveryKey,
        authHeader,
        (recoveryRunID, recoveryBody, recoveryUserID, recoveryKeyValue, recoveryAttemptCount, recoveryAuthHeader) =>
          runSuggestionJob(recoveryRunID, recoveryBody, recoveryUserID, recoveryKeyValue, recoveryAttemptCount, recoveryAuthHeader),
        admin(),
      ));
      run = recoveredRun;
    }
    return corsResponse(
      JSON.stringify(suggestionRunResponse(recoveredRun)),
      { status: 200 },
    );
  }

  let body: OutlineFromRecipeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }
  // Resolve existing idempotent runs before applying the fixed default so
  // recovery preserves the model identity recorded on that run.
  if (body.storyMaterialEnrichment) {
    body = {
      ...body,
      storyMaterialEnrichment: normalizeProviderStoryMaterialItemIDs(
        downgradeUnverifiedProviderRecipeReferences(body.storyMaterialEnrichment, body.recipe),
      ) as StoryMaterialEnrichment,
    };
  }
  const validationError = validateRequest(body);
  if (validationError) {
    return errorResponse("invalid_request", validationError, 400);
  }
  const intimacyCompatibilityError = validateAudienceCompatibility(body.recipe?.project?.contentRating, normalizeIntimacyRating(body.recipe?.project?.intimacyRating));
  if (intimacyCompatibilityError) {
    return errorResponse("invalid_audience_compatibility", intimacyCompatibilityError, 422);
  }
  body = { ...body, recipe: { ...body.recipe, project: { ...body.recipe.project, intimacyRating: normalizeIntimacyRating(body.recipe.project.intimacyRating) } } };
  const db = admin();
  // Current clients must identify the concrete Outline and canonical project
  // lineage. Validate against the real schema (local_project_id + lineage_id)
  // before rate limiting, run creation, or any billable work.
  if (!body.outline_id || !body.project_lineage_id) {
    return errorResponse("planning_identity_required", "outline_id and project_lineage_id are required", 400);
  }
  const { data: outlineRow, error: outlineError } = await db
    .from("outlines")
    .select("id, user_id, local_project_id, lineage_id, source_recipe_hash")
    .eq("id", body.outline_id)
    .maybeSingle();
  if (outlineError) return errorResponse("db_error", "Could not verify outline ownership", 500);
  if (!outlineRow) return errorResponse("outline_not_found", "outline_id does not reference an existing outline", 400);
  if (outlineRow.user_id !== user.id) return errorResponse("outline_not_owned", "outline_id does not belong to the authenticated user", 403);
  if (String(outlineRow.local_project_id).toLowerCase() !== String(body.recipe.project.id).toLowerCase()) {
    return errorResponse("outline_wrong_project", "outline_id does not belong to the supplied project identity", 400);
  }
  if (!outlineRow.lineage_id || String(outlineRow.lineage_id).toLowerCase() !== String(body.project_lineage_id).toLowerCase()) {
    return errorResponse("outline_lineage_mismatch", "outline_id lineage does not match the supplied project_lineage_id", 400);
  }
  const provenance = await recipeProvenance(body.recipe);
  if (outlineRow.source_recipe_hash && outlineRow.source_recipe_hash !== provenance.sourceRecipeHash) {
    const { count } = await db.from("outline_sections").select("id", { count: "exact", head: true })
      .eq("outline_id", body.outline_id).neq("status", "deleted");
    if ((count ?? 0) > 0) return errorResponse("recipe_provenance_conflict", "Recipe changed after sections were planned; start a fresh outline or edit the existing recipe.", 409);
  }
  // Estimates are read-only: they use the authenticated entitlement and
  // canonical model pricing, but never create a run, provider attempt, usage
  // event, ledger entry, or rate-limit log.
  if (body.estimate_only === true) {
    const selectedModel = await new SupabaseGenerationModelStore(db).getEnabledModelById(
      body.modelID?.trim() || LEGACY_PLANNING_MODEL_ID,
    );
    if (!selectedModel) {
      return errorResponse("model_unavailable", `Selected outline model is unavailable: ${body.modelID ?? LEGACY_PLANNING_MODEL_ID}`, 422);
    }
    try {
      const entitlement = await new SupabaseCreditStore(db).loadOrDefault(user.id);
      const estimate = estimateOutlinePlanningCost(body, selectedModel, entitlement);
      return corsResponse(JSON.stringify({
        estimated_credits: estimate.estimatedCredits,
        lower_bound_credits: estimate.lowerBoundCredits,
        upper_bound_credits: estimate.upperBoundCredits,
        available_credits: estimate.availableCredits,
        projected_balance: estimate.projectedBalance,
        allowed: estimate.allowed,
        model: estimate.model,
        expected_stages: estimate.expectedStages,
      }), { status: 200 });
    } catch (error) {
      console.error("[outline-from-recipe] estimate failed", error);
      return errorResponse("estimate_unavailable", "Outline pricing could not be estimated", 503);
    }
  }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);
  }
  // PR 7: calculate both identities BEFORE checkRateLimit so reconnects
  // can short-circuit without consuming a rate-limit slot or logging.
  // Existing historical rows may use the pre-model fingerprint; new rows
  // persist the canonical body with an explicit model.
  const incomingBody = body;
  let identityResolution = await resolvePlanningRequestIdentity(incomingBody);
  let { canonicalBody, identity, lookupKeys } = identityResolution;
  // PR 7: resolve an existing matching idempotent run first. If the
  // current request's idempotency key is already bound to a run with the
  // same fingerprint, reconnect to it (no rate limit, no log entry). If
  // the fingerprint differs, reject as 409 idempotency_conflict. This is
  // the idempotency-safe path for app reconnects / worker retries /
  // iOS suggestion-status polling that re-submits the same request after
  // a transient network failure.
  const existingResult = await db
    .from("outline_suggestion_runs")
    .select("id, status, request_fingerprint, lease_expires_at, error_code, suggestions, warnings, error, diagnostics, planning_state, story_material, credit_cost_charged, remaining_credits, request_json, created_at, updated_at, completed_at, attempt_count")
    .eq("user_id", user.id)
    .in("idempotency_key", lookupKeys)
    .maybeSingle();
  let existing = existingResult.data;
  const existingError = existingResult.error;
  if (existingError) {
    console.error("[outline-from-recipe] existing-run resolve failed", existingError);
    return errorResponse("db_error", existingError.message ?? "Could not resolve existing run", 500);
  }
  if (existing) {
    identityResolution = await resolvePlanningRequestIdentity(incomingBody, existing);
    ({ canonicalBody, identity, lookupKeys } = identityResolution);
    if (existing.request_fingerprint && !identityResolution.acceptedFingerprints.has(existing.request_fingerprint)) {
      return errorResponse(
        "idempotency_conflict",
        "The idempotency key is already bound to a different suggestion request",
        409,
      );
    }
    if (isRetryableSemanticVerificationFailure(existing)) {
      const recoveredDiagnostics = {
        ...(existing.diagnostics ?? {}),
        semanticRetryCount: Number(existing.diagnostics?.semanticRetryCount ?? 0) + 1,
        stage: "semantic_reverification_retry_pending",
      };
      const { error: retryError } = await db.from("outline_suggestion_runs").update({
        status: "pending", error_code: null, error: null, completed_at: null,
        lease_owner: null, lease_expires_at: null, diagnostics: recoveredDiagnostics,
        attempt_count: (existing.attempt_count ?? 0) + 1,
      }).eq("id", existing.id).eq("status", "failed");
      if (retryError) return errorResponse("db_error", retryError.message ?? "Could not retry semantic verification", 500);
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
      return corsResponse(JSON.stringify({ ...suggestionRunResponse(existing), status: "pending", errorCode: null, error: null, diagnostics: recoveredDiagnostics }), { status: 200 });
    }
    if (isRetryableSemanticRepairFailure(existing)) {
      const recoveredDiagnostics = {
        ...(existing.diagnostics ?? {}),
        semanticRecoveryAttempts: Number(existing.diagnostics?.semanticRecoveryAttempts ?? 0) + 1,
        stage: "semantic_repair_recovery_pending",
      };
      const { error: retryError } = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        diagnostics: recoveredDiagnostics,
        attempt_count: (existing.attempt_count ?? 0) + 1,
      }).eq("id", existing.id).eq("status", "failed");
      if (retryError) return errorResponse("db_error", retryError.message ?? "Could not recover failed semantic repair", 500);
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
      return corsResponse(JSON.stringify({ ...suggestionRunResponse(existing), status: "pending", errorCode: null, error: null, diagnostics: recoveredDiagnostics }), { status: 200 });
    }
    if (isRetryableStoryMaterialFailure(existing)) {
      // This exact request failed before billing. Requeue the same run under
      // the same idempotency identity so the repaired server can retry it
      // without creating a duplicate run or charging twice.
      const { error: retryError } = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        attempt_count: (existing.attempt_count ?? 0) + 1,
      }).eq("id", existing.id).eq("status", "failed").eq("credit_cost_charged", 0);
      if (retryError) return errorResponse("db_error", retryError.message ?? "Could not retry failed suggestion run", 500);
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
      return corsResponse(
        JSON.stringify({
          run_id: existing.id,
          status: "pending",
          suggestions: existing.suggestions,
          warnings: existing.warnings,
          errorCode: null,
          error: null,
          diagnostics: existing.diagnostics,
          storyMaterialEnrichment: existing.story_material,
          created_at: existing.created_at,
          updated_at: new Date().toISOString(),
          completed_at: null,
          creditCostCharged: existing.credit_cost_charged,
          remainingCredits: existing.remaining_credits,
          sourceRecipe: existing.request_json?.recipe ?? null,
        }),
        { status: 200 },
      );
    }
    if (isRetryableInsufficientCreditFailure(existing)) {
      const { error: retryError } = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        attempt_count: (existing.attempt_count ?? 0) + 1,
      }).eq("id", existing.id).eq("status", "failed");
      if (retryError) return errorResponse("db_error", retryError.message ?? "Could not resume after adding credits", 500);
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
      return corsResponse(JSON.stringify({ ...suggestionRunResponse(existing), status: "pending", errorCode: null, error: null }), { status: 200 });
    }
    if (isRetryableExpansionFailure(existing)) {
      const { error: retryError } = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        attempt_count: (existing.attempt_count ?? 0) + 1,
      }).eq("id", existing.id).eq("status", "failed");
      if (retryError) return errorResponse("db_error", retryError.message ?? "Could not resume expansion", 500);
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
      return corsResponse(JSON.stringify({ ...suggestionRunResponse(existing), status: "pending", errorCode: null, error: null }), { status: 200 });
    }
    if (!existing) {
      return errorResponse("db_error", "Could not resolve existing suggestion run", 500);
    }
    if (existing.status === "running" || existing.status === "pending") {
      const reclaimed = await reclaimExpiredSuggestionRun(db, existing);
      if (reclaimed) {
        const authoritative = await loadAuthoritativeSuggestionRun(db, existing.id);
        if (!authoritative) {
          return errorResponse(
            "recovery_state_unavailable",
            "Could not read the authoritative recovered suggestion state; retry the request.",
            503,
          );
        }
        existing = authoritative;
      }
    }
    if (!existing) {
      return errorResponse("recovery_state_unavailable", "Could not read the authoritative recovered suggestion state; retry the request.", 503);
    }
    if (existing.status === "pending") {
      // Reconnects and continuation POSTs do not consume another rate-limit
      // slot or request-log entry. The pending claim makes this race-safe.
      const recoveredBody = await recoverPersistedPlanningBody(db, existing);
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, recoveredBody, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
    }
    // Reconnect: return existing run status. Skip checkRateLimit + logRequest
    // so a stray reconnect does NOT consume a rate-limit slot or produce
    // a duplicate request-log entry.
    return corsResponse(
      JSON.stringify(suggestionRunResponse(existing)),
      { status: 200 },
    );
  }
  // PR 7: only NEW logical requests reach checkRateLimit. Reconnects were
  // handled by the resolve-existing path above; this is a fresh
  // outline-from-recipe request with a brand-new idempotency key.
  body = canonicalBody;
  identity = identityResolution.canonicalIdentity;
  const selectedModel = await new SupabaseGenerationModelStore(db).getEnabledModelById(body.modelID!);
  if (!selectedModel) {
    return errorResponse("model_unavailable", `Selected outline model is unavailable: ${body.modelID}`, 422);
  }
  const rateResult = await checkRateLimit(userClient, user.id);
  if (!rateResult.allowed) {
    return corsResponse(
      JSON.stringify({
        errorCode: "rate_limited",
        retryAfterSeconds: rateResult.retryAfterSeconds,
      }),
      {
        status: 429,
        headers: { "Retry-After": String(rateResult.retryAfterSeconds ?? 60) },
      },
    );
  }
  const insert = await db.from("outline_suggestion_runs").insert({
    user_id: user.id,
    project_id: body.recipe.project.id,
    // PR 4: persist canonical lineage on the run so future resume / repair /
    // ownership queries can reconcile local project UUID drift against the
    // canonical lineage. Legacy callers may send undefined; the column
    // allows null and the server-side ownership check has already passed
    // (or was skipped because outline_id was also absent).
    project_lineage_id: body.project_lineage_id ?? null,
    idempotency_key: identity.key,
    request_fingerprint: identity.fingerprint,
    request_json: body,
    status: "pending",
  }).select("id, status, created_at, updated_at, suggestions, warnings, error_code, error, credit_cost_charged, remaining_credits, request_json").maybeSingle();

  // PR 7: track whether this is a fresh insert (eligible for logRequest)
  // or a 23505 race-fallback (reconnect, NOT eligible). Upfront resolve
  // already short-circuited reconnects; 23505 here means two clients raced
  // past the upfront check at the same microsecond.
  const isFreshInsert = !insert.error && !!insert.data;
  let run: any = insert.data;
  if (insert.error) {
    if (insert.error.code !== "23505") {
      return errorResponse("db_error", insert.error.message ?? "Could not create suggestion run", 500);
    }
    const existing = await db.from("outline_suggestion_runs")
      .select("id, status, created_at, updated_at, suggestions, warnings, error_code, error, diagnostics, planning_state, story_material, credit_cost_charged, remaining_credits, request_json, lease_expires_at, attempt_count, request_fingerprint")
      .eq("user_id", user.id).eq("idempotency_key", identity.key).single();
    if (existing.error || !existing.data) return errorResponse("db_error", existing.error?.message ?? "Could not resolve suggestion run", 500);
    run = existing.data;
    const raceIdentity = await resolvePlanningRequestIdentity(incomingBody, run);
    if (run.request_fingerprint && !raceIdentity.acceptedFingerprints.has(run.request_fingerprint)) {
      return errorResponse("idempotency_conflict", "The idempotency key is already bound to a different suggestion request", 409);
    }
    const stale = run.status === "running" && run.lease_expires_at && new Date(run.lease_expires_at).getTime() < Date.now();
    const resumableExpansionFailure = isRetryableExpansionFailure(run);
    const resumableSemanticRepairFailure = isRetryableSemanticRepairFailure(run);
    const resumableSemanticVerificationFailure = isRetryableSemanticVerificationFailure(run);
    if (stale) {
      if (await reclaimExpiredSuggestionRun(db, run)) {
        const authoritative = await loadAuthoritativeSuggestionRun(db, run.id);
        if (!authoritative) {
          return errorResponse(
            "recovery_state_unavailable",
            "Could not read the authoritative recovered suggestion state; retry the request.",
            503,
          );
        }
        run = authoritative;
      }
    } else if (resumableExpansionFailure || resumableSemanticRepairFailure || resumableSemanticVerificationFailure) {
      const recoveredDiagnostics = resumableSemanticRepairFailure || resumableSemanticVerificationFailure
        ? { ...(run.diagnostics ?? {}), semanticRecoveryAttempts: Number(run.diagnostics?.semanticRecoveryAttempts ?? 0) + 1, stage: "semantic_repair_recovery_pending" }
        : run.diagnostics;
      const reclaimed = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        ...(recoveredDiagnostics ? { diagnostics: recoveredDiagnostics } : {}),
        attempt_count: (run.attempt_count ?? 0) + 1,
      }).eq("id", run.id).eq("status", "failed");
      if (!reclaimed.error) run.status = "pending";
    }
  }
  if (!run) {
    return errorResponse("db_error", "Could not create or resolve suggestion run", 500);
  }
  // PR 7: log the request exactly once per NEW logical suggestion request.
  // Fresh inserts (the first POST with a given idempotency_key) get one
  // "queued" entry; reconnects (upfront resolve hit) and 23505
  // race-fallbacks do NOT log so the rate-limit counter does not double
  // count duplicates. logRequest failure is non-fatal — the worker still
  // runs the job; checkRateLimit counts entries so a transient log
  // failure could allow one extra request through the limit window.
  if (isFreshInsert) {
    try {
      await logRequest(db, user.id, "queued", undefined, selectedModel);
    } catch (logError) {
      console.error("[outline-from-recipe] logRequest failed", logError);
    }
  }
  // A pending duplicate may be the only way to restart a worker lost during
  // suspension. The pending claim inside runSuggestionJob makes this race-safe.
  if (run.status === "pending") {
    // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
    const recoveredBody = await recoverPersistedPlanningBody(db, run);
    // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
    EdgeRuntime.waitUntil(runSuggestionJob(run.id, recoveredBody, user.id, openaiKey, run.attempt_count ?? 0, authHeader));
  }
  return corsResponse(
    JSON.stringify({
      run_id: run.id,
      status: run.status,
      suggestions: run.suggestions,
      warnings: run.warnings,
      errorCode: run.error_code,
      error: run.error,
      creditCostCharged: run.credit_cost_charged,
      remainingCredits: run.remaining_credits,
      created_at: run.created_at,
      updated_at: run.updated_at,
    }),
    { status: 202 },
  );
});
