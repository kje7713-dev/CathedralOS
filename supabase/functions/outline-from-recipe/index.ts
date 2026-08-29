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
// Takes a recipe (PromptPack-shaped) + arc template (StoryArcTemplate-shaped),
// returns 5-15 suggested OutlineSection payloads.
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
//     "recipe": { id, name, characters[], storySpark|null, aftertaste|null,
//                 themes[], motifs[], notes? },
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
      "minItems": 5,
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
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RecipeBlob {
  id: string;
  name: string;
  characters?: Array<{ id: string; name: string; summary?: string }>;
  storySpark?: {
    id: string;
    title: string;
    situation?: string;
    stakes?: string;
  } | null;
  aftertaste?: { id: string; label: string; note?: string } | null;
  themes?: Array<{ id: string; question: string; coreTension?: string }>;
  motifs?: Array<{ id: string; label: string; meaning?: string }>;
  notes?: string;
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
  recipe: RecipeBlob;
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

type SuggestionLLMCall = (
  system: string,
  user: string,
  maxOutputTokens: number,
  responseFormat: unknown,
  action: string,
) => Promise<string>;

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

function validateRequest(req: unknown): string | null {
  if (!req || typeof req !== "object") return "request must be an object";
  const r = req as Partial<OutlineFromRecipeRequest>;
  if (!r.recipe?.id || !r.recipe?.name) {
    return "recipe.id and recipe.name required";
  }
  if (
    !r.arcTemplate?.id || !Array.isArray(r.arcTemplate.beats) ||
    r.arcTemplate.beats.length === 0
  ) {
    return "arcTemplate.id and non-empty arcTemplate.beats required";
  }
  return null;
}

function buildPrompt(
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
    `You are an expert novel outliner. Given a recipe (curated characters, sparks, themes, motifs), a story arc template (ordered beats), and a per-beat section allocation plan, produce a novel outline — the section-by-section blueprint a writer would actually draft over many chapters.

## Use the allocation plan exactly

This particular novel has been planned with the following per-beat allocation. For each beat, generate EXACTLY the allocated number of sections — no fewer, no more:

${allocationLines}

Each section should be a distinct scene/chapter within its beat, exploring different moments, characters, or sub-events.

${
      req.existingSections && req.existingSections.length > 0
        ? `Existing sections already in this outline (DO NOT duplicate — build on them where natural; prefer beats without existing sections):
${
          req.existingSections.map((s) =>
            `- "${s.title ?? "(untitled)"}" (${s.container ?? "scene"}, ${
              s.pov ?? "thirdPersonLimited"
            }): ${s.summary ?? ""}`
          ).join("\n")
        }

`
        : ""
    }Distribute the arc beats across the suggestions — every beat should appear in at least one suggestion's storyArcBeatID. Skip beats already covered by an existing section if possible. You may reuse beats across suggestions if multiple sections handle the same beat from different angles.

Respond with structured JSON matching the schema.`;

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
// before the generation call runs. Output is a per-beat allocation
// that the buildPrompt step consumes as context. Keeps the model from
// defaulting to one-section-per-beat when called cold.
async function planSectionAllocation(
  req: OutlineFromRecipeRequest,
  apiKey: string,
  billableCall?: SuggestionLLMCall,
): Promise<Map<string, { count: number; rationale: string }>> {
  const system =
    `You are an expert novel outliner. Given a recipe (curated characters, sparks, themes, motifs) and a story arc template (ordered beats), decide how many outline sections each beat deserves in this particular novel.

A novel outline is built from many sections per beat. Some beats are quick transitions (1-2 sections). Some are major movements unfolding across many scenes (5-10+ sections). The same arc template produces very different outlines for different recipes — a fast-paced thriller might give 1-2 sections per beat; an intimate literary novel might give 8-10 to major beats.

For each beat, output a JSON object with:
- beatID: the beat's UUID (must match exactly)
- sectionCount: how many outline sections this beat deserves (1-10)
- rationale: one sentence explaining why

Total sections across all beats should be 30-60+ for a novel-length outline.

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
      existingSections: req.existingSections ?? [],
    },
    null,
    2,
  );

  const raw = billableCall
    ? await billableCall(
      system,
      user,
      2048,
      { type: "json_object" },
      "outline-plan",
    )
    : await callOpenAI(system, user, apiKey, {
      maxTokens: 2048,
      useJsonSchema: false,
    });

  let parsed: any = {};
  try {
    parsed = JSON.parse(raw);
  } catch {
    parsed = {};
  }

  const allocations: any[] = Array.isArray(parsed)
    ? parsed
    : Array.isArray(parsed.allocations)
    ? parsed.allocations
    : [];

  const out = new Map<string, { count: number; rationale: string }>();
  for (const beat of req.arcTemplate.beats) {
    const planned = allocations.find((p: any) => p?.beatID === beat.id);
    out.set(beat.id, {
      count: Math.max(1, Math.min(10, Number(planned?.sectionCount) || 3)),
      rationale: String(planned?.rationale ?? "default"),
    });
  }
  return out;
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

function validateSuggestions(
  parsed: any,
  beatIds: Set<string>,
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
  // Soft warning: every supplied beat should be referenced at least once
  for (const bid of beatIds) {
    if (!used.has(bid)) {
      warnings.push(`no suggestion references beat ${bid}`);
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
      return result.featureResult;
    };

    const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
    const allocation = await planSectionAllocation(
      body,
      openaiKey,
      billableCall,
    );
    const { system, user: userPrompt } = buildPrompt(body, allocation);
    const rawResponse = await billableCall(
      system,
      userPrompt,
      16000,
      {
        type: "json_schema",
        json_schema: {
          name: "outline_suggestions",
          strict: true,
          schema: RESPONSE_SCHEMA,
        },
      },
      "outline-suggestions",
    );
    const parsed = JSON.parse(rawResponse);
    const result = validateSuggestions(parsed, beatIds);
    await db.from("outline_suggestion_runs").update({
      status: "completed",
      suggestions: result.suggestions,
      warnings: result.warnings,
      completed_at: new Date().toISOString(),
    }).eq("id", runId);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await db.from("outline_suggestion_runs").update({
      status: "failed",
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
        "id, status, suggestions, warnings, error, created_at, updated_at, completed_at",
      )
      .eq("id", runId).single();
    if (error || !run) return errorResponse("not_found", "run not found", 404);
    return corsResponse(JSON.stringify({ run_id: run.id, ...run }), {
      status: 200,
    });
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
