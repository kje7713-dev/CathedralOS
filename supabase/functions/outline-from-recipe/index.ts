import { createClient } from "jsr:@supabase/supabase-js@2";
import { runBillableLLM } from "../_shared/billable-llm.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { SupabaseGenerationModelStore } from "../generate-story/_generation_models.ts";
import {
  type LLMMessage,
  OpenAIProvider,
} from "../generate-story/_provider.ts";

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

// JSON Schema for the structured output. gpt-4o-mini supports structured output
// with strict: true; this enforces shape + enum + length bounds server-side.
const RESPONSE_SCHEMA = {
  "type": "object",
  "properties": {
    "suggestions": {
      "type": "array",
      "minItems": 0,
      "maxItems": 100,
      "items": {
        "type": "object",
        "properties": {
          "title": { "type": "string", "minLength": 1, "maxLength": 120 },
          "summary": { "type": "string", "minLength": 1, "maxLength": 2000 },
          "container": {
            "type": "string",
            "enum": [
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
            ],
          },
          "pov": {
            "type": "string",
            "enum": [
              "firstPerson",
              "secondPerson",
              "thirdPersonLimited",
              "thirdPersonOmniscient",
            ],
          },
          "terminalBeat": {
            "type": "string",
            "minLength": 1,
            "maxLength": 500,
          },
          "storyArcBeatID": { "type": "string" },
        },
        "required": [
          "title",
          "summary",
          "container",
          "pov",
          "terminalBeat",
          "storyArcBeatID",
        ],
        "additionalProperties": false,
      },
    },
  },
  "required": ["suggestions"],
  "additionalProperties": false,
} as const;

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
}

interface ExistingSectionBlob {
  title?: string;
  summary?: string;
  container?: string;
  pov?: string;
  terminalBeat?: string;
  storyArcBeatID?: string; // null for manual/free-form sections
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
) => Promise<SuggestionLLMResult>;

interface Suggestion {
  title: string;
  summary: string;
  container: string;
  pov: string;
  terminalBeat: string;
  storyArcBeatID: string;
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
  if (
    r.arcTemplate.beats.some((beat) =>
      !beat || typeof beat.id !== "string" || beat.id.trim() === ""
    )
  ) {
    return "arcTemplate.beats must have non-empty ids";
  }
  return null;
}

export function buildPrompt(
  req: OutlineFromRecipeRequest,
  allocation: Map<string, { count: number; rationale: string }>,
): { system: string; user: string } {
  const allocationLines = Array.from(allocation.entries())
    .map(([beatId, info]) => {
      const beat = req.arcTemplate.beats.find((b) => b.id === beatId);
      return `- ${
        beat?.label ?? beatId
      }: ${info.count} sections (${info.rationale})`;
    })
    .join("\n");

  const system =
    `You are an expert novel outliner. Use the complete canonical recipe/project payload below, including its premise, selected characters and their populated fields, selected relationships, themes, motifs, story spark, aftertaste, recipe instructions, and included setting. Treat supplied facts as authoritative; do not infer personality traits from a character name alone. Given the story arc and per-beat allocation plan, produce the section-by-section outline.

## Use the allocation plan exactly

For each beat, generate EXACTLY the allocated number of distinct sections - no fewer, no more. A beat allocated 0 is already covered and must produce no new suggestion. Each generated section must advance the story with a new event, consequence, decision, or revelation rather than paraphrasing an existing or generated section.

${allocationLines}

${
      req.existingSections && req.existingSections.length > 0
        ? `Existing sections already in this outline (do not duplicate; build forward from them where natural):
${
          req.existingSections.map((s) =>
            `- "${s.title ?? "(untitled)"}" (${s.container ?? "scene"}, ${
              s.pov ?? "thirdPersonLimited"
            }): ${s.summary ?? ""}`
          ).join("\n")
        }\n\n`
        : ""
    }Respond with structured JSON matching the schema.`;
  const user = JSON.stringify(
    {
      recipe: req.recipe,
      arcTemplate: req.arcTemplate,
      hint: req.hint ?? null,
    },
    null,
    2,
  );

  return { system, user };
}

// Stage 1: planner. Decides how many sections each arc beat deserves
// before the generation call runs. The response is strict and validated so a
// malformed planner response can never silently become three sections/beat.
const ALLOCATION_SCHEMA = {
  type: "object",
  properties: {
    allocations: {
      type: "array",
      minItems: 0,
      maxItems: 100,
      items: {
        type: "object",
        properties: {
          beatID: { type: "string", minLength: 1 },
          sectionCount: { type: "integer", minimum: 0, maximum: 10 },
          rationale: { type: "string", minLength: 1, maxLength: 500 },
        },
        required: ["beatID", "sectionCount", "rationale"],
        additionalProperties: false,
      },
    },
  },
  required: ["allocations"],
  additionalProperties: false,
} as const;

type Allocation = { count: number; rationale: string };

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
      !["beatID", "sectionCount", "rationale"].includes(key)
    );
    if (unexpectedKeys.length > 0) {
      throw new Error(
        `allocation contains unexpected field(s): ${unexpectedKeys.join(", ")}`,
      );
    }
    const beatID = candidate.beatID;
    const count = candidate.sectionCount;
    const rationale = candidate.rationale;
    if (typeof beatID !== "string" || !validBeatIDs.has(beatID)) {
      throw new Error(`allocation contains unknown beatID: ${String(beatID)}`);
    }
    if (seen.has(beatID)) {
      throw new Error(`allocation contains duplicate beatID: ${beatID}`);
    }
    if (!Number.isInteger(count) || Number(count) < 0 || Number(count) > 10) {
      throw new Error(`allocation has invalid sectionCount for beat ${beatID}`);
    }
    if (typeof rationale !== "string" || rationale.trim() === "") {
      throw new Error(`allocation has missing rationale for beat ${beatID}`);
    }
    seen.add(beatID);
    out.set(beatID, { count: Number(count), rationale });
  }
  if (out.size !== validBeatIDs.size) {
    const missing = beats.filter((beat) => !seen.has(beat.id)).map((beat) =>
      beat.id
    );
    throw new Error(`allocation is missing beat(s): ${missing.join(", ")}`);
  }
  const total = Array.from(out.values()).reduce(
    (sum, item) => sum + item.count,
    0,
  );
  if (total < 0 || total > 100) {
    throw new Error(`allocation total is not sensible: ${total}`);
  }
  return new Map(beats.map((beat) => [beat.id, out.get(beat.id)!]));
}

export function buildAllocationPrompt(
  req: OutlineFromRecipeRequest,
): { system: string; user: string } {
  const system =
    `You are an expert novel outliner. Given a complete canonical recipe/project payload and a story arc template (ordered beats), decide how many outline sections each beat deserves in this particular novel.

Some beats are quick transitions (1-2 sections). Some are major movements unfolding across many scenes (5-10+ sections). The same arc template produces very different outlines for different recipes. Let the supplied premise, characters, and arc determine density; do not expand merely because the output is called a novel.

For each beat, output exactly one JSON object with beatID matching the supplied UUID exactly, sectionCount as an integer from 0 through 10, and a concise rationale. Include every beat exactly once, including beats with sectionCount 0. A beat sufficiently covered by existing sections may receive 0; an uncovered beat in an empty outline should receive 1 or more when the story needs it. Do not output any other root key. The total may be short or long; do not target a fixed total.

Output JSON only. No commentary, no prose.`;

  const user = JSON.stringify(
    {
      recipe: req.recipe,
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
              schema: options?.jsonSchema ?? RESPONSE_SCHEMA,
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

export function validateSuggestions(
  parsed: any,
  beatIds: Set<string>,
  allocation?: Map<string, Allocation>,
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
    valid.push({
      title: String(s.title).slice(0, 200),
      summary: String(s.summary).slice(0, 4000),
      container: s.container,
      pov: s.pov,
      terminalBeat: String(s.terminalBeat).slice(0, 1000),
      storyArcBeatID: s.storyArcBeatID,
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
      if (actual !== plan.count) {
        throw new Error(
          `outline generation returned ${actual} sections for beat ${beatID}; expected ${plan.count}`,
        );
      }
    }
    const expectedTotal = Array.from(allocation.values())
      .filter((plan) => plan.count > 0)
      .reduce((sum, plan) => sum + plan.count, 0);
    if (valid.length !== expectedTotal) {
      throw new Error(
        "outline generation count does not equal allocation total",
      );
    }
  } else {
    // Backward-compatible validation for callers that do not have a plan.
    for (const bid of beatIds) {
      if (!used.has(bid)) warnings.push(`no suggestion references beat ${bid}`);
    }
  }
  return { suggestions: valid, warnings };
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

async function runSuggestionJob(
  runId: string,
  body: OutlineFromRecipeRequest,
  userId: string,
  openaiKey: string,
): Promise<void> {
  const db = admin();
  await db.from("outline_suggestion_runs").update({ status: "running" }).eq(
    "id",
    runId,
  );
  try {
    const modelStore = new SupabaseGenerationModelStore(db);
    const model = await modelStore.getEnabledModelById(OPENAI_MODEL);
    if (!model) {
      throw new Error(`Enabled billing model not found: ${OPENAI_MODEL}`);
    }
    const creditStore = new SupabaseCreditStore(db);
    const provider = new OpenAIProvider(openaiKey, OPENAI_MODEL);
    let creditCostCharged = 0;
    let remainingCredits: number | null = null;
    const persistBilling = async (
      result: {
        actualCharge: number;
        charged: boolean;
        remainingCredits: number;
      },
    ) => {
      if (result.charged) creditCostCharged += result.actualCharge;
      remainingCredits = result.remainingCredits;
      await db.from("outline_suggestion_runs").update({
        credit_cost_charged: creditCostCharged,
        remaining_credits: remainingCredits,
      }).eq("id", runId);
    };
    const billableCall: SuggestionLLMCall = async (
      system,
      user,
      maxOutputTokens,
      responseFormat,
      action,
    ) => {
      const messages: LLMMessage[] = [
        { role: "system", content: system },
        { role: "user", content: user },
      ];
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
        onProviderSuccess: async (providerResult) => providerResult.content,
      }, { adminClient: db, provider, creditStore });
      await persistBilling(result);
      return {
        content: result.featureResult,
        creditCostCharged: result.charged ? result.actualCharge : 0,
        remainingCredits: result.remainingCredits,
      };
    };

    const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
    const allocation = await planSectionAllocation(
      body,
      openaiKey,
      billableCall,
    );
    const { system, user: userPrompt } = buildPrompt(body, allocation);
    const responseFormat = {
      type: "json_schema",
      json_schema: {
        name: "outline_suggestions",
        strict: true,
        schema: RESPONSE_SCHEMA,
      },
    };
    let result: { suggestions: Suggestion[]; warnings: string[] } | undefined;
    const expectedTotal = Array.from(allocation.values())
      .reduce((sum, plan) => sum + plan.count, 0);
    let generationError: Error | undefined;
    if (expectedTotal === 0) {
      result = { suggestions: [], warnings: [] };
    }
    for (const correction of expectedTotal === 0 ? [] : [false, true]) {
      const correctionSystem = correction
        ? `${system}\n\nThe previous response failed validation: ${
          generationError?.message ?? "it did not satisfy the allocation"
        }. Return a complete corrected response. Recount the suggestions for every beat before responding. Do not omit, merge, or add sections; a beat allocated 0 must still have no suggestions.`
        : system;
      const rawResponse = await billableCall(
        correctionSystem,
        userPrompt,
        16000,
        responseFormat,
        correction ? "outline-suggestions-retry" : "outline-suggestions",
      );
      const parsed = JSON.parse(rawResponse.content);
      try {
        result = validateSuggestions(parsed, beatIds, allocation);
        break;
      } catch (error) {
        if (!(error instanceof Error)) throw error;
        generationError = error;
        // Retry only validation failures. Provider and JSON errors retain their
        // existing failure behavior and must not trigger another charge.
        if (correction) throw error;
      }
    }
    if (!result) {
      throw generationError ?? new Error("outline generation failed");
    }
    await db.from("outline_suggestion_runs").update({
      status: "completed",
      suggestions: result.suggestions,
      warnings: result.warnings,
      credit_cost_charged: creditCostCharged,
      remaining_credits: remainingCredits,
      completed_at: new Date().toISOString(),
    }).eq("id", runId);
  } catch (err) {
    const errorCode = err && typeof err === "object" && "code" in err
      ? String((err as { code?: unknown }).code)
      : (err instanceof Error &&
          /insufficient credits|requires ~|you have/i.test(err.message)
        ? "insufficient_credits"
        : (err instanceof Error && /openai|provider/i.test(err.message)
          ? "provider_error"
          : "server_error"));
    const message = err instanceof Error ? err.message : String(err);
    await db.from("outline_suggestion_runs").update({
      status: "failed",
      error_code: errorCode,
      error: message.slice(0, 2000),
      completed_at: new Date().toISOString(),
    }).eq("id", runId);
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
    const runId = new URL(req.url).searchParams.get("run_id");
    if (!runId) {
      return errorResponse("missing_param", "run_id query param required", 400);
    }
    const { data: run, error } = await userClient.from(
      "outline_suggestion_runs",
    )
      .select(
        "id, status, suggestions, warnings, error_code, error, created_at, updated_at, completed_at, credit_cost_charged, remaining_credits",
      )
      .eq("id", runId).single();
    if (error) {
      console.error("[outline-from-recipe] polling query failed", error);
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
        created_at: run.created_at,
        updated_at: run.updated_at,
        completed_at: run.completed_at,
        creditCostCharged: run.credit_cost_charged,
        remainingCredits: run.remaining_credits,
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
  const { data: run, error } = await db.from("outline_suggestion_runs").insert({
    user_id: user.id,
    request_json: body,
    status: "pending",
  }).select("id, created_at, updated_at").single();
  if (error || !run) {
    return errorResponse(
      "db_error",
      error?.message ?? "Could not create suggestion run",
      500,
    );
  }
  // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
  EdgeRuntime.waitUntil(runSuggestionJob(run.id, body, user.id, openaiKey));
  return corsResponse(
    JSON.stringify({
      run_id: run.id,
      status: "pending",
      created_at: run.created_at,
      updated_at: run.updated_at,
    }),
    { status: 202 },
  );
});
