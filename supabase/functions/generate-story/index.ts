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
//
// NEVER place any of these values in the iOS app or commit them to source
// control. See docs/generate-story-edge-function.md for setup instructions.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildProviderFromEnv, LLMProvider } from "./_provider.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const ALLOWED_ACTIONS = ["generate", "regenerate", "continue", "remix"] as const;
type GenerationAction = typeof ALLOWED_ACTIONS[number];

const ALLOWED_LENGTH_MODES = ["short", "medium", "long", "chapter"] as const;
type LengthMode = typeof ALLOWED_LENGTH_MODES[number];

const MAX_BUDGET: Record<LengthMode, number> = {
  short: 800,
  medium: 1600,
  long: 3000,
  chapter: 6000,
};

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
  previousOutputText?: string;
  readingLevel?: string;
  contentRating?: string;
  audienceNotes?: string;
  localGenerationID?: string;
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
    short: "Write a short passage (roughly 300–500 words).",
    medium: "Write a medium-length passage (roughly 600–1000 words).",
    long: "Write a longer passage (roughly 1200–2000 words).",
    chapter: "Write a full chapter-length passage (roughly 2500–4000 words).",
  };

  const actionGuidance: Record<GenerationAction, string> = {
    generate:
      "Generate a brand-new story passage based on the details below.",
    regenerate:
      "Regenerate the story passage — produce a fresh take on the same source material.",
    continue:
      "Continue the story from where the previous passage left off. Do not repeat content that has already been written.",
    remix:
      "Remix the story — reinterpret the source material in a creative new direction while respecting the core characters and setting.",
  };

  const lines: string[] = [
    "You are a creative writing assistant helping authors craft compelling story content.",
    "",
    `Action: ${actionGuidance[req.generationAction]}`,
    `Length: ${lengthGuidance[req.generationLengthMode]}`,
    `Approximate maximum output: ${req.outputBudget} tokens.`,
    "",
  ];

  if (req.readingLevel) {
    lines.push(`Reading level: ${req.readingLevel}`);
  }
  if (req.contentRating) {
    lines.push(`Content rating: ${req.contentRating}`);
  }
  if (req.audienceNotes) {
    lines.push(`Audience notes: ${req.audienceNotes}`);
  }

  if (req.projectName) {
    lines.push(`Project: ${req.projectName}`);
  }
  if (req.promptPackName) {
    lines.push(`Prompt pack: ${req.promptPackName}`);
  }

  lines.push("", "--- Story context / prompt pack payload ---", payloadText);

  if (
    (req.generationAction === "continue" ||
      req.generationAction === "remix") &&
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
  // If the text begins with a markdown heading, use it as the title.
  const headingMatch = text.match(/^#{1,3}\s+(.+)/m);
  if (headingMatch) {
    return headingMatch[1].trim();
  }
  // Otherwise fall back to the pack/project name.
  return fallback || "";
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
async function handler(req: Request, provider?: LLMProvider): Promise<Response> {
  // Preflight
  if (req.method === "OPTIONS") {
    return corsResponse("", { status: 204 });
  }

  if (req.method !== "POST") {
    return corsResponse(
      JSON.stringify({ status: "failed", errorMessage: "Method not allowed" }),
      { status: 405 },
    );
  }

  // -------------------------------------------------------------------------
  // Auth — reject unauthenticated requests; derive user_id from JWT
  // -------------------------------------------------------------------------

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return corsResponse(
      JSON.stringify({ status: "failed", errorMessage: "Unauthorized" }),
      { status: 401 },
    );
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseURL || !supabaseAnonKey) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorMessage: "Server configuration error",
      }),
      { status: 500 },
    );
  }

  // Build a client scoped to the requesting user so RLS applies to all writes.
  const userClient = createClient(supabaseURL, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  // Verify JWT and extract user_id server-side. Never trust user_id from the body.
  const {
    data: { user },
    error: authError,
  } = await userClient.auth.getUser();

  if (authError || !user) {
    return corsResponse(
      JSON.stringify({ status: "failed", errorMessage: "Unauthorized" }),
      { status: 401 },
    );
  }

  const userId = user.id;

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
        errorMessage: "sourcePayloadJSON is required",
      }),
      { status: 422 },
    );
  }

  // Enforce server-side budget cap — do not trust the client value blindly.
  const serverMax = MAX_BUDGET[generationLengthMode];
  const outputBudget = Math.min(
    Math.max(1, Math.round(body.outputBudget ?? serverMax)),
    serverMax,
  );

  // previousOutputText is required for "continue" to avoid a no-op generation.
  if (generationAction === "continue" && !body.previousOutputText) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorMessage:
          "previousOutputText is required when generationAction is 'continue'",
      }),
      { status: 422 },
    );
  }

  const projectName = body.projectName ?? "";
  const promptPackName = body.promptPackName ?? "";

  // -------------------------------------------------------------------------
  // Resolve provider (injected or from env)
  // -------------------------------------------------------------------------

  let llm: LLMProvider;
  try {
    llm = provider ?? buildProviderFromEnv();
  } catch (err) {
    const msg = err instanceof Error ? err.message : "Provider configuration error";
    return corsResponse(
      JSON.stringify({ status: "failed", errorMessage: msg }),
      { status: 500 },
    );
  }

  // -------------------------------------------------------------------------
  // Build prompt and call LLM
  // -------------------------------------------------------------------------

  const systemPrompt = buildPrompt({
    sourcePayloadJSON: body.sourcePayloadJSON,
    generationAction,
    generationLengthMode,
    outputBudget,
    previousOutputText: body.previousOutputText,
    readingLevel: body.readingLevel,
    contentRating: body.contentRating,
    audienceNotes: body.audienceNotes,
    projectName,
    promptPackName,
  });

  let llmResult: { content: string; modelName: string; inputTokens?: number; outputTokens?: number };
  let providerFailed = false;
  let providerErrorMessage = "";

  try {
    llmResult = await llm.complete(
      [{ role: "user", content: systemPrompt }],
      outputBudget,
    );
  } catch (err) {
    providerFailed = true;
    providerErrorMessage = err instanceof Error ? err.message : "LLM provider error";
    llmResult = { content: "", modelName: "" };

    // Best-effort: record a failed usage event even if we cannot return content.
    await userClient.from("generation_usage_events").insert({
      user_id: userId,
      generation_output_id: null,
      action: generationAction,
      model_name: llmResult.modelName || Deno.env.get("OPENAI_MODEL_DEFAULT") || "gpt-4o-mini",
      input_tokens: null,
      output_tokens: null,
      generation_length_mode: generationLengthMode,
      output_budget: outputBudget,
      status: "failed",
    });

    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorMessage: `Generation failed: ${providerErrorMessage}`,
      }),
      { status: 502 },
    );
  }

  // -------------------------------------------------------------------------
  // Persist generation_outputs row
  // -------------------------------------------------------------------------

  const generatedText = llmResult.content.trim();
  const title = extractTitle(
    generatedText,
    promptPackName || projectName,
  );

  // Normalize sourcePayloadJSON for storage — always persist as an object.
  const sourcePayloadForDB =
    typeof body.sourcePayloadJSON === "string"
      ? JSON.parse(body.sourcePayloadJSON)
      : body.sourcePayloadJSON;

  const { data: outputRow, error: outputInsertError } = await userClient
    .from("generation_outputs")
    .insert({
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
      output_budget: outputBudget,
      status: "complete",
      visibility: "private",
    })
    .select("id")
    .single();

  if (outputInsertError) {
    // Log the error but do not block the response — the client still gets the
    // generated text. A usage event is still recorded without an output link.
    console.error("generation_outputs insert error:", outputInsertError);
  }

  const generationOutputId = outputRow?.id ?? null;

  // -------------------------------------------------------------------------
  // Persist generation_usage_events row
  // -------------------------------------------------------------------------

  const { error: usageInsertError } = await userClient
    .from("generation_usage_events")
    .insert({
      user_id: userId,
      generation_output_id: generationOutputId,
      action: generationAction,
      model_name: llmResult.modelName,
      input_tokens: llmResult.inputTokens ?? null,
      output_tokens: llmResult.outputTokens ?? null,
      generation_length_mode: generationLengthMode,
      output_budget: outputBudget,
      status: "complete",
    });

  if (usageInsertError) {
    console.error("generation_usage_events insert error:", usageInsertError);
  }

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
      outputBudget,
      inputTokens: llmResult.inputTokens,
      outputTokens: llmResult.outputTokens,
      status: "complete",
    }),
    { status: 200 },
  );
}

Deno.serve((req) => handler(req));

// Export handler for testing.
export { handler };
