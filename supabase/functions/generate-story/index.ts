// =============================================================================
// index.ts — generate-story Supabase Edge Function
//
// Accepts an authenticated generation request from the iOS app, calls the
// configured LLM provider server-side, persists the output and a usage event
// to Postgres, and returns the generated text to the client.
//
// Secrets required (set via `supabase secrets set`):
//   OPENAI_API_KEY            — OpenAI secret key
//   OPENAI_MODEL_DEFAULT      — model used for normal generation (default: gpt-4o-mini)
//   OPENAI_MODEL_PREMIUM      — (optional) reserved for future premium tier
//   SUPABASE_SERVICE_ROLE_KEY — Supabase service-role key (auto-injected in Edge Functions)
//
// Request safety:
//   Requests are validated and rate-limited before any LLM call is made.
//   Payload size limits and per-user rate limits are enforced server-side.
//
// Credit enforcement:
//   Credit cost is computed server-side from generationLengthMode.
//   Client-submitted cost values are IGNORED.
//   Insufficient credits → 402 with errorCode "insufficient_credits".
//   Credits are charged ONLY after a successful LLM response has been
//   persisted to generation_outputs.
//   A failed LLM call or persistence error does NOT charge credits.
//
// Rate limiting (per user, rolling windows):
//   5  requests / minute
//   30 requests / hour
//   20 failed requests / hour (anti-abuse)
//   Exceeded limit → 429 with errorCode "rate_limited" + retryAfterSeconds.
//
// Provider timeout:
//   OpenAI calls are aborted after PROVIDER_TIMEOUT_MS (90 s). A timed-out
//   request returns errorCode "provider_timeout" and does NOT charge credits.
//
// Observability:
//   Every request is logged to generation_request_logs (no raw prompt text).
//   The log row is written after the response is determined.
//
// Retry policy:
//   No automatic retries are performed server-side. Retrying a failed long
//   generation would risk double-charging credits. The client may retry on
//   transient errors (provider_timeout, provider_overloaded) using the
//   retryAfterSeconds hint when present.
//
// NEVER place any of these values in the iOS app or commit them to source
// control. See docs/generate-story-edge-function.md for setup instructions.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildProviderFromEnv, LLMProvider, ProviderError, PROVIDER_TIMEOUT_MS } from "./_provider.ts";
import {
  ALLOWED_LENGTH_MODES,
  type LengthMode,
  checkCredits,
  SupabaseCreditStore,
  type CreditStore,
} from "./_credits.ts";
import {
  SupabaseRateLimitStore,
  type RateLimitStore,
} from "./_rate_limiter.ts";
import {
  computeActualCharge,
  computeEstimatedCharge,
  estimateTokensFromText,
  normalizedModelId,
  SupabaseGenerationModelStore,
  type GenerationModelStore,
} from "./_generation_models.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const ALLOWED_ACTIONS = ["generate", "regenerate", "continue", "remix"] as const;
type GenerationAction = typeof ALLOWED_ACTIONS[number];

const MAX_BUDGET: Record<LengthMode, number> = {
  short: 800,
  medium: 1600,
  long: 3000,
  chapter: 6000,
};

/** Maximum allowed character length for sourcePayloadJSON (50 KB). */
export const MAX_SOURCE_PAYLOAD_CHARS = 50_000;

/** Maximum allowed character length for previousOutputText (20 KB). */
export const MAX_PREVIOUS_OUTPUT_CHARS = 20_000;

// ---------------------------------------------------------------------------
// CORS headers — allow the Supabase iOS client to call this function
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsResponse(body: string, init: ResponseInit = {}): Response {
  return new Response(body, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...(init.headers ?? {}),
    },
  });
}

function providerErrorResponse(providerErrorCode: string, fallbackMessage: string): {
  httpStatus: number;
  body: Record<string, string | number | null>;
  headers?: Record<string, string>;
} {
  switch (providerErrorCode) {
    case "provider_insufficient_quota":
      return {
        httpStatus: 402,
        body: {
          status: "failed",
          errorCode: "provider_insufficient_quota",
          errorMessage:
            "The generation provider account has no available API quota. Check OpenAI billing, usage limits, or project budget.",
          retryAfterSeconds: null,
        },
      };
    case "provider_rate_limited":
      return {
        httpStatus: 429,
        body: {
          status: "failed",
          errorCode: "provider_rate_limited",
          errorMessage:
            "The generation provider is rate limited. Please try again shortly.",
          retryAfterSeconds: 60,
        },
        headers: { "Retry-After": "60" },
      };
    case "provider_timeout":
      return {
        httpStatus: 504,
        body: {
          status: "failed",
          errorCode: "provider_timeout",
          errorMessage:
            "The generation service took too long to respond. Please try again.",
        },
      };
    default:
      return {
        httpStatus: 502,
        body: {
          status: "failed",
          errorCode: providerErrorCode,
          errorMessage: `Generation failed: ${fallbackMessage}`,
        },
      };
  }
}

// ---------------------------------------------------------------------------
// Request body type
// ---------------------------------------------------------------------------

interface GenerateStoryRequest {
  projectName?: string;
  promptPackName?: string;
  sourcePayloadJSON: unknown; // object or JSON string
  generationAction: string;
  generationLengthMode: string;
  outputBudget: number;
  selectedModelId?: string;
  previousOutputText?: string;
  readingLevel?: string;
  contentRating?: string;
  audienceNotes?: string;
  localGenerationID?: string;
}

interface GenerationOutputInsert {
  user_id: string;
  local_generation_id: string | null;
  project_name: string;
  prompt_pack_name: string;
  title: string;
  output_text: string;
  source_payload_json: unknown;
  model_name: string;
  generation_action: GenerationAction;
  generation_length_mode: LengthMode;
  output_budget: number;
  status: "complete" | "draft";
  visibility: "private";
}

interface GenerationUsageEventInsert {
  user_id: string;
  generation_output_id: string | null;
  action: GenerationAction;
  model_name: string;
  input_tokens: number | null;
  output_tokens: number | null;
  generation_length_mode: LengthMode;
  output_budget: number;
  status: "complete" | "failed";
}

interface GenerationPersistenceStore {
  insertOutput(
    row: GenerationOutputInsert,
  ): Promise<{ data: { id: string } | null; error: unknown | null }>;
  insertUsageEvent(
    row: GenerationUsageEventInsert,
  ): Promise<{ error: unknown | null }>;
}

class SupabaseGenerationPersistenceStore implements GenerationPersistenceStore {
  // deno-lint-ignore no-explicit-any
  private readonly db: any;

  // deno-lint-ignore no-explicit-any
  constructor(adminClient: any) {
    this.db = adminClient;
  }

  insertOutput(
    row: GenerationOutputInsert,
  ): Promise<{ data: { id: string } | null; error: unknown | null }> {
    return this.db
      .from("generation_outputs")
      .insert(row)
      .select("id")
      .single();
  }

  async insertUsageEvent(
    row: GenerationUsageEventInsert,
  ): Promise<{ error: unknown | null }> {
    const { error } = await this.db.from("generation_usage_events").insert(row);
    return { error };
  }
}

interface HandlerDependencies {
  provider?: LLMProvider;
  creditStore?: CreditStore;
  rateLimitStore?: RateLimitStore;
  generationModelStore?: GenerationModelStore;
  authenticatedUserId?: string;
  persistenceStore?: GenerationPersistenceStore;
}

// ---------------------------------------------------------------------------
// Prompt builder
// ---------------------------------------------------------------------------

// Loose structural type for the decoded PromptPackExportPayload.
// All fields are optional so the prompt builder degrades gracefully if any
// field is absent (e.g., older payloads, partial data, test stubs).
interface PromptPackPayloadShape {
  project?: {
    name?: string;
    summary?: string;
    readingLevel?: string;
    contentRating?: string;
    audienceNotes?: string;
  };
  setting?: {
    included?: boolean;
    summary?: string;
    worldRules?: string[];
    constraints?: string[];
    domains?: string[];
    themes?: string[];
    season?: string;
    historicalPressure?: string;
    politicalForces?: string;
    socialOrder?: string;
    environmentalPressure?: string;
    technologyLevel?: string;
    mythicFrame?: string;
    religiousPressure?: string;
    economicPressure?: string;
    taboos?: string[];
    institutions?: string[];
    dominantValues?: string[];
    hiddenTruths?: string[];
    instructionBias?: string;
  };
  selectedCharacters?: Array<{
    name?: string;
    roles?: string[];
    goals?: string[];
    fears?: string[];
    flaws?: string[];
    secrets?: string[];
    wounds?: string[];
    coreLie?: string;
    coreTruth?: string;
    arcStart?: string;
    arcEnd?: string;
    breakingPoints?: string[];
    moralLines?: string[];
    selfDeceptions?: string[];
    identityConflicts?: string[];
    instructionBias?: string;
  }>;
  selectedRelationships?: Array<{
    name?: string;
    relationshipType?: string;
    tension?: string;
    unspokenTruth?: string;
    whatEachWantsFromTheOther?: string;
    whatWouldBreakIt?: string;
    whatWouldTransformIt?: string;
  }>;
  selectedThemeQuestions?: Array<{
    question?: string;
    coreTension?: string;
    moralFaultLine?: string;
    endingTruth?: string;
  }>;
  selectedMotifs?: Array<{
    label?: string;
    meaning?: string;
  }>;
  selectedStorySpark?: {
    title?: string;
    situation?: string;
    stakes?: string;
    urgency?: string;
    threat?: string;
    twist?: string;
    opportunity?: string;
    complication?: string;
    clock?: string;
    triggerEvent?: string;
    initialImbalance?: string;
    reversalPotential?: string;
    falseResolution?: string;
  } | null;
  selectedAftertaste?: {
    label?: string;
    note?: string;
    emotionalResidue?: string;
    endingTexture?: string;
    desiredAmbiguityLevel?: string;
    readerQuestionLeftOpen?: string;
    lastImageFeeling?: string;
  } | null;
  promptPack?: {
    notes?: string;
    instructionBias?: string;
  };
}

function join(items: (string | undefined | null)[], sep = "; "): string {
  return (items.filter(Boolean) as string[]).join(sep);
}

function nonEmpty(s: string | undefined | null): s is string {
  return typeof s === "string" && s.trim().length > 0;
}

function section(header: string, lines: string[]): string[] {
  const body = lines.filter(Boolean);
  if (body.length === 0) return [];
  return [header, ...body, ""];
}

function buildStructuredPromptBody(p: PromptPackPayloadShape): string[] {
  const out: string[] = [];

  // 1. Premise
  if (nonEmpty(p.project?.summary)) {
    out.push(...section("## Premise", [p.project!.summary!]));
  }

  // 2. World & Constraints
  const s = p.setting;
  if (s?.included) {
    const settingLines: string[] = [];
    if (nonEmpty(s.summary)) settingLines.push(s.summary!);
    if (s.worldRules?.length)    settingLines.push(`World rules: ${join(s.worldRules)}`);
    if (s.constraints?.length)   settingLines.push(`Constraints: ${join(s.constraints)}`);
    if (s.domains?.length)       settingLines.push(`Domains: ${join(s.domains, ", ")}`);
    if (s.themes?.length)        settingLines.push(`Themes: ${join(s.themes, ", ")}`);
    if (nonEmpty(s.season))              settingLines.push(`Season / Time: ${s.season}`);
    if (nonEmpty(s.historicalPressure))  settingLines.push(`Historical pressure: ${s.historicalPressure}`);
    if (nonEmpty(s.politicalForces))     settingLines.push(`Political forces: ${s.politicalForces}`);
    if (nonEmpty(s.socialOrder))         settingLines.push(`Social order: ${s.socialOrder}`);
    if (nonEmpty(s.environmentalPressure)) settingLines.push(`Environmental pressure: ${s.environmentalPressure}`);
    if (nonEmpty(s.technologyLevel))     settingLines.push(`Technology level: ${s.technologyLevel}`);
    if (nonEmpty(s.mythicFrame))         settingLines.push(`Mythic frame: ${s.mythicFrame}`);
    if (nonEmpty(s.religiousPressure))   settingLines.push(`Religious pressure: ${s.religiousPressure}`);
    if (nonEmpty(s.economicPressure))    settingLines.push(`Economic pressure: ${s.economicPressure}`);
    if (s.taboos?.length)        settingLines.push(`Taboos: ${join(s.taboos)}`);
    if (s.institutions?.length)  settingLines.push(`Institutions: ${join(s.institutions, ", ")}`);
    if (s.dominantValues?.length) settingLines.push(`Dominant values: ${join(s.dominantValues, ", ")}`);
    if (s.hiddenTruths?.length)  settingLines.push(`Hidden truths: ${join(s.hiddenTruths)}`);
    if (nonEmpty(s.instructionBias)) settingLines.push(`Setting instruction: ${s.instructionBias}`);
    out.push(...section("## World & Constraints", settingLines));
  }

  // 3. Selected Characters (highest priority selected element)
  const chars = p.selectedCharacters;
  if (chars?.length) {
    out.push("## Characters");
    for (const c of chars) {
      if (nonEmpty(c.name)) out.push(`### ${c.name}`);
      if (c.roles?.length)           out.push(`Roles: ${join(c.roles, ", ")}`);
      if (c.goals?.length)           out.push(`Goals: ${join(c.goals)}`);
      if (c.fears?.length)           out.push(`Fears: ${join(c.fears)}`);
      if (c.flaws?.length)           out.push(`Flaws: ${join(c.flaws)}`);
      if (c.secrets?.length)         out.push(`Secrets: ${join(c.secrets)}`);
      if (c.wounds?.length)          out.push(`Wounds: ${join(c.wounds)}`);
      if (nonEmpty(c.coreLie))       out.push(`Core lie: ${c.coreLie}`);
      if (nonEmpty(c.coreTruth))     out.push(`Core truth: ${c.coreTruth}`);
      if (nonEmpty(c.arcStart))      out.push(`Arc (start): ${c.arcStart}`);
      if (nonEmpty(c.arcEnd))        out.push(`Arc (end): ${c.arcEnd}`);
      if (c.breakingPoints?.length)  out.push(`Breaking points: ${join(c.breakingPoints)}`);
      if (c.moralLines?.length)      out.push(`Moral lines: ${join(c.moralLines)}`);
      if (c.selfDeceptions?.length)  out.push(`Self-deceptions: ${join(c.selfDeceptions)}`);
      if (c.identityConflicts?.length) out.push(`Identity conflicts: ${join(c.identityConflicts)}`);
      if (nonEmpty(c.instructionBias)) out.push(`Character instruction: ${c.instructionBias}`);
    }
    out.push("");
  }

  // 4. Selected Relationships
  const rels = p.selectedRelationships;
  if (rels?.length) {
    out.push("## Relationships");
    for (const r of rels) {
      if (nonEmpty(r.name)) out.push(`### ${r.name}`);
      if (nonEmpty(r.relationshipType)) out.push(`Type: ${r.relationshipType}`);
      if (nonEmpty(r.tension))          out.push(`Tension: ${r.tension}`);
      if (nonEmpty(r.unspokenTruth))    out.push(`Unspoken truth: ${r.unspokenTruth}`);
      if (nonEmpty(r.whatEachWantsFromTheOther)) out.push(`What each wants: ${r.whatEachWantsFromTheOther}`);
      if (nonEmpty(r.whatWouldBreakIt)) out.push(`What would break it: ${r.whatWouldBreakIt}`);
      if (nonEmpty(r.whatWouldTransformIt)) out.push(`What would transform it: ${r.whatWouldTransformIt}`);
    }
    out.push("");
  }

  // 5. Selected Theme Questions
  const themes = p.selectedThemeQuestions;
  if (themes?.length) {
    out.push("## Themes");
    for (const t of themes) {
      if (nonEmpty(t.question))      out.push(`- ${t.question}`);
      if (nonEmpty(t.coreTension))   out.push(`  Core tension: ${t.coreTension}`);
      if (nonEmpty(t.moralFaultLine)) out.push(`  Moral fault line: ${t.moralFaultLine}`);
      if (nonEmpty(t.endingTruth))   out.push(`  Ending truth: ${t.endingTruth}`);
    }
    out.push("");
  }

  // 6. Selected Motifs
  const motifs = p.selectedMotifs;
  if (motifs?.length) {
    out.push("## Motifs");
    for (const m of motifs) {
      out.push(`- ${m.label ?? ""}${nonEmpty(m.meaning) ? ": " + m.meaning : ""}`);
    }
    out.push("");
  }

  // 7. Dramatic Seed — spark translated into an explicit writing instruction
  const spark = p.selectedStorySpark;
  if (spark) {
    const sparkLines: string[] = [];
    sparkLines.push(
      `Bring this dramatic situation directly to life in the writing: "${spark.title ?? ""}"`,
    );
    if (nonEmpty(spark.situation))        sparkLines.push(`Situation: ${spark.situation}`);
    if (nonEmpty(spark.stakes))           sparkLines.push(`Stakes: ${spark.stakes}`);
    if (nonEmpty(spark.urgency))          sparkLines.push(`Urgency: ${spark.urgency}`);
    if (nonEmpty(spark.threat))           sparkLines.push(`Threat: ${spark.threat}`);
    if (nonEmpty(spark.twist))            sparkLines.push(`Twist: ${spark.twist}`);
    if (nonEmpty(spark.opportunity))      sparkLines.push(`Opportunity: ${spark.opportunity}`);
    if (nonEmpty(spark.complication))     sparkLines.push(`Complication: ${spark.complication}`);
    if (nonEmpty(spark.clock))            sparkLines.push(`Clock: ${spark.clock}`);
    if (nonEmpty(spark.triggerEvent))     sparkLines.push(`Trigger event: ${spark.triggerEvent}`);
    if (nonEmpty(spark.initialImbalance)) sparkLines.push(`Initial imbalance: ${spark.initialImbalance}`);
    if (nonEmpty(spark.reversalPotential)) sparkLines.push(`Reversal potential: ${spark.reversalPotential}`);
    if (nonEmpty(spark.falseResolution))  sparkLines.push(`False resolution: ${spark.falseResolution}`);
    out.push(...section("## Dramatic Seed", sparkLines));
  }

  // 8. Ending Instruction — aftertaste translated into a directive for the closing beat
  const at = p.selectedAftertaste;
  if (at) {
    const atLines: string[] = [];
    atLines.push(`Close the piece so the reader feels: ${at.label ?? ""}`);
    if (nonEmpty(at.note))                  atLines.push(at.note!);
    if (nonEmpty(at.emotionalResidue))      atLines.push(`Emotional residue: ${at.emotionalResidue}`);
    if (nonEmpty(at.endingTexture))         atLines.push(`Ending texture: ${at.endingTexture}`);
    if (nonEmpty(at.desiredAmbiguityLevel)) atLines.push(`Ambiguity: ${at.desiredAmbiguityLevel}`);
    if (nonEmpty(at.readerQuestionLeftOpen)) atLines.push(`Leave open: ${at.readerQuestionLeftOpen}`);
    if (nonEmpty(at.lastImageFeeling))      atLines.push(`Last image: ${at.lastImageFeeling}`);
    out.push(...section("## Ending Instruction", atLines));
  }

  // 9. Pack-level notes and instruction bias
  if (nonEmpty(p.promptPack?.notes)) {
    out.push(...section("## Notes", [p.promptPack!.notes!]));
  }
  if (nonEmpty(p.promptPack?.instructionBias)) {
    out.push(...section("## Instruction Bias", [p.promptPack!.instructionBias!]));
  }

  return out;
}

function buildPrompt(req: {
  sourcePayloadJSON: unknown;
  generationAction: GenerationAction;
  generationLengthMode: LengthMode;
  outputBudget: number;
  previousOutputText?: string;
  readingLevel?: string;
  contentRating?: string;
  audienceNotes?: string;
  projectName: string;
  promptPackName: string;
}): string {
  // Parse the payload — degrade gracefully if malformed.
  let payload: PromptPackPayloadShape = {};
  try {
    payload = (
      typeof req.sourcePayloadJSON === "string"
        ? JSON.parse(req.sourcePayloadJSON)
        : req.sourcePayloadJSON
    ) as PromptPackPayloadShape;
  } catch {
    // Payload could not be parsed — continue with empty shape so the writing
    // task and instructions are still emitted.
  }

  // Resolve audience fields — prefer top-level req fields, fall back to payload.
  const readingLevel  = req.readingLevel  || payload?.project?.readingLevel  || "";
  const contentRating = req.contentRating || payload?.project?.contentRating || "";
  const audienceNotes = req.audienceNotes || payload?.project?.audienceNotes || "";

  const actionTask: Record<GenerationAction, string> = {
    generate:
      "Write an opening story scene that brings the premise and selected elements to life.",
    regenerate:
      "Write a fresh story scene based on the same premise and selected elements — a new take, not a copy.",
    continue:
      "Continue the story directly from where the previous passage ended. Do not repeat or summarize what has already been written.",
    remix:
      "Reinterpret the premise and selected elements in a creative new direction while keeping the core characters and world intact.",
  };

  const lengthGuidance: Record<LengthMode, string> = {
    short:
      "Length: one complete short scene or vignette (roughly 300–500 words).",
    medium:
      "Length: one complete scene with a full dramatic beat (roughly 600–1000 words).",
    long:
      "Length: a complete extended multi-beat scene sequence (roughly 1200–2000 words).",
    chapter:
      "Length: one complete chapter-shaped section with progression (roughly 2500–4000 words).",
  };

  const lines: string[] = [
    "You are a creative writing assistant helping authors craft compelling story content.",
    "",
  ];

  // Audience controls (emit early so the model sees them before the content)
  if (readingLevel || contentRating || audienceNotes) {
    if (readingLevel)  lines.push(`Reading level: ${readingLevel}`);
    if (contentRating) lines.push(`Content rating: ${contentRating}`);
    if (audienceNotes) lines.push(`Audience notes: ${audienceNotes}`);
    lines.push("");
  }

  // Structured story context extracted from payload
  lines.push(...buildStructuredPromptBody(payload));

  // Previous output for continue / remix
  if (
    (req.generationAction === "continue" || req.generationAction === "remix") &&
    req.previousOutputText
  ) {
    lines.push(
      "## Previous Output",
      "Do not repeat or closely paraphrase what follows — continue or reinterpret from this point:",
      req.previousOutputText,
      "",
    );
  }

  // Writing Task — explicit statement of what to produce
  lines.push(
    "## Writing Task",
    actionTask[req.generationAction],
    lengthGuidance[req.generationLengthMode],
    `Approximate maximum output: ${req.outputBudget} tokens.`,
    "",
  );

  // Writing Instructions — stable block
  lines.push(
    "## Writing Instructions",
    "- Write actual story prose, not summary or setup description",
    "- Use the selected characters, relationships, spark, and motifs directly — put them in the scene",
    "- Preserve the premise and any world constraints established above",
    "- Write with tension, movement, and specificity",
    "- Avoid generic filler and avoid simply restating the setup",
    "- Close the piece according to the Ending Instruction if one is present",
    "- Respect the reading level, content rating, and audience notes at all times",
    "- Do not include meta-commentary, titles, or headings unless explicitly requested",
    "- End cleanly within the requested length; do not stop mid-sentence",
    "- If you cannot cover everything, narrow the scope rather than running over",
  );

  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Title extraction helper
// ---------------------------------------------------------------------------

function extractTitle(text: string, fallback: string): string {
  const headingMatch = text.match(/^#{1,3}\s+(.+)/m);
  if (headingMatch) return headingMatch[1].trim();
  return fallback || "";
}

function describeError(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string" && error.length > 0) return error;

  try {
    const serialized = JSON.stringify(error);
    if (serialized && serialized !== "{}") return serialized;
  } catch {
    // Ignore serialization failures and fall back to the supplied message.
  }

  return fallback;
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

async function handler(
  req: Request,
  deps: HandlerDependencies = {},
): Promise<Response> {
  const requestStartMs = Date.now();
  const requestId = crypto.randomUUID();
  const {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId,
    persistenceStore: injectedPersistenceStore,
  } = deps;

  // Preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return corsResponse(
      JSON.stringify({ status: "failed", errorMessage: "Method not allowed" }),
      { status: 405 },
    );
  }

  // -------------------------------------------------------------------------
  // Auth -- reject unauthenticated requests; derive user_id from JWT
  // -------------------------------------------------------------------------

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  let userId = authenticatedUserId;

  if (!userId) {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return corsResponse(
        JSON.stringify({
          status: "failed",
          errorCode: "unauthenticated",
          errorMessage: "Unauthorized",
        }),
        { status: 401 },
      );
    }

    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseURL || !supabaseAnonKey) {
      return corsResponse(
        JSON.stringify({
          status: "failed",
          errorCode: "backend_config_missing",
          errorMessage: "Server configuration error",
        }),
        { status: 500 },
      );
    }

    const userClient = createClient(supabaseURL, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const {
      data: { user },
      error: authError,
    } = await userClient.auth.getUser();

    if (authError || !user) {
      return corsResponse(
        JSON.stringify({
          status: "failed",
          errorCode: "unauthenticated",
          errorMessage: "Unauthorized",
        }),
        { status: 401 },
      );
    }

    userId = user.id;
  }

  // -------------------------------------------------------------------------
  // Build service-role client for credit and rate-limit operations.
  // This client bypasses RLS and can write to user_entitlements,
  // user_credit_ledger, and generation_request_logs.
  // It is NEVER exposed to the iOS client.
  // -------------------------------------------------------------------------

  let store: CreditStore;
  let limiter: RateLimitStore;
  const requiresAdminClient =
    creditStore === undefined ||
    rateLimitStore === undefined ||
    injectedPersistenceStore === undefined ||
    generationModelStore === undefined;
  let adminClient:
    // deno-lint-ignore no-explicit-any
    any | null = null;

  if (requiresAdminClient) {
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseURL || !serviceRoleKey) {
      return corsResponse(
        JSON.stringify({
          status: "failed",
          errorCode: "backend_config_missing",
          errorMessage: "Server configuration error",
        }),
        { status: 500 },
      );
    }
    adminClient = createClient(supabaseURL, serviceRoleKey);
  }

  if (creditStore !== undefined && rateLimitStore !== undefined) {
    store = creditStore;
    limiter = rateLimitStore;
  } else {
    store = new SupabaseCreditStore(adminClient);
    limiter = new SupabaseRateLimitStore(adminClient);
  }

  let persistence: GenerationPersistenceStore;
  let modelStore: GenerationModelStore;
  if (injectedPersistenceStore !== undefined) {
    persistence = injectedPersistenceStore;
  } else {
    persistence = new SupabaseGenerationPersistenceStore(adminClient);
  }
  if (generationModelStore !== undefined) {
    modelStore = generationModelStore;
  } else {
    modelStore = new SupabaseGenerationModelStore(adminClient);
  }

  // -------------------------------------------------------------------------
  // Parse request body
  // -------------------------------------------------------------------------

  let body: GenerateStoryRequest;
  try {
    body = await req.json();
  } catch {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: "Invalid JSON body",
      }),
      { status: 400 },
    );
  }

  // -------------------------------------------------------------------------
  // Server-side validation
  // -------------------------------------------------------------------------

  if (!ALLOWED_ACTIONS.includes(body.generationAction as GenerationAction)) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: `Invalid generationAction. Allowed values: ${ALLOWED_ACTIONS.join(", ")}`,
      }),
      { status: 422 },
    );
  }
  const generationAction = body.generationAction as GenerationAction;

  if (!ALLOWED_LENGTH_MODES.includes(body.generationLengthMode as LengthMode)) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: `Invalid generationLengthMode. Allowed values: ${ALLOWED_LENGTH_MODES.join(", ")}`,
      }),
      { status: 422 },
    );
  }
  const generationLengthMode = body.generationLengthMode as LengthMode;

  if (!body.sourcePayloadJSON) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: "sourcePayloadJSON is required",
      }),
      { status: 422 },
    );
  }

  // Enforce sourcePayloadJSON size limit.
  const sourcePayloadStr =
    typeof body.sourcePayloadJSON === "string"
      ? body.sourcePayloadJSON
      : JSON.stringify(body.sourcePayloadJSON);
  if (sourcePayloadStr.length > MAX_SOURCE_PAYLOAD_CHARS) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: `sourcePayloadJSON exceeds maximum size of ${MAX_SOURCE_PAYLOAD_CHARS} characters`,
      }),
      { status: 422 },
    );
  }

  // Enforce previousOutputText size limit.
  if (body.previousOutputText != null && body.previousOutputText.length > MAX_PREVIOUS_OUTPUT_CHARS) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: `previousOutputText exceeds maximum size of ${MAX_PREVIOUS_OUTPUT_CHARS} characters`,
      }),
      { status: 422 },
    );
  }

  // Enforce server-side budget cap -- do not trust the client value blindly.
  const serverMax = MAX_BUDGET[generationLengthMode];
  const outputBudget = Math.min(
    Math.max(1, Math.round(body.outputBudget ?? serverMax)),
    serverMax,
  );
  const selectedModelId = normalizedModelId(body.selectedModelId);
  const selectedModel = await modelStore.getEnabledModelById(selectedModelId);
  if (!selectedModel) {
    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget,
      selectedModelId,
      status: "failed",
      errorCode: "invalid_model",
      errorMessage: "Selected model is invalid or disabled.",
      durationMs: Date.now() - requestStartMs,
    });
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_model",
        errorMessage: "Selected model is invalid or disabled.",
      }),
      { status: 400 },
    );
  }
  const maxCompletionTokens = Math.min(
    outputBudget,
    selectedModel.max_output_tokens ?? outputBudget,
  );

  // previousOutputText is required for "continue" to avoid a no-op generation.
  if (generationAction === "continue" && !body.previousOutputText) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage:
          "previousOutputText is required when generationAction is 'continue'",
      }),
      { status: 422 },
    );
  }

  const projectName = body.projectName ?? "";
  const promptPackName = body.promptPackName ?? "";

  // -------------------------------------------------------------------------
  // Rate limiting -- must happen before credit check and provider call
  //
  // Per-user rolling-window limits are checked against generation_request_logs.
  // Exceeding any limit returns 429 with retryAfterSeconds so the client can
  // back off appropriately.
  // -------------------------------------------------------------------------

  const rateLimitCheck = await limiter.checkLimits(userId);
  if (!rateLimitCheck.allowed) {
    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget,
      selectedModelId,
      providerModel: selectedModel.provider_model,
      maxCompletionTokens,
      status: "rate_limited",
      errorCode: "rate_limited",
      errorMessage: "Rate limit exceeded",
      durationMs: Date.now() - requestStartMs,
    });

    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "rate_limited",
        errorMessage: "Too many requests. Please wait before generating again.",
        retryAfterSeconds: rateLimitCheck.retryAfterSeconds,
      }),
      {
        status: 429,
        headers: {
          "Retry-After": String(rateLimitCheck.retryAfterSeconds ?? 60),
        },
      },
    );
  }

  // -------------------------------------------------------------------------
  // Credit enforcement -- must happen BEFORE the LLM provider call
  //
  // Credit check is computed server-side from selected model rates and estimated
  // input/output tokens. The client cannot override model rates.
  // -------------------------------------------------------------------------

  const systemPrompt = buildPrompt({
    sourcePayloadJSON: body.sourcePayloadJSON,
    generationAction,
    generationLengthMode,
    outputBudget: maxCompletionTokens,
    previousOutputText: body.previousOutputText,
    readingLevel: body.readingLevel,
    contentRating: body.contentRating,
    audienceNotes: body.audienceNotes,
    projectName,
    promptPackName,
  });
  const estimatedInputTokens = estimateTokensFromText(systemPrompt);
  const requiredCredits = computeEstimatedCharge(
    estimatedInputTokens,
    maxCompletionTokens,
    selectedModel,
  );
  const entitlement = await store.loadOrDefault(userId);
  const creditCheck = checkCredits(entitlement, requiredCredits);

  if (!creditCheck.allowed) {
    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget: maxCompletionTokens,
      selectedModelId,
      providerModel: selectedModel.provider_model,
      maxCompletionTokens,
      status: "insufficient_credits",
      errorCode: "insufficient_credits",
      errorMessage: "Insufficient credits for this generation.",
      durationMs: Date.now() - requestStartMs,
    });

    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "insufficient_credits",
        errorMessage: "Insufficient credits for this generation.",
        requiredCredits: creditCheck.requiredCredits,
        availableCredits: creditCheck.availableCredits,
      }),
      { status: 402 },
    );
  }

  // -------------------------------------------------------------------------
  // Resolve provider (injected or from env)
  // -------------------------------------------------------------------------

  let llm: LLMProvider;
  try {
    llm = provider ?? buildProviderFromEnv();
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Provider configuration error";
    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget: maxCompletionTokens,
      selectedModelId,
      providerModel: selectedModel.provider_model,
      maxCompletionTokens,
      status: "failed",
      errorCode: "backend_config_missing",
      errorMessage: msg,
      durationMs: Date.now() - requestStartMs,
    });
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "backend_config_missing",
        errorMessage: msg,
      }),
      { status: 500 },
    );
  }

  // -------------------------------------------------------------------------
  // Build prompt and call LLM
  // -------------------------------------------------------------------------

  let llmResult: {
    content: string;
    modelName: string;
    finishReason?: string;
    inputTokens?: number;
    outputTokens?: number;
    totalTokens?: number;
  };

  try {
    llmResult = await llm.complete(
      [{ role: "user", content: systemPrompt }],
      maxCompletionTokens,
      selectedModel.provider_model,
    );
  } catch (err) {
    // Classify provider errors into stable error codes.
    // Credits are NOT charged on provider failure.
    let providerErrorCode = "unknown";
    const isTimeout = err instanceof ProviderError && err.errorCode === "provider_timeout";
    const isInsufficientQuota = err instanceof ProviderError &&
      err.errorCode === "provider_insufficient_quota";

    if (err instanceof ProviderError) {
      providerErrorCode = err.errorCode;
    }

    const providerErrorMessage = err instanceof Error ? err.message : "LLM provider error";
    const failureResponse = providerErrorResponse(providerErrorCode, providerErrorMessage);

    if (isTimeout) {
      // Structured log so operators can confirm timeoutMs in logs.
      console.error("[generate-story] provider_timeout", {
        action: generationAction,
        lengthMode: generationLengthMode,
        timeoutMs: PROVIDER_TIMEOUT_MS,
        model: selectedModel.provider_model,
      });
    }

    // Best-effort: record a failed usage event for audit purposes.
    // Skipped on provider_timeout / provider_insufficient_quota — no output was
    // produced and credits are not charged.
    if (!isTimeout && !isInsufficientQuota) {
      const { error: usageInsertError } = await persistence.insertUsageEvent({
        user_id: userId,
        generation_output_id: null,
        action: generationAction,
        model_name: selectedModel.provider_model,
        input_tokens: null,
        output_tokens: null,
        generation_length_mode: generationLengthMode,
        output_budget: maxCompletionTokens,
        status: "failed",
      });

      if (usageInsertError) {
        console.error("[generate-story] generation_usage_events insert failed", usageInsertError);
      }
    }

    // Log the failed request.
    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget: maxCompletionTokens,
      selectedModelId,
      providerModel: selectedModel.provider_model,
      maxCompletionTokens,
      status: "failed",
      errorCode: providerErrorCode,
      errorMessage: providerErrorMessage,
      modelName: selectedModel.provider_model,
      actualCharge: 0,
      durationMs: Date.now() - requestStartMs,
    });

    return corsResponse(
      JSON.stringify(failureResponse.body),
      {
        status: failureResponse.httpStatus,
        ...(failureResponse.headers ? { headers: failureResponse.headers } : {}),
      },
    );
  }

  // -------------------------------------------------------------------------
  // Persist generation_outputs row
  // -------------------------------------------------------------------------

  const generatedText = llmResult.content.trim();
  const wasTruncated = llmResult.finishReason === "length";
  const outputStatus: GenerationOutputInsert["status"] = wasTruncated ? "draft" : "complete";
  const title = extractTitle(generatedText, promptPackName || projectName);

  // Normalize sourcePayloadJSON for storage -- always persist as an object.
  const sourcePayloadForDB =
    typeof body.sourcePayloadJSON === "string"
      ? JSON.parse(body.sourcePayloadJSON)
      : body.sourcePayloadJSON;

  const { data: outputRow, error: outputInsertError } = await persistence.insertOutput({
    user_id: userId,
    local_generation_id: body.localGenerationID ?? null,
    project_name: projectName,
    prompt_pack_name: promptPackName,
    title,
    output_text: generatedText,
    source_payload_json: sourcePayloadForDB,
    model_name: llmResult.modelName,
    generation_action: generationAction,
    generation_length_mode: generationLengthMode,
    output_budget: maxCompletionTokens,
    status: outputStatus,
    visibility: "private",
  });

  if (outputInsertError || !outputRow?.id) {
    const persistenceFailure =
      outputInsertError ?? new Error("generation_outputs insert returned no row");
    console.error("[generate-story] generation_outputs insert failed", {
      requestId,
      userId,
      error: outputInsertError ?? null,
      outputRow: outputRow ?? null,
    });

    await limiter.recordRequest(userId, {
      requestId,
      action: generationAction,
      generationLengthMode,
      outputBudget: maxCompletionTokens,
      selectedModelId,
      providerModel: selectedModel.provider_model,
      maxCompletionTokens,
      status: "failed",
      errorCode: "persistence_failed",
      errorMessage: describeError(
        persistenceFailure,
        "Failed to persist generation output.",
      ),
      modelName: llmResult.modelName,
      inputTokens: llmResult.inputTokens,
      outputTokens: llmResult.outputTokens,
      totalTokens: llmResult.totalTokens,
      actualCharge: 0,
      durationMs: Date.now() - requestStartMs,
    });

    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "persistence_failed",
        errorMessage: "Failed to save generated output.",
      }),
      { status: 500 },
    );
  }

  const generationOutputId = outputRow.id;

  // -------------------------------------------------------------------------
  // Persist generation_usage_events row
  // -------------------------------------------------------------------------

  const { error: usageInsertError } = await persistence.insertUsageEvent({
    user_id: userId,
    generation_output_id: generationOutputId,
    action: generationAction,
    model_name: llmResult.modelName,
    input_tokens: llmResult.inputTokens ?? null,
    output_tokens: llmResult.outputTokens ?? null,
    generation_length_mode: generationLengthMode,
    output_budget: maxCompletionTokens,
    status: "complete",
  });

  if (usageInsertError) {
    console.error("[generate-story] generation_usage_events insert failed", usageInsertError);
  }

  // -------------------------------------------------------------------------
  // Charge credits -- only after successful generation
  //
  // Credits are charged AFTER the LLM provider returns successfully and the
  // output row is persisted.
  // A failed LLM call or output persistence failure does NOT charge.
  // Monthly allowance is drained first; purchased balance is used second.
  // -------------------------------------------------------------------------

  const actualInputTokens = llmResult.inputTokens ?? 0;
  const actualOutputTokens = llmResult.outputTokens ?? 0;
  const actualCharge = computeActualCharge(
    actualInputTokens,
    actualOutputTokens,
    selectedModel,
  );
  const updatedEntitlement = await store.charge(
    userId,
    actualCharge,
    entitlement,
    generationOutputId,
  );

  const remainingCredits =
    updatedEntitlement.monthly_credit_allowance +
    updatedEntitlement.purchased_credit_balance;

  // -------------------------------------------------------------------------
  // Log successful request
  // -------------------------------------------------------------------------

  await limiter.recordRequest(userId, {
    requestId,
    action: generationAction,
    generationLengthMode,
    outputBudget: maxCompletionTokens,
    selectedModelId,
    providerModel: selectedModel.provider_model,
    maxCompletionTokens,
    status: wasTruncated ? "incomplete" : "success",
    errorCode: wasTruncated ? "output_truncated" : undefined,
    errorMessage: wasTruncated
      ? "The generation hit the model length limit and may be incomplete."
      : undefined,
    modelName: llmResult.modelName,
    inputTokens: llmResult.inputTokens,
    outputTokens: llmResult.outputTokens,
    totalTokens: llmResult.totalTokens,
    actualCharge,
    durationMs: Date.now() - requestStartMs,
  });

  // -------------------------------------------------------------------------
  // Return response
  // -------------------------------------------------------------------------

  return corsResponse(
    JSON.stringify({
      generatedText,
      title,
      modelName: llmResult.modelName,
      generationAction,
      generationLengthMode,
      requestedLengthMode: generationLengthMode,
      selectedModelId,
      outputBudget: maxCompletionTokens,
      maxCompletionTokens,
      finishReason: llmResult.finishReason ?? null,
      wasTruncated,
      inputTokens: llmResult.inputTokens,
      outputTokens: llmResult.outputTokens,
      totalTokens: llmResult.totalTokens,
      creditCostCharged: actualCharge,
      remainingCredits,
      status: wasTruncated ? "incomplete" : "complete",
      errorCode: wasTruncated ? "output_truncated" : null,
      errorMessage: wasTruncated
        ? "This output hit the model length limit and may be incomplete."
        : null,
    }),
    { status: 200 },
  );
}

Deno.serve((req) => handler(req));

// Export handler and helpers for testing.
export { handler };
export { checkCredits, computeCharge } from "./_credits.ts";
export { RATE_LIMITS } from "./_rate_limiter.ts";
export { classifyOpenAIStatus, ProviderError, PROVIDER_TIMEOUT_MS } from "./_provider.ts";
export { computeActualCharge, computeEstimatedCharge, DEFAULT_GENERATION_MODEL_ID } from "./_generation_models.ts";
