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

/**
 * PR-372: a single content block inside an LLMMessage — used for OpenAI
 * explicit cache breakpoint markers (GPT-5.6+ Responses API only). Adding
 * `prompt_cache_breakpoint: { mode: "explicit" }` to a block marks the END
 * of a stable prefix that OpenAI should cache. Content after the last
 * selected breakpoint is processed at uncached rates without a cache-write
 * charge.
 *
 * Do NOT add Anthropic-style `cache_control: { type: "ephemeral" }`
 * markers — OpenAI uses different field names. See PR-372 plan doc.
 */
export interface LLMContentBlock {
  /** OpenAI content block type. "input_text" for Responses API,
   *  "text" for Chat Completions API. The Responses API rejects "text"
   *  and the Chat Completions API rejects "input_text". */
  type: "input_text" | "text";
  text: string;
  /** PR-372: explicit cache breakpoint marker. Only valid in
   *  `options.cacheMode === "explicit"`. */
  prompt_cache_breakpoint?: { mode: "explicit" };
}

/** String for legacy callers; array of content blocks for explicit cache
 *  breakpoint support. */
export type LLMContent = string | LLMContentBlock[];

export interface LLMMessage {
  /** PR-372: added "developer" role (OpenAI Responses API stable content
   *  per the GPT-5.6+ prompt caching docs). */
  role: "system" | "developer" | "user" | "assistant";
  /** String for legacy callers; array of content blocks for explicit
   *  cache breakpoint support. */
  content: LLMContent;
}

export interface LLMResponse {
  content: string;
  modelName: string;
  finishReason?: string;
  inputTokens?: number;
  /** Cached input tokens (from OpenAI response.usage.prompt_tokens_details.cached_tokens). */
  cachedInputTokens?: number;
  /** PR-372: cache-write input tokens (from
   *  OpenAI response.usage.input_tokens_details.cache_write_tokens).
   *  Some providers / older model versions don't report this; undefined
   *  when absent. Used by the corrected provider COGS formula:
   *  `ordinaryUncached = max(0, totalInput - cached - cacheWrite)`. */
  cacheWriteInputTokens?: number;
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
 *
 * PR-372 additions: `cacheMode` + `promptCacheKey` enable OpenAI prompt
 * caching per the GPT-5.6+ cache boundary spec.
 *  - `cacheMode === "none"`     → no cache fields sent
 *  - `cacheMode === "implicit"` → sends `prompt_cache_key` only (automatic
 *                                 prefix matching). Default for most OpenAI
 *                                 models; safe fallback when the model
 *                                 doesn't support explicit mode.
 *  - `cacheMode === "explicit"` → adds top-level
 *                                 `prompt_cache_options: { mode: "explicit" }`
 *                                 plus `prompt_cache_breakpoint: { mode: "explicit" }`
 *                                 on the last stable content block.
 *                                 Responses API only; chat/completions
 *                                 downgrades to implicit (prompt_cache_key).
 *                                 Do NOT enable on models that don't
 *                                 support it (per PR-372 Kevin correction #2).
 */
export interface LLMProviderOptions {
  /** OpenAI Structured Outputs json_schema payload. */
  responseFormat?: unknown;
  /** Sampling temperature (0-2). Only forwarded by the chat/completions path. */
  temperature?: number;
  /** PR-372: cache capability for this request. */
  cacheMode?: "none" | "implicit" | "explicit";
  /** PR-372: stable cache key for grouping related requests. Generate-story
   *  sets this to `cath:proj:${projectId}:v1` so cache entries are reachable
   *  across Nth-of-project generations within the cache TTL window. */
  promptCacheKey?: string;
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
    return await this.callResponses(
      messages,
      maxTokens,
      resolvedModel,
      options,
    );
  }

  /**
   * PR-372: build the Responses API request body. Adds `prompt_cache_key`
   * and (in explicit mode) `prompt_cache_options: { mode: "explicit" }`
   * per the OpenAI GPT-5.6+ cache boundary spec. Content-block-level
   * `prompt_cache_breakpoint: { mode: "explicit" }` markers are added by
   * the caller (buildPrompt / index.ts) on the LAST stable content block
   * and pass through unchanged.
   */
  private buildResponsesBody(
    resolvedModel: string,
    messages: LLMMessage[],
    maxTokens: number,
    options?: LLMProviderOptions,
  ): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: resolvedModel,
      input: messages,
      max_output_tokens: maxTokens,
      store: false,
    };
    if (options?.promptCacheKey) {
      body.prompt_cache_key = options.promptCacheKey;
    }
    if (options?.cacheMode === "explicit") {
      // Top-level explicit-mode flag (OpenAI GPT-5.6+ Responses API).
      body.prompt_cache_options = { mode: "explicit" };
    }
    // "implicit" cacheMode sends prompt_cache_key only (no top-level
    // prompt_cache_options), which is OpenAI's automatic prefix matching
    // behavior. We deliberately do NOT send any cache field when
    // cacheMode === "none".
    return body;
  }

  private async callResponses(
    messages: LLMMessage[],
    maxTokens: number,
    resolvedModel: string,
    options?: LLMProviderOptions,
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
        // PR-372: cache fields are additive — when the caller does NOT
        // provide cacheMode / promptCacheKey, the request shape is
        // byte-identical to the pre-PR-372 generate-story path (no cache
        // fields sent). Preserves "no generation semantic changes" when
        // callers don't opt in.
        body: JSON.stringify(this.buildResponsesBody(
          resolvedModel,
          messages,
          maxTokens,
          options,
        )),
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
      // PR-372: extract cache_write_tokens. Some providers / older model
      // versions don't report this; treat undefined as 0 in the runner via
      // Math.max(0, ...) when reading.
      cacheWriteInputTokens: inputTokenDetails?.cache_write_tokens as
        | number
        | undefined,
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
    // PR-372: chat/completions supports prompt_cache_key but NOT
    // prompt_cache_options / prompt_cache_breakpoint (those are Responses
    // API only). When the caller passes cacheMode === "explicit" through
    // chat/completions, we downgrade to implicit by sending prompt_cache_key
    // only. chat/completions callers should use cacheMode "implicit" or
    // "none" to match their actual capability.
    if (options.promptCacheKey) {
      body.prompt_cache_key = options.promptCacheKey;
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
      // PR-372: cache_write_tokens from chat/completions usage.
      cacheWriteInputTokens:
        ((json.usage as Record<string, unknown> | undefined)
          ?.prompt_tokens_details as Record<string, unknown> | undefined)
          ?.cache_write_tokens as number | undefined,
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
