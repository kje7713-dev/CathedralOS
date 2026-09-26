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
        {
          role: "system",
          content: [{ type: "input_text", text: "system prompt" }],
        },
        {
          role: "user",
          content: [{ type: "input_text", text: "user prompt" }],
        },
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
    const messages = (lastRequest.body as Record<string, unknown>)
      .messages as Array<Record<string, unknown>>;
    assertEquals(Array.isArray(messages), true);
    assertEquals(messages[0].content, [{
      type: "text",
      text: "system prompt",
    }]);
    assertEquals(messages[1].content, [{ type: "text", text: "user prompt" }]);
    assertEquals(response.content, "ok");
    assertEquals(response.modelName, "gpt-4o-mini");
    assertEquals(response.inputTokens, 100);
    assertEquals(response.outputTokens, 50);
  } finally {
    uninstallFetchStub();
  }
});

Deno.test("OpenAIProvider: Responses structured output preserves cache boundary", async () => {
  installFetchStub(responsesApiResponse('{"scene":"ok"}'));
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-5.6-luna",
      PROVIDER_TIMEOUT_MS,
    );
    await provider.complete(
      [
        {
          role: "developer",
          content: [{
            type: "input_text",
            text: "stable prompt",
            prompt_cache_breakpoint: { mode: "explicit" },
          }],
        },
        { role: "user", content: [{ type: "input_text", text: "task" }] },
      ],
      4500,
      "gpt-5.6-luna",
      {
        responseFormatTarget: "responses",
        responseFormat: {
          type: "json_schema",
          json_schema: {
            name: "scene",
            strict: true,
            schema: { type: "object" },
          },
        },
        cacheMode: "explicit",
        promptCacheKey: "cath:test:v1",
      },
    );
    assertExists(lastRequest);
    assertStringIncludes(lastRequest.url, "/v1/responses");
    assertEquals(lastRequest.body.text, {
      format: {
        type: "json_schema",
        name: "scene",
        strict: true,
        schema: { type: "object" },
      },
    });
    assertEquals(lastRequest.body.prompt_cache_options, { mode: "explicit" });
    assertEquals(lastRequest.body.prompt_cache_key, "cath:test:v1");
    assertEquals(
      (lastRequest.body.input as Array<Record<string, unknown>>)[0].content,
      [{
        type: "input_text",
        text: "stable prompt",
        prompt_cache_breakpoint: { mode: "explicit" },
      }],
    );
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

// =============================================================================
// Provider error classification — spec-required cases
//
// Kevin 2026-09-21:
//   - 429 + credit_balance_exhausted → provider_billing_unavailable
//     (NON-RETRYABLE; treated as its own stable internal condition;
//      must NOT be classified as provider_rate_limited)
//   - 429 + insufficient_quota → existing insufficient-quota behavior
//   - ordinary 429 (no upstream code) → provider_rate_limited
// =============================================================================

import {
  classifyOpenAIStatus,
  extractOpenAIErrorDetails,
  formatOpenAIError,
  getProviderBillingUnavailableUpstream,
  isProviderBillingUnavailable,
  ProviderBillingUnavailableError,
  ProviderError,
} from "./_provider.ts";

Deno.test("classifyOpenAIStatus: 429 + credit_balance_exhausted → provider_billing_unavailable", () => {
  assertEquals(
    classifyOpenAIStatus(429, "credit_balance_exhausted"),
    "provider_billing_unavailable",
  );
});

Deno.test("classifyOpenAIStatus: 429 + organization_spend_limit_exceeded → provider_billing_unavailable", () => {
  assertEquals(
    classifyOpenAIStatus(429, "organization_spend_limit_exceeded"),
    "provider_billing_unavailable",
  );
});

Deno.test("classifyOpenAIStatus: 429 + insufficient_quota → provider_insufficient_quota", () => {
  assertEquals(
    classifyOpenAIStatus(429, "insufficient_quota"),
    "provider_insufficient_quota",
  );
});

Deno.test("classifyOpenAIStatus: ordinary 429 without upstream code → provider_rate_limited", () => {
  assertEquals(classifyOpenAIStatus(429), "provider_rate_limited");
  assertEquals(classifyOpenAIStatus(429, undefined), "provider_rate_limited");
  assertEquals(
    classifyOpenAIStatus(429, "some_other_code"),
    "provider_rate_limited",
  );
});

Deno.test("classifyOpenAIStatus: 401/403 → provider_rejected (preserved)", () => {
  assertEquals(classifyOpenAIStatus(401), "provider_rejected");
  assertEquals(classifyOpenAIStatus(403), "provider_rejected");
});

Deno.test("classifyOpenAIStatus: 5xx → provider_overloaded (preserved)", () => {
  assertEquals(classifyOpenAIStatus(500), "provider_overloaded");
  assertEquals(classifyOpenAIStatus(503), "provider_overloaded");
});

Deno.test("extractOpenAIErrorDetails: parses credit_balance_exhausted from real OpenAI payload", () => {
  const raw = JSON.stringify({
    error: {
      message: "You have no credits remaining...",
      type: "insufficient_quota",
      param: null,
      code: "credit_balance_exhausted",
    },
  });
  const details = extractOpenAIErrorDetails(429, raw);
  assertEquals(details.status, 429);
  assertEquals(details.code, "credit_balance_exhausted");
  assertStringIncludes(details.message, "credits remaining");
});

Deno.test("formatOpenAIError: includes status, upstream code, and message", () => {
  const raw = JSON.stringify({
    error: {
      message: "no credits",
      code: "credit_balance_exhausted",
    },
  });
  const formatted = formatOpenAIError(extractOpenAIErrorDetails(429, raw));
  assertStringIncludes(formatted, "status=429");
  assertStringIncludes(formatted, "code=credit_balance_exhausted");
  assertStringIncludes(formatted, "no credits");
});

// =============================================================================
// ProviderError / ProviderBillingUnavailableError contract
// =============================================================================

Deno.test("ProviderError: carries stable errorCode + upstream + retryable flag", () => {
  const err = new ProviderError(
    "OpenAI error (status=429, code=credit_balance_exhausted, message=...)",
    "provider_billing_unavailable",
    false,
    { code: "credit_balance_exhausted", message: "no credits", status: 429 },
  );
  assertEquals(err.errorCode, "provider_billing_unavailable");
  assertEquals(err.retryable, false);
  assertEquals(err.upstream?.code, "credit_balance_exhausted");
  assertEquals(err.upstream?.status, 429);
  assertEquals(err.name, "ProviderError");
});

Deno.test("ProviderBillingUnavailableError: is a ProviderError with stable code + upstream", () => {
  const err = new ProviderBillingUnavailableError({
    code: "credit_balance_exhausted",
    message: "no credits remaining",
    status: 429,
  });
  assertEquals(err instanceof ProviderError, true);
  assertEquals(err instanceof ProviderBillingUnavailableError, true);
  assertEquals(err.errorCode, "provider_billing_unavailable");
  assertEquals(err.retryable, false);
  assertEquals(err.upstream?.code, "credit_balance_exhausted");
  assertEquals(err.upstream?.status, 429);
  assertEquals(err.name, "ProviderBillingUnavailableError");
  assertStringIncludes(err.message, "billing unavailable");
});

Deno.test("ProviderBillingUnavailableError: default upstream.code propagates into message", () => {
  const err = new ProviderBillingUnavailableError({
    code: "credit_balance_exhausted",
  });
  assertStringIncludes(err.message, "credit_balance_exhausted");
});

// =============================================================================
// Provider-level mocked-fetch tests (Kevin 2026-09-21 #3):
//   Mocked OpenAI 429 credit_balance_exhausted response MUST surface as
//   ProviderBillingUnavailableError with retryable=false and upstream.code
//   populated from the OpenAI error.code field.
// =============================================================================

Deno.test("OpenAIProvider: Responses API 429 credit_balance_exhausted → ProviderBillingUnavailableError(retryable=false, upstream.code=credit_balance_exhausted)", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((_input: string | URL | Request, _init?: RequestInit) => {
    return Promise.resolve(
      new Response(
        JSON.stringify({
          error: {
            code: "credit_balance_exhausted",
            message: "You have no credits remaining on this account.",
            type: "insufficient_quota",
            param: null,
          },
        }),
        { status: 429, headers: { "content-type": "application/json" } },
      ),
    );
  }) as typeof fetch;
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-5.6-luna",
      PROVIDER_TIMEOUT_MS,
    );
    let caught: unknown;
    try {
      await provider.complete(
        [{ role: "user", content: "hi" }],
        100,
        "gpt-5.6-luna",
      );
    } catch (e) {
      caught = e;
    }
    assertExists(caught);
    assertEquals(caught instanceof ProviderBillingUnavailableError, true);
    assertEquals(
      (caught as ProviderBillingUnavailableError).errorCode,
      "provider_billing_unavailable",
    );
    assertEquals((caught as ProviderBillingUnavailableError).retryable, false);
    assertEquals(
      (caught as ProviderBillingUnavailableError).upstream?.code,
      "credit_balance_exhausted",
    );
    assertEquals(
      (caught as ProviderBillingUnavailableError).upstream?.status,
      429,
    );
    assertStringIncludes(
      (caught as ProviderBillingUnavailableError).message,
      "credit_balance_exhausted",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("OpenAIProvider: chat/completions 429 credit_balance_exhausted → ProviderBillingUnavailableError(retryable=false)", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((_input: string | URL | Request, _init?: RequestInit) => {
    return Promise.resolve(
      new Response(
        JSON.stringify({
          error: {
            code: "credit_balance_exhausted",
            message: "no credits",
            type: "insufficient_quota",
          },
        }),
        { status: 429, headers: { "content-type": "application/json" } },
      ),
    );
  }) as typeof fetch;
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-4o-mini",
      PROVIDER_TIMEOUT_MS,
    );
    let caught: unknown;
    try {
      await provider.complete(
        [{ role: "user", content: "hi" }],
        100,
        "gpt-4o-mini",
        {
          responseFormat: { type: "json_schema" },
          responseFormatTarget: "chat",
        },
      );
    } catch (e) {
      caught = e;
    }
    assertExists(caught);
    assertEquals(caught instanceof ProviderBillingUnavailableError, true);
    assertEquals(
      (caught as ProviderBillingUnavailableError).errorCode,
      "provider_billing_unavailable",
    );
    assertEquals((caught as ProviderBillingUnavailableError).retryable, false);
    assertEquals(
      (caught as ProviderBillingUnavailableError).upstream?.code,
      "credit_balance_exhausted",
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("OpenAIProvider: 429 without upstream code still produces ProviderError (NOT provider_billing_unavailable)", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = ((_input: string | URL | Request, _init?: RequestInit) => {
    return Promise.resolve(
      new Response("rate limited", { status: 429 }),
    );
  }) as typeof fetch;
  try {
    const provider = new OpenAIProvider(
      "test-key",
      "gpt-4o-mini",
      PROVIDER_TIMEOUT_MS,
    );
    let caught: unknown;
    try {
      await provider.complete(
        [{ role: "user", content: "hi" }],
        100,
        "gpt-4o-mini",
      );
    } catch (e) {
      caught = e;
    }
    assertExists(caught);
    // Must NOT be ProviderBillingUnavailableError (no upstream code).
    assertEquals(caught instanceof ProviderBillingUnavailableError, false);
    assertEquals(caught instanceof ProviderError, true);
    assertEquals((caught as ProviderError).errorCode, "provider_rate_limited");
    // Retry is NOT the provider's job — the upstream catch chain
    // (run-outline RetryableGenerationError) handles the delayed retry.
    // The provider just throws; retryable=false is the correct contract.
    assertEquals((caught as ProviderError).retryable, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

// =============================================================================
// Canonical predicates (isProviderBillingUnavailable / getProviderBillingUnavailableUpstream)
// must NOT classify by parsing messages — only stable-code surfaces.
// =============================================================================

Deno.test("isProviderBillingUnavailable: detects ProviderBillingUnavailableError instance", () => {
  assertEquals(
    isProviderBillingUnavailable(
      new ProviderBillingUnavailableError({
        code: "credit_balance_exhausted",
        status: 429,
      }),
    ),
    true,
  );
});

Deno.test("isProviderBillingUnavailable: detects ProviderError with errorCode", () => {
  assertEquals(
    isProviderBillingUnavailable(
      new ProviderError("...", "provider_billing_unavailable", false),
    ),
    true,
  );
});

Deno.test("isProviderBillingUnavailable: detects SectionEmbeddingError-shaped object", () => {
  assertEquals(
    isProviderBillingUnavailable({ code: "provider_billing_unavailable" }),
    true,
  );
});

Deno.test("isProviderBillingUnavailable: does NOT match plain string containing 'billing'", () => {
  // MUST NOT classify by parsing human-readable messages.
  assertEquals(
    isProviderBillingUnavailable("provider billing unavailable error"),
    false,
  );
  assertEquals(
    isProviderBillingUnavailable({ message: "credit_balance_exhausted" }),
    false,
  );
});

Deno.test("isProviderBillingUnavailable: returns false for other ProviderError codes", () => {
  assertEquals(
    isProviderBillingUnavailable(
      new ProviderError("...", "provider_rate_limited", true),
    ),
    false,
  );
  assertEquals(
    isProviderBillingUnavailable(
      new ProviderError("...", "provider_overloaded", true),
    ),
    false,
  );
});

Deno.test("isProviderBillingUnavailable: returns false for null/undefined", () => {
  assertEquals(isProviderBillingUnavailable(null), false);
  assertEquals(isProviderBillingUnavailable(undefined), false);
});

Deno.test("getProviderBillingUnavailableUpstream: returns upstream from dedicated subclass", () => {
  const upstream = {
    code: "credit_balance_exhausted",
    message: "no credits",
    status: 429,
  };
  assertEquals(
    getProviderBillingUnavailableUpstream(
      new ProviderBillingUnavailableError(upstream),
    ),
    upstream,
  );
});

Deno.test("getProviderBillingUnavailableUpstream: preserves SectionEmbeddingError upstream metadata", () => {
  const upstream = getProviderBillingUnavailableUpstream({
    code: "provider_billing_unavailable",
    upstream: {
      code: "credit_balance_exhausted",
      message: "trusted upstream message",
      status: 429,
    },
  });
  assertEquals(upstream, {
    code: "credit_balance_exhausted",
    message: "trusted upstream message",
    status: 429,
  });
});

Deno.test("getProviderBillingUnavailableUpstream: returns undefined for unrelated errors", () => {
  assertEquals(
    getProviderBillingUnavailableUpstream(
      new ProviderError("...", "provider_rate_limited", true),
    ),
    undefined,
  );
  assertEquals(getProviderBillingUnavailableUpstream(null), undefined);
});
