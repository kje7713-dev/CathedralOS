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

export function extractResponseText(json: Record<string, unknown>): string {
  if (typeof json?.output_text === "string") return json.output_text;

  const parts: string[] = [];
  const output = json.output as Array<Record<string, unknown>> | undefined;
  for (const item of output ?? []) {
    const contents = item.content as Array<Record<string, unknown>> | undefined;
    for (const content of contents ?? []) {
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

export function extractResponsesFinishReason(
  json: Record<string, unknown>,
): string | undefined {
  if (json?.status === "incomplete") {
    const incomplete = json.incomplete_details as
      | Record<string, unknown>
      | undefined;
    const reason = incomplete?.reason;
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
  /** Cached input tokens (from OpenAI response.usage.prompt_tokens_details.cached_tokens). */
  cachedInputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
  /** Additional tool / function-call cost in USD. 0 for most chat models. */
  toolCostUsd?: number;
}

/**
 * Provider-specific knobs. Coherence-check sets `responseFormat` to enable
 * Structured Outputs via the chat/completions endpoint. Generate-story leaves
 * it unset and uses the Responses API path. `temperature` is forwarded to
 * chat/completions when set; ignored by the Responses API (it controls its
 * own sampling).
 */
export interface LLMProviderOptions {
  /** OpenAI Structured Outputs json_schema payload. */
  responseFormat?: unknown;
  /** Sampling temperature (0-2). Only forwarded by the chat/completions path. */
  temperature?: number;
}

export interface LLMProvider {
  complete(
    messages: LLMMessage[],
    maxTokens: number,
    providerModel?: string,
    options?: LLMProviderOptions,
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
    options?: LLMProviderOptions,
  ): Promise<LLMResponse> {
    const resolvedModel = providerModel ?? this.model;
    // Route on options.responseFormat: if set, use chat/completions with
    // Structured Outputs (coherence-check path). Otherwise use the Responses
    // API (generate-story path; preserves prior behavior).
    if (options?.responseFormat) {
      return await this.callChatCompletions(
        messages,
        maxTokens,
        resolvedModel,
        options,
      );
    }
    return await this.callResponses(messages, maxTokens, resolvedModel);
  }

  private async callResponses(
    messages: LLMMessage[],
    maxTokens: number,
    resolvedModel: string,
  ): Promise<LLMResponse> {
    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      this.timeoutMs,
    );

    let resp: Response;
    try {
      resp = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify({
          model: resolvedModel,
          input: messages,
          max_output_tokens: maxTokens,
          store: false,
        }),
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

    const json: Record<string, unknown> = await resp.json();
    const usage = json.usage as Record<string, unknown> | undefined;
    const inputTokenDetails = usage?.input_tokens_details as
      | Record<string, unknown>
      | undefined;
    return {
      content: extractResponseText(json),
      modelName: typeof json.model === "string" ? json.model : resolvedModel,
      finishReason: extractResponsesFinishReason(json),
      inputTokens: usage?.input_tokens as number | undefined,
      cachedInputTokens: inputTokenDetails?.cached_tokens as number | undefined,
      outputTokens: usage?.output_tokens as number | undefined,
      totalTokens: usage?.total_tokens as number | undefined,
      toolCostUsd: 0,
    };
  }

  /**
   * chat/completions path used by coherence-check. Returns content from
   * `choices[0].message.content` and token counts from `usage`. Supports
   * Structured Outputs via `response_format` when supplied.
   */
  private async callChatCompletions(
    messages: LLMMessage[],
    maxTokens: number,
    resolvedModel: string,
    options: LLMProviderOptions,
  ): Promise<LLMResponse> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);

    const body: Record<string, unknown> = {
      model: resolvedModel,
      messages,
      max_completion_tokens: maxTokens,
    };
    if (options.responseFormat) {
      body.response_format = options.responseFormat;
    }
    if (typeof options.temperature === "number") {
      body.temperature = options.temperature;
    }

    let resp: Response;
    try {
      resp = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      if (err instanceof Error && err.name === "AbortError") {
        throw new ProviderError(
          `OpenAI chat/completions timed out after ${this.timeoutMs}ms (model=${resolvedModel})`,
          "provider_timeout",
          false,
        );
      }
      throw new ProviderError(
        `OpenAI chat/completions network error: ${
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
      throw new ProviderError(
        formatOpenAIError(details),
        code,
        code === "provider_overloaded",
      );
    }

    const json: Record<string, unknown> = await resp.json();
    const choices = json.choices;
    const choice = Array.isArray(choices)
      ? choices[0] as Record<string, unknown> | undefined
      : undefined;
    const message = choice?.message as Record<string, unknown> | undefined;
    const rawContent = message?.content;
    const content = typeof rawContent === "string" ? rawContent : "";
    return {
      content,
      modelName: typeof json.model === "string" ? json.model : resolvedModel,
      finishReason: typeof choice?.finish_reason === "string"
        ? choice.finish_reason
        : undefined,
      inputTokens: (json.usage as Record<string, unknown> | undefined)
        ?.prompt_tokens as number | undefined,
      cachedInputTokens: ((json.usage as Record<string, unknown> | undefined)
        ?.prompt_tokens_details as Record<string, unknown> | undefined)
        ?.cached_tokens as number | undefined,
      outputTokens: (json.usage as Record<string, unknown> | undefined)
        ?.completion_tokens as number | undefined,
      totalTokens: (json.usage as Record<string, unknown> | undefined)
        ?.total_tokens as number | undefined,
      toolCostUsd: 0,
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
  const model = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini";
  return new OpenAIProvider(apiKey, model);
}
