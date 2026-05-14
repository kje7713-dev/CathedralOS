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
  status: "complete";
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
  const payloadText =
    typeof req.sourcePayloadJSON === "string"
      ? req.sourcePayloadJSON
      : JSON.stringify(req.sourcePayloadJSON, null, 2);

  const lengthGuidance: Record<LengthMode, string> = {
    short: "Write a short passage (roughly 300-500 words).",
    medium: "Write a medium-length passage (roughly 600-1000 words).",
    long: "Write a longer passage (roughly 1200-2000 words).",
    chapter: "Write a full chapter-length passage (roughly 2500-4000 words).",
  };

  const actionGuidance: Record<GenerationAction, string> = {
    generate:
      "Generate a brand-new story passage based on the details below.",
    regenerate:
      "Regenerate the story passage -- produce a fresh take on the same source material.",
    continue:
      "Continue the story from where the previous passage left off. Do not repeat content that has already been written.",
    remix:
      "Remix the story -- reinterpret the source material in a creative new direction while respecting the core characters and setting.",
  };

  const lines: string[] = [
    "You are a creative writing assistant helping authors craft compelling story content.",
    "",
    `Action: ${actionGuidance[req.generationAction]}`,
    `Length: ${lengthGuidance[req.generationLengthMode]}`,
    `Approximate maximum output: ${req.outputBudget} tokens.`,
    "",
  ];

  if (req.readingLevel) lines.push(`Reading level: ${req.readingLevel}`);
  if (req.contentRating) lines.push(`Content rating: ${req.contentRating}`);
  if (req.audienceNotes) lines.push(`Audience notes: ${req.audienceNotes}`);
  if (req.projectName) lines.push(`Project: ${req.projectName}`);
  if (req.promptPackName) lines.push(`Prompt pack: ${req.promptPackName}`);

  lines.push("", "--- Story context / prompt pack payload ---", payloadText);

  if (
    (req.generationAction === "continue" || req.generationAction === "remix") &&
    req.previousOutputText
  ) {
    lines.push(
      "",
      "--- Previous output (do not repeat verbatim) ---",
      req.previousOutputText,
    );
  }

  lines.push(
    "",
    "Write only the story content. Do not include meta-commentary, titles, or headings unless the prompt pack explicitly requests them.",
    "Respect the reading level, content rating, and audience notes above at all times.",
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
    let httpStatus = 502;
    const isTimeout = err instanceof ProviderError && err.errorCode === "provider_timeout";

    if (err instanceof ProviderError) {
      providerErrorCode = err.errorCode;
      if (isTimeout) httpStatus = 504;
      if (providerErrorCode === "provider_rate_limited") httpStatus = 429;
    }

    const providerErrorMessage = err instanceof Error ? err.message : "LLM provider error";

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
    // Skipped on provider_timeout — no output was produced and credits are not charged.
    if (!isTimeout) {
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
      JSON.stringify({
        status: "failed",
        errorCode: providerErrorCode,
        errorMessage: `Generation failed: ${providerErrorMessage}`,
        ...(providerErrorCode === "provider_rate_limited" ? { retryAfterSeconds: 60 } : {}),
      }),
      {
        status: httpStatus,
        ...(providerErrorCode === "provider_rate_limited"
          ? { headers: { "Retry-After": "60" } }
          : {}),
      },
    );
  }

  // -------------------------------------------------------------------------
  // Persist generation_outputs row
  // -------------------------------------------------------------------------

  const generatedText = llmResult.content.trim();
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
    status: "complete",
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
    status: "success",
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
      selectedModelId,
      outputBudget: maxCompletionTokens,
      inputTokens: llmResult.inputTokens,
      outputTokens: llmResult.outputTokens,
      totalTokens: llmResult.totalTokens,
      creditCostCharged: actualCharge,
      remainingCredits,
      status: "complete",
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
