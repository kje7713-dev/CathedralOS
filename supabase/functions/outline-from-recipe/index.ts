import { createClient } from "jsr:@supabase/supabase-js@2";
import { BillableLLMError, runBillableLLM } from "../_shared/billable-llm.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { SupabaseGenerationModelStore } from "../generate-story/_generation_models.ts";
import {
  type LLMMessage,
  OpenAIProvider,
} from "../generate-story/_provider.ts";
import {
  buildCompactPlanningView,
  compactExistingSections,
  compactText,
  compactMaterial,
  compactMaterialForOutline,
  compactObligations,
  compactRecipe,
  stableJSONStringify,
  promptMetrics,
} from "./_prompt_context.ts";
import {
  type RecipeObligation,
  deriveRecipeObligations,
  obligationCoverage,
  renderRecipeObligations,
} from "./_recipe_obligations.ts";

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
//   OPENAI_MODEL_DEFAULT      — model used (default: gpt-5.6-luna, must support structured output)
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
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5.6-luna";

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
export interface ArcRoleContract {
  allowedFunctions: DramaticFunction[];
  requiredFunctions: DramaticFunction[];
  forbidsNewPrimaryConflict: boolean;
  allowsMajorEscalation: boolean;
  closureExpectation: "none" | "partial" | "strong";
  phaseDirection: ArcPhaseDirection;
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
  ...options,
});

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

export function arcRoleContract(beat: { role?: string; label?: string }, templateName = ""): ArcRoleContract {
  const template = BUILTIN_ROLE_CONTRACTS[normalizedTemplateName(templateName)];
  const role = beat.role ?? "";
  return template?.[role] ?? CONTRACTS[fallbackRoleFamily(role)] ?? CONTRACTS.escalation;
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
    terminalBeat: { type: "string", minLength: 1, maxLength: 500 },
    entryState: { type: "string", minLength: 1, maxLength: 1200 },
    dramaticEvent: { type: "string", minLength: 1, maxLength: 2000 },
    resultingChange: { type: "string", minLength: 1, maxLength: 1200 },
    terminalState: { type: "string", minLength: 1, maxLength: 1200 },
    dramaticFunction: { type: "string", enum: DRAMATIC_FUNCTIONS },
  },
  required: ["title", "summary", "container", "pov", "terminalBeat", "entryState", "dramaticEvent", "resultingChange", "terminalState", "dramaticFunction"],
  additionalProperties: false,
} as const;

export function buildSuggestionResponseSchema(
  beats: Array<{ id: string; role?: string; label?: string }>,
  allocation: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  templateName = "",
) {
  const properties: Record<string, unknown> = {};
  const required: string[] = [];
  const sectionSchema = obligations.length > 0
    ? {
      ...SECTION_SCHEMA,
      properties: {
        ...SECTION_SCHEMA.properties,
        recipeRequirementIDs: {
          type: "array",
          minItems: 1,
          maxItems: 50,
          items: { type: "string", enum: obligations.map((obligation) => obligation.id) },
        },
      },
      required: [...SECTION_SCHEMA.required, "recipeRequirementIDs"],
    }
    : SECTION_SCHEMA;
  for (const beat of beats) {
    const minimum = allocation.get(beat.id)?.minSections ?? 0;
    const contract = arcRoleContract(beat, templateName);
    const beatSectionSchema = {
      ...sectionSchema,
      properties: {
        ...sectionSchema.properties,
        dramaticFunction: { type: "string", enum: contract.allowedFunctions },
      },
    };
    properties[beat.id] = {
      type: "array",
      minItems: minimum,
      items: beatSectionSchema,
    };
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
    if (!Array.isArray(rawSections)) throw new Error(`response missing beat ${beat.id}`);
    for (const raw of rawSections) {
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
const NOVEL_TARGET_WORDS: [number, number] = [70000, 90000];
const TOKENS_PER_WORD = 1.3;
const NOVEL_MIN_PROJECTED_TOKENS = NOVEL_TARGET_WORDS[0] * TOKENS_PER_WORD;
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
  project: { id: string; summary?: string };
  setting: { included: boolean };
  selectedCharacters: unknown[];
  selectedStorySpark: unknown | null;
  selectedAftertaste: unknown | null;
  selectedRelationships: unknown[];
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

interface ArcTemplateBlob {
  id: string;
  name: string;
  description?: string;
  beats: Array<
    { id: string; role: string; label: string; description?: string }
  >;
}

interface OutlineFromRecipeRequest {
  recipe: CanonicalRecipeEnvelope;
  arcTemplate: ArcTemplateBlob;
  hint?: string;
  existingSections?: ExistingSectionBlob[]; // iOS-side outline state at request time
  storyMaterialEnrichment?: StoryMaterialEnrichment; // candidate reuse from a prior planning pass
  requestedFormat?: StoryMaterialFormat;
  outline_id?: string;
  // PR 4: canonical planning identity. Server-validated pre-billable so a
  // stale Outline reference (delete + restore, sync race) cannot survive
  // into a paid LLM call.
  project_lineage_id?: string;
  idempotencyKey?: string;
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
    ...Object.fromEntries(STORY_MATERIAL_CATEGORIES.map((category) => [category, { type: "array", maxItems: 50, items: STORY_MATERIAL_ITEM_SCHEMA }])),
  },
  required: ["schema", "version", "format", "rationale", ...STORY_MATERIAL_CATEGORIES],
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

export function validateStoryMaterialEnrichment(value: unknown, options: { allowMissingProvenance?: boolean; recipe?: CanonicalRecipeEnvelope } = {}): StoryMaterialEnrichment {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("story material enrichment must be an object");
  const candidate = value as Record<string, unknown>;
  if (candidate.schema !== "cathedralos.story_material_enrichment" || candidate.version !== 2) throw new Error("story material enrichment has an unsupported schema or version");
  if (!["novel", "shortStory", "other"].includes(String(candidate.format))) throw new Error("story material enrichment has an invalid format");
  if (typeof candidate.rationale !== "string" || candidate.rationale.trim() === "") throw new Error("story material enrichment requires a rationale");
  const provenanceFields = ["sourceRecipeHash", "sourceRecipeVersion", "sourcePromptPackID", "sourcePromptPackName"];
  if (!options.allowMissingProvenance && provenanceFields.some((field) => typeof candidate[field] !== "string" && field !== "sourceRecipeVersion" || field === "sourceRecipeVersion" && !Number.isInteger(candidate[field]))) throw new Error("story material enrichment is missing server-owned recipe provenance");
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
    system: `You are the story-material enrichment planner for CathedralOS. Create a concrete package before outline planning, not prose or a final outline. Sparse input does NOT mean a shorter or simpler story: Cathedral has a larger invention burden and must invent the opposition, supporting cast, institutions, locations, objectives, failures, discoveries, relationships, consequences, reversals, and escalation needed for ${format}-scale development while respecting authored facts. Rich input means preserve, connect, and deepen supplied material before inventing replacements; do not make detailed recipes less ambitious. Emit source=planner only for every returned item and always use null sourceReference. Do not reproduce or relabel authored recipe material; the server deterministically extracts canonical recipe-backed material. Do not fill categories mechanically, but ensure the package is concrete enough that the outline planner does not invent the entire plot section by section. Return only JSON matching the enrichment schema.${repairInstruction}`,
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

interface SuggestionLLMResult {
  content: string;
  creditCostCharged: number;
  remainingCredits: number;
}

type SuggestionLLMCall = (
  system: string,
  user: string,
  maxOutputTokens: number,
  responseFormat: unknown,
  action: string,
  validateResponse?: (content: string) => unknown | Promise<unknown>,
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
  deficitTokens: number;
  meetsMinimum: boolean;
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
    minimumWords: NOVEL_TARGET_WORDS[0],
    deficitTokens,
    meetsMinimum: deficitTokens === 0,
  };
}

export function needsNovelExpansion(
  suggestions: PlannedSectionLike[],
  existingSections: PlannedSectionLike[] = [],
): boolean {
  return !evaluateNovelScale(suggestions, existingSections).meetsMinimum;
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
          terminalBeat: { type: "string", minLength: 1, maxLength: 500 },
          entryState: { type: "string", minLength: 1, maxLength: 1200 },
          dramaticEvent: { type: "string", minLength: 1, maxLength: 2000 },
          resultingChange: { type: "string", minLength: 1, maxLength: 1200 },
          terminalState: { type: "string", minLength: 1, maxLength: 1200 },
          dramaticFunction: { type: "string", enum: DRAMATIC_FUNCTIONS },
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
export function buildExpansionResponseSchema(contract?: ArcRoleContract) {
  const dramaticFunction = contract?.allowedFunctions ?? [...DRAMATIC_FUNCTIONS];
  return {
    ...EXPANSION_SCHEMA,
    properties: {
      suggestions: {
        ...EXPANSION_SCHEMA.properties.suggestions,
        items: {
          ...EXPANSION_SCHEMA.properties.suggestions.items,
          properties: {
            ...EXPANSION_SCHEMA.properties.suggestions.items.properties,
            dramaticFunction: { type: "string", enum: dramaticFunction },
          },
        },
      },
    },
  };
}

export type ExpansionAddition = Suggestion & { insertAfterTitle: string | null };

export class ExpansionValidationError extends Error {}

export type NovelPlanningFailureCode = "failed_under_target" | "failed_expansion";

export class RecipeObligationValidationError extends Error {
  readonly code = "missing_recipe_obligations";
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
}

export interface ProgressiveExpansionResult {
  suggestions: Suggestion[];
  warnings: string[];
  diagnostics: ExpansionRoundDiagnostic[];
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
  expand: (current: Suggestion[], context: ExpansionPromptContext, beat?: ExpansionBeatContext) => Promise<ExpansionAddition[]>,
  onRound?: (diagnostic: ExpansionRoundDiagnostic, all: ExpansionRoundDiagnostic[], current: Suggestion[]) => Promise<void> | void,
  options: ProgressiveExpansionOptions = {},
): Promise<ProgressiveExpansionResult> {
  let suggestions = [...initial];
  const existingSections = options.existingSections ?? [];
  const diagnostics: ExpansionRoundDiagnostic[] = [...(options.priorDiagnostics ?? [])];
  const warnings: string[] = [];
  const startRound = Math.max(1, options.startRound ?? 1);
  for (let round = startRound; round <= MAX_EXPANSION_ROUNDS && needsNovelExpansion(suggestions, existingSections); round++) {
    const projectedTokensBefore = evaluateNovelScale(suggestions, existingSections).projectedTokens;
    const before: ExpansionPromptContext = {
      round,
      projectedTokens: projectedTokensBefore,
      projectedWords: projectedTokensBefore / TOKENS_PER_WORD,
      desiredWords: NOVEL_TARGET_WORDS,
      remainingDeficitTokens: evaluateNovelScale(suggestions, existingSections).deficitTokens,
    };
    try {
      const targetBeats = options.beats?.length
        ? options.beats
        : [undefined];
      let roundSuggestions = suggestions;
      let additionsReturned = 0;
      let hitCap = false;
      const firstBeatIndex = round === startRound ? Math.max(0, options.startBeatIndex ?? 0) : 0;
      for (let beatIndex = firstBeatIndex; beatIndex < targetBeats.length; beatIndex++) {
        const beat = targetBeats[beatIndex];
        if (!needsNovelExpansion(roundSuggestions, existingSections)) break;
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
        const additions = await expand(roundSuggestions, {
          ...before,
          projectedTokens: evaluateNovelScale(roundSuggestions, existingSections).projectedTokens,
          projectedWords: evaluateNovelScale(roundSuggestions, existingSections).projectedWords,
          remainingDeficitTokens: evaluateNovelScale(roundSuggestions, existingSections).deficitTokens,
        }, beatContext);
        if (beatContext && additions.some((addition) => addition.storyArcBeatID !== beatContext.beatID)) {
          throw new ExpansionValidationError(`beat-local expansion returned a section for another beat; expected ${beatContext.beatID}`);
        }
        const merged = mergeExpansionAdditions(roundSuggestions, additions);
        if (merged.length > MAX_PLANNED_SECTIONS) {
          hitCap = true;
          break;
        }
        roundSuggestions = merged;
        additionsReturned += additions.length;
        await options.onBeat?.(round, beatIndex + 1, roundSuggestions, diagnostics);
      }
      const overCap = hitCap || roundSuggestions.length > MAX_PLANNED_SECTIONS;
      const accepted = overCap ? suggestions : roundSuggestions;
      const projectedTokensAfter = evaluateNovelScale(accepted, existingSections).projectedTokens;
      const diagnostic: ExpansionRoundDiagnostic = {
        round, sectionCountBefore: suggestions.length, projectedTokensBefore,
        projectedWordsBefore: projectedTokensBefore / TOKENS_PER_WORD,
        additionsReturned: overCap ? 0 : additionsReturned, sectionCountAfter: accepted.length,
        projectedTokensAfter, projectedWordsAfter: projectedTokensAfter / TOKENS_PER_WORD,
        remainingEstimatedDeficitTokens: evaluateNovelScale(accepted, existingSections).deficitTokens,
        status: overCap || accepted.length >= MAX_PLANNED_SECTIONS ? "capped" : "completed",
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
      const diagnostic: ExpansionRoundDiagnostic = {
        round, sectionCountBefore: suggestions.length, projectedTokensBefore,
        projectedWordsBefore: projectedTokensBefore / TOKENS_PER_WORD, additionsReturned: 0,
        sectionCountAfter: suggestions.length, projectedTokensAfter: projectedTokensBefore,
        projectedWordsAfter: projectedTokensBefore / TOKENS_PER_WORD,
        remainingEstimatedDeficitTokens: evaluateNovelScale(suggestions, existingSections).deficitTokens,
        status: "invalid", error: error.message.slice(0, 500),
      };
      diagnostics.push(diagnostic);
      await onRound?.(diagnostic, diagnostics, suggestions);
      throw new NovelScalePlanningError(
        "failed_expansion",
        `Novel expansion failed validation in round ${round}; the outline remains below the ${NOVEL_TARGET_WORDS[0].toLocaleString()}-word minimum.`,
      );
    }
  }
  const finalScale = evaluateNovelScale(suggestions, existingSections);
  if (!finalScale.meetsMinimum) {
    throw new NovelScalePlanningError(
      "failed_under_target",
      `Novel outline remains below the ${NOVEL_TARGET_WORDS[0].toLocaleString()}-word minimum after ${diagnostics.length} expansion round${diagnostics.length === 1 ? "" : "s"}.`,
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
  const unusedStoryMaterial = findUnusedStoryMaterial(
    current,
    req.storyMaterialEnrichment,
  );
  const beatContext = context?.beat;
  const targetBeat = beatContext ? req.arcTemplate.beats.find((beat) => beat.id === beatContext.beatID) : undefined;
  const targetContract = targetBeat ? arcRoleContract(targetBeat, req.arcTemplate.name) : undefined;
  const unsatisfiedRequiredFunctions = targetContract?.requiredFunctions.filter((required) => !beatContext?.currentSections.some((section) => section.dramaticFunction === required)) ?? [];
  const semanticContract = targetContract
    ? `Authoritative semantic contract for this beat: allowedFunctions=${targetContract.allowedFunctions.join(", ")}; requiredFunctionsStillUnsatisfied=${unsatisfiedRequiredFunctions.join(", ") || "none"}; forbidsNewPrimaryConflict=${targetContract.forbidsNewPrimaryConflict}; allowsMajorEscalation=${targetContract.allowsMajorEscalation}; closureExpectation=${targetContract.closureExpectation}; phaseDirection=${targetContract.phaseDirection}. The server is the source of truth.`
    : "No beat-local semantic contract applies to this global repair call; preserve each existing section's contract.";
  const beatDirective = beatContext
    ? `This is beat-local expansion for Story Arc beat ${beatContext.beatID}${beatContext.beatLabel ? ` (${beatContext.beatLabel})` : ""}. Develop only this beat; every returned section must use storyArcBeatID ${beatContext.beatID}. The beat currently contains approximately ${Math.round(beatContext.projectedWords).toLocaleString()} projected words. Its description is: ${beatContext.beatDescription ?? "(not supplied)"}. ${semanticContract}`
    : "Expand across the supplied outline while preserving each section's Story Arc beat.";
  return {
    system: `The current outline is compressed for a ${requestedStoryMaterialFormat(req)}. This is bounded progressive expansion round ${round} of ${MAX_EXPANSION_ROUNDS}. The current projection is approximately ${Math.round(projectedWords).toLocaleString()} words (${Math.round(projectedTokens).toLocaleString()} tokens), versus the preferred broad ${requestedStoryMaterialFormat(req)} range of ${NOVEL_TARGET_WORDS[0].toLocaleString()}-${NOVEL_TARGET_WORDS[1].toLocaleString()} words. The remaining estimated deficit is approximately ${Math.round(remainingDeficitTokens).toLocaleString()} tokens. ${beatDirective} Return ONLY ADDITIONAL section suggestions; never return, rewrite, reorder, or omit existing sections. Add distinct events, consequences, decisions, reversals, tests, discoveries, and aftermath where the current outline is compressed. Develop material in this order: unused or underdeveloped enrichment items; deeper causal chains; meaningful complications; relationships; opposition; consequences and aftermath; geographic/social/strategic scope; reversals and discoveries; additional phases inside complex set pieces; and only then genuinely separate new dramatic developments. Do not add a new section for the same dramatic state. Prefer the currently unused enrichment items listed in the request; connect them to existing relationships, opposition, consequences, and discoveries before inventing generic replacements. Each addition must use the same container semantics: scene = one continuous dramatic event (800-1,800 expected tokens); developedScene = escalation with multiple tactics (1,500-3,000); setPiece = major action/confrontation/reveal (2,000-5,000); sceneSequence = several connected scenes pursuing one objective (3,000-7,000). These are literary planning ranges only, not provider ceilings. Do not inflate containers to satisfy the size check by converting smaller containers into larger containers. Every addition must explicitly include entryState, dramaticEvent, resultingChange, terminalState, and a plannedWordRange as a soft literary target subordinate to the container and natural stopping point, and must reference a valid beat and include insertAfterTitle for an existing section, or null to append within its beat. Assign only applicable recipeRequirementIDs from the supplied obligation list; additions may contain an empty list. Return JSON matching the expansion schema.

## Recipe obligations
The JSON request contains the authoritative obligations exactly once.`,
    user: JSON.stringify({
      global: {
        project: req.recipe?.project ? { id: req.recipe.project.id ?? null, name: compactText((req.recipe.project as any).name, 200), summary: compactText(req.recipe.project.summary, 1200) } : null,
        recipe: { selectedStorySpark: compactRecipe(req.recipe).selectedStorySpark, selectedAftertaste: compactRecipe(req.recipe).selectedAftertaste },
        arc: { name: req.arcTemplate.name, beats: req.arcTemplate.beats.map((b: any) => ({ id: b.id, label: compactText(b.label, 180), description: compactText(b.description, 500) })) },
      },
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
  for (const raw of parsed.suggestions) {
    const { insertAfterTitle } = raw ?? {};
    const validated = validateSuggestions({ suggestions: [raw] }, beatIds, undefined, obligations, template).suggestions[0];
    if (!validated) throw new Error("expansion returned an invalid addition");
    if (template) {
      const beat = template.beats.find((candidate) => candidate.id === validated.storyArcBeatID);
      const roleContract = beat ? arcRoleContract(beat, template.name) : undefined;
      if (roleContract?.forbidsNewPrimaryConflict && PRIMARY_CONFLICT_SIGNALS.test(semanticText(validated))) {
        throw new Error(`expansion introduced a new primary conflict in beat ${validated.storyArcBeatID}`);
      }
    }
    if (insertAfterTitle !== null && typeof insertAfterTitle !== "string") throw new Error("expansion placement must be a title or null");
    if (insertAfterTitle !== null && !originalTitles.has(insertAfterTitle)) throw new Error("expansion placement must reference an original section");
    if (insertAfterTitle !== null) {
      const anchor = original.find((s) => s.title === insertAfterTitle);
      if (!anchor || anchor.storyArcBeatID !== validated.storyArcBeatID) throw new Error("expansion placement crosses arc beats");
    }
    const fingerprint = `${validated.title}|${validated.summary}|${validated.storyArcBeatID}`;
    if (fingerprints.has(fingerprint)) throw new Error("expansion introduced a duplicate section contract");
    fingerprints.add(fingerprint);
    additions.push({ ...validated, insertAfterTitle });
  }
  return additions;
}

export function parseExpansionResponse(
  content: string,
  beatIds: Set<string>,
  original: Suggestion[],
  obligations: RecipeObligation[] = [],
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
): ExpansionAddition[] {
  try {
    return validateExpansionAdditions(JSON.parse(content), beatIds, original, obligations, template);
  } catch (error) {
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


export function buildPrompt(
  req: OutlineFromRecipeRequest,
  allocation: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  storyMaterial?: StoryMaterialEnrichment,
): { system: string; user: string } {
  const allocationLines = Array.from(allocation.entries())
    .map(([beatId, info]) => {
      const beat = req.arcTemplate.beats.find((b) => b.id === beatId);
      return `- ${
        beat?.label ?? beatId
      }: minimum ${info.minSections} section${info.minSections === 1 ? "" : "s"} (${info.rationale})`;
    })
    .join("\n");
  const contractLines = req.arcTemplate.beats.map((beat) => {
    const contract = arcRoleContract(beat, req.arcTemplate.name);
    return `- ${beat.label} (${beat.role}): allowed functions=${contract.allowedFunctions.join(", ")}; phase=${contract.phaseDirection}; ${contract.forbidsNewPrimaryConflict ? "do not introduce a new primary conflict" : "major escalation is allowed"}`;
  }).join("\n");

  const system =
    `You are an expert ${requestedStoryMaterialFormat(req)} outliner. Use the complete canonical recipe/project payload below, including its premise, selected characters and their populated fields, selected relationships, themes, motifs, story spark, aftertaste, recipe instructions, and included setting. Treat supplied facts as authoritative; do not infer personality traits from a character name alone. Given the story arc, produce one complete section-by-section outline in this single pass.

Every section must commit to one canonical event. Never use unresolved alternatives such as "X or Y", "someone", "a friend", "somewhere", or multiple possible versions of the event. Choose the specific person, place, object, and action.

Each section must produce a materially new resulting state. Do not create another section merely to restate or reconfirm a relationship change, realization, warning, or trust shift already achieved. Revisit an arc only when a new event escalates, reverses, costs, or transforms it.

## Container semantics for planning

Choose a container for the scale of one dramatic unit, not to fake novel length:
- scene: one continuous dramatic event, expected 800-1,800 tokens
- developedScene: a fuller scene with escalation and multiple tactics, 1,500-3,000
- setPiece: a major action, confrontation, ceremony, or reveal, 2,000-5,000
- sceneSequence: several connected scenes pursuing one objective, 3,000-7,000
- chapter: a publishing or pacing division, 3,000-8,000+
The expected ranges are literary targets; runtime/provider headroom is not a desired length.

## Recipe obligations
The JSON planning context contains the authoritative obligations exactly once.

## Compact planning context
Use the deterministic, provenance-preserving planning view below. Items marked source=recipe are authored facts; source=planner are development candidates and must not be treated as authored facts. The server retains the full canonical recipe for validation. When the planning context supplies a concrete location, clue, institution, object, threat mechanism, or consequence, use it rather than generic phrases such as "damaged site", "weak point", "psychic pressure", or "thin place".

## Use the minimum-only allocation

For each beat, generate at least the stated minimum number of distinct sections. The minimum is a floor for dramatic coverage, not a target or maximum: generate additional sections whenever the material supports distinct events, consequences, decisions, or revelations. A beat with minimum 0 is already covered for this pass and must produce no new suggestion. Never pad with paraphrases.

## Novel-ready section titles

Write each section title as a concise, specific, evocative working title suitable for a ${requestedStoryMaterialFormat(req)} outline or ${requestedStoryMaterialFormat(req)}-ready table of contents. The title should name the concrete dramatic event, decision, reversal, discovery, confrontation, or consequence that this section actually dramatizes. Do not restate or lightly rephrase the premise, Story Arc beat label, terminal beat, or section summary. Avoid generic placeholders such as "Setup," "Conflict," "Events," or "Scene"; each title must distinguish its section from the others in the same beat.

## Generation-ready section contract
For every section, explicitly state entryState, dramaticEvent, resultingChange, and terminalState. Also return exactly one server-validated dramaticFunction from the allowed functions for that beat; the function must agree with the event and resulting change, not merely repeat the beat label. The dramaticEvent must be a specific objective, confrontation, discovery, decision, reversal, or consequence; resultingChange must alter the protagonist, opposition, relationship, information, resources, or stakes. The terminalState is the concrete condition handed to the next section. Do not copy an arc-beat label into these fields. Do not provide plannedWordRange; the server derives it deterministically from container; it never overrides the Section Contract, container, or natural stopping point.

Canonical dramatic event responsibility: each section must commit to one canonical dramatic realization of what happens. The outline planner owns plot decisions; the later prose generator owns execution. When needed to make the section generation-ready, choose the concrete location, participating characters, triggering action, confrontation, discovery, failure or reversal, and immediate consequence. Do not leave those decisions as interchangeable possibilities for the prose generator. Avoid unresolved planner alternatives such as “at the school or arcade,” “a road, bridge, school, or home,” “a chase or near-miss,” “an object or sound,” “someone is attacked,” “something happens,” “may/could/might reveal,” or “such as X or Y.” Do not mechanically ban words such as “or,” “may,” or “could”: they remain valid when uncertainty or choice is itself part of the canonical dramatic event, such as “Brody must decide whether to confess or keep lying.” The prohibited case is the planner leaving multiple interchangeable plot realizations undecided. As a useful standard, two prose generators following the same section contract should dramatize substantially the same plot event, even though dialogue, prose, blocking, sensory detail, pacing, and moment-to-moment execution may differ. Make entryState, resultingChange, and terminalState similarly concrete enough to constrain continuity, without turning them into prose or over-specifying incidental details. The outline should define the event and its continuity consequences, not pre-write the novel.

${allocationLines}

## Semantic Story Arc contracts
${contractLines}

The Resurrection must not replay the Ordeal at greater scale. The Ordeal must create a cost, revelation, failure, or changed condition that materially alters how the final confrontation works.

Respond with structured JSON matching the schema. This is the only provider call for Suggest Sections; do not return a plan for another model or defer plot decisions.`;
  const planningView = buildCompactPlanningView(
    { ...req, storyMaterialEnrichment: storyMaterial },
    obligations,
    storyMaterial,
  );
  planningView.materialIndex = compactMaterialForOutline(storyMaterial);
  const user = JSON.stringify({
    planningContext: planningView,
    allocation: Array.from(allocation.entries()),
    hint: req.hint ?? null,
  }, null, 2);

  return { system, user };
}

// Stage 1: planner. Decides how many sections each arc beat deserves
// before the generation call runs. The response is strict and validated so a
// malformed planner response can never silently become an unbounded plan.
const ALLOCATION_SCHEMA = {
  type: "object",
  properties: {
    allocations: {
      type: "array",
      minItems: 0,
      maxItems: MAX_PLANNED_SECTIONS,
      items: {
        type: "object",
        properties: {
          beatIndex: { type: "integer", minimum: 0 },
          minSections: { type: "integer", minimum: 0, maximum: 10 },
          rationale: { type: "string", minLength: 1, maxLength: 500 },
        },
        required: ["beatIndex", "minSections", "rationale"],
        additionalProperties: false,
      },
    },
  },
  required: ["allocations"],
  additionalProperties: false,
} as const;

type Allocation = {
  minSections: number;
  rationale: string;
};

export class AllocationRetryRequired extends Error {
  constructor(public readonly reason: string) {
    super(`allocation planner requires one bounded retry: ${reason}`);
    this.name = "AllocationRetryRequired";
  }
}

export function suggestionContractFingerprint(suggestion: Suggestion): string {
  return `${suggestion.title}|${suggestion.summary}|${suggestion.storyArcBeatID}`;
}

export function mergeSuggestionsByBeatOrder(
  beatOrder: string[],
  firstPass: Suggestion[],
  repaired: Suggestion[],
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
): Map<string, Allocation> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
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
      !["beatIndex", "minSections", "rationale"].includes(key)
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
    if (!Number.isInteger(minSections) || Number(minSections) < 0 || Number(minSections) > 10) {
      throw new Error(`allocation has invalid minSections for beat ${beatID}`);
    }
    if (typeof rationale !== "string" || rationale.trim() === "") {
      throw new Error(`allocation has missing rationale for beat ${beatID}`);
    }
    seen.add(beatID);
    out.set(beatID, {
      minSections: Number(minSections),
      rationale,
    });
  }
  if (out.size !== validBeatIDs.size) {
    const missing = beats.filter((beat) => !seen.has(beat.id)).map((beat) =>
      beat.id
    );
    throw new Error(`allocation is missing beat(s): ${missing.join(", ")}`);
  }
  return new Map(beats.map((beat) => [beat.id, out.get(beat.id)!]));
}

export function buildAllocationPrompt(
  req: OutlineFromRecipeRequest,
  obligations: RecipeObligation[] = [],
): { system: string; user: string } {
  const system =
    `You are an expert outliner. Given a complete canonical recipe/project payload, a verified story-material enrichment package, and a story arc template (ordered beats), decide how many outline sections each beat deserves in this particular ${requestedStoryMaterialFormat(req)}.

This request is for a ${requestedStoryMaterialFormat(req)}. Plan enough distinct dramatic material appropriate to that format; for a novel, plan enough for a plausible 70,000-90,000 word work when sections generate near their expected literary ranges. This is a broad scale target, not an exact word count. Do not satisfy it with giant containers: major arc movements should decompose into multiple events, consequences, decisions, reversals, tests, discoveries, and aftermath. Quick transitions may take 1-2 sections; major movements commonly need 5-10 sections. Use the supplied premise, characters, and arc to decide where density belongs.

## Recipe obligations
The JSON request contains the authoritative obligations exactly once.

For every Story Arc beat, determine the minimum number of NEW dramatic sections still required to adequately realize that movement in a novel after considering the supplied existingSections. Output exactly one allocation for every beat using beatIndex, the zero-based ordinal from the ordered beat list below. Never output UUIDs or beat IDs. The server maps beatIndex to the canonical beat identity. Include every beat exactly once. minSections represents the number of additional sections still required beyond existingSections — it is a floor, not a target or maximum. The later outline generator may create additional sections whenever the material supports them. A beat sufficiently covered by existing sections may use minSections 0 (existing coverage is already accounted for; do not include it in minSections). Do not output any other root key.

Output JSON only. No commentary, no prose.`;

  const planningView = buildCompactPlanningView(
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
    allocation: "Return one minimum-only floor per canonical beat; additional sections remain legal.",
    hint: req.hint ?? null,
  }, null, 2);
  return { system, user };
}

export async function planSectionAllocation(
  req: OutlineFromRecipeRequest,
  apiKey: string,
  billableCall?: SuggestionLLMCall,
  obligations: RecipeObligation[] = [],
  options: { retryOnly?: boolean; deferRetry?: boolean } = {},
): Promise<Map<string, Allocation>> {
  const { system, user } = buildAllocationPrompt(req, obligations);
  const responseFormat = {
    type: "json_schema",
    json_schema: {
      name: "outline_section_allocations",
      strict: true,
      schema: ALLOCATION_SCHEMA,
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
        2048,
        responseFormat,
        correction ? "outline-plan-retry" : "outline-plan",
        (content) => parseAndValidateAllocation(content, req.arcTemplate.beats),
      )
      : {
        content: await callOpenAI(callSystem, user, apiKey, {
          maxTokens: 2048,
          useJsonSchema: true,
          jsonSchemaName: "outline_section_allocations",
          jsonSchema: ALLOCATION_SCHEMA,
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
      return parseAndValidateAllocation(
        await call(correction),
        req.arcTemplate.beats,
      );
    } catch (error) {
      if (error instanceof SuggestionWorkerYield) throw error;
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
): Promise<void> {
  const { error } = await supabase.from("generation_request_logs").insert({
    request_id: crypto.randomUUID(),
    user_id: userId,
    action: "outline-from-recipe",
    generation_length_mode: "outline",
    output_budget: 0,
    status,
    error_code: errorCode ?? null,
    model_name: OPENAI_MODEL,
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
        temperature: 0.7,
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

export function validateSuggestions(
  parsed: any,
  beatIds: Set<string>,
  allocation?: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
  template?: Pick<ArcTemplateBlob, "name" | "beats">,
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
    valid.push({
      title: String(s.title).slice(0, 200),
      summary: String(s.summary).slice(0, 4000),
      container: s.container,
      pov: s.pov,
      terminalBeat: String(s.terminalBeat).slice(0, 1000),
      // Preserve legacy payload shape when older callers omit the additive
      // contract; new structured responses retain all four explicit fields.
      ...(typeof s.entryState === "string" ? { entryState: s.entryState.slice(0, 1200) } : {}),
      ...(typeof s.dramaticEvent === "string" ? { dramaticEvent: s.dramaticEvent.slice(0, 2000) } : {}),
      ...(typeof s.resultingChange === "string" ? { resultingChange: s.resultingChange.slice(0, 1200) } : {}),
      ...(typeof s.terminalState === "string" ? { terminalState: s.terminalState.slice(0, 1200) } : {}),
      ...(DRAMATIC_FUNCTIONS.includes(s.dramaticFunction) ? { dramaticFunction: s.dramaticFunction as DramaticFunction } : {}),
      plannedWordRange: plannedWordRangeForContainer(s.container),
      storyArcBeatID: s.storyArcBeatID,
      ...(validRequirementIDs.length > 0 ? { recipeRequirementIDs: validRequirementIDs } : {}),
    });
    used.add(s.storyArcBeatID);
  }
  if (allocation) {
    const counts = new Map<string, number>();
    for (const suggestion of valid) {
      counts.set(
        suggestion.storyArcBeatID,
        (counts.get(suggestion.storyArcBeatID) ?? 0) + 1,
      );
    }
    for (const [beatID, plan] of allocation) {
      const actual = counts.get(beatID) ?? 0;
      if (actual < plan.minSections) {
        throw new Error(
          `beat ${beatID} returned ${actual} section${actual === 1 ? "" : "s"}; minimum is ${plan.minSections}`,
        );
      }
    }
  } else {
    // Backward-compatible validation for callers that do not have a plan.
    for (const bid of beatIds) {
      if (!used.has(bid)) warnings.push(`no suggestion references beat ${bid}`);
    }
  }
  return { suggestions: valid, warnings };
}


export interface OutlineQualityDiagnostic {
  distinctnessIssues: string[];
  causalScaleIssues: string[];
  semanticArcIssues: string[];
  supportingEntities: string[];
  unusedStoryMaterialItems: number;
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

const PRIMARY_CONFLICT_SIGNALS = /\b(launch(?:es|ed)?|mount(?:s|ed)?|wage(?:s|d)?|invade(?:s|d)?|attack(?:s|ed)?|assault(?:s|ed)?|conquer(?:s|ed)?|take over|seize(?:s|d)?|overthrow(?:s|n)?|decisive assault|citywide takeover)\b/;
const CLOSURE_SIGNALS = /\b(settle(?:s|d)?|stabiliz(?:e|es|ed)|new normal|aftermath|mourning|rebuild(?:s|ing)?|govern(?:s|ed|ance)|peace|accept(?:s|ed)?|legacy|closing image)\b/;
// “Aftermath” describes what follows an ending; it does not itself answer
// the central dramatic question. Required resolution beats therefore need a
// concrete settling/answering action in the state-change fields, not merely a
// final-looking label or the word “aftermath”.
const RESOLUTION_ACTION_SIGNALS = /\b(?<!un)(?:resolve(?:s|d)?|answer(?:s|ed)?|settle(?:s|d)?|stabiliz(?:e|es|ed)|ends?|ended|defeat(?:s|ed)?|disarm(?:s|ed)?|dismantle(?:s|d)?|restore(?:s|d)?|rebuild(?:s|ing)?|govern(?:s|ed|ance)|make(?:s|d)? peace|new normal|accept(?:s|ed)?|legacy|closing image)\b/;

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
      } else if (required === "resolution" && !requiredSections.some((section) =>
        RESOLUTION_ACTION_SIGNALS.test(semanticText(section))
      )) {
        issues.push(`beat ${beat.label} (${beat.id}) declares resolution but does not materially resolve the central dramatic question or conflict`);
      }
    }
  }
  return issues;
}

/** Validate both the declared function and the sequence-level macro-structure. */
const REQUIRED_FUNCTION_REPAIR_SCHEMA = {
  type: "object",
  properties: {
    section: SECTION_SCHEMA,
  },
  required: ["section"],
  additionalProperties: false,
} as const;

/**
 * Repair a required Story Arc function by rewriting one existing section.
 * This is intentionally separate from macro beat reassignment: an aftermath
 * section is in the correct Final Image beat, but it still needs a concrete
 * resolution event and settled terminal state. The post-repair gate below
 * rejects a cosmetic function relabel or another aftermath-only rewrite.
 */
export async function repairRequiredStoryArcFunctions(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  billableCall: SuggestionLLMCall,
  obligations: RecipeObligation[] = [],
): Promise<{ suggestions: Suggestion[]; repaired: string[]; unresolved: string[] }> {
  let result = suggestions.map((section) => ({ ...section }));
  const repaired: string[] = [];
  const unresolved: string[] = [];

  for (const beat of template.beats) {
    const roleContract = arcRoleContract(beat, template.name);
    for (const required of roleContract.requiredFunctions) {
      const currentIssues = validateRequiredStoryArcFunctions(result, { ...template, beats: [beat] });
      const issue = currentIssues.find((item) => item.includes(`(${beat.id})`));
      if (!issue) continue;
      const beatSections = result.filter((section) => section.storyArcBeatID === beat.id);
      const target = beatSections.find((section) => section.dramaticFunction !== required) ?? beatSections[0];
      if (!target) {
        unresolved.push(beat.label);
        continue;
      }
      const system = `You are repairing one outline section for the ${template.name} Story Arc. Rewrite the supplied section in place; do not add a new section, change its beat, or invent a new primary conflict. The beat requires the dramatic function ${required}. For resolution, the resultingChange and terminalState must show the central dramatic question or conflict being answered and settled on the page. An aftermath, mood, memorial, or continuing residue alone is not a resolution. Return only JSON matching the required repair schema.`;
      const user = JSON.stringify({
        beat: { id: beat.id, role: beat.role, label: beat.label, contract: roleContract },
        requiredFunction: required,
        section: target,
        instruction: "Preserve any applicable recipeRequirementIDs, but replace aftermath-only closure with a concrete resolution action and settled terminal state.",
      }, null, 2);
      let repairedSection: Suggestion | undefined;
      try {
        const raw = await billableCall(
          system,
          user,
          4000,
          { type: "json_schema", json_schema: { name: "outline_required_function_repair", strict: true, schema: REQUIRED_FUNCTION_REPAIR_SCHEMA } },
          `outline-semantic-repair-${beat.id}-${required}`,
          (content) => {
            const parsed = JSON.parse(content);
            if (!parsed?.section || typeof parsed.section !== "object") throw new Error("semantic repair response missing section");
            const candidate = {
              ...parsed.section,
              storyArcBeatID: beat.id,
              recipeRequirementIDs: target.recipeRequirementIDs ?? [],
            };
            const validated = validateSuggestions({ suggestions: [candidate] }, new Set([beat.id]), undefined, obligations, { ...template, beats: [beat] });
            if (validated.suggestions.length !== 1) throw new Error("semantic repair response did not produce one valid section");
            return validated.suggestions[0];
          },
        );
        const parsed = JSON.parse(raw.content);
        const candidate = {
          ...parsed.section,
          storyArcBeatID: beat.id,
          recipeRequirementIDs: target.recipeRequirementIDs ?? [],
        };
        repairedSection = validateSuggestions({ suggestions: [candidate] }, new Set([beat.id]), undefined, obligations, { ...template, beats: [beat] }).suggestions[0];
      } catch {
        repairedSection = undefined;
      }
      if (!repairedSection) {
        unresolved.push(target.title);
        continue;
      }
      const targetIndex = result.indexOf(target);
      result[targetIndex] = repairedSection;
      const remainingIssue = validateRequiredStoryArcFunctions(result, { ...template, beats: [beat] }).find((item) => item.includes(`(${beat.id})`));
      if (remainingIssue) {
        unresolved.push(target.title);
      } else {
        repaired.push(`${target.title}: ${required}`);
      }
    }
  }
  return { suggestions: result, repaired, unresolved };
}

export function validateStoryArcSemantics(
  suggestions: Suggestion[],
  template: Pick<ArcTemplateBlob, "name" | "beats">,
  allocation?: Map<string, Allocation>,
): string[] {
  const issues: string[] = [
    ...validatePostRepairBeatCoverage(suggestions, template, allocation),
    ...validateRequiredStoryArcFunctions(suggestions, template),
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
  const usedText = suggestions.map(contractText).join(" ");
  const supportingEntities = storyMaterial
    ? STORY_MATERIAL_CATEGORIES.flatMap((category) => storyMaterial[category])
      .filter((item) => !usedText.includes(`${item.label} ${item.description}`.toLowerCase().split(/\s+/)[0]))
      .map((item) => item.id)
      .slice(0, 50)
    : [];
  return {
    distinctnessIssues,
    causalScaleIssues,
    semanticArcIssues,
    supportingEntities,
    unusedStoryMaterialItems: supportingEntities.length,
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

const SUGGESTION_LEASE_MS = 3 * 60 * 1000;

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
}): Promise<boolean> {
  const observedLeaseExpiry = run.lease_expires_at;
  if (run.status !== "running" || !observedLeaseExpiry || new Date(observedLeaseExpiry).getTime() >= Date.now()) return false;
  const reclaimed = await db.from("outline_suggestion_runs").update({
    status: "pending",
    error_code: null,
    error: null,
    completed_at: null,
    lease_owner: null,
    lease_expires_at: null,
    attempt_count: (run.attempt_count ?? 0) + 1,
  })
    .eq("id", run.id)
    .eq("status", "running")
    .eq("lease_expires_at", observedLeaseExpiry)
    .select("id")
    .maybeSingle();
  if (reclaimed.error || !reclaimed.data) return false;
  await markInterruptedProviderAttempts(db, run.id, observedLeaseExpiry);
  return true;
}

async function scheduleSuggestionContinuation(body: OutlineFromRecipeRequest, authHeader: string): Promise<void> {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const response = await fetch(`${url}/functions/v1/outline-from-recipe`, {
    method: "POST",
    headers: { Authorization: authHeader, "Content-Type": "application/json" },
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
): Promise<boolean> {
  if (run?.status !== "pending" || !run.request_json || !openaiKey) return false;
  await startWorker(
    run.id,
    run.request_json as OutlineFromRecipeRequest,
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
  let diagnostics: Record<string, unknown> = {
    ...priorDiagnostics,
    stage: "starting",
    worker: {
      ...priorWorker,
      sliceCount: workerSliceCount,
      lastSliceStartedAt: new Date().toISOString(),
      lastYieldReason: null,
      nextAction: "resume persisted planning checkpoint",
    },
  };
  const touchLease = async () => {
    await db.from("outline_suggestion_runs").update({ lease_expires_at: leaseExpiry() }).eq("id", runId).eq("lease_owner", workerToken);
  };
  const updateRun = async (patch: Record<string, unknown>) => {
    return await db.from("outline_suggestion_runs").update(patch).eq("id", runId).eq("lease_owner", workerToken);
  };
  let plannedMinimumSections: number | null = null;
  let latestValidSuggestions: Suggestion[] = Array.isArray(claimedRun.suggestions)
    ? claimedRun.suggestions as Suggestion[]
    : [];
  try {
    const modelStore = dependencies.model ? null : new SupabaseGenerationModelStore(db);
    const model = dependencies.model ?? await modelStore!.getEnabledModelById(OPENAI_MODEL);
    if (!model) {
      throw new Error(`Enabled billing model not found: ${OPENAI_MODEL}`);
    }
    const creditStore = dependencies.creditStore ?? new SupabaseCreditStore(db);
    const provider = dependencies.provider ?? new OpenAIProvider(openaiKey, OPENAI_MODEL);
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
          recipeBytes: new TextEncoder().encode(JSON.stringify(compactRecipe(body.recipe))).byteLength,
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
      const result = await billableLLM({
        userID: userId,
        purpose: "outline-suggestion",
        action,
        model,
        messages,
        maxOutputTokens,
        providerOptions: {
          responseFormat,
          temperature: 0.7,
          cacheMode: model.cacheMode,
          promptCacheKey: model.cacheMode === "none" ? undefined : promptCacheKey,
        },
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
          if (validateResponse) await validateResponse(providerResult.content);
          return providerResult.content;
        },
      }, { adminClient: db, provider, creditStore });
      await persistBilling();
      return {
        content: result.featureResult,
        creditCostCharged: result.charged ? result.actualCharge : 0,
        remainingCredits: result.remainingCredits,
      };
    };

    const expandNovel = async (
      initialSuggestions: Suggestion[],
      recipeObligations: RecipeObligation[],
      startRound = 1,
      startBeatIndex = 0,
      priorDiagnostics: ExpansionRoundDiagnostic[] = [],
    ): Promise<ProgressiveExpansionResult> => {
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
          const expandedRaw = await billableCall(
            expansion.system,
            expansion.user,
            16000,
            { type: "json_schema", json_schema: { name: "outline_expansion", strict: true, schema: buildExpansionResponseSchema(beat ? arcRoleContract(body.arcTemplate.beats.find((candidate) => candidate.id === beat.beatID)!, body.arcTemplate.name) : undefined) } },
            `outline-expansion-${context.round}-${beat?.beatID ?? "global"}`,
            (content) => {
              const additions = parseExpansionResponse(content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations, body.arcTemplate);
              const merged = mergeExpansionAdditions(current, additions);
              if (merged.length > MAX_PLANNED_SECTIONS) {
                throw new ExpansionValidationError(
                  `outline expansion exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`,
                );
              }
              return additions;
            },
          );
          return parseExpansionResponse(expandedRaw.content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations, body.arcTemplate);
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
          await updateRun({
            suggestions: current,
            planning_state: planningState,
            diagnostics: { ...diagnostics, expansionCheckpoint },
          });
        },
        {
          existingSections: body.existingSections ?? [],
          startRound,
          startBeatIndex,
          priorDiagnostics,
          beats: body.arcTemplate.beats,
          onBeat: async (round, nextBeatIndex, current, allDiagnostics) => {
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
            await updateRun({ suggestions: current, planning_state: planningState, diagnostics });
          },
        },
      );
    };

    const provenance = await recipeProvenance(body.recipe);
    if (!body.storyMaterialEnrichment && claimedRun.story_material) {
      body = {
        ...body,
        storyMaterialEnrichment: normalizeProviderStoryMaterialItemIDs(
          downgradeUnverifiedProviderRecipeReferences(claimedRun.story_material, body.recipe),
        ) as StoryMaterialEnrichment,
      };
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
      // PR8 (revised): persist the (possibly repaired) story_material and
      // the resume-stage diagnostics BEFORE expandNovel so a later failure
      // or interruption cannot lose the completed repair. Idempotent with
      // any earlier persist inside resumeOrRepairStoryMaterial — the final
      // updateRun below overwrites the same fields with completed-stage
      // diagnostics on success.
      await updateRun({
        story_material: resumedMaterial,
        diagnostics,
      });
      const recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>);
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
        diagnostics = {
          ...diagnostics,
          expansionError: error instanceof Error ? error.message : String(error),
          novelScale: evaluateNovelScale(resume.suggestions, body.existingSections ?? []),
        };
        throw error;
      }
      const resumedScale = evaluateNovelScale(completedSuggestions, body.existingSections ?? []);
      if (!resumedScale.meetsMinimum) {
        throw new NovelScalePlanningError(
          "failed_under_target",
          `Novel outline remains below the ${NOVEL_TARGET_WORDS[0].toLocaleString()}-word minimum after expansion resume.`,
        );
      }
      // PR8 (revised): story_material was already persisted above (before
      // expandNovel) so future resumes can validate without re-repairing.
      // The final updateRun only carries the completed-stage diagnostics
      // and standard completion fields.
      await updateRun({
        status: "completed",
        suggestions: completedSuggestions,
        warnings: completionWarnings,
        completed_at: new Date().toISOString(),
        planning_state: { ...planningState, phase: "completed" },
        diagnostics: { ...diagnostics, stage: "completed", finalSectionCounts: countSuggestionsByBeat(completedSuggestions), novelScale: resumedScale },
        lease_owner: null,
        lease_expires_at: null,
      });
      return;
    }
    let storyMaterial: StoryMaterialEnrichment | null = null;
    let enrichmentDiagnostics: Record<string, unknown> = { enrichmentModel: OPENAI_MODEL, sourceRecipeHash: provenance.sourceRecipeHash, sourceRecipeVersion: provenance.sourceRecipeVersion, sourcePromptPackID: provenance.sourcePromptPackID };
    if (body.storyMaterialEnrichment) {
      try {
        const candidate = validateStoryMaterialEnrichment(body.storyMaterialEnrichment, { recipe: body.recipe });
        const compatible = isCompatibleStoryMaterialEnrichment(candidate, provenance, requestedStoryMaterialFormat(body));
        const sufficiency = storyMaterialSufficiency(candidate, body.recipe, requestedStoryMaterialFormat(body));
        if (compatible && sufficiency.sufficient) {
          storyMaterial = candidate;
          enrichmentDiagnostics = { ...enrichmentDiagnostics, generatedOrReused: "reused", enrichmentCreditCostCharged: 0, sufficiency: sufficiency.sufficient ? "sufficient" : "insufficient", sufficiencyReasons: sufficiency.reasons, itemCountsByCategory: sufficiency.counts, recipeDerivedItemCount: sufficiency.recipeDerivedItemCount, plannerInventedItemCount: sufficiency.plannerInventedItemCount };
        } else {
          enrichmentDiagnostics = { ...enrichmentDiagnostics, reuseRejected: compatible ? "insufficient" : "recipe_provenance_mismatch", priorSourceRecipeHash: candidate.sourceRecipeHash, priorSourceRecipeVersion: candidate.sourceRecipeVersion };
        }
      } catch (error) {
        enrichmentDiagnostics = { ...enrichmentDiagnostics, reuseRejected: error instanceof Error ? error.message : "incompatible_enrichment" };
      }
    }
    if (!storyMaterial) {
      const generateEnrichment = async (action: string, prior?: StoryMaterialEnrichment, repairReason?: string) => {
        const enrichmentPrompt = buildEnrichmentPrompt(body, prior, repairReason);
        let parsedMaterial: StoryMaterialEnrichment | null = null;
        const enrichmentResult = await billableCall(
          enrichmentPrompt.system,
          enrichmentPrompt.user,
          12000,
          { type: "json_schema", json_schema: { name: "story_material_enrichment", strict: true, schema: STORY_MATERIAL_ENRICHMENT_SCHEMA } },
          action,
          (content) => {
            try {
              const normalizedProviderMaterial = normalizeProviderStoryMaterialItemIDs(
                downgradeUnverifiedProviderRecipeReferences(JSON.parse(content), body.recipe),
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
              if (error instanceof StoryMaterialSufficiencyError) throw error;
              throw new StoryMaterialValidationError(error instanceof Error ? error.message : String(error));
            }
            const sufficiency = storyMaterialSufficiency(parsedMaterial, body.recipe, requestedStoryMaterialFormat(body));
            if (!sufficiency.sufficient) throw new StoryMaterialSufficiencyError(sufficiency.reasons);
            return parsedMaterial;
          },
        );
        const material = parsedMaterial ?? validateStoryMaterialEnrichment(JSON.parse(enrichmentResult.content), { allowMissingProvenance: true, recipe: body.recipe });
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
      await updateRun({ story_material: storyMaterial, planning_state: planningState, diagnostics: { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_complete" } });
    }
    if (!storyMaterial) throw new Error("story material enrichment was not produced");
    await updateRun({
      story_material: storyMaterial,
      diagnostics: { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_ready" },
    });
    await persistPlanningProvenance(db, body, runId, storyMaterial, provenance);
    body = { ...body, storyMaterialEnrichment: storyMaterial };
    const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
    const recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>);
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
    await updateRun({ planning_context: planningContext, planning_context_hash: planningContextHash, planning_context_version: claimedRun.planning_context_version ?? 1 });
    // PR 5: allocation counts are residual NEW sections. Persist the validated
    // plan before the next provider boundary so continuation does not rerun a
    // settled allocation call or double-subtract existing coverage.
    const persistedAllocation = Array.isArray(planningState.allocationEntries)
      ? planningState.allocationEntries as Array<[string, Allocation]>
      : null;
    let allocation: Map<string, Allocation>;
    if (persistedAllocation) {
      allocation = new Map<string, Allocation>(persistedAllocation);
    } else {
      const retryOnly = planningState.nextAction === "outline-plan-retry";
      try {
        allocation = await planSectionAllocation(
          body,
          openaiKey,
          billableCall,
          recipeObligations,
          { retryOnly, deferRetry: !retryOnly },
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
        allocationRetryReason: undefined,
      };
      await updateRun({ planning_state: planningState });
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
      recipeObligations,
    };
    const { system, user: userPrompt } = buildPrompt(body, allocation, recipeObligations, storyMaterial);
    const responseSchema = buildSuggestionResponseSchema(body.arcTemplate.beats, allocation, recipeObligations, body.arcTemplate.name);
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
        16000,
        responseFormat,
        "outline-suggestions",
        (content) => {
          const flattened = flattenSuggestionResponse(JSON.parse(content), body.arcTemplate.beats);
          diagnostics = { ...diagnostics, stage: "outline_validating", firstPassParsedCounts: countSuggestionsByBeat(flattened.suggestions) };
          const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations, body.arcTemplate);
          const merged = mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), validated.suggestions, []);
          if (merged.length > MAX_PLANNED_SECTIONS) {
            throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
          }
          return validated;
        },
      );
      const flattened = flattenSuggestionResponse(JSON.parse(rawResponse.content), body.arcTemplate.beats);
      const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations, body.arcTemplate);
      result = { suggestions: mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), validated.suggestions, []), warnings: validated.warnings };
      diagnostics = { ...diagnostics, stage: "outline_validated", firstPassParsedCounts: countSuggestionsByBeat(result.suggestions), firstPassValidatedCounts: countSuggestionsByBeat(result.suggestions) };
      if (result.suggestions.length > MAX_PLANNED_SECTIONS) {
        throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
      }
    }

    // Structural validation above is the completion gate. The following checks
    // are intentionally advisory: literary heuristics must never reject a
    // structurally usable outline or trigger another billable call.
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
      ...(initialQuality.advisoryValidationError
        ? { advisoryValidationError: initialQuality.advisoryValidationError }
        : {}),
    };

    const coverage = obligationCoverage([...(body.existingSections ?? []), ...result.suggestions], recipeObligations);
    diagnostics = {
      ...diagnostics,
      recipeObligationCoverage: coverage.covered,
      missingRequiredRecipeObligations: coverage.missingRequired.map((obligation) => obligation.id),
      novelScale: evaluateNovelScale(result.suggestions, body.existingSections ?? []),
    };
    let completedSuggestions = result.suggestions;
    let completionWarnings = result.warnings;
    const outlineNeedsExpansion = requestedStoryMaterialFormat(body) === "novel" &&
      needsNovelExpansion(completedSuggestions, body.existingSections ?? []);
    planningState = {
      ...planningState,
      phase: "outline_complete",
      nextAction: outlineNeedsExpansion ? "expansion" : "completed",
    };
    await updateRun({
      suggestions: completedSuggestions,
      planning_state: planningState,
      diagnostics,
    });
    if (outlineNeedsExpansion) {
      planningState = {
        ...planningState,
        phase: "expansion",
        expansionStartRound: 1,
        expansionDiagnostics: [],
      };
      const expansionCheckpoint = buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], []);
      planningState = { ...planningState, phase: "expansion", expansionCheckpoint };
      diagnostics = { ...diagnostics, stage: "expansion_pending", expansionCheckpoint };
      await updateRun({
        suggestions: completedSuggestions,
        planning_state: planningState,
        diagnostics,
      });
      const expanded = await expandNovel(completedSuggestions, recipeObligations, 1, 0, []);
      completedSuggestions = expanded.suggestions;
      completionWarnings = [...completionWarnings, ...expanded.warnings];
      diagnostics = {
        ...diagnostics,
        expansionRounds: expanded.diagnostics,
        expansionCheckpoint: buildExpansionCheckpoint(completedSuggestions, body.existingSections ?? [], expanded.diagnostics),
        novelScale: evaluateNovelScale(completedSuggestions, body.existingSections ?? []),
      };
    }
    const finalScale = evaluateNovelScale(completedSuggestions, body.existingSections ?? []);
    if (requestedStoryMaterialFormat(body) === "novel" && !finalScale.meetsMinimum) {
      throw new Error("outline expansion did not reach plausible novel scale");
    }
    await updateRun({
      status: "completed",
      suggestions: completedSuggestions,
      warnings: completionWarnings,
      completed_at: new Date().toISOString(),
      planning_state: { ...planningState, phase: "completed" },
      diagnostics: { ...diagnostics, stage: "completed", finalSectionCounts: countSuggestionsByBeat(completedSuggestions), novelScale: finalScale },
      lease_owner: null,
      lease_expires_at: null,
    });
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
    const errorCode = err instanceof StoryMaterialSufficiencyError
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
    await updateRun({
      status: "failed",
      suggestions: latestValidSuggestions,
      error_code: errorCode,
      error: message.slice(0, 2000),
      diagnostics: {
        ...diagnostics,
        stage: "failed",
        plannedMinimumSections,
        error: message.slice(0, 500),
        ...(requestedStoryMaterialFormat(body) === "novel"
          ? { novelScale: evaluateNovelScale(latestValidSuggestions, body.existingSections ?? []) }
          : {}),
      },
      completed_at: new Date().toISOString(),
      lease_owner: null,
      lease_expires_at: null,
    });
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "GET" && req.method !== "POST") {
    return errorResponse("method_not_allowed", "GET or POST required", 405);
  }
  const authHeader = req.headers.get("Authorization");
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
      "id, status, suggestions, warnings, error_code, error, diagnostics, story_material, created_at, updated_at, completed_at, credit_cost_charged, remaining_credits, request_json, project_id, idempotency_key, request_fingerprint, attempt_count, lease_expires_at";

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
    if (run.status === "running") {
      const reclaimed = await reclaimExpiredSuggestionRun(admin(), run);
      if (reclaimed) recoveredRun = { ...run, status: "pending", lease_expires_at: null };
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
      ));
      run = recoveredRun;
    }
    return corsResponse(
      JSON.stringify({
        run_id: run.id,
        status: run.status,
        suggestions: run.suggestions,
        warnings: run.warnings,
        errorCode: run.error_code,
        error: run.error,
        diagnostics: run.diagnostics,
        storyMaterialEnrichment: run.story_material,
        created_at: run.created_at,
        updated_at: run.updated_at,
        completed_at: run.completed_at,
        creditCostCharged: run.credit_cost_charged,
        remainingCredits: run.remaining_credits,
        sourceRecipe: run.request_json?.recipe ?? null,
      }),
      { status: 200 },
    );
  }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) {
    return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);
  }
  let body: OutlineFromRecipeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }
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
  // PR 7: calculate logical identity BEFORE checkRateLimit so reconnects
  // can short-circuit without consuming a rate-limit slot or logging.
  const identity = await logicalSuggestionIdentity(body);
  // PR 7: resolve an existing matching idempotent run first. If the
  // current request's idempotency key is already bound to a run with the
  // same fingerprint, reconnect to it (no rate limit, no log entry). If
  // the fingerprint differs, reject as 409 idempotency_conflict. This is
  // the idempotency-safe path for app reconnects / worker retries /
  // iOS suggestion-status polling that re-submits the same request after
  // a transient network failure.
  const { data: existing, error: existingError } = await db
    .from("outline_suggestion_runs")
    .select("id, status, request_fingerprint, lease_expires_at, error_code, suggestions, warnings, error, diagnostics, story_material, credit_cost_charged, remaining_credits, request_json, created_at, updated_at, completed_at, attempt_count")
    .eq("user_id", user.id)
    .eq("idempotency_key", identity.key)
    .maybeSingle();
  if (existingError) {
    console.error("[outline-from-recipe] existing-run resolve failed", existingError);
    return errorResponse("db_error", existingError.message ?? "Could not resolve existing run", 500);
  }
  if (existing) {
    if (
      existing.request_fingerprint &&
      existing.request_fingerprint !== identity.fingerprint
    ) {
      return errorResponse(
        "idempotency_conflict",
        "The idempotency key is already bound to a different suggestion request",
        409,
      );
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
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, body, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
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
    if (existing.status === "running") {
      const reclaimed = await reclaimExpiredSuggestionRun(db, existing);
      if (reclaimed) existing.status = "pending";
    }
    if (existing.status === "pending") {
      // Reconnects and continuation POSTs do not consume another rate-limit
      // slot or request-log entry. The pending claim makes this race-safe.
      // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
      EdgeRuntime.waitUntil(runSuggestionJob(existing.id, body, user.id, openaiKey, existing.attempt_count ?? 0, authHeader));
    }
    // Reconnect: return existing run status. Skip checkRateLimit + logRequest
    // so a stray reconnect does NOT consume a rate-limit slot or produce
    // a duplicate request-log entry.
    return corsResponse(
      JSON.stringify({
        run_id: existing.id,
        status: existing.status,
        suggestions: existing.suggestions,
        warnings: existing.warnings,
        errorCode: existing.error_code,
        error: existing.error,
        diagnostics: existing.diagnostics,
        storyMaterialEnrichment: existing.story_material,
        created_at: existing.created_at,
        updated_at: existing.updated_at,
        completed_at: existing.completed_at,
        creditCostCharged: existing.credit_cost_charged,
        remainingCredits: existing.remaining_credits,
        sourceRecipe: existing.request_json?.recipe ?? null,
      }),
      { status: 200 },
    );
  }
  // PR 7: only NEW logical requests reach checkRateLimit. Reconnects were
  // handled by the resolve-existing path above; this is a fresh
  // outline-from-recipe request with a brand-new idempotency key.
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
      .select("id, status, created_at, updated_at, suggestions, warnings, error_code, error, diagnostics, story_material, credit_cost_charged, remaining_credits, request_json, lease_expires_at, attempt_count, request_fingerprint")
      .eq("user_id", user.id).eq("idempotency_key", identity.key).single();
    if (existing.error || !existing.data) return errorResponse("db_error", existing.error?.message ?? "Could not resolve suggestion run", 500);
    run = existing.data;
    if (run.request_fingerprint && run.request_fingerprint !== identity.fingerprint) {
      return errorResponse("idempotency_conflict", "The idempotency key is already bound to a different suggestion request", 409);
    }
    const stale = run.status === "running" && run.lease_expires_at && new Date(run.lease_expires_at).getTime() < Date.now();
    const resumableExpansionFailure = run.status === "failed" && run.error_code === "failed_expansion" && expansionResumeState(run) !== null;
    if (stale) {
      if (await reclaimExpiredSuggestionRun(db, run)) run.status = "pending";
    } else if (resumableExpansionFailure) {
      const reclaimed = await db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
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
      await logRequest(db, user.id, "queued");
    } catch (logError) {
      console.error("[outline-from-recipe] logRequest failed", logError);
    }
  }
  // A pending duplicate may be the only way to restart a worker lost during
  // suspension. The pending claim inside runSuggestionJob makes this race-safe.
  if (run.status === "pending") {
    // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
    EdgeRuntime.waitUntil(runSuggestionJob(run.id, body, user.id, openaiKey, run.attempt_count ?? 0, authHeader));
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
