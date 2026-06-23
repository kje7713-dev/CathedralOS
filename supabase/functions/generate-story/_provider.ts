// =============================================================================
// _provider.ts — Mockable OpenAI provider wrapper for generate-story
//
// Isolates all OpenAI API calls behind a single interface so tests can
// inject a mock without hitting the live API.
//
// Error contract:
//   Provider failures throw `ProviderError` with a stable `errorCode` field.
//   The handler maps these codes to app-facing error codes in the response.
//
// Timeout:
//   OpenAIProvider enforces PROVIDER_TIMEOUT_MS via AbortController.
//   If the provider does not respond in time, ProviderError("provider_timeout")
//   is thrown and credits are NOT charged.
// =============================================================================

/** Milliseconds before an OpenAI request is aborted with provider_timeout. */
export const PROVIDER_TIMEOUT_MS = 90_000;

// ---------------------------------------------------------------------------
// Stable provider error codes
// ---------------------------------------------------------------------------

export type ProviderErrorCode =
  | "provider_timeout"
  | "provider_insufficient_quota"
  | "provider_rate_limited"
  | "provider_overloaded"
  | "provider_rejected"
  | "invalid_request"
  | "unknown";

/**
 * Thrown by LLMProvider implementations when the upstream call fails.
 * Always carries a stable `errorCode` for consistent app-facing responses.
 */
export class ProviderError extends Error {
  constructor(
    message: string,
    public readonly errorCode: ProviderErrorCode,
    /** Whether a single retry is safe for this error type. */
    public readonly retryable: boolean = false,
  ) {
    super(message);
    this.name = "ProviderError";
  }
}

/**
 * Maps an OpenAI HTTP status code to a stable ProviderErrorCode.
 * Exported for unit testing.
 */
export function classifyOpenAIStatus(
  status: number,
  openAIErrorCode?: string,
): ProviderErrorCode {
  if (status === 429) {
    if (openAIErrorCode === "insufficient_quota") {
      return "provider_insufficient_quota";
    }
    return "provider_rate_limited";
  }
  if (status === 401 || status === 403) return "provider_rejected";
  if (status === 400 || status === 422) return "invalid_request";
  if (status >= 500) return "provider_overloaded";
  return "unknown";
}

interface OpenAIErrorDetails {
  status: number;
  code?: string;
  message: string;
  param?: string;
}

export function extractOpenAIErrorDetails(
  status: number,
  responseText: string,
): OpenAIErrorDetails {
  let code: string | undefined;
  let message = responseText.trim() || "Unknown OpenAI error";
  let param: string | undefined;

  try {
    const parsed = JSON.parse(responseText) as {
      error?: {
        code?: unknown;
        message?: unknown;
        param?: unknown;
        type?: unknown;
      };
    };
    const error = parsed?.error;
    if (error) {
      if (typeof error.code === "string" && error.code.length > 0) {
        code = error.code;
      } else if (typeof error.type === "string" && error.type.length > 0) {
        code = error.type;
      }

      if (typeof error.message === "string" && error.message.length > 0) {
        message = error.message;
      }

      if (typeof error.param === "string" && error.param.length > 0) {
        param = error.param;
      }
    }
  } catch {
    // Non-JSON responses keep the raw text fallback.
  }

  return { status, code, message, param };
}

export function formatOpenAIError(details: OpenAIErrorDetails): string {
  const parts = [
    `status=${details.status}`,
    `code=${details.code ?? "unknown"}`,
    `message=${details.message}`,
  ];
  if (details.param) {
    parts.push(`param=${details.param}`);
  }
  return `OpenAI error (${parts.join(", ")})`;
}

// deno-lint-ignore no-explicit-any
export function extractResponseText(json: any): string {
  if (typeof json?.output_text === "string") return json.output_text;

  const parts: string[] = [];
  for (const item of json?.output ?? []) {
    for (const content of item?.content ?? []) {
      if (
        content?.type === "output_text" &&
        typeof content?.text === "string"
      ) {
        parts.push(content.text);
      }
    }
  }
  return parts.join("");
}

function isTokenLimitIncompleteReason(reason: string): boolean {
  const normalized = reason.toLowerCase();
  return normalized === "max_output_tokens" ||
    normalized === "max_completion_tokens" ||
    normalized === "output_token_limit" ||
    normalized === "token_limit" ||
    (normalized.includes("token") &&
      (normalized.includes("max") || normalized.includes("limit")));
}

// deno-lint-ignore no-explicit-any
export function extractResponsesFinishReason(json: any): string | undefined {
  if (json?.status === "incomplete") {
    const reason = json?.incomplete_details?.reason;
    if (
      typeof reason === "string" &&
      isTokenLimitIncompleteReason(reason)
    ) {
      return "length";
    }
  }

  return typeof json?.status === "string" && json.status.length > 0
    ? json.status
    : undefined;
}

// ---------------------------------------------------------------------------
// LLM interface types
// ---------------------------------------------------------------------------

export interface LLMMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface LLMResponse {
  content: string;
  modelName: string;
  finishReason?: string;
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
  reasoningTokens?: number;
}

export interface LLMCompletionOptions {
  reasoning?: {
    effort: "none";
  };
}

export interface LLMProvider {
  complete(
    messages: LLMMessage[],
    maxTokens: number,
    providerModel?: string,
    options?: LLMCompletionOptions,
  ): Promise<LLMResponse>;
}

// ---------------------------------------------------------------------------
// OpenAI implementation
// ---------------------------------------------------------------------------

export class OpenAIProvider implements LLMProvider {
  private readonly apiKey: string;
  private readonly model: string;
  private readonly timeoutMs: number;

  constructor(
    apiKey: string,
    model: string,
    timeoutMs: number = PROVIDER_TIMEOUT_MS,
  ) {
    this.apiKey = apiKey;
    this.model = model;
    this.timeoutMs = timeoutMs;
  }

  async complete(
    messages: LLMMessage[],
    maxTokens: number,
    providerModel?: string,
    options?: LLMCompletionOptions,
  ): Promise<LLMResponse> {
    const resolvedModel = providerModel ?? this.model;
    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      this.timeoutMs,
    );

    const requestBody: Record<string, unknown> = {
      model: resolvedModel,
      input: messages,
      max_output_tokens: maxTokens,
      store: false,
    };
    if (resolvedModel.startsWith("gpt-5")) {
      requestBody.reasoning = options?.reasoning ?? { effort: "none" };
    }

    let resp: Response;
    try {
      resp = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      // AbortError → timeout; everything else is a network-level failure.
      if (err instanceof Error && err.name === "AbortError") {
        throw new ProviderError(
          `OpenAI request timed out after ${this.timeoutMs}ms (model=${resolvedModel})`,
          "provider_timeout",
          false,
        );
      }
      throw new ProviderError(
        `OpenAI network error: ${
          err instanceof Error ? err.message : String(err)
        }`,
        "unknown",
        true,
      );
    } finally {
      clearTimeout(timer);
    }

    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      const details = extractOpenAIErrorDetails(resp.status, text);
      const code = classifyOpenAIStatus(resp.status, details.code);
      console.error("[generate-story] OpenAI request failed", details);
      throw new ProviderError(
        formatOpenAIError(details),
        code,
        code === "provider_overloaded",
      );
    }

    // deno-lint-ignore no-explicit-any
    const json: any = await resp.json();
    return {
      content: extractResponseText(json),
      modelName: json.model ?? resolvedModel,
      finishReason: extractResponsesFinishReason(json),
      inputTokens: json.usage?.input_tokens,
      outputTokens: json.usage?.output_tokens,
      totalTokens: json.usage?.total_tokens,
      reasoningTokens: json.usage?.output_tokens_details?.reasoning_tokens ??
        json.usage?.reasoning_tokens,
    };
  }
}

// ---------------------------------------------------------------------------
// Factory — resolves provider from environment secrets
// ---------------------------------------------------------------------------

export function buildProviderFromEnv(): OpenAIProvider {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is not set");
  }
  const model = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5.4-mini";
  return new OpenAIProvider(apiKey, model);
}
