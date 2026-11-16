import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  computeMaxChargeCredits,
  estimateTokensFromMessages,
  type GenerationModel,
  inputTokenLimitDetails,
  isBillableGenerationModel,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";
import {
  availableCredits,
  checkCredits,
  type CreditStore,
} from "../generate-story/_credits.ts";
import {
  BillableLLMError,
  type BillableProviderResult,
  runBillableLLM,
} from "../_shared/billable-llm.ts";
import type { LLMMessage, LLMProvider } from "../generate-story/_provider.ts";

export interface SynopsisRequest {
  action?: "estimate" | "generate";
  project_id: string;
  title: string;
  source_text: string;
}

export interface SynopsisDependencies {
  adminClient: SupabaseClient;
  provider: LLMProvider;
  creditStore: CreditStore;
  defaultModel: string;
}

const MAX_SOURCE_CHARS = 100_000;
const MAX_OUTPUT_TOKENS = 320;

export function validateSynopsisRequest(body: unknown): SynopsisRequest {
  const value = body as Partial<SynopsisRequest> | null;
  if (
    value?.action !== undefined && value.action !== "estimate" &&
    value.action !== "generate"
  ) {
    throw new Error("action must be estimate or generate");
  }
  if (typeof value?.project_id !== "string" || !value.project_id.trim()) {
    throw new Error("project_id required");
  }
  if (typeof value?.title !== "string" || !value.title.trim()) {
    throw new Error("title required");
  }
  if (typeof value?.source_text !== "string" || !value.source_text.trim()) {
    throw new Error("source_text required");
  }
  if (value.source_text.length > MAX_SOURCE_CHARS) {
    throw new Error(`source_text exceeds ${MAX_SOURCE_CHARS} characters`);
  }
  return {
    action: value.action ?? "generate",
    project_id: value.project_id.trim(),
    title: value.title.trim().slice(0, 300),
    source_text: value.source_text.trim(),
  };
}

function buildMessages(request: SynopsisRequest): LLMMessage[] {
  return [
    {
      role: "system",
      content: [
        "You write back-cover copy for a completed fiction story.",
        "Return only one polished synopsis in plain text, with no heading, bullets, quotation marks, or commentary.",
        "Write 80 to 180 words.",
        "Establish the protagonist, central situation, setting, genre or tone, and main hook.",
        "Create curiosity without summarizing the ending or inventing facts not supported by the story.",
      ].join(" "),
    },
    {
      role: "user",
      content:
        `Title: ${request.title}\n\nStory source:\n${request.source_text}`,
    },
  ];
}

async function idempotencyKey(
  userID: string,
  request: SynopsisRequest,
): Promise<string> {
  const payload =
    `${userID}|${request.project_id}|${request.title}|${request.source_text}`;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(payload),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function resolveModel(
  deps: SynopsisDependencies,
): Promise<GenerationModel | null> {
  const result = await deps.adminClient.from("generation_models").select("*")
    .eq("provider_model", deps.defaultModel).maybeSingle();
  return result.data as GenerationModel | null;
}

function errorResponse(
  code: string,
  message: string,
  status: number,
): Response {
  return new Response(JSON.stringify({ errorCode: code, message }), {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Content-Type": "application/json",
    },
  });
}

export async function handleSynopsis(
  userID: string,
  request: SynopsisRequest,
  deps: SynopsisDependencies,
): Promise<Response> {
  const model = await resolveModel(deps);
  if (!model || !isBillableGenerationModel(model)) {
    return errorResponse(
      "model_unavailable_or_unpriced",
      "The synopsis model is unavailable or has unverified pricing.",
      400,
    );
  }

  const messages = buildMessages(request);
  const estimatedInputTokens = estimateTokensFromMessages(messages);
  const inputLimit = inputTokenLimitDetails(estimatedInputTokens);
  if (inputLimit) {
    return errorResponse(
      "input_token_limit_exceeded",
      `Estimated input is ${inputLimit.estimatedInputTokens} tokens; Cathedral's hard limit is ${inputLimit.limit} tokens`,
      413,
    );
  }

  const estimatedCredits = computeMaxChargeCredits({
    uncachedInputTokens: estimatedInputTokens,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: MAX_OUTPUT_TOKENS,
    toolCostUsd: 0,
  }, snapshotPricing(model));
  const entitlement = await deps.creditStore.loadOrDefault(userID);
  const creditCheck = checkCredits(entitlement, estimatedCredits);
  if (request.action === "estimate") {
    return new Response(
      JSON.stringify({
        estimated_credits: estimatedCredits,
        available_credits: availableCredits(entitlement),
        allowed: creditCheck.allowed,
      }),
      {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Content-Type": "application/json",
        },
      },
    );
  }
  if (!creditCheck.allowed) {
    return errorResponse(
      "insufficient_credits",
      "Not enough credits for a story synopsis.",
      402,
    );
  }

  const key = await idempotencyKey(userID, request);
  try {
    const result = await runBillableLLM<{ synopsis: string }>({
      userID,
      purpose: "epub-synopsis",
      action: "generate",
      model,
      messages,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      usageContext: {
        projectID: request.project_id,
        generationLengthMode: "short",
        outputBudget: MAX_OUTPUT_TOKENS,
        idempotencyKey: key,
      },
      onProviderSuccess: async (providerResult: BillableProviderResult) => {
        const synopsis = providerResult.content.trim().replace(
          /^['"]|['"]$/g,
          "",
        );
        const words = synopsis.split(/\s+/).filter(Boolean).length;
        if (words < 40 || words > 220) {
          throw new Error("Synopsis length was outside the supported range");
        }
        return { synopsis };
      },
    }, {
      adminClient: deps.adminClient,
      provider: deps.provider,
      creditStore: deps.creditStore,
    });
    return new Response(JSON.stringify(result.featureResult), {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Content-Type": "application/json",
      },
    });
  } catch (error) {
    if (
      error instanceof BillableLLMError && error.code === "insufficient_credits"
    ) return errorResponse("insufficient_credits", error.message, 402);
    const code = (error as { errorCode?: string })?.errorCode;
    if (code === "provider_timeout") {
      return errorResponse(
        code,
        "The synopsis provider timed out. No credits were charged.",
        504,
      );
    }
    return errorResponse(
      "synopsis_generation_failed",
      error instanceof Error ? error.message : String(error),
      502,
    );
  }
}

export { buildMessages, MAX_OUTPUT_TOKENS };
