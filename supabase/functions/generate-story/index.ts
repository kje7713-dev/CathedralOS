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
  computeGenerationCreditCharge,
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

/** Estimate-only action — returns a cost estimate without calling the LLM. */
const ESTIMATE_ACTION = "estimate" as const;

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
  // Style picker (replaces length-based density guidance in the prompt).
  // “auto” = no length target, model writes naturally within budget.
  // “compact/standard/expansive” = density hint the model can honor.
  // Optional for backwards compat — omitted => “auto”.
  // Output container: what size / shape the finished unit should be.
  // Drives whatItContains + naturalStoppingPoint in the prompt.
  // Optional for backwards compat — omitted => "scene".
  container?: string;
  // Point of view: who narrates the scene.
  // Optional for backwards compat — omitted => "thirdPersonLimited".
  pov?: string;
  // @deprecated use container instead. Kept for backwards compat with
  // older iOS builds that still send style.
  style?: string;
  outputBudget: number;
  selectedModelId?: string;
  previousOutputText?: string;
  readingLevel?: string;
  contentRating?: string;
  audienceNotes?: string;
  // Terminal beat: the specific dramatic action + immediate reaction that
  // closes the scene. Optional. When set, rendered as the LAST input section
  // in the user message so the model sees it right before the Writing Task.
  terminalBeat?: string;
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
  // Phase 1 telemetry: USD revenue (= credits charged * $0.05/credit).
  // Optional; null for failed events where no credits were charged.
  credit_revenue_usd?: number | null;
}

interface ModelRateRow {
  input_per_1k_usd: number;
  output_per_1k_usd: number;
  premium_markup_pct: number;
  tier: "cheap" | "standard" | "premium";
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
    // Phase 1 telemetry: compute per-model USD cost and margin from model_rates.
    // Only runs when we have both token counts and a known model rate; failed
    // events (no tokens) and unmapped models (no rate row) get nulls.
    const marginFields = await this.computeMarginFields(row);
    const insertRow = { ...row, ...marginFields };
    // credit_revenue_usd is only persisted when the caller passes it.
    if (row.credit_revenue_usd == null) {
      delete (insertRow as Record<string, unknown>).credit_revenue_usd;
    }
    const { error } = await this.db.from("generation_usage_events").insert(insertRow);
    return { error };
  }

  private async computeMarginFields(
    row: GenerationUsageEventInsert,
  ): Promise<Record<string, number | null>> {
    const empty = {
      model_input_usd: null,
      model_output_usd: null,
      total_model_usd: null,
      credit_revenue_usd: row.credit_revenue_usd ?? null,
      margin_usd: null,
      margin_pct: null,
    };
    if (row.input_tokens == null || row.output_tokens == null) return empty;

    const rate = await this.lookupModelRate(row.model_name);
    if (!rate) return empty;

    const inputUsd = (row.input_tokens / 1000) * rate.input_per_1k_usd;
    const outputUsd = (row.output_tokens / 1000) * rate.output_per_1k_usd;
    const totalUsd = inputUsd + outputUsd;
    const revenueUsd = row.credit_revenue_usd ?? 0;
    const marginUsd = revenueUsd - totalUsd;
    const marginPct = revenueUsd > 0 ? marginUsd / revenueUsd : null;

    return {
      model_input_usd: round6(inputUsd),
      model_output_usd: round6(outputUsd),
      total_model_usd: round6(totalUsd),
      credit_revenue_usd: round6(revenueUsd),
      margin_usd: round6(marginUsd),
      margin_pct: marginPct == null ? null : round6(marginPct),
    };
  }

  private async lookupModelRate(modelName: string): Promise<ModelRateRow | null> {
    const { data, error } = await this.db
      .from("model_rates")
      .select("input_per_1k_usd, output_per_1k_usd, premium_markup_pct, tier")
      .eq("model_name", modelName)
      .eq("is_active", true)
      .maybeSingle();
    if (error || !data) return null;
    const r = data as Record<string, unknown>;
    return {
      input_per_1k_usd: Number(r.input_per_1k_usd) || 0,
      output_per_1k_usd: Number(r.output_per_1k_usd) || 0,
      premium_markup_pct: Number(r.premium_markup_pct) || 0,
      tier: (r.tier as ModelRateRow["tier"]) || "cheap",
    };
  }
}

function round6(n: number): number {
  return Math.round(n * 1e6) / 1e6;
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

  // 2. Selected Characters — priority element; rendered before world/setting
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
    // Fields captured by PromptPackExportBuilder.build() but previously dropped
    // by buildStructuredPromptBody. Each line uses nonEmpty() / array-length
    // checks so empty values cost nothing in tokens.
    if (c.preferences?.length)       out.push(`Preferences: ${join(c.preferences)}`);
    if (c.resources?.length)         out.push(`Resources: ${join(c.resources)}`);
    if (c.failurePatterns?.length)   out.push(`Failure patterns: ${join(c.failurePatterns)}`);
    if (c.needs?.length)             out.push(`Needs: ${join(c.needs)}`);
    if (c.contradictions?.length)   out.push(`Contradictions: ${join(c.contradictions)}`);
    if (c.obsessions?.length)       out.push(`Obsessions: ${join(c.obsessions)}`);
    if (c.attachments?.length)      out.push(`Attachments: ${join(c.attachments)}`);
    if (nonEmpty(c.notes))           out.push(`Notes: ${c.notes}`);
    if (c.virtues?.length)           out.push(`Virtues: ${join(c.virtues)}`);
    if (nonEmpty(c.publicMask))      out.push(`Public mask: ${c.publicMask}`);
    if (nonEmpty(c.privateLogic))    out.push(`Private logic: ${c.privateLogic}`);
    if (nonEmpty(c.speechStyle))     out.push(`Speech style: ${c.speechStyle}`);
    if (nonEmpty(c.reputation))      out.push(`Reputation: ${c.reputation}`);
    if (nonEmpty(c.status))          out.push(`Status: ${c.status}`);
    }
    out.push("");
  }

  // 3. Selected Relationships — priority element
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
    // Fields captured by PromptPackExportBuilder.build() but previously dropped
    // by buildStructuredPromptBody.
    if (nonEmpty(r.loyalty))         out.push(`Loyalty: ${r.loyalty}`);
    if (nonEmpty(r.fear))            out.push(`Fear: ${r.fear}`);
    if (nonEmpty(r.desire))          out.push(`Desire: ${r.desire}`);
    if (nonEmpty(r.dependency))      out.push(`Dependency: ${r.dependency}`);
    if (nonEmpty(r.history))         out.push(`History: ${r.history}`);
    if (nonEmpty(r.powerBalance))    out.push(`Power balance: ${r.powerBalance}`);
    if (nonEmpty(r.resentment))      out.push(`Resentment: ${r.resentment}`);
    if (nonEmpty(r.misunderstanding)) out.push(`Misunderstanding: ${r.misunderstanding}`);
    if (nonEmpty(r.notes))           out.push(`Notes: ${r.notes}`);
    }
    out.push("");
  }

  // 4. Selected Theme Questions — priority element
  const themes = p.selectedThemeQuestions;
  if (themes?.length) {
    out.push("## Themes");
    for (const t of themes) {
      if (nonEmpty(t.question))      out.push(`- ${t.question}`);
      if (nonEmpty(t.coreTension))   out.push(`  Core tension: ${t.coreTension}`);
      if (nonEmpty(t.moralFaultLine)) out.push(`  Moral fault line: ${t.moralFaultLine}`);
      if (nonEmpty(t.endingTruth))   out.push(`  Ending truth: ${t.endingTruth}`);
    // Fields captured by PromptPackExportBuilder.build() but previously dropped.
    if (nonEmpty(t.valueConflict))   out.push(`  Value conflict: ${t.valueConflict}`);
    if (nonEmpty(t.notes))           out.push(`  Notes: ${t.notes}`);
    }
    out.push("");
  }

  // 5. Selected Motifs — priority element
  const motifs = p.selectedMotifs;
  if (motifs?.length) {
    out.push("## Motifs");
    for (const m of motifs) {
      out.push(`- ${m.label ?? ""}${nonEmpty(m.meaning) ? ": " + m.meaning : ""}`);
      // Fields captured by PromptPackExportBuilder.build() but previously dropped.
      if (nonEmpty(m.category)) out.push(`  Category: ${m.category}`);
      if (m.examples?.length)   out.push(`  Examples: ${join(m.examples)}`);
      if (nonEmpty(m.notes))    out.push(`  Notes: ${m.notes}`);
    }
    out.push("");
  }

  // 6. Dramatic Seed — spark is the primary engine; rendered with explicit direction
  //    so the model knows every line of the scene should serve this conflict/event.
  const spark = p.selectedStorySpark;
  if (spark) {
    const sparkLines: string[] = [];
    sparkLines.push(
      `This spark is the primary dramatic engine of the scene: "${spark.title ?? ""}"`,
    );
    sparkLines.push(
      "Express it as the central conflict, event, reveal, or pressure — everything in the scene should serve this.",
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

  // 7. World & Constraints — rendered after selected elements so they read as
  //    supporting context, not as the primary writing directive.
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

  // 8. Ending Instruction — aftertaste as a direct emotional residue directive
  const at = p.selectedAftertaste;
  if (at) {
    const atLines: string[] = [];
    atLines.push(`Leave the reader with ${at.label ?? ""} — shape the final image, tone, and consequence to produce this emotional residue.`);
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

// Output container: how large the finished unit should be.
// "modelDecides" lets the server pick based on the recipe.
type Container =
  | "modelDecides"
  | "beat"
  | "moment"
  | "vignette"
  | "microScene"
  | "scene"
  | "developedScene"
  | "setPiece"
  | "sceneSequence"
  | "shortStory"
  | "chapter"
  | "episode"
  | "novella";

// Point of view: who narrates the scene.
type POV = "firstPerson" | "secondPerson" | "thirdPersonLimited" | "thirdPersonOmniscient";

// Pre-flight hard cap lookup for credit estimation. Mirrors the hardCap
// values in containerConfig inside buildPrompt — keep in sync if those
// values change. Used by the Phase 2 pre-flight cost check.
const CONTAINER_HARD_CAPS: Record<Container, number> = {
  modelDecides: 8000,
  beat: 350,
  moment: 700,
  vignette: 1200,
  microScene: 1200,
  scene: 2300,
  developedScene: 4000,
  setPiece: 6500,
  sceneSequence: 9000,
  shortStory: 10000,
  chapter: 11000,
  episode: 18000,
  novella: 60000,
};

function buildPrompt(req: {
  sourcePayloadJSON: unknown;
  generationAction: GenerationAction;
  generationLengthMode: LengthMode;
  container: Container;
  pov: POV;
  outputBudget: number;
  previousOutputText?: string;
  readingLevel?: string;
  contentRating?: string;
  audienceNotes?: string;
  // Terminal beat: optional concrete endpoint the model should land on.
  // When set, rendered in the user message as the last input section
  // before the Writing Task. When absent, the model privately infers one.
  terminalBeat?: string;
  projectName: string;
  promptPackName: string;
}): { craft: string; context: string } {
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

  // Style-driven scene guidance. Replaces the old length-based targets that
  // the model often ignored. “auto” gives no length target at all — the
  // model writes whatever fits the budget. “compact/standard/expansive” give
  // density hints the model can actually honor.
  // Container config: name, what-it-contains, natural-stopping-point,
  // expected token range, and hard cap. The hard cap is emergency headroom,
  // not the desired output length. Models trained on creative writing
  // recognize these terms and respond to them with the right shape.
  interface ContainerConfig {
    name: string;
    whatItContains: string;
    naturalStoppingPoint: string;
    expectedRange: string;
    hardCap: number;
  }
  const containerConfig: Record<Container, ContainerConfig> = {
    modelDecides: {
      name: "Model decides",
      whatItContains: "(server picks the right container for the recipe)",
      naturalStoppingPoint: "(naturally terminates per the chosen container)",
      expectedRange: "varies",
      hardCap: 8000,
    },
    beat: {
      name: "Beat",
      whatItContains: "One action, reaction, discovery, or exchange",
      naturalStoppingPoint: "The immediate action completes",
      expectedRange: "75–250 tokens",
      hardCap: 350,
    },
    moment: {
      name: "Moment",
      whatItContains: "One focused emotional or sensory event",
      naturalStoppingPoint: "A realization, image, gesture, or decision",
      expectedRange: "200–500 tokens",
      hardCap: 700,
    },
    vignette: {
      name: "Vignette",
      whatItContains: "A compact portrait of a person, place, relationship, or situation",
      naturalStoppingPoint: "A resonant image or emotional turn",
      expectedRange: "300–900 tokens",
      hardCap: 1200,
    },
    microScene: {
      name: "Micro-scene",
      whatItContains: "One goal, one obstacle, one change",
      naturalStoppingPoint: "The immediate interaction changes state",
      expectedRange: "400–900 tokens",
      hardCap: 1200,
    },
    scene: {
      name: "Scene",
      whatItContains: "One continuous dramatic event",
      naturalStoppingPoint: "Goal succeeds, fails, changes, or becomes impossible",
      expectedRange: "800–1,800 tokens",
      hardCap: 2300,
    },
    developedScene: {
      name: "Developed scene",
      whatItContains: "A fuller scene with escalation and multiple tactics",
      naturalStoppingPoint: "The central conflict reaches a definite outcome",
      expectedRange: "1,500–3,000 tokens",
      hardCap: 4000,
    },
    setPiece: {
      name: "Set piece",
      whatItContains: "A major action, confrontation, ceremony, battle, escape, or reveal",
      naturalStoppingPoint: "The major event completes",
      expectedRange: "2,000–5,000 tokens",
      hardCap: 6500,
    },
    sceneSequence: {
      name: "Scene sequence",
      whatItContains: "Several connected scenes pursuing one larger objective",
      naturalStoppingPoint: "The sequence-level objective is achieved or fails",
      expectedRange: "3,000–7,000 tokens",
      hardCap: 9000,
    },
    shortStory: {
      name: "Short story",
      whatItContains: "A complete independent narrative",
      naturalStoppingPoint: "The central dramatic question is answered",
      expectedRange: "2,500–8,000 tokens",
      hardCap: 10000,
    },
    chapter: {
      name: "Chapter",
      whatItContains: "A publishing or pacing division containing one or more scenes",
      naturalStoppingPoint: "A turn, hook, revelation, decision, or transition",
      expectedRange: "3,000–8,000+ tokens",
      hardCap: 11000,
    },
    episode: {
      name: "Episode",
      whatItContains: "A self-contained installment within a larger serial",
      naturalStoppingPoint: "The episode’s main problem resolves, often with a larger hook",
      expectedRange: "5,000–15,000+ tokens",
      hardCap: 18000,
    },
    novella: {
      name: "Novella",
      whatItContains: "A complete extended story with multiple sequences",
      naturalStoppingPoint: "Central arc and major subplots resolve",
      expectedRange: "20,000–50,000 tokens",
      hardCap: 60000,
    },
  };

  // POV config: who narrates. Models know these canonical options.
  interface POVConfig {
    name: string;
    instruction: string;
  }
  const povConfig: Record<POV, POVConfig> = {
    firstPerson: {
      name: "First person",
      instruction: "Write in first person (I, me, my). The viewpoint character narrates in their own voice.",
    },
    secondPerson: {
      name: "Second person",
      instruction: "Write in second person (you, your). Address the reader or the viewpoint character directly.",
    },
    thirdPersonLimited: {
      name: "Third person limited",
      instruction: "Write in third person limited (he/she/they). Stay close to one character’s perspective; show only what that character can perceive and feel.",
    },
    thirdPersonOmniscient: {
      name: "Third person omniscient",
      instruction: "Write in third person omniscient (he/she/they). The narrator is all-knowing and can enter any character’s mind.",
    },
  };

  // Narrative shape: server infers from recipe for v1. Hardcoded to
  // Confrontation because the recipe's dramatic seed is the strongest
  // signal. Future: model-picked in a quick first call.
  const inferredShape = "Confrontation";

  // Container-aware scene instructions. The model gets:
  //  - the container's "what it contains" so it knows the shape
  //  - the container's "natural stopping point" so it knows when to end
  //  - structural limits so it doesn't sprawl
  //  - the POV so it knows who is narrating
  // The hard cap is emergency headroom, NOT a budget the model should fill.
  const containerInstructions = (
    containerName: string,
    whatItContains: string,
    naturalStoppingPoint: string,
    expectedRange: string,
  ): string =>
    `Write one complete ${containerName.toLowerCase()} (${expectedRange} tokens expected).

What it contains:
${whatItContains}

Natural stopping point:
${naturalStoppingPoint}

Structural limits:
- Use a limited number of major beats proportional to the scene’s complexity. Do not over-stuff.
- Do not introduce a new subplot.
- Do not introduce a new unresolved conflict near the ending.
- End immediately after the natural stopping point.
- Do not continue into the aftermath, next destination, next scene, or consequences.
- Produce a complete ending before stopping.`;

  const povInstruction = (pov: POV): string => povConfig[pov].instruction;

  // Craft directives — sent as the SYSTEM message. Persistent across
  // requests; the model weighs system instructions higher than user.
  //
  // Container instructions live here (moved from the user message in this
  // commit). The model weighs structural limits much more heavily when they
  // appear in the system message vs the user message.
  const cfg = containerConfig[req.container];
  const craftLines: string[] = [
    "You are a creative writing assistant helping authors craft compelling story content.",
    "",
    "## Container (CRITICAL SHAPE GUIDANCE)",
    containerInstructions(cfg.name, cfg.whatItContains, cfg.naturalStoppingPoint, cfg.expectedRange),
    "",
  ];

  // Per-request context — sent as the USER message.
  const contextLines: string[] = [];

  // Audience controls — per-request context (USER message).
  if (readingLevel || contentRating || audienceNotes) {
    if (readingLevel)  contextLines.push(`Reading level: ${readingLevel}`);
    if (contentRating) contextLines.push(`Content rating: ${contentRating}`);
    if (audienceNotes) contextLines.push(`Audience notes: ${audienceNotes}`);
    contextLines.push("");
  }

  // Structured story context — per-request context (USER message).
  contextLines.push(...buildStructuredPromptBody(payload));

  // Previous output for continue / remix — per-request context (USER message).
  if (
    (req.generationAction === "continue" || req.generationAction === "remix") &&
    req.previousOutputText
  ) {
    contextLines.push(
      "## Previous Output",
      "Do not repeat or closely paraphrase what follows — continue or reinterpret from this point:",
      req.previousOutputText,
      "",
    );
  }

  // Writing Task — per-request specifics, lives in the user message.
  // Container-driven shape lives in the SYSTEM message (computed above and
  // pushed into craftLines) — the model weights system > user for structural
  // limits, so the container guidance now anchors in the system message.
  // The user message just carries the per-request specifics (action,
  // narrative shape, POV).
  // Terminal beat — optional concrete endpoint, rendered as the LAST input
  // section in the user message so the model sees it right before the
  // Writing Task. Strongest anchor position.
  if (nonEmpty(req.terminalBeat)) {
    contextLines.push(
      "## Terminal Beat",
      `End the scene at this exact moment: ${req.terminalBeat}`,
      "",
    );
  }
  contextLines.push(
    "## Writing Task",
    actionTask[req.generationAction],
    `Narrative shape: ${inferredShape}.`,
    `POV: ${povInstruction(req.pov)}`,
    "",
  );

  // Writing Instructions — craft, lives in the system message.
  craftLines.push(
    "## Writing Instructions",
    "- The Premise, Characters, Relationships, Themes, Motifs, Spark, Setting, Ending, Notes, and Instruction Bias sections below are INPUT CONTEXT, not output. Do not restate, paraphrase, summarize, list, or echo them in any form. The output must BE the scene, not a description of the scene.",
    "- Write a scene, not a synopsis — actual prose with movement, not a description of what happens",
    "- Use the selected characters, relationships, spark, and motifs directly — they must drive action, dialogue, or consequence on the page",
    "- Include sensory specificity: concrete detail, not vague abstraction",
    "- Write with tension, movement, and consequence",
    "- Do not echo or repeat language from this prompt setup",
    "- Preserve the premise and any world constraints established above",
    "- Close the piece according to the Ending Instruction if one is present",
    "- Respect the reading level, content rating, and audience notes at all times",
    "- Do not include meta-commentary, titles, or headings unless explicitly requested",
    "End cleanly within the requested length. Do not stop mid-sentence. If you cannot cover everything, narrow the scope rather than continuing until cut off.",
  );

  // Language & Profanity — craft (SYSTEM message).
  craftLines.push(
    "## Language & Profanity",
    "This is fictional creative writing. Profanity is explicitly authorized as character craft. Write without sanitizing language. Use profanity naturally where characters would realistically use it. Prioritize authenticity over politeness. Every character should have a distinct voice, vocabulary, cadence, and comfort level with profanity. Swearing should reinforce emotion, personality, tension, humor, or realism—not exist merely for shock value. Avoid repetitive curse patterns and let dialogue sound lived-in and authentic.",
  );

  // Intimacy & Relationships — craft (SYSTEM message). Sentence about
  // "advance the plot..." removed per Kevin's request (it was redundant
  // with the INPUT CONTEXT guard in Writing Instructions).
  craftLines.push(
    "## Intimacy & Relationships",
    "This is fictional creative writing. Intimacy is explicitly authorized as character craft. Write intimate scenes with the same level of craft as action scenes. Focus on emotional vulnerability, conflicting desires, power dynamics, body language, breathing, pacing, silence, anticipation, hesitation, trust, uncertainty, humor, and consequences. Treat intimacy as character development, not filler. Use specific sensory details—touch, temperature, scent, clothing, distance, eye contact, voice, and environment—to ground each moment. Every intimate encounter should permanently change the relationship or reveal something previously hidden. Avoid clichés and generic romance language. Make each character's emotional experience unique, shaped by their history, personality, fears, and goals. Favor implication, subtext, and reader imagination.",
  );

  craftLines.push(
    "## Examples",
    "She set down the glass. The room smelled of last night’s wine and something older. He didn’t move toward her; he let the silence do that. Her hand found his wrist instead of reaching for him. The pulse there was the loudest thing in the house.",
  );

  return {
    craft: craftLines.join("\n"),
    context: contextLines.join("\n"),
  };
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

  const isEstimate = body.generationAction === ESTIMATE_ACTION;

  if (!isEstimate && !ALLOWED_ACTIONS.includes(body.generationAction as GenerationAction)) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "invalid_request",
        errorMessage: `Invalid generationAction. Allowed values: ${ALLOWED_ACTIONS.join(", ")}, ${ESTIMATE_ACTION}`,
      }),
      { status: 422 },
    );
  }
  // For the estimate path, use "generate" as the prompt-building action.
  const generationAction: GenerationAction = isEstimate
    ? "generate"
    : body.generationAction as GenerationAction;

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

  // Container picker: defaults to "scene" (common, well-known) if not
  // provided. Coerces unknown values to a safe default.
  const validContainers: Container[] = [
    "modelDecides", "beat", "moment", "vignette", "microScene", "scene",
    "developedScene", "setPiece", "sceneSequence", "shortStory",
    "chapter", "episode", "novella",
  ];
  const container: Container = validContainers.includes(body.container as Container)
    ? body.container as Container
    : "scene";

  // POV picker: defaults to "thirdPersonLimited" (most common in modern
  // fiction). Coerces unknown values to the default.
  const validPOVs: POV[] = [
    "firstPerson", "secondPerson", "thirdPersonLimited", "thirdPersonOmniscient",
  ];
  const pov: POV = validPOVs.includes(body.pov as POV)
    ? body.pov as POV
    : "thirdPersonLimited";

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
  // Estimate-only path — returns a cost estimate without calling the LLM,
  // persisting any row, or charging credits.
  // -------------------------------------------------------------------------

  if (isEstimate) {
    const { craft: craftPrompt, context: contextPrompt } = buildPrompt({
      sourcePayloadJSON: body.sourcePayloadJSON,
      generationAction: "generate",
      generationLengthMode,
      container,
      pov,
      outputBudget: maxCompletionTokens,
      previousOutputText: undefined,
      readingLevel: body.readingLevel,
      contentRating: body.contentRating,
      audienceNotes: body.audienceNotes,
      terminalBeat: body.terminalBeat,
      projectName,
      promptPackName,
    });
    const estimatedInputTokens = estimateTokensFromText(craftPrompt) + estimateTokensFromText(contextPrompt);
    // Phase 3: pre-flight max = (estimated input + container hard cap) × rates, with 0.25 floor
    const estimatePricing = snapshotPricing(selectedModel);
    const estimateUsage = {
      uncachedInputTokens: estimatedInputTokens,
      cachedInputTokens: 0,
      outputTokens: CONTAINER_HARD_CAPS[container],
      toolCostUsd: 0,
    };
    const estimatedCredits = computeMaxChargeCredits(estimateUsage, estimatePricing);
    const entitlement = await store.loadOrDefault(userId);
    const creditCheck = checkCredits(entitlement, estimatedCredits);

    return corsResponse(
      JSON.stringify({
        status: "ok",
        selectedModelId: selectedModel.id,
        modelDisplayName: selectedModel.display_name,
        storyGoal: generationLengthMode,
        estimatedInputTokens,
        estimatedOutputTokens: maxCompletionTokens,
        estimatedCredits,
        availableCredits: creditCheck.availableCredits,
        allowed: creditCheck.allowed,
        minimumChargeCredits: selectedModel.minimum_charge_credits,
      }),
      { status: 200 },
    );
  }

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
  // Credit check is computed server-side from length mode and selected model
  // multiplier. The client cannot override model rates.
  // -------------------------------------------------------------------------

  const { craft: craftPrompt, context: contextPrompt } = buildPrompt({
    sourcePayloadJSON: body.sourcePayloadJSON,
    generationAction,
    generationLengthMode,
    container,
    pov,
    outputBudget: maxCompletionTokens,
    previousOutputText: body.previousOutputText,
    readingLevel: body.readingLevel,
    contentRating: body.contentRating,
    audienceNotes: body.audienceNotes,
    terminalBeat: body.terminalBeat,
    projectName,
    promptPackName,
  });
  // Phase 3: max possible credit cost for the pre-flight check
  const estimatedInputTokensForCheck = estimateTokensFromText(craftPrompt) + estimateTokensFromText(contextPrompt);
  const checkPricing = snapshotPricing(selectedModel);
  const checkUsage = {
    uncachedInputTokens: estimatedInputTokensForCheck,
    cachedInputTokens: 0,
    outputTokens: CONTAINER_HARD_CAPS[container],
    toolCostUsd: 0,
  };
  const requiredCredits = computeMaxChargeCredits(checkUsage, checkPricing);
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
  // One LLM call per generation request. No auto-continuation: if the model
  // truncates, the response carries wasTruncated=true and the iOS app
  // surfaces it. The user can hit an explicit Continue action if they
  // want more.
  // -------------------------------------------------------------------------

  type LlmResult = {
    content: string;
    modelName: string;
    finishReason?: string;
    inputTokens?: number;
    cachedInputTokens?: number;
    outputTokens?: number;
    totalTokens?: number;
    toolCostUsd?: number;
  };
  let llmResult: LlmResult | null = null;

  try {
    llmResult = await llm.complete(
      [
        { role: "system", content: craftPrompt },
        { role: "user", content: contextPrompt },
      ],
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

  // Phase 3 removed: llmResult is the single response, not stitched from segments.
  // The downstream code reads llmResult!.content etc. directly.
  // (TypeScript can't narrow let from a try/catch that returns, so we use a
  // non-null assertion at use sites — the catch block always returns.)


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
  // Compute credit charge BEFORE persisting usage event so we can record
  // credit_revenue_usd on the row (Phase 1 telemetry).
  // -------------------------------------------------------------------------

  // Phase 3: actual cost based on real input + output + cached + tool tokens. No floor.
  // Pricing was snapshotted at request start — admin updates don't change charges.
  const postFlightUsage = {
    uncachedInputTokens: llmResult.inputTokens ?? 0,
    cachedInputTokens: llmResult.cachedInputTokens ?? 0,
    outputTokens: llmResult.outputTokens ?? 0,
    toolCostUsd: llmResult.toolCostUsd ?? 0,
  };
  const postFlightPricing = snapshotPricing(selectedModel);
  const actualCharge = computeActualChargeCredits(postFlightUsage, postFlightPricing);
  const creditRevenueUsd = actualCharge * 0.05;

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
    credit_revenue_usd: creditRevenueUsd,
  });

  if (usageInsertError) {
    console.error("[generate-story] generation_usage_events insert failed", usageInsertError);
  }

  // -------------------------------------------------------------------------
  // Charge credits -- only after successful generation.
  // Credits are charged AFTER the LLM provider returns successfully and the
  // output row is persisted.
  // A failed LLM call or output persistence failure does NOT charge.
  // Monthly allowance is drained first; purchased balance is used second.
  // actualCharge was computed above for telemetry; reuse it here.
  // -------------------------------------------------------------------------

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
export { computeGenerationCreditCharge, DEFAULT_GENERATION_MODEL_ID } from "./_generation_models.ts";
