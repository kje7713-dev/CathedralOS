import { createClient } from "jsr:@supabase/supabase-js@2";
import { runBillableLLM } from "../_shared/billable-llm.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { SupabaseGenerationModelStore } from "../generate-story/_generation_models.ts";
import {
  type LLMMessage,
  OpenAIProvider,
} from "../generate-story/_provider.ts";
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
  },
  required: ["title", "summary", "container", "pov", "terminalBeat", "entryState", "dramaticEvent", "resultingChange", "terminalState"],
  additionalProperties: false,
} as const;

export function buildSuggestionResponseSchema(
  beats: Array<{ id: string }>,
  allocation: Map<string, Allocation>,
  obligations: RecipeObligation[] = [],
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
    properties[beat.id] = {
      type: "array",
      minItems: minimum,
      items: sectionSchema,
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
  const handles = new Map<string, string>();
  if (typeof recipe.project.summary === "string" && recipe.project.summary.trim()) handles.set("project.summary", recipe.project.summary);
  const add = (prefix: string, values: unknown[], fallback: string) => values.forEach((value, index) => {
    if (!value || typeof value !== "object") return;
    const row = value as Record<string, unknown>;
    const id = typeof row.id === "string" && row.id.trim() ? row.id : `${fallback}-${index + 1}`;
    const handle = `${prefix}:${id}`;
    handles.set(handle, typeof row.name === "string" ? row.name : typeof row.label === "string" ? row.label : JSON.stringify(row));
  });
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
        const referencedMaterial = handles?.get(row.sourceReference);
        if (handles && !referencedMaterial) throw new Error(`recipe story material item ${row.id} has an unverified source reference`);
        if (row.label === row.sourceReference || row.description === row.sourceReference) throw new Error(`recipe story material item ${row.id} has no authored description`);
        if (referencedMaterial) {
          const sourceTokens = referencedMaterial.toLowerCase().match(/[a-z0-9]{4,}/g) ?? [];
          const itemText = `${String(row.label)} ${String(row.description)}`.toLowerCase();
          if (sourceTokens.length > 0 && !sourceTokens.some((token) => itemText.includes(token))) throw new Error(`recipe story material item ${row.id} does not correspond to referenced recipe material`);
        }
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

export function buildEnrichmentPrompt(req: OutlineFromRecipeRequest, candidate?: StoryMaterialEnrichment, repairReason?: string): { system: string; user: string } {
  const format = requestedStoryMaterialFormat(req);
  const repairInstruction = repairReason
    ? `\n\nThe previous enrichment response was rejected: ${repairReason}. Repair it by using source=recipe only with an exact handle from recipeMaterialHandles. Never copy an item id into sourceReference, invent a handle, or use a human-readable label as a handle. Use source=planner with sourceReference null for anything that cannot be tied to an exact handle.`
    : "";
  return {
    system: `You are the story-material enrichment planner for CathedralOS. Create a concrete package before outline planning, not prose or a final outline. Sparse input does NOT mean a shorter or simpler story: Cathedral has a larger invention burden and must invent the opposition, supporting cast, institutions, locations, objectives, failures, discoveries, relationships, consequences, reversals, and escalation needed for ${format}-scale development while respecting authored facts. Rich input means preserve, connect, and deepen supplied material before inventing replacements; do not make detailed recipes less ambitious. Use source=recipe only with one of the server-provided recipe handles; use source=planner for all connective or newly invented material and use null sourceReference. The server, not you, owns recipe provenance. Do not fill categories mechanically, but ensure the package is concrete enough that the outline planner does not invent the entire plot section by section. Return only JSON matching the enrichment schema.${repairInstruction}`,
    user: JSON.stringify({ recipe: req.recipe, recipeMaterialHandles: Object.fromEntries(recipeMaterialHandles(req.recipe)), priorEnrichment: candidate ?? null, arcTemplate: req.arcTemplate, hint: req.hint ?? null, requestedFormat: format }, null, 2),
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
      validateStoryMaterialEnrichment(r.storyMaterialEnrichment, { allowMissingProvenance: true });
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
          storyArcBeatID: { type: "string" },
          insertAfterTitle: { type: ["string", "null"] },
          recipeRequirementIDs: { type: "array", minItems: 0, maxItems: 50, items: { type: "string", minLength: 1 } },
        },
        required: ["title", "summary", "container", "pov", "terminalBeat", "entryState", "dramaticEvent", "resultingChange", "terminalState", "storyArcBeatID", "insertAfterTitle", "recipeRequirementIDs"],
      },
    },
  },
  required: ["suggestions"], additionalProperties: false,
} as const;

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
  priorDiagnostics?: ExpansionRoundDiagnostic[];
  beats?: Array<{ id: string; label?: string; description?: string }>;
}

export interface ExpansionCheckpoint {
  stage: "expansion";
  nextRound: number;
  scale: NovelScaleEvaluation;
  expansionRounds: ExpansionRoundDiagnostic[];
}

export function buildExpansionCheckpoint(
  suggestions: Suggestion[],
  existingSections: PlannedSectionLike[],
  expansionRounds: ExpansionRoundDiagnostic[],
): ExpansionCheckpoint {
  const completedRounds = expansionRounds
    .filter((diagnostic) => diagnostic.status === "completed")
    .map((diagnostic) => diagnostic.round);
  const lastCompletedRound = completedRounds.length > 0
    ? Math.max(...completedRounds)
    : 0;
  return {
    stage: "expansion",
    nextRound: Math.max(1, lastCompletedRound + 1),
    scale: evaluateNovelScale(suggestions, existingSections),
    expansionRounds,
  };
}

export interface ExpansionResumeState {
  suggestions: Suggestion[];
  startRound: number;
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
      for (const beat of targetBeats) {
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
): StoryMaterialItem[] {
  if (!storyMaterial) return [];
  const usedText = current.map(contractText).join(" ");
  return STORY_MATERIAL_CATEGORIES.flatMap((category) => storyMaterial[category])
    .filter((item) => {
      const labelTokens = contentTokens(item.label);
      if (labelTokens.size === 0) return true;
      return !Array.from(labelTokens).some((token) => usedText.includes(token));
    })
    .slice(0, 60);
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
  const unusedStoryMaterial = findUnusedStoryMaterial(current, req.storyMaterialEnrichment);
  const beatContext = context?.beat;
  const beatDirective = beatContext
    ? `This is beat-local expansion for Story Arc beat ${beatContext.beatID}${beatContext.beatLabel ? ` (${beatContext.beatLabel})` : ""}. Develop only this beat; every returned section must use storyArcBeatID ${beatContext.beatID}. The beat currently contains approximately ${Math.round(beatContext.projectedWords).toLocaleString()} projected words. Its description is: ${beatContext.beatDescription ?? "(not supplied)"}.`
    : "Expand across the supplied outline while preserving each section's Story Arc beat.";
  return {
    system: `The current outline is compressed for a ${requestedStoryMaterialFormat(req)}. This is bounded progressive expansion round ${round} of ${MAX_EXPANSION_ROUNDS}. The current projection is approximately ${Math.round(projectedWords).toLocaleString()} words (${Math.round(projectedTokens).toLocaleString()} tokens), versus the preferred broad ${requestedStoryMaterialFormat(req)} range of ${NOVEL_TARGET_WORDS[0].toLocaleString()}-${NOVEL_TARGET_WORDS[1].toLocaleString()} words. The remaining estimated deficit is approximately ${Math.round(remainingDeficitTokens).toLocaleString()} tokens. ${beatDirective} Return ONLY ADDITIONAL section suggestions; never return, rewrite, reorder, or omit existing sections. Add distinct events, consequences, decisions, reversals, tests, discoveries, and aftermath where the current outline is compressed. Develop material in this order: unused or underdeveloped enrichment items; deeper causal chains; meaningful complications; relationships; opposition; consequences and aftermath; geographic/social/strategic scope; reversals and discoveries; additional phases inside complex set pieces; and only then genuinely separate new dramatic developments. Do not add a new section for the same dramatic state. Prefer the currently unused enrichment items listed in the request; connect them to existing relationships, opposition, consequences, and discoveries before inventing generic replacements. Each addition must use the same container semantics: scene = one continuous dramatic event (800-1,800 expected tokens); developedScene = escalation with multiple tactics (1,500-3,000); setPiece = major action/confrontation/reveal (2,000-5,000); sceneSequence = several connected scenes pursuing one objective (3,000-7,000). These are literary planning ranges only, not provider ceilings. Do not inflate containers to satisfy the size check by converting smaller containers into larger containers. Every addition must explicitly include entryState, dramaticEvent, resultingChange, terminalState, and a plannedWordRange as a soft literary target subordinate to the container and natural stopping point, and must reference a valid beat and include insertAfterTitle for an existing section, or null to append within its beat. Assign only applicable recipeRequirementIDs from the supplied obligation list; additions may contain an empty list. Return JSON matching the expansion schema.

## Recipe obligations
${renderRecipeObligations(obligations)}`,
    user: JSON.stringify({ recipe: req.recipe, storyMaterialEnrichment: req.storyMaterialEnrichment ?? null, arcTemplate: req.arcTemplate, recipeObligations: obligations, existingSections: req.existingSections ?? [], currentSuggestions: current, beatLocalContext: beatContext ?? null, unusedStoryMaterial, expansion: { round, projectedTokens, projectedWords, desiredWords: context?.desiredWords ?? NOVEL_TARGET_WORDS, remainingDeficitTokens } }, null, 2),
  };
}

export function validateExpansionAdditions(
  parsed: any,
  beatIds: Set<string>,
  original: Suggestion[],
  obligations: RecipeObligation[] = [],
): ExpansionAddition[] {
  if (!parsed || !Array.isArray(parsed.suggestions)) throw new Error("expansion response missing suggestions array");
  const originalTitles = new Set(original.map((s) => s.title));
  const additions: ExpansionAddition[] = [];
  const fingerprints = new Set(original.map((s) => `${s.title}|${s.summary}|${s.storyArcBeatID}`));
  for (const raw of parsed.suggestions) {
    const { insertAfterTitle } = raw ?? {};
    const validated = validateSuggestions({ suggestions: [raw] }, beatIds, undefined, obligations).suggestions[0];
    if (!validated) throw new Error("expansion returned an invalid addition");
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
): ExpansionAddition[] {
  try {
    return validateExpansionAdditions(JSON.parse(content), beatIds, original, obligations);
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


export function adjustAllocationForExistingSections(
  allocation: Map<string, Allocation>,
  existingSections: ExistingSectionBlob[] = [],
): Map<string, Allocation> {
  const counts = new Map<string, number>();
  for (const section of existingSections) {
    if (section.storyArcBeatID) counts.set(section.storyArcBeatID, (counts.get(section.storyArcBeatID) ?? 0) + 1);
  }
  return new Map(Array.from(allocation.entries()).map(([beatID, plan]) => [beatID, {
    minSections: Math.max(0, plan.minSections - (counts.get(beatID) ?? 0)),
    rationale: plan.rationale,
  }]));
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

  const system =
    `You are an expert ${requestedStoryMaterialFormat(req)} outliner. Use the complete canonical recipe/project payload below, including its premise, selected characters and their populated fields, selected relationships, themes, motifs, story spark, aftertaste, recipe instructions, and included setting. Treat supplied facts as authoritative; do not infer personality traits from a character name alone. Given the story arc and per-beat allocation plan, produce the section-by-section outline.

## Container semantics for planning

Choose a container for the scale of one dramatic unit, not to fake novel length:
- scene: one continuous dramatic event, expected 800-1,800 tokens
- developedScene: a fuller scene with escalation and multiple tactics, 1,500-3,000
- setPiece: a major action, confrontation, ceremony, or reveal, 2,000-5,000
- sceneSequence: several connected scenes pursuing one objective, 3,000-7,000
- chapter: a publishing or pacing division, 3,000-8,000+
The expected ranges are literary targets; runtime/provider headroom is not a desired length.

## Recipe obligations

The following obligations were derived from populated canonical recipe fields. Required obligations must be materially advanced by one or more sections. Supporting items are optional texture and must not be promoted into mandatory plot events. Each section may include zero or more applicable recipeRequirementIDs; attach only obligations materially advanced by that section.
${renderRecipeObligations(obligations)}

## Story material enrichment
${storyMaterial ? JSON.stringify(storyMaterial, null, 2) : "No enrichment package was supplied; preserve the complete recipe while planning."}
Use this package to develop concrete events. Do not treat planner-invented material as authored recipe fact.

## Use the minimum-only allocation

For each beat, generate at least the stated minimum number of distinct sections. The minimum is a floor for dramatic coverage, not a target or maximum: generate additional sections whenever the material supports distinct events, consequences, decisions, or revelations. A beat with minimum 0 is already covered for this pass and must produce no new suggestion. Never pad with paraphrases.

## Novel-ready section titles

Write each section title as a concise, specific, evocative working title suitable for a ${requestedStoryMaterialFormat(req)} outline or ${requestedStoryMaterialFormat(req)}-ready table of contents. The title should name the concrete dramatic event, decision, reversal, discovery, confrontation, or consequence that this section actually dramatizes. Do not restate or lightly rephrase the premise, Story Arc beat label, terminal beat, or section summary. Avoid generic placeholders such as "Setup," "Conflict," "Events," or "Scene"; each title must distinguish its section from the others in the same beat.

## Generation-ready section contract
For every section, explicitly state entryState, dramaticEvent, resultingChange, and terminalState. The dramaticEvent must be a specific objective, confrontation, discovery, decision, reversal, or consequence; resultingChange must alter the protagonist, opposition, relationship, information, resources, or stakes. The terminalState is the concrete condition handed to the next section. Do not copy an arc-beat label into these fields. Do not provide plannedWordRange; the server derives it deterministically from container; it never overrides the Section Contract, container, or natural stopping point.

${allocationLines}

${
      req.existingSections && req.existingSections.length > 0
        ? `Existing sections already in this outline (do not duplicate; build forward from them where natural):
${
          req.existingSections.map((s) =>
            `- "${s.title ?? "(untitled)"}" (${s.container ?? "scene"}, ${
              s.pov ?? "thirdPersonLimited"
            }): ${s.summary ?? ""} [recipeRequirementIDs: ${(s.recipeRequirementIDs ?? []).join(", ") || "none"}]`
          ).join("\n")
        }\n\n`
        : ""
    }Respond with structured JSON matching the schema.`;
  const user = JSON.stringify(
    {
      recipe: req.recipe,
      arcTemplate: req.arcTemplate,
      recipeObligations: obligations,
      storyMaterialEnrichment: storyMaterial ?? null,
      hint: req.hint ?? null,
    },
    null,
    2,
  );

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
          beatID: { type: "string", minLength: 1 },
          minSections: { type: "integer", minimum: 0, maximum: 10 },
          rationale: { type: "string", minLength: 1, maxLength: 500 },
        },
        required: ["beatID", "minSections", "rationale"],
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
      !["beatID", "minSections", "rationale"].includes(key)
    );
    if (unexpectedKeys.length > 0) {
      throw new Error(
        `allocation contains unexpected field(s): ${unexpectedKeys.join(", ")}`,
      );
    }
    const beatID = candidate.beatID;
    const minSections = candidate.minSections;
    const rationale = candidate.rationale;
    if (typeof beatID !== "string" || !validBeatIDs.has(beatID)) {
      throw new Error(`allocation contains unknown beatID: ${String(beatID)}`);
    }
    if (seen.has(beatID)) {
      throw new Error(`allocation contains duplicate beatID: ${beatID}`);
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
): { system: string; user: string } {
  const system =
    `You are an expert outliner. Given a complete canonical recipe/project payload, a verified story-material enrichment package, and a story arc template (ordered beats), decide how many outline sections each beat deserves in this particular ${requestedStoryMaterialFormat(req)}.

This request is for a ${requestedStoryMaterialFormat(req)}. Plan enough distinct dramatic material appropriate to that format; for a novel, plan enough for a plausible 70,000-90,000 word work when sections generate near their expected literary ranges. This is a broad scale target, not an exact word count. Do not satisfy it with giant containers: major arc movements should decompose into multiple events, consequences, decisions, reversals, tests, discoveries, and aftermath. Quick transitions may take 1-2 sections; major movements commonly need 5-10 sections. Use the supplied premise, characters, and arc to decide where density belongs.

For every Story Arc beat, determine the minimum number of distinct dramatic sections required to adequately realize that movement in a novel. Output exactly one JSON object with beatID matching the supplied UUID exactly, minSections as an integer from 0 through 10, and a concise rationale. Include every beat exactly once. This number is a floor, not a target or maximum. Major movements should generally require more minimum coverage than transitions, but the later outline generator may create additional sections whenever the material supports them. A beat sufficiently covered by existing sections may use minSections 0. Do not output any other root key.

Output JSON only. No commentary, no prose.`;

  const user = JSON.stringify(
    {
      requestedFormat: requestedStoryMaterialFormat(req),
      recipe: req.recipe,
      storyMaterialEnrichment: req.storyMaterialEnrichment ?? null,
      arcTemplate: {
        id: req.arcTemplate.id,
        name: req.arcTemplate.name,
        beats: req.arcTemplate.beats.map((b) => ({
          id: b.id,
          label: b.label,
          description: b.description,
        })),
      },
      existingSectionsByBeat: Object.fromEntries(
        req.arcTemplate.beats.map((beat) => [
          beat.id,
          (req.existingSections ?? []).filter((section) =>
            section.storyArcBeatID === beat.id
          ),
        ]),
      ),
      existingUnlinkedSections: (req.existingSections ?? []).filter((section) =>
        !section.storyArcBeatID ||
        !req.arcTemplate.beats.some((beat) =>
          beat.id === section.storyArcBeatID
        )
      ),
    },
    null,
    2,
  );
  return { system, user };
}

async function planSectionAllocation(
  req: OutlineFromRecipeRequest,
  apiKey: string,
  billableCall?: SuggestionLLMCall,
): Promise<Map<string, Allocation>> {
  const { system, user } = buildAllocationPrompt(req);
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
  for (const correction of [false, true]) {
    try {
      return parseAndValidateAllocation(
        await call(correction),
        req.arcTemplate.beats,
      );
    } catch (error) {
      if (!(error instanceof Error)) throw error;
      firstError = error;
    }
  }
  throw new Error(
    `allocation planner failed validation after retry: ${
      firstError?.message ?? "unknown error"
    }`,
  );
}

async function checkRateLimit(
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

async function logRequest(
  supabase: ReturnType<typeof makeSupabase>,
  userId: string,
  status: string,
  errorCode?: string,
): Promise<void> {
  await supabase.from("generation_request_logs").insert({
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
  const timeout = setTimeout(() => ac.abort(), 90_000);
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
  supportingEntities: string[];
  unusedStoryMaterialItems: number;
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

export function validateOutlinePlanningQuality(
  suggestions: Suggestion[],
  storyMaterial?: StoryMaterialEnrichment,
  format: StoryMaterialFormat = "novel",
): OutlineQualityDiagnostic {
  const distinctnessIssues = findDramaticDistinctnessIssues(suggestions);
  const causalScaleIssues = findCausalScaleIssues(suggestions, storyMaterial, format);
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
    supportingEntities,
    unusedStoryMaterialItems: supportingEntities.length,
  };
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

const SUGGESTION_LEASE_MS = 15 * 60 * 1000;

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

async function repairRecipeObligations(
  body: OutlineFromRecipeRequest,
  current: Suggestion[],
  beatIds: Set<string>,
  obligations: RecipeObligation[],
  billableCall: SuggestionLLMCall,
): Promise<Suggestion[]> {
  const missing = obligationCoverage([...(body.existingSections ?? []), ...current], obligations).missingRequired;
  if (missing.length === 0) return current;
  const projectedTokens = projectedExpectedTokens(current);
  const prompt = buildExpansionPrompt(body, current, {
    round: 1,
    projectedTokens,
    projectedWords: projectedTokens / TOKENS_PER_WORD,
    desiredWords: NOVEL_TARGET_WORDS,
    remainingDeficitTokens: Math.max(0, NOVEL_MIN_PROJECTED_TOKENS - projectedTokens),
  }, obligations);
  const system = `${prompt.system}\n\nThis is a bounded recipe-obligation repair. Add only distinct sections that materially advance every missing REQUIRED obligation listed below; do not rewrite existing sections.\nMissing required obligations: ${missing.map((obligation) => `${obligation.id}: ${obligation.statement}`).join(" | ")}`;
  const rawResult = await billableCall(
    system,
    prompt.user,
    16000,
    { type: "json_schema", json_schema: { name: "outline_obligation_repair", strict: true, schema: EXPANSION_SCHEMA } },
    "outline-obligation-repair",
    (content) => {
      const additions = validateExpansionAdditions(JSON.parse(content), beatIds, current, obligations);
      const merged = mergeExpansionAdditions(current, additions);
      if (merged.length > MAX_PLANNED_SECTIONS) throw new Error(`outline obligation repair exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
      return additions;
    },
  );
  const additions = validateExpansionAdditions(JSON.parse(rawResult.content), beatIds, current, obligations);
  return validateSuggestions(
    { suggestions: mergeExpansionAdditions(current, additions) },
    beatIds,
    undefined,
    obligations,
  ).suggestions;
}

class StoryMaterialSufficiencyError extends Error {
  constructor(public readonly reasons: string[]) {
    super(`story material enrichment is insufficient: ${reasons.join("; ")}`);
    this.name = "StoryMaterialSufficiencyError";
  }
}

class StoryMaterialValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "StoryMaterialValidationError";
  }
}

async function persistEnrichmentProvenance(db: any, body: OutlineFromRecipeRequest, runId: string, material: StoryMaterialEnrichment, provenance: StoryMaterialProvenance): Promise<void> {
  if (!body.outline_id) return;
  const { error } = await db.from("outlines").update({
    enrichment_schema_version: material.version,
    enrichment_source_recipe_hash: provenance.sourceRecipeHash,
    enrichment_run_id: runId,
    enrichment_planner_version: "story-material-v2",
  }).eq("id", body.outline_id);
  if (error) throw new Error(`Could not persist outline enrichment provenance: ${error.message}`);
}

async function runSuggestionJob(
  runId: string,
  body: OutlineFromRecipeRequest,
  userId: string,
  openaiKey: string,
  priorAttemptCount = 0,
): Promise<void> {
  const db = admin();
  const workerToken = crypto.randomUUID();
  const claim = await db.from("outline_suggestion_runs").update({
    status: "running",
    lease_owner: workerToken,
    lease_expires_at: leaseExpiry(),
    attempt_count: priorAttemptCount + 1,
  }).eq("id", runId).eq("status", "pending")
    .select("id, credit_cost_charged, remaining_credits, story_material, suggestions, diagnostics")
    .maybeSingle();
  if (claim.error || !claim.data) return;
  const claimedRun: any = claim.data;
  const touchLease = async () => {
    await db.from("outline_suggestion_runs").update({ lease_expires_at: leaseExpiry() }).eq("id", runId).eq("lease_owner", workerToken);
  };
  const updateRun = async (patch: Record<string, unknown>) => {
    return await db.from("outline_suggestion_runs").update(patch).eq("id", runId).eq("lease_owner", workerToken);
  };
  let plannedMinimumSections: number | null = null;
  let diagnostics: Record<string, unknown> = { stage: "starting" };
  let latestValidSuggestions: Suggestion[] = Array.isArray(claimedRun.suggestions)
    ? claimedRun.suggestions as Suggestion[]
    : [];
  try {
    const modelStore = new SupabaseGenerationModelStore(db);
    const model = await modelStore.getEnabledModelById(OPENAI_MODEL);
    if (!model) {
      throw new Error(`Enabled billing model not found: ${OPENAI_MODEL}`);
    }
    const creditStore = new SupabaseCreditStore(db);
    const provider = new OpenAIProvider(openaiKey, OPENAI_MODEL);
    // Reclaimed workers resume from persisted billing/material state. The
    // usage-event idempotency key is the final no-double-charge guard, while
    // reusing persisted enrichment avoids repeating a settled paid stage.
    let creditCostCharged = Number(claimedRun.credit_cost_charged ?? 0);
    let remainingCredits: number | null = claimedRun.remaining_credits ?? null;
    const persistBilling = async (
      result: {
        actualCharge: number;
        charged: boolean;
        remainingCredits: number;
      },
    ) => {
      if (result.charged) creditCostCharged += result.actualCharge;
      remainingCredits = result.remainingCredits;
      await updateRun({
        credit_cost_charged: creditCostCharged,
        remaining_credits: remainingCredits,
        lease_expires_at: leaseExpiry(),
      });
    };
    const billableCall: SuggestionLLMCall = async (
      system,
      user,
      maxOutputTokens,
      responseFormat,
      action,
      validateResponse,
    ) => {
      const messages: LLMMessage[] = [
        { role: "system", content: system },
        { role: "user", content: user },
      ];
      await touchLease();
      const result = await runBillableLLM({
        userID: userId,
        purpose: "outline-suggestion",
        action,
        model,
        messages,
        maxOutputTokens,
        providerOptions: { responseFormat, temperature: 0.7 },
        usageContext: {
          generationLengthMode: "outline",
          outputBudget: maxOutputTokens,
          idempotencyKey: `${runId}:${action}`,
        },
        onProviderSuccess: async (providerResult) => {
          if (validateResponse) await validateResponse(providerResult.content);
          return providerResult.content;
        },
      }, { adminClient: db, provider, creditStore });
      await persistBilling(result);
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
            { type: "json_schema", json_schema: { name: "outline_expansion", strict: true, schema: EXPANSION_SCHEMA } },
            `outline-expansion-${context.round}-${beat?.beatID ?? "global"}`,
            (content) => {
              const additions = parseExpansionResponse(content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations);
              const merged = mergeExpansionAdditions(current, additions);
              if (merged.length > MAX_PLANNED_SECTIONS) {
                throw new ExpansionValidationError(
                  `outline expansion exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`,
                );
              }
              return additions;
            },
          );
          return parseExpansionResponse(expandedRaw.content, new Set(body.arcTemplate.beats.map((beat) => beat.id)), current, recipeObligations);
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
          await updateRun({ suggestions: current, diagnostics });
        },
        {
          existingSections: body.existingSections ?? [],
          startRound,
          priorDiagnostics,
          beats: body.arcTemplate.beats,
        },
      );
    };

    const provenance = await recipeProvenance(body.recipe);
    if (!body.storyMaterialEnrichment && claimedRun.story_material) {
      body = { ...body, storyMaterialEnrichment: claimedRun.story_material as StoryMaterialEnrichment };
    }
    const resume = expansionResumeState(claimedRun);
    if (requestedStoryMaterialFormat(body) === "novel" && resume && claimedRun.story_material) {
      const resumedMaterial = validateStoryMaterialEnrichment(claimedRun.story_material as StoryMaterialEnrichment, { recipe: body.recipe });
      const sufficiency = storyMaterialSufficiency(resumedMaterial, body.recipe, requestedStoryMaterialFormat(body));
      if (!isCompatibleStoryMaterialEnrichment(resumedMaterial, provenance, requestedStoryMaterialFormat(body)) || !sufficiency.sufficient) {
        throw new Error("persisted expansion checkpoint has incompatible story material");
      }
      body = { ...body, storyMaterialEnrichment: resumedMaterial };
      latestValidSuggestions = resume.suggestions;
      diagnostics = {
        ...(claimedRun.diagnostics && typeof claimedRun.diagnostics === "object" ? claimedRun.diagnostics : {}),
        stage: "expansion_resume",
        resumedFromRound: resume.startRound,
      };
      const recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>);
      const expanded = await expandNovel(resume.suggestions, recipeObligations, resume.startRound, resume.priorDiagnostics);
      const expandedQuality = validateOutlinePlanningQuality(expanded.suggestions, resumedMaterial, requestedStoryMaterialFormat(body));
      if (expandedQuality.distinctnessIssues.length > 0) {
        throw new Error(`expanded outline failed dramatic distinctness validation: ${expandedQuality.distinctnessIssues[0]}`);
      }
      const coverage = obligationCoverage([...(body.existingSections ?? []), ...expanded.suggestions], recipeObligations);
      if (coverage.missingRequired.length > 0) {
        throw new RecipeObligationValidationError(
          `required recipe obligations remain uncovered: ${coverage.missingRequired.map((obligation) => obligation.id).join(", ")}`,
        );
      }
      const finalScale = evaluateNovelScale(expanded.suggestions, body.existingSections ?? []);
      diagnostics = {
        ...diagnostics,
        stage: "completed",
        expansionRounds: expanded.diagnostics,
        expansionCheckpoint: buildExpansionCheckpoint(expanded.suggestions, body.existingSections ?? [], expanded.diagnostics),
        novelScale: finalScale,
        finalSectionCounts: countSuggestionsByBeat(expanded.suggestions),
      };
      if (!finalScale.meetsMinimum) {
        throw new NovelScalePlanningError(
          "failed_under_target",
          `Novel outline remains below the ${NOVEL_TARGET_WORDS[0].toLocaleString()}-word minimum at completion.`,
        );
      }
      await updateRun({
        status: "completed",
        suggestions: expanded.suggestions,
        warnings: expanded.warnings,
        credit_cost_charged: creditCostCharged,
        remaining_credits: remainingCredits,
        completed_at: new Date().toISOString(),
        diagnostics,
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
              parsedMaterial = validateStoryMaterialEnrichment(JSON.parse(content), { allowMissingProvenance: true, recipe: body.recipe });
            } catch (error) {
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
      try {
        generated = await generateEnrichment("story-material-enrichment");
      } catch (error) {
        if (error instanceof StoryMaterialSufficiencyError) {
          enrichmentDiagnostics = { ...enrichmentDiagnostics, repairAttempted: true, firstPassSufficiencyReasons: error.reasons };
          generated = await generateEnrichment("story-material-enrichment-repair");
        } else if (error instanceof StoryMaterialValidationError) {
          enrichmentDiagnostics = { ...enrichmentDiagnostics, repairAttempted: true, firstPassValidationError: error.message };
          generated = await generateEnrichment("story-material-enrichment-repair", undefined, error.message);
        } else {
          throw error;
        }
      }
      storyMaterial = generated.material;
      const sufficiency = storyMaterialSufficiency(storyMaterial, body.recipe, requestedStoryMaterialFormat(body));
      enrichmentDiagnostics = { ...enrichmentDiagnostics, generatedOrReused: "generated", enrichmentCreditCostCharged: generated.result.creditCostCharged, schemaVersion: storyMaterial.version, sufficiency: sufficiency.sufficient ? "sufficient" : "insufficient", sufficiencyReasons: sufficiency.reasons, itemCountsByCategory: sufficiency.counts, recipeDerivedItemCount: sufficiency.recipeDerivedItemCount, plannerInventedItemCount: sufficiency.plannerInventedItemCount };
      await updateRun({ story_material: storyMaterial, diagnostics: { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_complete" } });
    }
    if (!storyMaterial) throw new Error("story material enrichment was not produced");
    await updateRun({
      story_material: storyMaterial,
      diagnostics: { ...diagnostics, ...enrichmentDiagnostics, stage: "story_material_ready" },
    });
    await persistEnrichmentProvenance(db, body, runId, storyMaterial, provenance);
    body = { ...body, storyMaterialEnrichment: storyMaterial };
    const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
    const recipeObligations = deriveRecipeObligations(body.recipe as unknown as Record<string, unknown>);
    const plannedAllocation = await planSectionAllocation(
      body,
      openaiKey,
      billableCall,
    );
    const allocation = adjustAllocationForExistingSections(plannedAllocation, body.existingSections);
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
    const responseSchema = buildSuggestionResponseSchema(body.arcTemplate.beats, allocation, recipeObligations);
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
          const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations);
          const merged = mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), validated.suggestions, []);
          if (merged.length > MAX_PLANNED_SECTIONS) {
            throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
          }
          return validated;
        },
      );
      const flattened = flattenSuggestionResponse(JSON.parse(rawResponse.content), body.arcTemplate.beats);
      const validated = validateSuggestions(flattened, beatIds, allocation, recipeObligations);
      result = { suggestions: mergeSuggestionsByBeatOrder(body.arcTemplate.beats.map((beat) => beat.id), validated.suggestions, []), warnings: validated.warnings };
      diagnostics = { ...diagnostics, stage: "outline_validated", firstPassParsedCounts: countSuggestionsByBeat(result.suggestions), firstPassValidatedCounts: countSuggestionsByBeat(result.suggestions) };
      if (result.suggestions.length > MAX_PLANNED_SECTIONS) {
        throw new Error(`outline exceeded global ${MAX_PLANNED_SECTIONS}-section safety cap`);
      }
    }

    const initialQuality = validateOutlinePlanningQuality(result.suggestions, storyMaterial, requestedStoryMaterialFormat(body));
    diagnostics = {
      ...diagnostics,
      sectionContractValidated: true,
      dramaticDistinctnessIssues: initialQuality.distinctnessIssues,
      causalScaleIssues: initialQuality.causalScaleIssues,
      unusedStoryMaterialItems: initialQuality.unusedStoryMaterialItems,
    };
    if (initialQuality.distinctnessIssues.length > 0) {
      throw new Error(`outline failed dramatic distinctness validation: ${initialQuality.distinctnessIssues[0]}`);
    }

    let coverage = obligationCoverage([...(body.existingSections ?? []), ...result.suggestions], recipeObligations);
    diagnostics = {
      ...diagnostics,
      recipeObligationCoverage: coverage.covered,
      missingRequiredRecipeObligations: coverage.missingRequired.map((obligation) => obligation.id),
    };
    if (coverage.missingRequired.length > 0) {
      result = {
        ...result,
        suggestions: await repairRecipeObligations(body, result.suggestions, beatIds, recipeObligations, billableCall),
      };
      coverage = obligationCoverage([...(body.existingSections ?? []), ...result.suggestions], recipeObligations);
      diagnostics = {
        ...diagnostics,
        recipeObligationCoverageAfterRepair: coverage.covered,
        missingRequiredRecipeObligationsAfterRepair: coverage.missingRequired.map((obligation) => obligation.id),
      };
      if (coverage.missingRequired.length > 0) {
        throw new RecipeObligationValidationError(
          `required recipe obligations remain uncovered: ${coverage.missingRequired.map((obligation) => obligation.id).join(", ")}`,
        );
      }
    }

    // Expand progressively in bounded rounds. Every round is additive and starts
    // from the complete valid outline produced so far. The checkpoint is written
    // before the first expansion call and after every accepted round.
    if (requestedStoryMaterialFormat(body) === "novel" && needsNovelExpansion(result.suggestions, body.existingSections ?? [])) {
      latestValidSuggestions = result.suggestions;
      const initialScale = evaluateNovelScale(result.suggestions, body.existingSections ?? []);
      const initialCheckpoint = buildExpansionCheckpoint(result.suggestions, body.existingSections ?? [], []);
      diagnostics = {
        ...diagnostics,
        stage: "expansion_checkpoint",
        expansionRounds: [],
        expansionCheckpoint: initialCheckpoint,
        novelScale: initialScale,
      };
      await updateRun({ suggestions: result.suggestions, diagnostics });
      const expanded = await expandNovel(result.suggestions, recipeObligations);
      result = { suggestions: expanded.suggestions, warnings: [...result.warnings, ...expanded.warnings] };
      const expandedQuality = validateOutlinePlanningQuality(result.suggestions, storyMaterial, requestedStoryMaterialFormat(body));
      diagnostics = { ...diagnostics, stage: "expansion_complete", expansionRounds: expanded.diagnostics, finalSectionCounts: countSuggestionsByBeat(result.suggestions), dramaticDistinctnessIssues: expandedQuality.distinctnessIssues, causalScaleIssues: expandedQuality.causalScaleIssues, unusedStoryMaterialItems: expandedQuality.unusedStoryMaterialItems, novelScale: evaluateNovelScale(result.suggestions, body.existingSections ?? []) };
      if (expandedQuality.distinctnessIssues.length > 0) {
        throw new Error(`expanded outline failed dramatic distinctness validation: ${expandedQuality.distinctnessIssues[0]}`);
      }
    }
    coverage = obligationCoverage([...(body.existingSections ?? []), ...result.suggestions], recipeObligations);
    if (coverage.missingRequired.length > 0) {
      throw new RecipeObligationValidationError(
        `required recipe obligations remain uncovered: ${coverage.missingRequired.map((obligation) => obligation.id).join(", ")}`,
      );
    }
    if (requestedStoryMaterialFormat(body) === "novel") {
      const finalScale = evaluateNovelScale(result.suggestions, body.existingSections ?? []);
      diagnostics = {
        ...diagnostics,
        novelScale: finalScale,
      };
      if (!finalScale.meetsMinimum) {
        throw new NovelScalePlanningError(
          "failed_under_target",
          `Novel outline remains below the ${NOVEL_TARGET_WORDS[0].toLocaleString()}-word minimum at completion.`,
        );
      }
    }
    await updateRun({
      status: "completed",
      suggestions: result.suggestions,
      warnings: result.warnings,
      credit_cost_charged: creditCostCharged,
      remaining_credits: remainingCredits,
      completed_at: new Date().toISOString(),
      diagnostics: { ...diagnostics, stage: "completed", finalSectionCounts: countSuggestionsByBeat(result.suggestions) },
      lease_owner: null,
      lease_expires_at: null,
    });
  } catch (err) {
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
  const validationError = validateRequest(body);
  if (validationError) {
    return errorResponse("invalid_request", validationError, 400);
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
  const db = admin();
  const identity = await logicalSuggestionIdentity(body);
  const insert = await db.from("outline_suggestion_runs").insert({
    user_id: user.id,
    project_id: body.recipe.project.id,
    idempotency_key: identity.key,
    request_fingerprint: identity.fingerprint,
    request_json: body,
    status: "pending",
  }).select("id, status, created_at, updated_at, suggestions, warnings, error_code, error, credit_cost_charged, remaining_credits, request_json").maybeSingle();

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
    if (stale || resumableExpansionFailure) {
      const reclaimQuery = db.from("outline_suggestion_runs").update({
        status: "pending",
        error_code: null,
        error: null,
        completed_at: null,
        lease_owner: null,
        lease_expires_at: null,
        attempt_count: (run.attempt_count ?? 0) + 1,
      }).eq("id", run.id).eq("status", run.status);
      const reclaimed = stale
        ? await reclaimQuery.eq("lease_expires_at", run.lease_expires_at)
        : await reclaimQuery;
      if (!reclaimed.error) run.status = "pending";
    }
  }
  if (!run) {
    return errorResponse("db_error", "Could not create or resolve suggestion run", 500);
  }
  // A pending duplicate may be the only way to restart a worker lost during
  // suspension. The pending claim inside runSuggestionJob makes this race-safe.
  if (run.status === "pending") {
    // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
    EdgeRuntime.waitUntil(runSuggestionJob(run.id, body, user.id, openaiKey, run.attempt_count ?? 0));
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
