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
export function classifyOpenAIStatus(status: number): ProviderErrorCode {
  if (status === 429) return "provider_rate_limited";
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
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
}

export interface LLMProvider {
  complete(
    messages: LLMMessage[],
    maxTokens: number,
    providerModel?: string,
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
  ): Promise<LLMResponse> {
    const resolvedModel = providerModel ?? this.model;
    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      this.timeoutMs,
    );

    let resp: Response;
    try {
      resp = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify({
          model: resolvedModel,
          messages,
          max_completion_tokens: maxTokens,
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
      const code = classifyOpenAIStatus(resp.status);
      const details = extractOpenAIErrorDetails(resp.status, text);
      console.error("[generate-story] OpenAI request failed", details);
      throw new ProviderError(
        formatOpenAIError(details),
        code,
        code === "provider_overloaded",
      );
    }

    // deno-lint-ignore no-explicit-any
    const json: any = await resp.json();
    const choice = json.choices?.[0];
    if (!choice) {
      throw new ProviderError("OpenAI returned no choices", "unknown", false);
    }

    return {
      content: choice.message?.content ?? "",
      modelName: json.model ?? resolvedModel,
      inputTokens: json.usage?.prompt_tokens,
      outputTokens: json.usage?.completion_tokens,
      totalTokens: json.usage?.total_tokens,
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
