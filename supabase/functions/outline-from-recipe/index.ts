import { createClient } from 'jsr:@supabase/supabase-js@2'

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
//   OPENAI_MODEL_DEFAULT      — model used (default: gpt-4o-mini, must support structured output)
//   SUPABASE_URL              — Supabase project URL (auto-injected)
//   SUPABASE_ANON_KEY         — Supabase anon key (auto-injected)
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Rate limiting: 5/min, 30/hour per user (uses generation_request_logs).
// Credits: not charged for Phase 2 (suggestions helper, not generation).
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
//   200 { "suggestions": [ { title, summary, container, pov, terminalBeat,
//                            storyArcBeatID }, ... ],
//         "warnings": [...optional] }
//   400 invalid_request — malformed body
//   401 not_authenticated — missing or invalid JWT
//   429 rate_limited — Retry-After header set
//   500 not_configured — server-side OPENAI_API_KEY missing
//   502 provider_error / invalid_response — LLM call failed or returned bad JSON
// =============================================================================

const OPENAI_API_URL = "https://api.openai.com/v1/chat/completions";
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini";

// JSON Schema for the structured output. gpt-4o-mini supports structured output
// with strict: true; this enforces shape + enum + length bounds server-side.
const RESPONSE_SCHEMA = {
  "type": "object",
  "properties": {
    "suggestions": {
      "type": "array",
      "minItems": 5,
      "maxItems": 15,
      "items": {
        "type": "object",
        "properties": {
          "title": { "type": "string", "minLength": 1, "maxLength": 120 },
          "summary": { "type": "string", "minLength": 1, "maxLength": 2000 },
          "container": {
            "type": "string",
            "enum": [
              "beat", "moment", "vignette", "microScene", "scene",
              "developedScene", "setPiece", "sceneSequence",
              "shortStory", "chapter", "episode",
            ],
          },
          "pov": {
            "type": "string",
            "enum": [
              "firstPerson", "secondPerson",
              "thirdPersonLimited", "thirdPersonOmniscient",
            ],
          },
          "terminalBeat": { "type": "string", "minLength": 1, "maxLength": 500 },
          "storyArcBeatID": { "type": "string" },
        },
        "required": ["title", "summary", "container", "pov", "terminalBeat", "storyArcBeatID"],
        "additionalProperties": false,
      },
    },
  },
  "required": ["suggestions"],
  "additionalProperties": false,
} as const;

const ALLOWED_CONTAINERS = new Set([
  "beat", "moment", "vignette", "microScene", "scene",
  "developedScene", "setPiece", "sceneSequence",
  "shortStory", "chapter", "episode",
]);

const ALLOWED_POVS = new Set([
  "firstPerson", "secondPerson",
  "thirdPersonLimited", "thirdPersonOmniscient",
]);

const RATE_LIMIT_PER_MINUTE = 5;
const RATE_LIMIT_PER_HOUR = 30;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
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
  storySpark?: { id: string; title: string; situation?: string; stakes?: string } | null;
  aftertaste?: { id: string; label: string; note?: string } | null;
  themes?: Array<{ id: string; question: string; coreTension?: string }>;
  motifs?: Array<{ id: string; label: string; meaning?: string }>;
  notes?: string;
}

interface ArcTemplateBlob {
  id: string;
  name: string;
  description?: string;
  beats: Array<{ id: string; role: string; label: string; description?: string }>;
}

interface OutlineFromRecipeRequest {
  recipe: RecipeBlob;
  arcTemplate: ArcTemplateBlob;
  hint?: string;
  existingSections?: ExistingSectionBlob[];  // iOS-side outline state at request time
}

interface ExistingSectionBlob {
  title?: string;
  summary?: string;
  container?: string;
  pov?: string;
  terminalBeat?: string;
  storyArcBeatID?: string;  // null for manual/free-form sections
}

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

function errorResponse(code: string, message: string, status: number): Response {
  return corsResponse(JSON.stringify({ errorCode: code, message }), { status });
}

function validateRequest(req: unknown): string | null {
  if (!req || typeof req !== "object") return "request must be an object";
  const r = req as Partial<OutlineFromRecipeRequest>;
  if (!r.recipe?.id || !r.recipe?.name) return "recipe.id and recipe.name required";
  if (!r.arcTemplate?.id || !Array.isArray(r.arcTemplate.beats) || r.arcTemplate.beats.length === 0) {
    return "arcTemplate.id and non-empty arcTemplate.beats required";
  }
  return null;
}

function buildPrompt(req: OutlineFromRecipeRequest): { system: string; user: string } {
  const system = `You are an expert story outliner. Given a recipe (a curated set of characters, sparks, themes, motifs) and a story arc template (ordered beats), produce a comprehensive set of outline sections that fully develops the arc into novel-ready chapters.

For EACH arc beat, produce 3-5 outline sections that explore different angles, sub-steps, or scenes within that beat. A 12-beat Hero\'s Journey should produce roughly 36-60 sections, not 12. Be ambitious — this is a novel outline, not a story sketch.

Each section should:
- Belong primarily to a single arc beat (cite the beat\'s UUID from the supplied arc beats)
- Use the characters, sparks, themes, and motifs from the recipe
- Have a clear container (scene, vignette, chapter, etc.) and POV
- Be a complete dramatic unit with its own climax and resolution
- Be distinct from other sections in the same beat — different scenes, different angles, different moments within the beat\'s arc

Be specific and grounded. Use the characters' voices and the story's genre. Each section summary should be evocative enough to inspire a writer.

${req.existingSections && req.existingSections.length > 0
    ? `Existing sections already in this outline (DO NOT duplicate — build on them where natural; prefer beats without existing sections):
${req.existingSections.map(s => `- "${s.title ?? "(untitled)"}" (${s.container ?? "scene"}, ${s.pov ?? "thirdPersonLimited"}): ${s.summary ?? ""}`).join("\n")}

`
    : ""}Distribute the arc beats across the suggestions — every beat should appear in at least one suggestion's storyArcBeatID. Skip beats already covered by an existing section if possible. You may reuse beats across suggestions if multiple sections handle the same beat from different angles.

Respond with structured JSON matching the schema.`;

  const user = JSON.stringify({
    recipe: req.recipe,
    arcTemplate: req.arcTemplate,
    hint: req.hint ?? null,
  }, null, 2);

  return { system, user };
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
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "outline_suggestions",
            strict: true,
            schema: RESPONSE_SCHEMA,
          },
        },
        max_completion_tokens: 4096,
        temperature: 0.7,
      }),
      signal: ac.signal,
    });
    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`OpenAI API error ${response.status}: ${errText.slice(0, 500)}`);
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
  const perBeatCount = new Map<string, number>();
  const valid: Suggestion[] = [];
  for (const s of parsed.suggestions) {
    if (!s?.title || !s?.summary) {
      warnings.push("dropped suggestion with missing title/summary");
      continue;
    }
    if (!ALLOWED_CONTAINERS.has(s.container)) {
      warnings.push(`dropped suggestion with invalid container: ${s.container}`);
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
      warnings.push(`dropped suggestion with unknown beat id: ${s.storyArcBeatID}`);
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
    perBeatCount.set(s.storyArcBeatID, (perBeatCount.get(s.storyArcBeatID) ?? 0) + 1);
  }
  // Per-beat coverage check: every supplied beat should have 3+ sections.
  // Hard-warn on 0 (beat missing), soft-warn on 1-2 (beat underdeveloped).
  for (const bid of beatIds) {
    const count = perBeatCount.get(bid) ?? 0;
    if (count === 0) {
      warnings.push(`no suggestion references beat ${bid}`);
    } else if (count < 3) {
      warnings.push(`beat ${bid} only has ${count} section(s) — aim for 3+`);
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST only", 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return errorResponse("not_authenticated", "Missing Authorization header", 401);

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey) return errorResponse("not_configured", "OPENAI_API_KEY missing", 500);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!supabaseUrl || !supabaseAnonKey) {
    return errorResponse("not_configured", "Supabase URL or anon key missing", 500);
  }

  let body: OutlineFromRecipeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }
  const validationError = validateRequest(body);
  if (validationError) return errorResponse("invalid_request", validationError, 400);

  const supabase = makeSupabase(supabaseUrl, supabaseAnonKey, authHeader);

  const { data: { user }, error: authErr } = await supabase.auth.getUser();
  if (authErr || !user) {
    return errorResponse("not_authenticated", "Invalid token", 401);
  }

  const rateResult = await checkRateLimit(supabase, user.id);
  if (!rateResult.allowed) {
    await logRequest(supabase, user.id, "rate_limited", "rate_limited");
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

  const beatIds = new Set(body.arcTemplate.beats.map((b) => b.id));
  const { system, user: userPrompt } = buildPrompt(body);

  let rawResponse: string;
  try {
    rawResponse = await callOpenAI(system, userPrompt, openaiKey);
  } catch (err) {
    await logRequest(supabase, user.id, "failed", "provider_error");
    return errorResponse("provider_error", String(err), 502);
  }

  let parsed: any;
  try {
    parsed = JSON.parse(rawResponse);
  } catch {
    await logRequest(supabase, user.id, "failed", "invalid_response");
    return errorResponse("invalid_response", "Could not parse LLM response", 502);
  }

  let result: { suggestions: Suggestion[]; warnings: string[] };
  try {
    result = validateSuggestions(parsed, beatIds);
  } catch (err) {
    await logRequest(supabase, user.id, "failed", "invalid_response");
    return errorResponse("invalid_response", String(err), 502);
  }

  await logRequest(supabase, user.id, "success");

  return corsResponse(
    JSON.stringify({
      suggestions: result.suggestions,
      warnings: result.warnings.length > 0 ? result.warnings : undefined,
    }),
    { status: 200 },
  );
});
