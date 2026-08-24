// =============================================================================
// generate-story/_provider_test.ts
//
// Tests for the OpenAIProvider dual-mode routing. Per PR #407 Blocker 2:
//   - responseFormat present  -> chat/completions + Structured Outputs
//   - responseFormat absent   -> Responses API
//
// No real OpenAI requests — fetch is mocked via a global stub.
// =============================================================================

import {
  assertEquals,
  assertExists,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { OpenAIProvider, PROVIDER_TIMEOUT_MS } from "./_provider.ts";

// ---------------------------------------------------------------------------
// fetch stub — captures the outgoing request so we can assert URL + body shape.
// ---------------------------------------------------------------------------

interface CapturedRequest {
  url: string;
  init: RequestInit;
  body: Record<string, unknown>;
}

let lastRequest: CapturedRequest | null = null;
const originalFetch = globalThis.fetch;

function installFetchStub(responseJson: Record<string, unknown>): void {
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const bodyText = init?.body ? String(init.body) : "{}";
    lastRequest = {
      url,
      init: init ?? {},
      body: JSON.parse(bodyText) as Record<string, unknown>,
    };
    return Promise.resolve(
      new Response(JSON.stringify(responseJson), { status: 200 }),
    );
  }) as typeof fetch;
}

function uninstallFetchStub(): void {
  globalThis.fetch = originalFetch as typeof fetch;
}

function chatCompletionsResponse(content: string): Record<string, unknown> {
  return {
    id: "chatcmpl-test",
    object: "chat.completion",
    created: 0,
    model: "gpt-4o-mini",
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: 100,
      completion_tokens: 50,
      total_tokens: 150,
      prompt_tokens_details: { cached_tokens: 0 },
    },
  };
}

function responsesApiResponse(content: string): Record<string, unknown> {
  return {
    id: "resp_test",
    object: "response",
    created: 0,
    model: "gpt-4o-mini",
    status: "completed",
    output: [
      {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: content }],
      },
    ],
    usage: {
      input_tokens: 100,
      input_tokens_details: { cached_tokens: 0 },
      output_tokens: 50,
      total_tokens: 150,
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("OpenAIProvider: responseFormat present routes to chat/completions + Structured Outputs", async () => {
  installFetchStub(chatCompletionsResponse("ok"));
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-4o-mini",
      PROVIDER_TIMEOUT_MS,
    );
    const response = await provider.complete(
      [
        { role: "system", content: "system prompt" },
        { role: "user", content: "user prompt" },
      ],
      1500,
      "gpt-4o-mini",
      {
        responseFormat: {
          type: "json_schema",
          json_schema: { name: "warnings" },
        },
        temperature: 0.2,
      },
    );
    assertExists(lastRequest);
    assertStringIncludes(lastRequest.url, "/v1/chat/completions");
    assertEquals(lastRequest.body.model, "gpt-4o-mini");
    // The Structured Outputs schema MUST be forwarded.
    assertExists((lastRequest.body as Record<string, unknown>).response_format);
    // Temperature MUST be forwarded.
    assertEquals(lastRequest.body.temperature, 0.2);
    assertEquals(lastRequest.body.max_completion_tokens, 1500);
    // Messages MUST be in the chat/completions array shape.
    assertExists(
      Array.isArray((lastRequest.body as Record<string, unknown>).messages),
    );
    assertEquals(response.content, "ok");
    assertEquals(response.modelName, "gpt-4o-mini");
    assertEquals(response.inputTokens, 100);
    assertEquals(response.outputTokens, 50);
  } finally {
    uninstallFetchStub();
  }
});

Deno.test("OpenAIProvider: responseFormat absent preserves Responses API path", async () => {
  installFetchStub(responsesApiResponse("ok"));
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-4o-mini",
      PROVIDER_TIMEOUT_MS,
    );
    const response = await provider.complete(
      [
        { role: "system", content: "system prompt" },
        { role: "user", content: "user prompt" },
      ],
      2300,
      "gpt-4o-mini",
    );
    assertExists(lastRequest);
    // No options -> Responses API (the old /v1/responses endpoint).
    assertStringIncludes(lastRequest.url, "/v1/responses");
    assertEquals(lastRequest.body.model, "gpt-4o-mini");
    assertEquals(lastRequest.body.max_output_tokens, 2300);
    // Responses API uses `input` (messages array), NOT `messages`.
    assertExists(
      Array.isArray((lastRequest.body as Record<string, unknown>).input),
    );
    assertEquals(
      (lastRequest.body as Record<string, unknown>).response_format,
      undefined,
      "response_format MUST NOT be set on Responses API requests",
    );
    assertEquals(response.content, "ok");
    assertEquals(response.inputTokens, 100);
    assertEquals(response.outputTokens, 50);
  } finally {
    uninstallFetchStub();
  }
});
