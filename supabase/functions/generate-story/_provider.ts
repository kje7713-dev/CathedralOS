// =============================================================================
// _provider.ts — Mockable OpenAI provider wrapper for generate-story
//
// Isolates all OpenAI API calls behind a single interface so tests can
// inject a mock without hitting the live API.
// =============================================================================

export interface LLMMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface LLMResponse {
  content: string;
  modelName: string;
  inputTokens?: number;
  outputTokens?: number;
}

export interface LLMProvider {
  complete(
    messages: LLMMessage[],
    maxTokens: number,
  ): Promise<LLMResponse>;
}

// ---------------------------------------------------------------------------
// OpenAI implementation
// ---------------------------------------------------------------------------

export class OpenAIProvider implements LLMProvider {
  private readonly apiKey: string;
  private readonly model: string;

  constructor(apiKey: string, model: string) {
    this.apiKey = apiKey;
    this.model = model;
  }

  async complete(messages: LLMMessage[], maxTokens: number): Promise<LLMResponse> {
    const body = JSON.stringify({
      model: this.model,
      messages,
      max_tokens: maxTokens,
    });

    const resp = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`,
      },
      body,
    });

    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      throw new Error(`OpenAI error ${resp.status}: ${text}`);
    }

    // deno-lint-ignore no-explicit-any
    const json: any = await resp.json();
    const choice = json.choices?.[0];
    if (!choice) {
      throw new Error("OpenAI returned no choices");
    }

    return {
      content: choice.message?.content ?? "",
      modelName: json.model ?? this.model,
      inputTokens: json.usage?.prompt_tokens,
      outputTokens: json.usage?.completion_tokens,
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
  const model =
    Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini";
  return new OpenAIProvider(apiKey, model);
}
