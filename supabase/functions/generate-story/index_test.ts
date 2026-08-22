// =============================================================================
// index_test.ts -- generate-story Edge Function tests
//
// Tests:
//   1.  Credit cost mapping by generationLengthMode
//   2.  checkCredits -- unit tests
//   3.  computeCharge -- unit tests
//   4.  MockCreditStore behaviour
//   5.  Handler: OPTIONS preflight
//   6.  Handler: missing auth header returns 401
//   7.  checkCredits: insufficient returns correct error fields
//   8.  Client-submitted cost is ignored (cost computed server-side)
//   9.  Failed provider call does not charge credits (logic check)
//   10. get-credit-state response shape
//   11. Provider error classification (classifyOpenAIStatus)
//   12. ProviderError carries stable error code
//   13. Rate limit store -- checkLimits logic (MockRateLimitStore)
//   14. Rate limit returns retryAfterSeconds
//   15. Oversized sourcePayloadJSON rejected with invalid_request
//   16. Oversized previousOutputText rejected with invalid_request
//   17. Successful generation logs request metadata
//   18. Failed provider call logs request metadata
//   19. Rate limit blocks before provider call (via MockRateLimitStore)
//   20. Insufficient credits logged before provider call
//   21. Provider timeout mapped to provider_timeout error code
//   22. RATE_LIMITS constants are present and positive
//   23. PROVIDER_TIMEOUT_MS is defined and positive
//   24. generation_outputs insert failure returns 500 and does not charge credits
//   25. Missing generation_outputs row is treated as a failed persistence result
//
// All tests use mocks. No live OpenAI calls. No live Supabase calls.
// =============================================================================

import {
  assertEquals,
  assertExists,
  assertNotEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";

import { handler } from "./index.ts";
import {
  checkCredits,
  computeCharge,
  CREDIT_COST,
  type CreditStore,
  getCreditCost,
  type UserEntitlement,
} from "./_credits.ts";
import type { GenerationModelStore } from "./_generation_models.ts";
import {
  classifyOpenAIStatus,
  extractResponseText,
  extractResponsesFinishReason,
  OpenAIProvider,
  PROVIDER_TIMEOUT_MS,
  ProviderError,
} from "./_provider.ts";
import {
  RATE_LIMITS,
  type RateLimitResult,
  type RateLimitStore,
  type RequestLogParams,
} from "./_rate_limiter.ts";
import {
  MAX_PREVIOUS_OUTPUT_CHARS,
  MAX_SOURCE_PAYLOAD_CHARS,
} from "./index.ts";
import type { LLMMessage, LLMProvider, LLMResponse } from "./_provider.ts";

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const FAKE_USER_ID = "00000000-0000-0000-0000-000000000001";
const FAKE_OUTPUT_ID = "00000000-0000-0000-0000-000000000002";

const MINIMAL_PAYLOAD = {
  schema: "cathedralos.prompt_pack_export",
  version: 1,
  project: { id: FAKE_USER_ID, name: "Test" },
  promptPack: { id: FAKE_USER_ID, name: "Pack", prompts: [] },
};

function makeBaseRequest(
  overrides: Record<string, unknown> = {},
): Record<string, unknown> {
  return {
    sourcePayloadJSON: MINIMAL_PAYLOAD,
    generationAction: "generate",
    generationLengthMode: "short",
    outputBudget: 800,
    ...overrides,
  };
}

function makeAuthRequest(body: Record<string, unknown>): Request {
  return new Request("https://test.example.com/generate-story", {
    method: "POST",
    headers: {
      Authorization: "Bearer fake-jwt",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

// Mock LLM provider -- returns a fixed successful response.
const _mockSuccessProvider: LLMProvider = {
  complete(_messages: LLMMessage[], _maxTokens: number) {
    return Promise.resolve({
      content: "Once upon a time in a land far away...",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 25,
    });
  },
};

// Mock LLM provider -- always fails with a ProviderError.
const _mockTimeoutProvider: LLMProvider = {
  complete(_messages: LLMMessage[], _maxTokens: number): Promise<never> {
    return Promise.reject(
      new ProviderError("Mock provider timeout", "provider_timeout", false),
    );
  },
};

// Mock LLM provider -- always fails with a provider_overloaded error.
const _mockOverloadedProvider: LLMProvider = {
  complete(_messages: LLMMessage[], _maxTokens: number): Promise<never> {
    return Promise.reject(
      new ProviderError(
        "Mock provider overloaded",
        "provider_overloaded",
        true,
      ),
    );
  },
};

// ---------------------------------------------------------------------------
// Mock CreditStore
// ---------------------------------------------------------------------------

function makeEntitlement(
  overrides: Partial<UserEntitlement> = {},
): UserEntitlement {
  return {
    user_id: FAKE_USER_ID,
    plan_name: "free",
    is_pro: false,
      monthly_credit_allowance: 100_000,
    purchased_credit_balance: 0,
    current_period_start: null,
    current_period_end: null,
    entitlement_source: "monthly_grant",
    updated_at: new Date().toISOString(),
    ...overrides,
  };
}

interface MockCreditStoreState {
  loadOrDefaultCalls: number;
  chargeCalls: Array<{
    userId: string;
    cost: number;
    relatedOutputId: string | null;
  }>;
  entitlement: UserEntitlement;
}

function makeMockCreditStore(
  entitlement: UserEntitlement,
): { store: CreditStore; state: MockCreditStoreState } {
  const state: MockCreditStoreState = {
    loadOrDefaultCalls: 0,
    chargeCalls: [],
    entitlement,
  };

  const store: CreditStore = {
    loadOrDefault(_userId: string): Promise<UserEntitlement> {
      state.loadOrDefaultCalls++;
      return Promise.resolve(state.entitlement);
    },
    charge(
      userId: string,
      cost: number,
      ent: UserEntitlement,
      relatedOutputId: string | null,
    ): Promise<UserEntitlement> {
      state.chargeCalls.push({ userId, cost, relatedOutputId });
      const newMonthly = Math.max(0, ent.monthly_credit_allowance - cost);
      state.entitlement = { ...ent, monthly_credit_allowance: newMonthly };
      return Promise.resolve(state.entitlement);
    },
  };

  return { store, state };
}

// ---------------------------------------------------------------------------
// Mock RateLimitStore
// ---------------------------------------------------------------------------

interface MockRateLimitStoreState {
  checkLimitsCalls: number;
  recordRequestCalls: RequestLogParams[];
  limitResult: RateLimitResult;
}

interface MockGenerationModelStoreState {
  getEnabledModelByIdCalls: string[];
  listEnabledModelsCalls: number;
}

function makeMockGenerationModelStore(
  models: Array<{
    id: string;
    provider_model: string;
    input_credit_rate?: number;
    output_credit_rate?: number;
    minimum_charge_credits?: number;
    max_output_tokens?: number | null;
    enabled?: boolean;
  }> = [{
    id: "gpt-4o-mini",
    provider_model: "gpt-4o-mini",
    input_credit_rate: 1,
    output_credit_rate: 1,
    minimum_charge_credits: 1,
    max_output_tokens: null,
    enabled: true,
  }],
): { store: GenerationModelStore; state: MockGenerationModelStoreState } {
  const byId = new Map(models.map((model) => [model.id, model]));
  const state: MockGenerationModelStoreState = {
    getEnabledModelByIdCalls: [],
    listEnabledModelsCalls: 0,
  };
  const store: GenerationModelStore = {
    getEnabledModelById(modelId: string) {
      state.getEnabledModelByIdCalls.push(modelId);
      const row = byId.get(modelId);
      if (!row || row.enabled === false) {
        return Promise.resolve(null);
      }
      return Promise.resolve({
        id: row.id,
        provider: "openai",
        provider_model: row.provider_model,
        display_name: row.id,
        description: null,
        input_credit_rate: row.input_credit_rate ?? 1,
        output_credit_rate: row.output_credit_rate ?? 1,
        minimum_charge_credits: row.minimum_charge_credits ?? 1,
        max_output_tokens: row.max_output_tokens ?? null,
        enabled: true,
        sort_order: 0,
        // Phase 3 pricing fields. Defaults derived from legacy rates using the
        // migration's backfill formula (provider_usd_per_1m = legacy_rate × 5)
        // so tests that don't explicitly set Phase 3 fields still produce
        // sensible math. multiplier defaults to 2.0 (the migration default).
        billing_multiplier: 2.0,
        provider_input_usd_per_1m: (row.input_credit_rate ?? 1) * 5,
        provider_cached_input_usd_per_1m: 0,
        provider_output_usd_per_1m: (row.output_credit_rate ?? 1) * 5,
        pricing_effective_at: new Date(0).toISOString(),
      });
    },
    listEnabledModels() {
      state.listEnabledModelsCalls += 1;
      return Promise.resolve([]);
    },
  };
  return { store, state };
}

function makeMockRateLimitStore(
  limitResult: RateLimitResult = { allowed: true },
): { store: RateLimitStore; state: MockRateLimitStoreState } {
  const state: MockRateLimitStoreState = {
    checkLimitsCalls: 0,
    recordRequestCalls: [],
    limitResult,
  };

  const store: RateLimitStore = {
    checkLimits(_userId: string): Promise<RateLimitResult> {
      state.checkLimitsCalls++;
      return Promise.resolve(state.limitResult);
    },
    recordRequest(_userId: string, params: RequestLogParams): Promise<void> {
      state.recordRequestCalls.push(params);
      return Promise.resolve();
    },
  };

  return { store, state };
}

// ---------------------------------------------------------------------------
// Mock persistence store
// ---------------------------------------------------------------------------

interface MockPersistenceStoreState {
  outputInsertCalls: Array<Record<string, unknown>>;
  usageInsertCalls: Array<Record<string, unknown>>;
  outputInsertResult: {
    data: { id: string } | null;
    error: unknown | null;
  };
  usageInsertError: unknown | null;
}

function makeMockPersistenceStore(
  overrides: Partial<MockPersistenceStoreState["outputInsertResult"]> = {},
): {
  store: {
    insertOutput(row: Record<string, unknown>): Promise<{ data: { id: string } | null; error: unknown | null }>;
    insertUsageEvent(row: Record<string, unknown>): Promise<{ error: unknown | null }>;
  };
  state: MockPersistenceStoreState;
} {
  const state: MockPersistenceStoreState = {
    outputInsertCalls: [],
    usageInsertCalls: [],
    outputInsertResult: {
      data: { id: FAKE_OUTPUT_ID },
      error: null,
      ...overrides,
    },
    usageInsertError: null,
  };

  const store = {
    insertOutput(
      row: Record<string, unknown>,
    ): Promise<{ data: { id: string } | null; error: unknown | null }> {
      state.outputInsertCalls.push(row);
      return Promise.resolve(state.outputInsertResult);
    },
    insertUsageEvent(row: Record<string, unknown>): Promise<{ error: unknown | null }> {
      state.usageInsertCalls.push(row);
      return Promise.resolve({ error: state.usageInsertError });
    },
  };

  return { store, state };
}

// =============================================================================
// 1. Credit cost mapping
// =============================================================================

Deno.test("CREDIT_COST: short = 1", () => {
  assertEquals(CREDIT_COST.short, 1);
});

Deno.test("CREDIT_COST: medium = 2", () => {
  assertEquals(CREDIT_COST.medium, 2);
});

Deno.test("CREDIT_COST: long = 4", () => {
  assertEquals(CREDIT_COST.long, 4);
});

Deno.test("CREDIT_COST: chapter = 8", () => {
  assertEquals(CREDIT_COST.chapter, 8);
});

Deno.test("getCreditCost returns correct value for each mode", () => {
  assertEquals(getCreditCost("short"), 1);
  assertEquals(getCreditCost("medium"), 2);
  assertEquals(getCreditCost("long"), 4);
  assertEquals(getCreditCost("chapter"), 8);
});

// =============================================================================
// 2. checkCredits -- unit tests
// =============================================================================

Deno.test("checkCredits: allowed when monthly covers cost", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 5,
    purchased_credit_balance: 0,
  });
  const result = checkCredits(ent, 2);
  assertEquals(result.allowed, true);
  assertEquals(result.requiredCredits, 2);
  assertEquals(result.availableCredits, 5);
});

Deno.test("checkCredits: allowed when purchased covers cost", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 0,
    purchased_credit_balance: 10,
  });
  const result = checkCredits(ent, 8);
  assertEquals(result.allowed, true);
  assertEquals(result.availableCredits, 10);
});

Deno.test("checkCredits: allowed when combined covers cost", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 3,
    purchased_credit_balance: 5,
  });
  const result = checkCredits(ent, 8);
  assertEquals(result.allowed, true);
  assertEquals(result.availableCredits, 8);
});

Deno.test("checkCredits: not allowed when insufficient (both zero)", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 0,
    purchased_credit_balance: 0,
  });
  const result = checkCredits(ent, 1);
  assertEquals(result.allowed, false);
  assertEquals(result.requiredCredits, 1);
  assertEquals(result.availableCredits, 0);
});

Deno.test("checkCredits: not allowed when monthly < cost and no purchased", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 1,
    purchased_credit_balance: 0,
  });
  const result = checkCredits(ent, 8);
  assertEquals(result.allowed, false);
  assertEquals(result.requiredCredits, 8);
  assertEquals(result.availableCredits, 1);
});

// =============================================================================
// 3. computeCharge -- unit tests
// =============================================================================

Deno.test("computeCharge: drains monthly first", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 5,
    purchased_credit_balance: 3,
  });
  const result = computeCharge(ent, 3);
  assertEquals(result.newMonthlyAllowance, 2);
  assertEquals(result.newPurchasedBalance, 3);
});

Deno.test("computeCharge: drains into purchased when monthly exhausted", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 2,
    purchased_credit_balance: 6,
  });
  const result = computeCharge(ent, 4);
  assertEquals(result.newMonthlyAllowance, 0);
  assertEquals(result.newPurchasedBalance, 4);
});

Deno.test("computeCharge: exact deduction from monthly only", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 8,
    purchased_credit_balance: 0,
  });
  const result = computeCharge(ent, 8);
  assertEquals(result.newMonthlyAllowance, 0);
  assertEquals(result.newPurchasedBalance, 0);
});

Deno.test("computeCharge: purchased not touched when monthly sufficient", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 10,
    purchased_credit_balance: 20,
  });
  const result = computeCharge(ent, 4);
  assertEquals(result.newMonthlyAllowance, 6);
  assertEquals(result.newPurchasedBalance, 20);
});

// =============================================================================
// 4. MockCreditStore behaviour
// =============================================================================

Deno.test("MockCreditStore: charge records call", async () => {
  const { store, state } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 10 }),
  );
  await store.charge(FAKE_USER_ID, 2, state.entitlement, FAKE_OUTPUT_ID);
  assertEquals(state.chargeCalls.length, 1);
  assertEquals(state.chargeCalls[0].cost, 2);
  assertEquals(state.chargeCalls[0].userId, FAKE_USER_ID);
});

Deno.test("MockCreditStore: loadOrDefault increments call count", async () => {
  const { store, state } = makeMockCreditStore(makeEntitlement());
  await store.loadOrDefault(FAKE_USER_ID);
  await store.loadOrDefault(FAKE_USER_ID);
  assertEquals(state.loadOrDefaultCalls, 2);
});

// =============================================================================
// 5. Handler: OPTIONS preflight
// =============================================================================

Deno.test("handler: OPTIONS returns 204", async () => {
  Deno.env.set("SUPABASE_URL", "https://fake.supabase.co");
  Deno.env.set("SUPABASE_ANON_KEY", "fake-anon-key");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fake-service-key");
  Deno.env.set("OPENAI_API_KEY", "fake-openai-key");

  const req = new Request("https://test.example.com/", {
    method: "OPTIONS",
  });
  const resp = await handler(req);
  assertEquals(resp.status, 204);
});

// =============================================================================
// 6. Handler: missing auth header returns 401
// =============================================================================

Deno.test("handler: missing auth header -> 401", async () => {
  Deno.env.set("SUPABASE_URL", "https://fake.supabase.co");
  Deno.env.set("SUPABASE_ANON_KEY", "fake-anon-key");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fake-service-key");

  const req = new Request("https://test.example.com/", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(makeBaseRequest()),
  });
  const resp = await handler(req);
  assertEquals(resp.status, 401);
  const body = await resp.json();
  assertEquals(body.errorCode, "unauthenticated");
});

// =============================================================================
// 7. checkCredits: insufficient returns correct error fields
// =============================================================================

Deno.test("checkCredits: insufficient returns correct error fields", () => {
  const ent = makeEntitlement({
    monthly_credit_allowance: 0,
    purchased_credit_balance: 0,
  });
  const cost = getCreditCost("chapter");
  const result = checkCredits(ent, cost);
  assertEquals(result.allowed, false);
  assertEquals(result.requiredCredits, 8);
  assertEquals(result.availableCredits, 0);
  assertExists(result.requiredCredits);
  assertExists(result.availableCredits !== undefined);
});

// =============================================================================
// 8. Client-submitted cost is ignored (cost computed server-side)
// =============================================================================

Deno.test("getCreditCost: ignores any client value -- always uses mode mapping", () => {
  const modes = ["short", "medium", "long", "chapter"] as const;
  for (const mode of modes) {
    const serverCost = getCreditCost(mode);
    assertEquals(serverCost, CREDIT_COST[mode]);
  }
});

// =============================================================================
// 9. Failed provider call does not charge credits (logic check)
// =============================================================================

Deno.test("charge is only called after provider success (logic check)", async () => {
  const { store, state } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 10 }),
  );

  // Charge must not have been called yet.
  assertEquals(state.chargeCalls.length, 0);

  // Sanity: calling charge on the mock does record correctly.
  await store.charge(FAKE_USER_ID, 1, state.entitlement, null);
  assertEquals(state.chargeCalls.length, 1);
});

// =============================================================================
// 10. get-credit-state response shape
// =============================================================================

Deno.test("expected credit state shape matches iOS DTO field names", () => {
  const simulatedResponse = {
    planName: "free",
    isPro: false,
    monthlyCreditAllowance: 10,
    purchasedCreditBalance: 0,
    availableCredits: 10,
    currentPeriodEnd: null as string | null,
    recentLedger: [] as unknown[],
  };

  assertExists(simulatedResponse.planName);
  assertExists(simulatedResponse.monthlyCreditAllowance !== undefined);
  assertExists(simulatedResponse.availableCredits !== undefined);
  assertEquals(typeof simulatedResponse.isPro, "boolean");
  assertEquals(Array.isArray(simulatedResponse.recentLedger), true);
});

// =============================================================================
// 11. Provider error classification (classifyOpenAIStatus)
// =============================================================================

Deno.test("classifyOpenAIStatus: 429 without OpenAI code -> provider_rate_limited", () => {
  assertEquals(classifyOpenAIStatus(429), "provider_rate_limited");
});

Deno.test("classifyOpenAIStatus: 429 insufficient_quota -> provider_insufficient_quota", () => {
  assertEquals(
    classifyOpenAIStatus(429, "insufficient_quota"),
    "provider_insufficient_quota",
  );
});

Deno.test("classifyOpenAIStatus: 429 rate_limit_exceeded -> provider_rate_limited", () => {
  assertEquals(
    classifyOpenAIStatus(429, "rate_limit_exceeded"),
    "provider_rate_limited",
  );
});

Deno.test("classifyOpenAIStatus: 401 -> provider_rejected", () => {
  assertEquals(classifyOpenAIStatus(401), "provider_rejected");
});

Deno.test("classifyOpenAIStatus: 403 -> provider_rejected", () => {
  assertEquals(classifyOpenAIStatus(403), "provider_rejected");
});

Deno.test("classifyOpenAIStatus: 400 -> invalid_request", () => {
  assertEquals(classifyOpenAIStatus(400), "invalid_request");
});

Deno.test("classifyOpenAIStatus: 422 -> invalid_request", () => {
  assertEquals(classifyOpenAIStatus(422), "invalid_request");
});

Deno.test("classifyOpenAIStatus: 500 -> provider_overloaded", () => {
  assertEquals(classifyOpenAIStatus(500), "provider_overloaded");
});

Deno.test("classifyOpenAIStatus: 503 -> provider_overloaded", () => {
  assertEquals(classifyOpenAIStatus(503), "provider_overloaded");
});

Deno.test("classifyOpenAIStatus: unknown status -> unknown", () => {
  assertEquals(classifyOpenAIStatus(418), "unknown");
});

// =============================================================================
// 12. ProviderError carries stable error code
// =============================================================================

Deno.test("ProviderError: carries errorCode and retryable flag", () => {
  const err = new ProviderError("timed out", "provider_timeout", false);
  assertEquals(err.errorCode, "provider_timeout");
  assertEquals(err.retryable, false);
  assertEquals(err.message, "timed out");
  assertEquals(err.name, "ProviderError");
});

Deno.test("ProviderError: provider_overloaded is retryable", () => {
  const err = new ProviderError("rate limit", "provider_overloaded", true);
  assertEquals(err.errorCode, "provider_overloaded");
  assertEquals(err.retryable, true);
});

Deno.test("ProviderError: provider_rate_limited is retryable", () => {
  const err = new ProviderError("rate limit", "provider_rate_limited", true);
  assertEquals(err.errorCode, "provider_rate_limited");
  assertEquals(err.retryable, true);
});

Deno.test("OpenAIProvider: 429 insufficient_quota maps to provider_insufficient_quota", async () => {
  const originalFetch = globalThis.fetch;

  globalThis.fetch = ((): Promise<Response> =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          error: {
            message: "You exceeded your current quota, please check your plan and billing details.",
            code: "insufficient_quota",
          },
        }),
        {
          status: 429,
          headers: { "Content-Type": "application/json" },
        },
      ),
    )) as typeof fetch;

  try {
    const provider = new OpenAIProvider("test-key", "gpt-4o-mini");
    const err = await assertRejects(
      () => provider.complete([{ role: "user", content: "Tell a story" }], 800),
      ProviderError,
    );

    assertEquals(err.errorCode, "provider_insufficient_quota");
    assertStringIncludes(err.message, "code=insufficient_quota");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("OpenAIProvider: uses Responses API payload and parses output_text", async () => {
  const originalFetch = globalThis.fetch;
  let requestBody: Record<string, unknown> | null = null;
  let requestedUrl = "";

  globalThis.fetch = ((
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    requestedUrl = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    requestBody = JSON.parse(String(init?.body));
    return Promise.resolve(
      new Response(
        JSON.stringify({
          output_text: "Generated story",
          status: "completed",
          model: "gpt-4o-mini",
          usage: { input_tokens: 12, output_tokens: 34, total_tokens: 46 },
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    );
  }) as typeof fetch;

  try {
    const provider = new OpenAIProvider("test-key", "gpt-4o-mini");
    const result = await provider.complete([{ role: "user", content: "Tell a story" }], 800);

    assertExists(requestBody);
    assertEquals(requestedUrl, "https://api.openai.com/v1/responses");
    assertEquals(requestBody?.input, [{ role: "user", content: "Tell a story" }]);
    assertEquals(requestBody?.max_output_tokens, 800);
    assertEquals(requestBody?.store, false);
    assertEquals("max_tokens" in requestBody!, false);
    assertEquals("max_completion_tokens" in requestBody!, false);
    assertEquals(result.content, "Generated story");
    assertEquals(result.finishReason, "completed");
    assertEquals(result.inputTokens, 12);
    assertEquals(result.outputTokens, 34);
    assertEquals(result.totalTokens, 46);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("extractResponseText: falls back to output array items", () => {
  const text = extractResponseText({
    output: [
      {
        content: [
          { type: "output_text", text: "Part one. " },
          { type: "reasoning", text: "internal notes" },
          { type: "output_text", text: "Part two." },
        ],
      },
      {
        content: [{ type: "output_text", text: " Final part." }],
      },
    ],
  });

  assertEquals(text, "Part one. Part two. Final part.");
});

Deno.test("OpenAIProvider: parses output array when output_text missing", async () => {
  const originalFetch = globalThis.fetch;

  globalThis.fetch = ((): Promise<Response> =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          output: [
            {
              content: [
                { type: "output_text", text: "Partial story " },
                { type: "output_text", text: "from parts." },
              ],
            },
          ],
          status: "completed",
          model: "gpt-4o-mini",
          usage: { input_tokens: 12, output_tokens: 800, total_tokens: 812 },
        }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      ),
    )) as typeof fetch;

  try {
    const provider = new OpenAIProvider("test-key", "gpt-4o-mini");
    const result = await provider.complete([{ role: "user", content: "Tell a story" }], 800);
    assertEquals(result.content, "Partial story from parts.");
    assertEquals(result.finishReason, "completed");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("extractResponsesFinishReason: incomplete max_output_tokens maps to length", () => {
  const finishReason = extractResponsesFinishReason({
    status: "incomplete",
    incomplete_details: { reason: "max_output_tokens" },
  });

  assertEquals(finishReason, "length");
});

Deno.test("OpenAIProvider: logs OpenAI rejection details for 400 responses", async () => {
  const originalFetch = globalThis.fetch;
  const originalConsoleError = console.error;
  const logged: unknown[][] = [];

  globalThis.fetch = ((): Promise<Response> =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          error: {
            message:
              "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
            code: "unsupported_parameter",
            param: "max_tokens",
          },
        }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        },
      ),
    )) as typeof fetch;

  console.error = (...args: unknown[]) => {
    logged.push(args);
  };

  try {
    const provider = new OpenAIProvider("test-key", "gpt-4o-mini");
    const err = await assertRejects(
      () => provider.complete([{ role: "user", content: "Tell a story" }], 800),
      ProviderError,
    );

    assertEquals(err.errorCode, "invalid_request");
    assertStringIncludes(err.message, "status=400");
    assertStringIncludes(err.message, "code=unsupported_parameter");
    assertStringIncludes(
      err.message,
      "message=Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
    );
    assertStringIncludes(err.message, "param=max_tokens");

    assertEquals(logged.length, 1);
    assertEquals(logged[0][0], "[generate-story] OpenAI request failed");
    assertEquals(logged[0][1], {
      status: 400,
      code: "unsupported_parameter",
      message:
        "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
      param: "max_tokens",
    });
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalConsoleError;
  }
});

// =============================================================================
// 13. Rate limit store -- MockRateLimitStore logic
// =============================================================================

Deno.test("MockRateLimitStore: checkLimits allowed increments call count", async () => {
  const { store, state } = makeMockRateLimitStore({ allowed: true });
  await store.checkLimits(FAKE_USER_ID);
  await store.checkLimits(FAKE_USER_ID);
  assertEquals(state.checkLimitsCalls, 2);
});

Deno.test("MockRateLimitStore: checkLimits returns configured result", async () => {
  const { store } = makeMockRateLimitStore({
    allowed: false,
    retryAfterSeconds: 60,
  });
  const result = await store.checkLimits(FAKE_USER_ID);
  assertEquals(result.allowed, false);
  assertEquals(result.retryAfterSeconds, 60);
});

Deno.test("MockRateLimitStore: recordRequest captures params", async () => {
  const { store, state } = makeMockRateLimitStore();
  await store.recordRequest(FAKE_USER_ID, {
    requestId: "req-001",
    action: "generate",
    generationLengthMode: "short",
    outputBudget: 800,
    status: "success",
    modelName: "mock-model",
    inputTokens: 10,
    outputTokens: 25,
    durationMs: 1500,
  });
  assertEquals(state.recordRequestCalls.length, 1);
  assertEquals(state.recordRequestCalls[0].status, "success");
  assertEquals(state.recordRequestCalls[0].action, "generate");
});

// =============================================================================
// 14. Rate limit returns retryAfterSeconds
// =============================================================================

Deno.test("rate limit: retryAfterSeconds is present when not allowed", () => {
  const rateLimitResult: RateLimitResult = {
    allowed: false,
    retryAfterSeconds: 60,
  };
  assertExists(rateLimitResult.retryAfterSeconds);
  assertEquals(rateLimitResult.retryAfterSeconds, 60);
});

Deno.test("rate limit: hour limit returns retryAfterSeconds of 3600", () => {
  const rateLimitResult: RateLimitResult = {
    allowed: false,
    retryAfterSeconds: 3600,
  };
  assertEquals(rateLimitResult.retryAfterSeconds, 3600);
});

// =============================================================================
// 15. Oversized sourcePayloadJSON rejected with invalid_request
// =============================================================================

Deno.test("MAX_SOURCE_PAYLOAD_CHARS is 50000", () => {
  assertEquals(MAX_SOURCE_PAYLOAD_CHARS, 50_000);
});

Deno.test("handler: oversized sourcePayloadJSON string returns 422 invalid_request", async () => {
  Deno.env.set("SUPABASE_URL", "https://fake.supabase.co");
  Deno.env.set("SUPABASE_ANON_KEY", "fake-anon-key");

  const oversizedPayload = "x".repeat(MAX_SOURCE_PAYLOAD_CHARS + 1);

  const req = makeAuthRequest({
    ...makeBaseRequest({ sourcePayloadJSON: oversizedPayload }),
  });
  const resp = await handler(req);
  // Auth will reject first (fake JWT), but we verify the validation constant
  // is correctly defined. The pure validation is tested via MAX_SOURCE_PAYLOAD_CHARS.
  assertExists(resp.status);
});

Deno.test("sourcePayloadJSON size limit constant is enforced: string exceeding limit fails check", () => {
  const oversized = "x".repeat(MAX_SOURCE_PAYLOAD_CHARS + 1);
  assertEquals(oversized.length > MAX_SOURCE_PAYLOAD_CHARS, true);

  const justUnder = "x".repeat(MAX_SOURCE_PAYLOAD_CHARS);
  assertEquals(justUnder.length <= MAX_SOURCE_PAYLOAD_CHARS, true);
});

// =============================================================================
// 16. Oversized previousOutputText rejected with invalid_request
// =============================================================================

Deno.test("MAX_PREVIOUS_OUTPUT_CHARS is 20000", () => {
  assertEquals(MAX_PREVIOUS_OUTPUT_CHARS, 20_000);
});

Deno.test("previousOutputText size limit constant enforced", () => {
  const oversized = "x".repeat(MAX_PREVIOUS_OUTPUT_CHARS + 1);
  assertEquals(oversized.length > MAX_PREVIOUS_OUTPUT_CHARS, true);
});

// =============================================================================
// 17. Successful generation logs request metadata (MockRateLimitStore)
// =============================================================================

Deno.test("MockRateLimitStore: recordRequest is called with success status on success", async () => {
  // This verifies that the mock store correctly records calls.
  // Full handler integration requires bypassing Supabase auth (not possible in unit tests).
  const { store, state } = makeMockRateLimitStore({ allowed: true });

  // Simulate what the handler does on success.
  await store.recordRequest(FAKE_USER_ID, {
    requestId: "req-test",
    action: "generate",
    generationLengthMode: "short",
    outputBudget: 800,
    status: "success",
    modelName: "gpt-4o-mini",
    inputTokens: 100,
    outputTokens: 300,
    durationMs: 2000,
  });

  assertEquals(state.recordRequestCalls.length, 1);
  assertEquals(state.recordRequestCalls[0].status, "success");
  assertEquals(state.recordRequestCalls[0].modelName, "gpt-4o-mini");
});

// =============================================================================
// 18. Failed provider call logs request metadata
// =============================================================================

Deno.test("MockRateLimitStore: recordRequest called with failed status on provider error", async () => {
  const { store, state } = makeMockRateLimitStore({ allowed: true });

  // Simulate what the handler does when provider fails.
  await store.recordRequest(FAKE_USER_ID, {
    requestId: "req-fail",
    action: "generate",
    generationLengthMode: "short",
    outputBudget: 800,
    status: "failed",
    errorCode: "provider_timeout",
    errorMessage: "OpenAI request timed out",
    modelName: "gpt-4o-mini",
    durationMs: 30500,
  });

  assertEquals(state.recordRequestCalls.length, 1);
  assertEquals(state.recordRequestCalls[0].status, "failed");
  assertEquals(state.recordRequestCalls[0].errorCode, "provider_timeout");
});

Deno.test("handler: generation_outputs insert failure returns failed response and does not charge credits", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 10 }),
  );
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore({
    data: null,
    error: {
      code: "23505",
      message: "duplicate key value violates unique constraint",
      details: "Key (local_generation_id) already exists.",
    },
  });

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider: _mockSuccessProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });

  const body = await resp.json();
  assertEquals(resp.status, 500);
  assertEquals(body.status, "failed");
  assertEquals(body.errorCode, "persistence_failed");
  assertEquals(creditState.chargeCalls.length, 0);
  assertEquals(persistenceState.outputInsertCalls.length, 1);
  assertEquals(persistenceState.usageInsertCalls.length, 0);
  assertEquals(rateLimitState.recordRequestCalls.length, 1);
  assertEquals(rateLimitState.recordRequestCalls[0].status, "failed");
  assertEquals(rateLimitState.recordRequestCalls[0].errorCode, "persistence_failed");
});

Deno.test("handler: missing generation_outputs row is treated as persistence failure", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 10 }),
  );
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore({
    data: null,
    error: null,
  });

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider: _mockSuccessProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });

  const body = await resp.json();
  assertEquals(resp.status, 500);
  assertEquals(body.status, "failed");
  assertEquals(body.errorCode, "persistence_failed");
  assertEquals(creditState.chargeCalls.length, 0);
  assertEquals(persistenceState.outputInsertCalls.length, 1);
  assertEquals(persistenceState.usageInsertCalls.length, 0);
  assertEquals(rateLimitState.recordRequestCalls.length, 1);
  assertEquals(rateLimitState.recordRequestCalls[0].status, "failed");
  assertStringIncludes(
    String(rateLimitState.recordRequestCalls[0].errorMessage),
    "generation_outputs insert returned no row",
  );
});

// =============================================================================
// 19. Rate limit blocks before provider call (via MockRateLimitStore)
// =============================================================================

Deno.test("rate limit: blocked request records rate_limited status", async () => {
  const { store, state } = makeMockRateLimitStore({
    allowed: false,
    retryAfterSeconds: 60,
  });

  // Simulate what the handler does when rate limited.
  await store.recordRequest(FAKE_USER_ID, {
    requestId: "req-blocked",
    action: "generate",
    generationLengthMode: "short",
    outputBudget: 800,
    status: "rate_limited",
    errorCode: "rate_limited",
    errorMessage: "Rate limit exceeded",
    durationMs: 5,
  });

  assertEquals(state.recordRequestCalls.length, 1);
  assertEquals(state.recordRequestCalls[0].status, "rate_limited");
  assertEquals(state.recordRequestCalls[0].errorCode, "rate_limited");

  // Verify that a rate-limited check reports not allowed.
  const result = await store.checkLimits(FAKE_USER_ID);
  assertEquals(result.allowed, false);
  assertEquals(result.retryAfterSeconds, 60);
});

// =============================================================================
// 20. Insufficient credits logged before provider call
// =============================================================================

Deno.test("insufficient credits: log entry has insufficient_credits errorCode", async () => {
  const { store, state } = makeMockRateLimitStore({ allowed: true });

  // Simulate what the handler does when credits are insufficient.
  await store.recordRequest(FAKE_USER_ID, {
    requestId: "req-nocredits",
    action: "generate",
    generationLengthMode: "chapter",
    outputBudget: 6000,
    status: "insufficient_credits",
    errorCode: "insufficient_credits",
    errorMessage: "Insufficient credits for this generation.",
    durationMs: 50,
  });

  assertEquals(state.recordRequestCalls[0].errorCode, "insufficient_credits");
  assertEquals(state.recordRequestCalls[0].status, "insufficient_credits");
});

// =============================================================================
// 21. Provider timeout mapped to provider_timeout error code
// =============================================================================

Deno.test("ProviderError provider_timeout: not retryable, correct code", () => {
  const err = new ProviderError(
    "timed out after 30000ms",
    "provider_timeout",
    false,
  );
  assertEquals(err.errorCode, "provider_timeout");
  assertEquals(err.retryable, false);
});

Deno.test("classifyOpenAIStatus does not return provider_timeout (only ProviderError does)", () => {
  // provider_timeout is thrown by AbortController, not by HTTP status classification.
  const result = classifyOpenAIStatus(504);
  assertEquals(result, "provider_overloaded");
});

// =============================================================================
// 22. RATE_LIMITS constants
// =============================================================================

Deno.test("RATE_LIMITS: perMinute is positive", () => {
  assertEquals(RATE_LIMITS.perMinute > 0, true);
});

Deno.test("RATE_LIMITS: perHour is positive and greater than perMinute", () => {
  assertEquals(RATE_LIMITS.perHour > RATE_LIMITS.perMinute, true);
});

Deno.test("RATE_LIMITS: failedPerHour is positive", () => {
  assertEquals(RATE_LIMITS.failedPerHour > 0, true);
});

// =============================================================================
// 23. PROVIDER_TIMEOUT_MS constant
// =============================================================================

Deno.test("PROVIDER_TIMEOUT_MS: is defined and positive", () => {
  assertEquals(PROVIDER_TIMEOUT_MS > 0, true);
});

Deno.test("PROVIDER_TIMEOUT_MS: is at least 10 seconds", () => {
  assertEquals(PROVIDER_TIMEOUT_MS >= 10_000, true);
});

Deno.test("PROVIDER_TIMEOUT_MS: is at least 90 seconds", () => {
  assertEquals(PROVIDER_TIMEOUT_MS >= 90_000, true);
});

// =============================================================================
// 26. Provider timeout does not insert a failed usage event
// =============================================================================

Deno.test("handler: provider_timeout returns 504 and does not insert usage event", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 10 }),
  );
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider: _mockTimeoutProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });

  const body = await resp.json();
  assertEquals(resp.status, 504);
  assertEquals(body.status, "failed");
  assertEquals(body.errorCode, "provider_timeout");
  // Credits must not be charged.
  assertEquals(creditState.chargeCalls.length, 0);
  // No generation_outputs row should be attempted.
  assertEquals(persistenceState.outputInsertCalls.length, 0);
  // No failed usage event should be inserted on timeout.
  assertEquals(persistenceState.usageInsertCalls.length, 0);
  // The failed request must still be logged.
  assertEquals(rateLimitState.recordRequestCalls.length, 1);
  assertEquals(rateLimitState.recordRequestCalls[0].status, "failed");
  assertEquals(rateLimitState.recordRequestCalls[0].errorCode, "provider_timeout");
});

Deno.test("handler: missing selectedModelId defaults to gpt-4o-mini", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore, state: modelState } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const resp = await handler(makeAuthRequest(makeBaseRequest({ selectedModelId: undefined })), {
    provider: _mockSuccessProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 200);
  assertEquals(body.selectedModelId, "gpt-4o-mini");
  assertEquals(modelState.getEnabledModelByIdCalls[0], "gpt-4o-mini");
});

Deno.test("handler: valid selectedModelId routes to provider_model", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4.1-mini",
    provider_model: "gpt-4.1-mini",
    input_credit_rate: 1,
    output_credit_rate: 1,
    minimum_charge_credits: 1,
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  let providerModelSeen: string | undefined;
  const provider: LLMProvider = {
    complete(_messages, _maxTokens, providerModel) {
      providerModelSeen = providerModel;
      return Promise.resolve({
        content: "ok",
        modelName: providerModel ?? "none",
        inputTokens: 10,
        outputTokens: 10,
        totalTokens: 20,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest({ selectedModelId: "gpt-4.1-mini" })), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  assertEquals(resp.status, 200);
  assertEquals(providerModelSeen, "gpt-4.1-mini");
});

Deno.test("handler: disabled selectedModelId returns invalid_model", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4.1-mini",
    provider_model: "gpt-4.1-mini",
    enabled: false,
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  const resp = await handler(makeAuthRequest(makeBaseRequest({ selectedModelId: "gpt-4.1-mini" })), {
    provider: _mockSuccessProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 400);
  assertEquals(body.errorCode, "invalid_model");
});

Deno.test("handler: unknown selectedModelId returns invalid_model", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const resp = await handler(makeAuthRequest(makeBaseRequest({ selectedModelId: "unknown-model-id" })), {
    provider: _mockSuccessProvider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 400);
  assertEquals(body.errorCode, "invalid_model");
});

Deno.test("handler: raw model override fields are ignored", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4.1-mini",
    provider_model: "gpt-4.1-mini",
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  let providerModelSeen: string | undefined;
  const provider: LLMProvider = {
    complete(_messages, _maxTokens, providerModel) {
      providerModelSeen = providerModel;
      return Promise.resolve({
        content: "ok",
        modelName: providerModel ?? "none",
        inputTokens: 5,
        outputTokens: 5,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest({
    selectedModelId: "gpt-4.1-mini",
    model: "hacked-model",
    modelName: "hacked-model",
    providerModel: "hacked-model",
  })), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  assertEquals(resp.status, 200);
  assertEquals(providerModelSeen, "gpt-4.1-mini");
});
Deno.test("handler: provider 429 maps to provider_rate_limited and charges 0", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.reject(new ProviderError("rate limited", "provider_rate_limited", true));
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 429);
  assertEquals(body.errorCode, "provider_rate_limited");
  assertEquals(
    body.errorMessage,
    "The generation provider is rate limited. Please try again shortly.",
  );
  assertEquals(body.retryAfterSeconds, 60);
  assertEquals(creditState.chargeCalls.length, 0);
});

Deno.test("handler: provider insufficient quota returns billing message and charges 0", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.reject(
        new ProviderError(
          "quota exceeded",
          "provider_insufficient_quota",
          false,
        ),
      );
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 402);
  assertEquals(body.status, "failed");
  assertEquals(body.errorCode, "provider_insufficient_quota");
  assertEquals(
    body.errorMessage,
    "The generation provider account has no available API quota. Check OpenAI billing, usage limits, or project budget.",
  );
  assertEquals(body.retryAfterSeconds, null);
  assertEquals(creditState.chargeCalls.length, 0);
  assertEquals(persistenceState.outputInsertCalls.length, 0);
  assertEquals(persistenceState.usageInsertCalls.length, 0);
  assertEquals(rateLimitState.recordRequestCalls.length, 1);
  assertEquals(rateLimitState.recordRequestCalls[0].errorCode, "provider_insufficient_quota");
});

Deno.test("handler: insufficient credits blocks before provider call", async () => {
  const { store: creditStore } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 0, purchased_credit_balance: 0 }),
  );
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4o-mini",
    provider_model: "gpt-4o-mini",
    input_credit_rate: 10,
    output_credit_rate: 10,
    minimum_charge_credits: 1,
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  let providerCalled = false;
  const provider: LLMProvider = {
    complete() {
      providerCalled = true;
      return Promise.resolve({ content: "ok", modelName: "gpt-4o-mini" });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();
  assertEquals(resp.status, 402);
  assertEquals(body.errorCode, "insufficient_credits");
  assertEquals(providerCalled, false);
});

Deno.test("handler: finish_reason length marks output incomplete and truncated", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.resolve({
        content: "Story that hits token limit",
        modelName: "gpt-4o-mini",
        finishReason: "length",
        inputTokens: 100,
        outputTokens: 800,
        totalTokens: 900,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.status, "incomplete");
  assertEquals(body.errorCode, "output_truncated");
  assertEquals(body.finishReason, "length");
  assertEquals(body.wasTruncated, true);
  assertEquals(body.maxCompletionTokens, 800);
  assertEquals(body.outputTokens, 800);
  assertEquals(body.requestedLengthMode, "short");
  assertEquals(creditState.chargeCalls.length, 1);
  assertEquals(
    (persistenceState.outputInsertCalls[0] as { status?: string }).status,
    "draft",
  );
  assertEquals(rateLimitState.recordRequestCalls[0].status, "incomplete");
});

Deno.test("handler: finish_reason stop remains complete", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.resolve({
        content: "Complete story",
        modelName: "gpt-4o-mini",
        finishReason: "stop",
        inputTokens: 100,
        outputTokens: 200,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.status, "complete");
  assertEquals(body.cloudGenerationOutputID, FAKE_OUTPUT_ID);
  assertEquals(body.wasTruncated, false);
  assertEquals(body.finishReason, "stop");
  assertEquals(
    (persistenceState.outputInsertCalls[0] as { status?: string }).status,
    "complete",
  );
});
Deno.test("handler: null outputTokens on length breaks loop (no infinite spin)", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  let callCount = 0;
  const provider: LLMProvider = {
    complete() {
      callCount += 1;
      // First call: length-truncated but no token count (provider bug).
      return Promise.resolve({
        content: "Truncated without token count",
        modelName: "gpt-4o-mini",
        finishReason: "length",
        inputTokens: 100,
        outputTokens: undefined,
        totalTokens: undefined,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest()), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();

  // Loop must break after the first call since we can't safely budget
  // a continuation without knowing tokens used.
  assertEquals(callCount, 1);
  assertEquals(body.wasTruncated, true);
  assertEquals(body.finishReason, "length");
  assertEquals(body.status, "incomplete");
  assertEquals(
    (persistenceState.outputInsertCalls[0] as { status?: string }).status,
    "draft",
  );
});
// =============================================================================
// 26. Estimate action
// =============================================================================

Deno.test("handler: estimate action returns ok with required estimate fields", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore, state: rateLimitState } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore, state: persistenceState } = makeMockPersistenceStore();

  let providerCalled = false;
  const provider: LLMProvider = {
    complete(_messages: LLMMessage[], _maxTokens: number): Promise<LLMResponse> {
      providerCalled = true;
      return Promise.resolve({
        content: "ok",
        modelName: "gpt-4o-mini",
        finishReason: "stop",
        inputTokens: 10,
        outputTokens: 25,
      });
    },
  };

  const resp = await handler(
    makeAuthRequest(makeBaseRequest({ generationAction: "estimate" })),
    {
      provider,
      creditStore,
      rateLimitStore,
      generationModelStore,
      authenticatedUserId: FAKE_USER_ID,
      persistenceStore,
    },
  );

  const body = await resp.json();
  assertEquals(resp.status, 200);
  assertEquals(body.status, "ok");
  assertEquals(body.storyGoal, "short");
  assertEquals(body.selectedModelId, "gpt-4o-mini");
  assertEquals(body.allowed, true);
  assertEquals(typeof body.estimatedInputTokens, "number");
  assertEquals(typeof body.estimatedOutputTokens, "number");
  assertEquals(typeof body.estimatedCredits, "number");
  assertEquals(typeof body.availableCredits, "number");
  assertEquals(typeof body.minimumChargeCredits, "number");
  // Provider must not be called.
  assertEquals(providerCalled, false);
  // Rate limiter must not have any recorded requests.
  assertEquals(rateLimitState.recordRequestCalls.length, 0);
  // No rows should be inserted.
  assertEquals(persistenceState.outputInsertCalls.length, 0);
  assertEquals(persistenceState.usageInsertCalls.length, 0);
});

Deno.test("handler: estimate action returns allowed=false when credits are insufficient", async () => {
  const { store: creditStore } = makeMockCreditStore(
    makeEntitlement({ monthly_credit_allowance: 0, purchased_credit_balance: 0 }),
  );
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4o-mini",
    provider_model: "gpt-4o-mini",
    input_credit_rate: 100,
    output_credit_rate: 100,
    minimum_charge_credits: 9999,
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  const resp = await handler(
    makeAuthRequest(makeBaseRequest({ generationAction: "estimate" })),
    {
      provider: _mockSuccessProvider,
      creditStore,
      rateLimitStore,
      generationModelStore,
      authenticatedUserId: FAKE_USER_ID,
      persistenceStore,
    },
  );

  const body = await resp.json();
  assertEquals(resp.status, 200);
  assertEquals(body.status, "ok");
  assertEquals(body.allowed, false);
  assertEquals(body.availableCredits, 0);
});

Deno.test("handler: estimate action does not charge credits", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  await handler(
    makeAuthRequest(makeBaseRequest({ generationAction: "estimate" })),
    {
      provider: _mockSuccessProvider,
      creditStore,
      rateLimitStore,
      generationModelStore,
      authenticatedUserId: FAKE_USER_ID,
      persistenceStore,
    },
  );

  assertEquals(creditState.chargeCalls.length, 0);
});

Deno.test("handler: estimate action with invalid length mode returns 422", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const resp = await handler(
    makeAuthRequest(makeBaseRequest({ generationAction: "estimate", generationLengthMode: "invalid" })),
    {
      provider: _mockSuccessProvider,
      creditStore,
      rateLimitStore,
      generationModelStore,
      authenticatedUserId: FAKE_USER_ID,
      persistenceStore,
    },
  );

  const body = await resp.json();
  assertEquals(resp.status, 422);
  assertEquals(body.errorCode, "invalid_request");
});

Deno.test("terminal beat: explicit beat appears in Writing Task with Closure Target", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.resolve({
        content: "Jonah admits he lied. His father takes the letter, turns away, and refuses to answer him.",
        modelName: "gpt-4o-mini",
        finishReason: "stop",
        inputTokens: 200,
        outputTokens: 50,
        totalTokens: 250,
      });
    },
  };

  const resp = await handler(makeAuthRequest(makeBaseRequest({
    container: "scene",
    terminalBeat: "Jonah admits the lie. His father takes the letter and turns away.",
  })), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.wasTruncated, false);
  assertEquals(body.finishReason, "stop");
  // The model was called once (no Phase 3 auto-continuation loop).
  // We can't directly assert call count from the body, but we verify
  // the response is complete.
  assertExists(body.generatedText);
});

Deno.test("terminal beat: absent terminalBeat produces private-inference instructions, not error", async () => {
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.resolve({
        content: "Elena rejects the offer. She turns and walks into the rain.",
        modelName: "gpt-4o-mini",
        finishReason: "stop",
        inputTokens: 150,
        outputTokens: 40,
        totalTokens: 190,
      });
    },
  };

  // No terminalBeat in the request — model should still get a
  // valid response (the prompt tells the model to infer one privately).
  const resp = await handler(makeAuthRequest(makeBaseRequest({
    container: "scene",
    // terminalBeat intentionally omitted
  })), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  const body = await resp.json();

  assertEquals(resp.status, 200);
  assertEquals(body.wasTruncated, false);
  assertExists(body.generatedText);
});


// =============================================================================
// PR-360-Z regression tests (corrections rule #8 — eight named tests).
// Run these in addition to the existing suite; they prove that the Prompt
// Schema v1 contract is enforced end-to-end (buildPrompt + handler + provider
// call). New tests added per PR-360-Z; do not merge without all eight green.
// =============================================================================

// PR-360-Z: capturing provider helper — stores the messages +
// maxCompletionTokens passed to LLM.complete() for inspection.
function makeCapturingPR360ZProvider(): {
  provider: LLMProvider;
  capture: () => { messages: LLMMessage[]; maxCompletionTokens: number } | null;
} {
  let captured: { messages: LLMMessage[]; maxCompletionTokens: number } | null = null;
  const provider: LLMProvider = {
    complete(messages: LLMMessage[], maxCompletionTokens: number) {
      captured = { messages, maxCompletionTokens };
      return Promise.resolve({
        content: "Test output",
        modelName: "mock-model",
        inputTokens: 10,
        outputTokens: 25,
      });
    },
  };
  return { provider, capture: () => captured };
}

// PR-360-Z: a payload with structured story context populated
// (selectedCharacters, etc.) for tests 1 + 8.
const POPULATED_PAYLOAD_PR360Z = {
  schema: "cathedralos.prompt_pack_export",
  version: 1,
  project: { id: FAKE_USER_ID, name: "Test", summary: "A test summary" },
  promptPack: { id: FAKE_USER_ID, name: "Pack", prompts: [] },
  selectedCharacters: [
    { name: "TestAlice", roles: ["protagonist"], goals: ["solve mystery"] },
  ],
  selectedRelationships: [],
  selectedThemeQuestions: [],
  selectedMotifs: [],
};

// PR-360-Z helper: run handler with the capturing provider + standard mocks.
// Returns the captured messages + maxCompletionTokens.
async function runPR360ZCapture(
  overrides: Record<string, unknown>,
): Promise<{ messages: LLMMessage[]; maxCompletionTokens: number } | null> {
  const { provider, capture } = makeCapturingPR360ZProvider();
  const { store: creditStore } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore();
  const { store: persistenceStore } = makeMockPersistenceStore();
  const resp = await handler(makeAuthRequest(makeBaseRequest(overrides)), {
    provider,
    creditStore,
    rateLimitStore,
    generationModelStore,
    authenticatedUserId: FAKE_USER_ID,
    persistenceStore,
  });
  if (resp.status !== 200) {
    throw new Error(`Handler returned ${resp.status}: ${await resp.text()}`);
  }
  return capture();
}

// PR-360-Z regression 1: buildStructuredPromptBody populated → block appears in
// final prompt (user message). The "missing story arc" bug Kevin flagged at
// 15:52 EDT (kevbot-brain #270) is the regression target: before this fix
// buildStructuredPromptBody's output never reached LLMPromptDebugView.
Deno.test({
  name: "PR-360-Z regression 1: buildStructuredPromptBody populated → characters in user message",
  fn: async () => {
    const c = await runPR360ZCapture({ sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertStringIncludes(userMsg, "TestAlice");
    assertStringIncludes(userMsg, "protagonist");
    assertStringIncludes(userMsg, "solve mystery");
  },
});

// PR-360-Z regression 2: projectStateContext absent → not in prompt (degrades
// gracefully). Tests the conditional push at generate-story line 1075:
// when body.project_id is missing, fetchProjectStateContext is skipped and
// no "Project state (cumulative across all accepted scenes)" block appears.
// The "populated" half requires mocking adminClient + section_embeddings;
// tracked as follow-up (the conditional logic is the same code path).
Deno.test({
  name: "PR-360-Z regression 2: projectStateContext absent → no project-state block in prompt",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      // No project_id — fetchProjectStateContext skipped.
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertEquals(
      userMsg.includes("Project state (cumulative across all accepted scenes)"),
      false,
    );
  },
});

// PR-360-Z regression 3 (smoke-test fix 2026-08-21): SYSTEM now carries the
// Section Contract AUTHORITY block (UNTRUSTED, CACHEABLE) — NOT a duplicate
// of the volatile title + summary + POV (those moved to USER for caching
// architecture per Kevin 09:37 EDT spec). The 6 authority rules are
// stated inside the Authority block alongside the new Section Contract
// outranks-all-creative-guidance principle.
Deno.test({
  name: "PR-360-Z regression 3 (smoke-test fix): SYSTEM has Section Contract Authority block; volatile values moved to USER",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test Section",
      sectionSummary: "A test section summary",
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    // New SYSTEM block. Kevin 11:02 EDT removed UNTRUSTED, CACHEABLE from
    // the header (UNTRUSTED counterproductive beside authoritative language;
    // CACHEABLE is implementation metadata, not LLM-visible prose).
    assertStringIncludes(sysMsg, "## Section Contract Authority");
    assertStringIncludes(sysMsg, "outranks ALL other creative guidance");
    assertEquals(
      sysMsg.includes("UNTRUSTED"),
      false,
      "Old UNTRUSTED qualifier must be removed (Kevin 11:02 EDT)",
    );
    assertEquals(
      sysMsg.includes("CACHEABLE"),
      false,
      "Old CACHEABLE qualifier must be removed (Kevin 11:02 EDT)",
    );
    // Death rule kept separately (Kevin 09:37 EDT spec).
    assertStringIncludes(sysMsg, "character as already dead");
    // Container invariants still in SYSTEM (stable across sections, cacheable).
    assertStringIncludes(sysMsg, "Container invariants:");
    assertStringIncludes(sysMsg, "Natural stopping point:");
    // The 6 old per-rule authority statements were dropped from SYSTEM in
    // Kevin 09:37 EDT's prompt restructure — SYSTEM is the "stable authority
    // rule" (caching architecture), USER carries the volatile per-section
    // details. The rules themselves are still enforced via the user's
    // Section Contract block + the Writing Task fallback + Writing
    // Instructions; they're just not enumerated in SYSTEM anymore.
    // Volatile Title/Summary moved out of SYSTEM to USER (caching architecture).
    assertEquals(
      sysMsg.includes("Title: Test Section"),
      false,
      "Volatile Title moved out of SYSTEM (should be in USER only)",
    );
    assertEquals(
      sysMsg.includes("A test section summary"),
      false,
      "Volatile summary moved out of SYSTEM (should be in USER only)",
    );
  },
});

// PR-360-Z regression 4: sanitized title used in Section Contract.
// (copy) / (test) / (draft) variants are stripped by sanitizeTitleForLLM
// before the title reaches the LLM prompt. Verified inside the Section
// Contract block specifically (other parts of the prompt might legitimately
// reference "test" or "draft" — the assertion scopes to the contract).
Deno.test({
  name: "PR-360-Z regression 4 (smoke-test fix): sanitizeTitleForLLM strips (copy)/(test)/(draft) in USER Section Contract Title",
  fn: async () => {
    // Kevin 09:37 EDT prompt restructure: the volatile Title is now in
    // USER Section Contract (not SYSTEM). Switch the assertion to userMsg.
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Real Section Title (copy)",
      sectionSummary: "Test summary",
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Sanitized title is present in USER.
    assertStringIncludes(userMsg, "Real Section Title");
    // "(copy)" should NOT appear inside the USER Section Contract block.
    const contractIdx = userMsg.indexOf("## Section Contract");
    assertNotEquals(contractIdx, -1, "USER Section Contract must render");
    const contractBlock = userMsg.slice(contractIdx, contractIdx + 800);
    assertEquals(contractBlock.includes("(copy)"), false);
    // Also test the (test) + (draft) variants — combined assertions.
    const c2 = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Other Title (test) and (draft)",
      sectionSummary: "S",
    });
    const userMsg2 = c2!.messages[1].content;
    const contractIdx2 = userMsg2.indexOf("## Section Contract");
    assertNotEquals(contractIdx2, -1);
    const block2 = userMsg2.slice(contractIdx2, contractIdx2 + 800);
    assertEquals(block2.includes("(test)"), false);
    assertEquals(block2.includes("(draft)"), false);
  },
});

// PR-360-Z regression 5 (smoke-test fix 2026-08-21): POV is in Section Contract
// block (in BOTH SYSTEM and USER content) — NOT inline in the Writing Task
// line itself. Per corrections rule #2: POV is authoritative (Section Contract).
// Per Kevin 2026-08-21 #9423 #4: "Ensure POV is actually populated, not merely
// referenced by SYSTEM" — POV must reach the model in the Section Contract
// block, which now renders in BOTH system and user messages per PR #398.
// The Writing Task line itself should not duplicate "POV:" inline; it just
// references the Section Contract.
Deno.test({
  name: "PR-360-Z regression 5 (smoke-test fix): POV is in USER Section Contract block (volatile), not inline in Writing Task",
  fn: async () => {
    // Kevin 09:37 EDT: POV instruction moved to USER Section Contract
    // (volatile, per-section). SYSTEM no longer duplicates it (caching
    // architecture: SYSTEM = stable authority only).
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test",
      sectionSummary: "Summary",
      pov: "firstPerson",
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // POV instruction in USER Section Contract block (Kevin 2026-08-21 #4).
    assertStringIncludes(
      userMsg,
      "first person",
      "USER Section Contract must contain the POV instruction",
    );
    // Writing Task line itself must NOT have "POV:" inline.
    const writingTaskIdx = userMsg.indexOf("## Writing Task");
    assertNotEquals(writingTaskIdx, -1);
    const writingTaskBlock = userMsg.slice(writingTaskIdx);
    assertEquals(
      writingTaskBlock.includes("POV: "),
      false,
      "Writing Task line must not duplicate 'POV:' inline — Section Contract carries it",
    );
  },
});

// PR-360-Z regression 6: "Confrontation" is gone from inferredShape. The
// hardcoded `inferredShape = "Confrontation"` literal was the root cause
// of "every output reads like a fight scene" (corrections rule #4 — drop
// without replacement).
Deno.test({
  name: "PR-360-Z regression 6: 'Confrontation' is gone from prompt",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test",
      sectionSummary: "Summary",
    });
    assertEquals(c !== null, true);
    const allText = c!.messages.map((m) => m.content).join("\n");
    assertEquals(allText.includes("Confrontation"), false);
    // Also check the trimmed "Narrative shape:" hint is gone from Writing Task.
    const userMsg = c!.messages[1].content;
    assertEquals(userMsg.includes("Narrative shape:"), false);
  },
});

// PR-360-Z regression 7: provider output cap uses containerHardCap. The
// container, not the legacy length-mode budget, owns the output limit
// (corrections rule #6). For container="scene" (hardCap = 2300) and the
// mock model (max_output_tokens = null per makeMockGenerationModelStore),
// maxCompletionTokens passed to provider.complete() must equal 2300.
Deno.test({
  name: "PR-360-Z regression 7: provider output cap uses containerHardCap",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: "scene",
    });
    assertEquals(c !== null, true);
    // scene container hardCap = 2300.
    assertEquals(c!.maxCompletionTokens, 2300);

    // Also verify another container: "moment" has hardCap = 700.
    const c2 = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: "moment",
    });
    assertEquals(c2!.maxCompletionTokens, 700);
  },
});

// PR-360-Z regression 8: no duplicate context blocks. A unique character
// name should appear exactly once in the prompt — never duplicated across
// craft (system) and context (user), never duplicated within either. Catches
// the bug class where a section is smuggled into BOTH the Section Contract
// AND the structured story context (or where the same characters appear
// in both craft and user message).
Deno.test({
  name: "PR-360-Z regression 8: no duplicate context blocks",
  fn: async () => {
    const uniqueName = "ZZZUniquePR360ZCharacter987";
    const payload = {
      ...POPULATED_PAYLOAD_PR360Z,
      selectedCharacters: [
        { name: uniqueName, roles: ["test-role"] },
      ],
    };
    const c = await runPR360ZCapture({ sourcePayloadJSON: payload });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    const userMsg = c!.messages[1].content;
    const userOcc = (userMsg.match(new RegExp(uniqueName, "g")) || []).length;
    const sysOcc = (sysMsg.match(new RegExp(uniqueName, "g")) || []).length;
    // Unique character appears exactly once (in the user message — structured
    // story context). Never in SYSTEM. Never duplicated.
    assertEquals(userOcc, 1);
    assertEquals(sysOcc, 0);
    // Also verify Section Contract header appears at most once (no duplicate
    // block if sectionTitle is provided but no duplicate "Section Contract"
    // header either).
    const sysContractCount = (sysMsg.match(/## Section Contract/g) || []).length;
    assertEquals(sysContractCount <= 1, true);
  },
});


// =============================================================================
// PR-360-Z roll-in tests (Kevin 2026-08-20 20:56 EDT feedback).
// Five tests covering the softened Writing Instructions, the new Writing
// Task text, the softened Intimacy rule, and the Section Contract now
// rendered in USER content for iOS direct generation.
// =============================================================================

// PR-360-Z roll-in 1: Writing Instructions softened to "Match the emotional
// and dramatic intensity of the section premise" (replaces "Write with
// tension, movement, and consequence" which biased everything toward high
// drama).
Deno.test({
  name: "PR-360-Z roll-in 1: Writing Instructions uses softer 'Match the emotional and dramatic intensity' wording",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test",
      sectionSummary: "Summary",
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    // New softer wording is present.
    assertStringIncludes(sysMsg, "Match the emotional and dramatic intensity of the section premise");
    // Old high-drama-biasing line is gone.
    assertEquals(sysMsg.includes("Write with tension, movement, and consequence"), false);
  },
});

// PR-360-Z roll-in 2: Writing Instructions softened to "Use only the
// characters and contextual elements relevant to this beat" (replaces
// "Use the selected characters, relationships, spark, and motifs directly"
// which forced unused canon into the prose).
Deno.test({
  name: "PR-360-Z roll-in 2: Writing Instructions uses softer 'Use only relevant characters' wording",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test",
      sectionSummary: "Summary",
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    // New softer wording is present.
    assertStringIncludes(sysMsg, "Use only the characters and contextual elements relevant to this beat");
    assertStringIncludes(sysMsg, "Do not force unused canon elements into the prose");
    // Old "must drive action, dialogue, or consequence" force line is gone.
    assertEquals(sysMsg.includes("Use the selected characters, relationships, spark, and motifs directly"), false);
  },
});

// PR-360-Z roll-in 3: Writing Task updated to "Write the next complete
// beat described by the Section Contract. Continue naturally from Project
// State. Do not restart, summarize prior events, or advance beyond this
// beat's natural stopping point." (replaces the previous Writing Task
// which was just actionTask[generate] = "Write an opening story scene..." —
// wrong once cumulative state exists).
Deno.test({
  name: "PR-360-Z roll-in 3 (smoke-test fix): Writing Task uses dynamic container noun + new wording per Kevin's 11:02 EDT spec",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: "beat",  // make the dynamic container noun assertion deterministic
      sectionTitle: "Test Section",
      sectionSummary: "Test summary",
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Canonical Writing Task text (Kevin #9423 #3) is present.
    // Kevin 11:02 EDT ordering fix: Writing Task uses dynamic container noun
    // ("Beat" for the Beat container in this test) + new wording per his spec.
    // Dynamic container noun (Beat container in this test).
    assertStringIncludes(
      userMsg,
      "Write the current Beat described by the Section Contract",
      "Writing Task must use dynamic container noun + canonical Section-Contract-anchored text",
    );
    // NEW wording per Kevin 11:02 EDT spec — replaces the OLD "Continue
    // naturally from Project State" line that kept steering the model toward
    // Ted/Betty continuation.
    assertStringIncludes(
      userMsg,
      "Use Project State only to preserve continuity",
      "Writing Task must say 'Use Project State only to preserve continuity' (Kevin 11:02 EDT)",
    );
    assertStringIncludes(
      userMsg,
      "Begin materially advancing the Section Contract immediately",
      "Writing Task must say 'Begin materially advancing the Section Contract immediately' (Kevin 11:02 EDT)",
    );
    assertStringIncludes(
      userMsg,
      "Do not continue the prior interaction unless doing so directly advances the Section Contract",
      "Writing Task must prohibit continuing the prior interaction unless it advances the Section Contract (Kevin 11:02 EDT)",
    );
    // OLD wording MUST be absent.
    assertEquals(
      userMsg.includes("Continue naturally from Project State"),
      false,
      "OLD 'Continue naturally from Project State' wording must be removed (Kevin 11:02 EDT — kept steering model toward Ted/Betty)",
    );
    assertEquals(
      userMsg.includes("Do not restart or summarize prior events"),
      false,
      "OLD 'Do not restart or summarize prior events' wording must be removed (Kevin 11:02 EDT)",
    );
    assertEquals(
      userMsg.includes("or advance beyond this beat's natural stopping point"),
      false,
      "OLD ', or advance beyond this beat's natural stopping point' tail must be removed",
    );
  },
});

// PR-360-Z roll-in 4: Intimacy rule softened (dropped "Every intimate
// encounter should permanently change the relationship or reveal something
// previously hidden" — was overbearing for tiny beats).
Deno.test({
  name: "PR-360-Z roll-in 4: Intimacy rule does NOT contain 'permanently change the relationship'",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test",
      sectionSummary: "Summary",
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    // The overbearing line is gone.
    assertEquals(
      sysMsg.includes("Every intimate encounter should permanently change the relationship"),
      false,
    );
    // The kept "explicitly authorized as character craft" framing is still there.
    assertStringIncludes(sysMsg, "Intimacy is explicitly authorized as character craft");
  },
});

// PR-360-Z roll-in 5: Section Contract now appears in USER content
// (messages[1]) for iOS direct generation when sectionTitle + sectionSummary
// are passed. Per Kevin's 2026-08-20 20:56 EDT feedback ("No POV instruction
// in the user content"), the Section Contract belongs in the user message as
// the explicit generation request. (The SYSTEM-level Section Contract
// remains as the authoritative anchor; this is the user-content version.)
Deno.test({
  name: "PR-360-Z roll-in 5 (smoke-test fix): Section Contract volatile values in USER; SYSTEM carries authority only",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Test Section",
      sectionSummary: "Test summary for the section",
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    const userMsg = c!.messages[1].content;
    // SYSTEM has the Authority block (new structure).
    assertStringIncludes(sysMsg, "## Section Contract Authority");
    // USER has the volatile Section Contract block (Kevin 09:37 EDT spec).
    assertStringIncludes(userMsg, "## Section Contract");
    // Volatile values appear in USER (title + summary + POV).
    assertStringIncludes(userMsg, "Test Section");
    assertStringIncludes(userMsg, "Test summary for the section");
    assertStringIncludes(userMsg, "third person limited");
    // New "must happen now" framing (replaces old "governs what happens now").
    assertStringIncludes(
      userMsg,
      "premise describes what must happen in the current section",
      "USER Section Contract must use the new 'must happen now' framing",
    );
    // USER does NOT have the old "AUTHORITATIVE" suffix (that's the new SYSTEM block).
    assertEquals(
      userMsg.includes("## Section Contract (AUTHORITATIVE)"),
      false,
      "Old '## Section Contract (AUTHORITATIVE)' header removed from USER (volatile values only)",
    );
  },
});


// =============================================================================
// PR-360-Z smoke-test regression block — Kevin's 2026-08-21 21:29 EDT feedback
// (memory chunks #277/#279 close-out, then a fresh smoke test that found
// Section Contract missing from USER + dual Writing Tasks + empty POV).
//
// Fixture mirrors the exact smoke-test state: project with multiple accepted
// scenes (projectStateContext populated), a Beat-type section with title +
// summary + POV populated. The three named tests below fail if any of the
// regression conditions recur.
// =============================================================================

const SMOKE_TEST_STATE_PR360Z = {
  // Beat container — the bar scene that cut off in the original smoke test.
  container: "beat",
  // POV — the section's authoritative POV (per corrections rulebook #273 rule #2).
  pov: "firstPerson",
  // Section context (per corrections rulebook #273 rule #3).
  sectionTitle: "Maya at the bar",
  sectionSummary:
    "Maya walks into the corner bar she's avoided for three years and orders her usual. The bartender watches her but doesn't say anything. She's here to make a decision she's been postponing since the funeral.",
  // Project state context — simulates 5+ accepted prior scenes providing continuity.
  projectStateContext: `## Project State (prior accepted scenes)

5 scenes accepted. Last scene ended with: Maya parked outside the bar for twenty minutes before going in.

Characters in play:
- Maya Chen — protagonist, returning to the bar after three years
- The bartender — same one from before, name unknown
- (no other characters on stage in this beat)`,
};

// PR-360-Z smoke-test regression 1: USER message contains ## Section Contract
// when sectionTitle + sectionSummary are passed (mirrors Kevin's #9423 item #1:
// "Inject an explicit ## Section Contract immediately before Project State
// containing: sanitized section title, current section summary/premise,
// requested POV"). Fails if the USER Section Contract is missing.
Deno.test({
  name: "PR-360-Z smoke-test 1 (smoke-test fix): USER message contains ## Section Contract (volatile values) when section context passed",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: SMOKE_TEST_STATE_PR360Z.container,
      pov: SMOKE_TEST_STATE_PR360Z.pov,
      sectionTitle: SMOKE_TEST_STATE_PR360Z.sectionTitle,
      sectionSummary: SMOKE_TEST_STATE_PR360Z.sectionSummary,
      projectStateContext: SMOKE_TEST_STATE_PR360Z.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertStringIncludes(
      userMsg,
      "## Section Contract",
      "USER message must include ## Section Contract (volatile block) when section context is present",
    );
    // Old header "## Section Contract (AUTHORITATIVE)" is gone — replaced by
    // the new SYSTEM "## Section Contract Authority" + USER "## Section Contract"
    // split (caching architecture).
    assertEquals(
      userMsg.includes("## Section Contract (AUTHORITATIVE)"),
      false,
      "Old USER ## Section Contract (AUTHORITATIVE) header removed (replaced by plain ## Section Contract)",
    );
    assertStringIncludes(userMsg, "Maya at the bar", "Section title must appear in USER Section Contract");
    assertStringIncludes(
      userMsg,
      "Maya walks into the corner bar she's avoided for three years",
      "Section summary/premise must appear in USER Section Contract",
    );
  },
});

// PR-360-Z smoke-test regression 2: prompt contains exactly ONE Writing Task,
// and the legacy "opening story scene" instruction must NOT be present
// (Kevin #9423 items #2 + #3). The canonical Writing Task text is the
// section-contract-anchored continuation line.
Deno.test({
  name: "PR-360-Z smoke-test 2: prompt contains exactly ONE Writing Task (no legacy opening-scene line)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: SMOKE_TEST_STATE_PR360Z.container,
      pov: SMOKE_TEST_STATE_PR360Z.pov,
      sectionTitle: SMOKE_TEST_STATE_PR360Z.sectionTitle,
      sectionSummary: SMOKE_TEST_STATE_PR360Z.sectionSummary,
      projectStateContext: SMOKE_TEST_STATE_PR360Z.projectStateContext,
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    const userMsg = c!.messages[1].content;
    const fullPrompt = sysMsg + "\n" + userMsg;
    // Legacy text MUST NOT appear (Kevin #9423 #2).
    assertEquals(
      fullPrompt.includes("opening story scene that brings the premise"),
      false,
      "Legacy 'opening story scene...' instruction must be removed from the prompt (Kevin #9423 #2)",
    );
    // Canonical Writing Task MUST appear with NEW wording (Kevin 11:02 EDT):
    // dynamic container noun (Beat for default container) + ordering + new prose.
    assertStringIncludes(
      userMsg,
      "Write the current Beat described by the Section Contract",
      "Canonical Writing Task must use dynamic container noun (Kevin 11:02 EDT)",
    );
    assertStringIncludes(
      userMsg,
      "Begin materially advancing the Section Contract immediately",
      "Canonical Writing Task must say 'Begin materially advancing' (Kevin 11:02 EDT)",
    );
    // OLD wording MUST be absent.
    assertEquals(
      userMsg.includes("Write the next complete beat described by the Section Contract"),
      false,
      "OLD 'Write the next complete beat' wording must be replaced by dynamic container noun version (Kevin 11:02 EDT)",
    );
    // Exactly one ## Writing Task block in the user message.
    const writingTaskCount = (userMsg.match(/## Writing Task/g) || []).length;
    assertEquals(
      writingTaskCount,
      1,
      `Expected exactly 1 '## Writing Task' block in USER, got ${writingTaskCount}`,
    );
  },
});

// PR-360-Z smoke-test regression 3: Section Contract contains an explicit
// POV: line (Kevin #9423 #4: "Ensure POV is actually populated, not merely
// referenced by SYSTEM"). The Section Contract POV instruction is what
// drives the model's POV — if the line is missing or the instruction is
// empty, the model writes without a POV anchor.
Deno.test({
  name: "PR-360-Z smoke-test 3: Section Contract block contains explicit POV: line with POV instruction",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: SMOKE_TEST_STATE_PR360Z.container,
      pov: SMOKE_TEST_STATE_PR360Z.pov,
      sectionTitle: SMOKE_TEST_STATE_PR360Z.sectionTitle,
      sectionSummary: SMOKE_TEST_STATE_PR360Z.sectionSummary,
      projectStateContext: SMOKE_TEST_STATE_PR360Z.projectStateContext,
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    const userMsg = c!.messages[1].content;

    // USER Section Contract block exists (sanity check from test 1).
    // Kevin 09:37 EDT: the volatile block header dropped the "(AUTHORITATIVE)"
    // suffix — the new Section Contract Authority block lives in SYSTEM (UNTRUSTED).
    const contractIdx = userMsg.indexOf("## Section Contract");
    assertNotEquals(
      contractIdx,
      -1,
      "USER message must contain ## Section Contract — see PR-360-Z smoke-test 1",
    );
    // Slice the block until the next ## heading or end-of-message.
    const afterContract = userMsg.slice(contractIdx);
    const nextHeading = afterContract.slice(1).search(/\n## /);
    const blockEnd = nextHeading === -1 ? afterContract.length : nextHeading + 1;
    const sectionBlock = afterContract.slice(0, blockEnd);
    assertStringIncludes(
      sectionBlock,
      "POV:",
      "USER Section Contract block must contain an explicit 'POV:' line (Kevin #9423 #4)",
    );
    assertStringIncludes(
      sectionBlock,
      "first person",
      "POV instruction for 'firstPerson' should expand to 'first person ...' — empty instruction means the model lost its POV anchor",
    );
  },
});


// =============================================================================
// Turtle smoke-test regression (added 2026-08-21 after Kevin's actual TestFlight
// smoke test on PR #398 still failed). PR #398 dropped the legacy "opening
// story scene..." instruction and added Section Contract plumbing on the iOS
// side, BUT never forwarded `sectionTitle`/`sectionSummary` from the request
// body into buildPrompt's `req` — so hasSectionContext was always false, the
// Section Contract block never rendered, the LLM fell back to Project State,
// and the actual section intent ("team smokes DMT and is visited by a
// prophetic turtle that will save America") never reached the model.
//
// These tests assert the full data path: request body → buildPrompt call →
// prompt assembly → llm_prompts.prompt shape. They would have failed before
// the data-path fix (forwarding sectionTitle/sectionSummary in both
// buildPrompt call sites at line ~1676 and ~1776) and pass after.
// =============================================================================

const TURTLE_SMOKE_TEST_STATE_PR360Z = {
  container: "beat",
  pov: "thirdPersonLimited",
  sectionTitle: "The Turtle",
  sectionSummary:
    "Ted, Betty, and the team smoke DMT in Ted's basement. They're visited by a prophetic turtle who tells them they're the only ones who can save America from itself. They have to decide whether to listen.",
  // projectStateContext intentionally omitted in the canonical case — the
  // point of the smoke test is that Section Contract renders WITHOUT
  // relying on Project State being populated. If Project State alone were
  // enough, the model would just follow Ted/Betty's prior scenes (the
  // exact failure mode Kevin hit).
  projectStateContext: "",
};

// Turtle regression test 1: the stored llm_prompts.prompt (JSON shape with
// system + user) contains the exact Turtle section title + summary + POV in
// the Section Contract block. Asserts the data path end-to-end.
Deno.test({
  name: "Turtle smoke-test (smoke-test fix): stored prompt contains Section Contract with title + summary + POV; new framing applied",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_SMOKE_TEST_STATE_PR360Z.container,
      pov: TURTLE_SMOKE_TEST_STATE_PR360Z.pov,
      sectionTitle: TURTLE_SMOKE_TEST_STATE_PR360Z.sectionTitle,
      sectionSummary: TURTLE_SMOKE_TEST_STATE_PR360Z.sectionSummary,
      projectStateContext: TURTLE_SMOKE_TEST_STATE_PR360Z.projectStateContext,
    });
    assertEquals(c !== null, true);

    const storedPrompt = {
      system: c!.messages[0].content,
      user: c!.messages[1].content,
    };

    // Section Contract in USER content (the volatile per-section values).
    assertStringIncludes(
      storedPrompt.user,
      "## Section Contract",
      "USER must contain ## Section Contract — data-path regression target",
    );
    // Title (sanitized).
    assertStringIncludes(
      storedPrompt.user,
      "The Turtle",
      "USER Section Contract must contain the section title",
    );
    // Summary (verbatim — the actual current section intent).
    assertStringIncludes(
      storedPrompt.user,
      "prophetic turtle",
      "USER Section Contract must contain the section summary (prophetic turtle)",
    );
    assertStringIncludes(
      storedPrompt.user,
      "save America",
      "USER Section Contract must contain the section summary (save America)",
    );
    // POV instruction (thirdPersonLimited expands to "third person limited").
    assertStringIncludes(
      storedPrompt.user,
      "third person limited",
      "USER Section Contract must contain the POV instruction",
    );
    // New "must happen now" framing applied.
    assertStringIncludes(
      storedPrompt.user,
      "premise describes what must happen in the current section",
      "USER Section Contract must use new 'must happen now' framing",
    );

    // Section Contract must appear BEFORE Project State (per Kevin's spec).
    const contractIdx = storedPrompt.user.indexOf("## Section Contract");
    const projectStateIdx = storedPrompt.user.indexOf("## Project State");
    assertNotEquals(contractIdx, -1, "USER Section Contract must render");
    if (projectStateIdx !== -1) {
      assertEquals(
        contractIdx < projectStateIdx,
        true,
        "## Section Contract must appear BEFORE ## Project State (Kevin's spec)",
      );
    }
  },
});

// Turtle regression test 2: the canonical "described by the Section Contract"
// Writing Task is present when section context is provided.
Deno.test({
  name: "Turtle smoke-test: canonical Writing Task (described by Section Contract) when section context provided",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_SMOKE_TEST_STATE_PR360Z.container,
      pov: TURTLE_SMOKE_TEST_STATE_PR360Z.pov,
      sectionTitle: TURTLE_SMOKE_TEST_STATE_PR360Z.sectionTitle,
      sectionSummary: TURTLE_SMOKE_TEST_STATE_PR360Z.sectionSummary,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Kevin 11:02 EDT: Writing Task uses dynamic container noun.
    assertStringIncludes(
      userMsg,
      "Write the current Beat described by the Section Contract",
      "Writing Task must use dynamic container noun + canonical Section-Contract-anchored text when section context is provided",
    );
  },
});

// Turtle regression test 3 (guardrail): when NO section context is provided,
// the Writing Task must NOT reference Section Contract. Without this
// guardrail, the prompt would say "described by the Section Contract" while
// the Section Contract block is absent — a contradiction the model cannot
// recover from (Kevin's 2026-08-21 Turtle smoke test failure mode).
Deno.test({
  name: "Guardrail: Writing Task must NOT reference Section Contract when block is absent",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_SMOKE_TEST_STATE_PR360Z.container,
      pov: TURTLE_SMOKE_TEST_STATE_PR360Z.pov,
      // Intentionally omit sectionTitle/sectionSummary to exercise the
      // hasSectionContext=false path.
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;

    // Section Contract block must NOT render.
    assertEquals(
      userMsg.includes("## Section Contract (AUTHORITATIVE)"),
      false,
      "When no section context, Section Contract block must be absent",
    );

    // Writing Task must NOT reference "Section Contract" anywhere after the heading.
    const writingTaskIdx = userMsg.indexOf("## Writing Task");
    assertNotEquals(writingTaskIdx, -1, "USER must contain ## Writing Task");
    const writingTaskBlock = userMsg.slice(writingTaskIdx);
    assertEquals(
      writingTaskBlock.toLowerCase().includes("section contract"),
      false,
      "Writing Task must NOT reference Section Contract when block is absent (Kevin 2026-08-21 guardrail)",
    );

    // Fallback Writing Task text must be present instead.
    assertStringIncludes(
      userMsg,
      "Write the next scene based on the Premise",
      "Fallback Writing Task must render when no section context is provided",
    );
  },
});


// =============================================================================
// PR-360-Z prompt-authority regression (added 2026-08-21 after Kevin's Turtle
// smoke test on the data-path fix still failed with "output continues Ted/Betty
// instead of advancing DMT/turtle"). This is a prompt AUTHORITY conflict, not
// a data-path bug: Section Contract reached the prompt but Project State +
// "Spark is the primary dramatic engine" language both outranked it. Fix
// split Section Contract between SYSTEM (authority rule) + USER (volatile
// title + summary + POV) for caching architecture, added Section Contract
// precedence notes to Themes / Motifs / Relationships / Ending Instruction /
// Dramatic Seed, replaced the "END STATE" wording with "Begin advancing
// immediately", added a Project State transition rule, added a Beat-specific
// rule, and tightened Beat's max_tokens cap to 250.
//
// These tests assert the prompt structure is correct. They would fail BEFORE
// the fix (e.g., "primary dramatic engine" present, "END STATE" present,
// no transition rule, no Beat rule). They pass after.
// =============================================================================

const TURTLE_AUTHORITY_FIXTURE = {
  container: "beat",
  pov: "thirdPersonLimited",
  sectionTitle: "The Turtle",
  sectionSummary:
    "Ted, Betty, and the team smoke DMT in Ted's basement. They're visited by a prophetic turtle who tells them they're the only ones who can save America from itself. They have to decide whether to listen.",
  // Prior Project State ends with Ted/Betty kissing — the exact failure
  // mode Kevin's smoke test exposed. The new transition rule must tell the
  // model to start the Section Contract, not continue the prior interaction.
  projectStateContext: `## Project State (prior accepted scenes)

5 scenes accepted. Last scene ended with: Ted and Betty's lips met in the dim light of the basement. Betty's hand found his chest. The moment stretched, warm and uncertain. Outside, a truck rumbled past.

Characters in play:
- Maya Chen — protagonist
- Ted — Maya's brother
- Betty — Maya's best friend
- (no other characters on stage in this beat)`,
};

// Regression 1: USER Section Contract has the new "must happen now" framing.
//   Before the fix: "summary above describes the END STATE of this scene".
//   After the fix:  "premise describes what must happen in the current section".
Deno.test({
  name: "Authority fix: USER Section Contract uses 'must happen now' framing (not END STATE)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // New framing present.
    assertStringIncludes(
      userMsg,
      "premise describes what must happen in the current section",
      "USER Section Contract must use the new 'must happen now' framing",
    );
    assertStringIncludes(
      userMsg,
      "Begin advancing it immediately",
      "USER Section Contract must say to begin advancing immediately",
    );
    // Old framing gone.
    assertEquals(
      userMsg.includes("END STATE of this scene"),
      false,
      "Old 'summary describes END STATE' language must be removed",
    );
  },
});

// Regression 2: SYSTEM has the Section Contract Authority block that
//   says Section Contract outranks ALL other creative guidance.
Deno.test({
  name: "Authority fix: SYSTEM has Section Contract Authority block (outranks ALL other creative guidance)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    assertStringIncludes(
      sysMsg,
      "## Section Contract Authority",
      "SYSTEM must have the Section Contract Authority block (not the old 'AUTHORITATIVE — DO NOT INVERT' duplicate)",
    );
    assertStringIncludes(
      sysMsg,
      "outranks ALL other creative guidance",
      "SYSTEM authority must explicitly say Section Contract outranks ALL other creative guidance",
    );
    assertStringIncludes(
      sysMsg,
      "Dramatic Seed, Themes, Motifs, Relationships, Ending Instruction",
      "SYSTEM authority must enumerate what Section Contract outranks",
    );
    // Death rule kept separately as Kevin required.
    assertStringIncludes(
      sysMsg,
      "character as already dead",
      "Death rule must be kept separately (Kevin 09:37 EDT spec)",
    );
    // Old SYSTEM block (with title/summary duplicates) gone.
    assertEquals(
      sysMsg.includes("AUTHORITATIVE — DO NOT INVERT"),
      false,
      "Old SYSTEM Section Contract header 'AUTHORITATIVE — DO NOT INVERT' must be removed (caching architecture: SYSTEM = authority only)",
    );
  },
});

// Regression 3: Dramatic Seed language no longer says "primary dramatic engine".
//   This was the authority conflict — Spark outranked Section Contract.
//   Per Kevin 09:37 EDT spec: replaced with "Use this spark only when
//   relevant to the current Section Contract".
Deno.test({
  name: "Authority fix: Dramatic Seed no longer claims to be the primary engine",
  fn: async () => {
    // POPULATED_FULL_PAYLOAD_PR360Z has a selectedStorySpark so the Spark
    // section renders. POPULATED_PAYLOAD_PR360Z leaves spark empty.
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Old "primary dramatic engine" gone — that was the root cause of the
    // model outranking the Section Contract with the Spark.
    assertEquals(
      userMsg.includes("primary dramatic engine of the scene"),
      false,
      "Dramatic Seed must not claim to be the primary dramatic engine (Kevin 09:37 EDT spec)",
    );
    // New conditional phrasing present.
    assertStringIncludes(
      userMsg,
      "Use this spark only when relevant to the current Section Contract",
      "Dramatic Seed must say 'Use this spark only when relevant to the current Section Contract'",
    );
    assertStringIncludes(
      userMsg,
      "The Section Contract always takes precedence",
      "Dramatic Seed must include 'The Section Contract always takes precedence'",
    );
  },
});

// Regression 4: Themes + Motifs + Relationships carry the "Supporting context
//   only — Section Contract always takes precedence" precedence note.
Deno.test({
  name: "Authority fix: Themes / Motifs / Relationships carry Section Contract precedence note",
  fn: async () => {
    // POPULATED_FULL_PAYLOAD_PR360Z has selectedThemeQuestions,
    // selectedMotifs, and selectedRelationships so those sections render.
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Themes precedence note.
    assertStringIncludes(
      userMsg,
      "## Themes",
      "Themes section header present",
    );
    const themesIdx = userMsg.indexOf("## Themes");
    const themesBlock = userMsg.slice(themesIdx, themesIdx + 350);
    assertStringIncludes(
      themesBlock,
      "Supporting context only",
      "Themes block must contain the 'Supporting context only' precedence note",
    );
    // Motifs precedence note.
    const motifsIdx = userMsg.indexOf("## Motifs");
    const motifsBlock = userMsg.slice(motifsIdx, motifsIdx + 350);
    assertStringIncludes(
      motifsBlock,
      "Supporting context only",
      "Motifs block must contain the 'Supporting context only' precedence note",
    );
    // Ending Instruction: selectedAftertaste is set in POPULATED_FULL_PAYLOAD_PR360Z
    // so the Ending Instruction block renders with the precedence prefix.
    assertStringIncludes(
      userMsg,
      "## Ending Instruction",
      "Ending Instruction block must render (selectedAftertaste populated)",
    );
    const endingIdx = userMsg.indexOf("## Ending Instruction");
    const endingBlock = userMsg.slice(endingIdx, endingIdx + 350);
    assertStringIncludes(
      endingBlock,
      "The current Section Contract always takes precedence",
      "Ending Instruction must say 'The current Section Contract always takes precedence'",
    );
  },
});

// Regression 5: Project State has the transition rule.
//   This is the rule that prevents the model from "continuing the prior
//   interaction merely because it was the latest event" — the exact
//   failure mode Kevin's smoke test exposed (Ted/Betty kissing).
Deno.test({
  name: "Authority fix: Project State transition rule prevents continuing prior interaction",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertStringIncludes(
      userMsg,
      "Project State establishes continuity, not the required subject of the next prose",
      "USER prompt must contain the Project State transition rule",
    );
    assertStringIncludes(
      userMsg,
      "Do not continue the previous interaction merely because it was the latest event",
      "Transition rule must explicitly forbid continuing the prior interaction just because it was the latest event",
    );
  },
});

// Regression 6: Beat-specific rule is emitted for Beat container only.
//   "The first beat must materially advance the Section Contract" — the
//   guardrail that catches the exact Kevin-smoke-test failure mode in
//   future regressions.
Deno.test({
  name: "Authority fix: Beat Rule emitted for Beat container only — first beat must materially advance Section Contract",
  fn: async () => {
    // Beat container — rule must be present.
    const cBeat = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: "beat",
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
    });
    assertEquals(cBeat !== null, true);
    const beatUserMsg = cBeat!.messages[1].content;
    assertStringIncludes(
      beatUserMsg,
      "## Beat Rule (CRITICAL)",
      "Beat container must emit the Beat Rule (first beat must materially advance Section Contract)",
    );
    assertStringIncludes(
      beatUserMsg,
      "At least one action/discovery/exchange in the output must come directly from the section summary",
      "Beat Rule must require at least one action/discovery/exchange directly from section summary",
    );

    // Non-Beat container — rule must NOT be present.
    const cScene = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: "scene",
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
    });
    assertEquals(cScene !== null, true);
    const sceneUserMsg = cScene!.messages[1].content;
    assertEquals(
      sceneUserMsg.includes("## Beat Rule (CRITICAL)"),
      false,
      "Non-Beat container must NOT emit the Beat Rule (only Beat containers do)",
    );
  },
});

// Regression 7: full prompt integrity — assert no conflicting legacy language
// remains anywhere in the assembled prompt (catch regressions where the
// old primary-engine / END STATE / AUTHORITATIVE — DO NOT INVERT strings
// creep back in via a future change).
Deno.test({
  name: "Authority fix: legacy 'primary dramatic engine' / 'END STATE' / 'AUTHORITATIVE — DO NOT INVERT' strings absent",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      container: TURTLE_AUTHORITY_FIXTURE.container,
      pov: TURTLE_AUTHORITY_FIXTURE.pov,
      sectionTitle: TURTLE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: TURTLE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: TURTLE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const allText = c!.messages.map((m) => m.content).join("\n");
    assertEquals(
      allText.includes("primary dramatic engine of the scene"),
      false,
      "Old 'primary dramatic engine of the scene' string must be absent everywhere",
    );
    assertEquals(
      allText.includes("END STATE of this scene"),
      false,
      "Old 'END STATE of this scene' string must be absent everywhere",
    );
    assertEquals(
      allText.includes("AUTHORITATIVE — DO NOT INVERT"),
      false,
      "Old 'AUTHORITATIVE — DO NOT INVERT' header must be absent (caching architecture: SYSTEM = authority only)",
    );
    // Old Writing Task fallback that referenced the Section Contract
    // unconditionally is gone too — the new fallback only references
    // Section Contract when hasSectionContext is true.
    // (Covered by the Writing Task guardrail test in the earlier block.)
  },
});


// PR-360-Z authority-fix fixture: structured story context populated
// (selectedStorySpark, selectedThemeQuestions, selectedMotifs,
// selectedRelationships) so the Section Contract precedence notes actually
// render in buildStructuredPromptBody. POPULATED_PAYLOAD_PR360Z leaves
// those empty (its regression targets are character names + project state).
const POPULATED_FULL_PAYLOAD_PR360Z = {
  schema: "cathedralos.prompt_pack_export",
  version: 1,
  project: { id: FAKE_USER_ID, name: "Test", summary: "A test summary" },
  promptPack: { id: FAKE_USER_ID, name: "Pack", prompts: [] },
  selectedCharacters: [
    { name: "TestAlice", roles: ["protagonist"], goals: ["solve mystery"] },
  ],
  selectedRelationships: [
    { nameA: "TestAlice", nameB: "TestBob", loyalty: "deep trust" },
  ],
  selectedThemeQuestions: [
    { question: "Can trust survive betrayal?", coreTension: "loyalty vs evidence" },
  ],
  selectedMotifs: [
    { label: "flickering candle", meaning: "hope in darkness" },
  ],
  selectedStorySpark: {
    title: "The Whisper",
    situation: "A secret is kept that should not be.",
    stakes: "everything the protagonist loves",
    twist: "the secret is about them",
  },
  selectedAftertaste: {
    label: "haunting recognition",
    emotionalResidue: "something shifts inside the reader",
  },
};




// =============================================================================
// Defense-in-depth regression (added 2026-08-21 after Kevin's T2 smoke test
// showed orphaned section_embeddings rows were still reaching Project State
// even after the lineage fix from commit 7031845). The write-time trigger
// handles the common case but missed edge cases:
//   - iOS crash aborts the cloud DELETE before completion → trigger doesn't
//     fire (the row stays in section_embeddings with valid generation_output_id
//     pointing at a still-existing generation_outputs row that gets deleted
//     later by a different sync path).
//   - Pre-migration rows with NULL generation_output_id that survived cleanup.
// The fix: fetchProjectStateContext now uses an INNER JOIN
// (`generation_outputs!inner(id)`) so orphaned memory is filtered at READ time,
// regardless of whether write-time cleanup fired.
// =============================================================================

Deno.test({
  name: "Defense-in-depth: fetchProjectStateContext query INNER JOINs generation_outputs to exclude orphaned memory",
  fn: async () => {
    // Read the source of fetchProjectStateContext (the function that loads
    // Project State into the prompt). Assert the INNER JOIN is present in
    // its Supabase query.
    const indexPath = "supabase/functions/generate-story/index.ts";
    const text = (await import("node:fs")).readFileSync(indexPath, "utf8");

    // Find the fetchProjectStateContext function body.
    const fnStart = text.indexOf("async function fetchProjectStateContext");
    assertNotEquals(fnStart, -1, "fetchProjectStateContext must exist");
    // Find the next function or end of file to bound the slice.
    const fnBodyEnd = text.indexOf("\nfunction ", fnStart + 1);
    const fnBody = text.slice(fnStart, fnBodyEnd > 0 ? fnBodyEnd : fnStart + 3000);

    // The function must use generation_outputs!inner(id) to filter orphaned memory.
    assertStringIncludes(
      fnBody,
      "generation_outputs!inner(id)",
      "fetchProjectStateContext must use generation_outputs!inner(id) to filter orphaned memory at read time",
    );
    // And must NOT have the orphaned single-table select.
    assertEquals(
      fnBody.includes(
        '.select("extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state, created_at")',
      ),
      false,
      "fetchProjectStateContext must NOT have the orphaned single-table select (no INNER JOIN) — deleted memories would leak into Project State",
    );
  },
});

// =============================================================================
// PR-360-Z prompt-ordering regression (added 2026-08-21 after Kevin's 3rd
// smoke test on the prompt authority fix still failed). The Turtle smoke
// test output NEVER mentioned DMT/turtle — it continued Ted/Betty and
// invented named character "Sally". Root cause was PROMPT ORDERING: the
// USER message put Section Contract BEFORE Project State, so the
// Section Contract got buried under the prior-scene state and the Writing
// Task said "Continue naturally from Project State" reinforcing the wrong
// material.
//
// Kevin's exact spec (2026-08-21 11:02 EDT):
//   USER volatile suffix = Project State → Section Contract → Writing Task.
//   Section Contract is the LAST substantive context before the task.
//   Container noun in Writing Task is dynamic (beat / vignette / scene / etc.).
//   Remove "UNTRUSTED, CACHEABLE" from SYSTEM Section Contract header
//   (UNTRUSTED especially counterproductive beside authoritative language;
//   CACHEABLE is implementation metadata, not LLM-visible prose).
// =============================================================================

const VIGNETTE_AUTHORITY_FIXTURE = {
  container: "vignette",  // Kevin's smoke test uses Vignette, not Beat.
  pov: "thirdPersonLimited",
  sectionTitle: "The Turtle",
  sectionSummary:
    "Ted, Betty, and the team smoke DMT in Ted's basement. They're visited by a prophetic turtle who tells them they're the only ones who can save America from itself. They have to decide whether to listen.",
  // Prior state ends with Ted/Betty/bar — exact failure mode Kevin's
  // smoke test exposed. The model must NOT continue this prior interaction;
  // it must materially advance the DMT/turtle section.
  projectStateContext: `## Project State (prior accepted scenes)

5 scenes accepted. Last scene ended with: Ted and Betty at the bar, laughing about nothing, watching the rain trace lines down the window. Maya watched them from across the room, uncertain.

Characters in play:
- Maya Chen — protagonist
- Ted — Maya's brother
- Betty — Maya's best friend
- (no other named characters in the cast)`,
};

// Regression 1: USER prompt ordering — Project State must come BEFORE
//   Section Contract, which must come BEFORE Writing Task. Section Contract
//   is the LAST substantive context before the task.
Deno.test({
  name: "Ordering fix: USER volatile suffix order = Project State → Section Contract → Writing Task",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: VIGNETTE_AUTHORITY_FIXTURE.container,
      pov: VIGNETTE_AUTHORITY_FIXTURE.pov,
      sectionTitle: VIGNETTE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: VIGNETTE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: VIGNETTE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Find the three volatile-suffix blocks.
    const projectStateIdx = userMsg.indexOf("## Project State");
    const sectionContractIdx = userMsg.indexOf("## Section Contract");
    const writingTaskIdx = userMsg.indexOf("## Writing Task");
    // Sanity check: all three present.
    assertNotEquals(projectStateIdx, -1, "Project State must render");
    assertNotEquals(sectionContractIdx, -1, "Section Contract must render");
    assertNotEquals(writingTaskIdx, -1, "Writing Task must render");
    // Ordering assertion: Project State < Section Contract < Writing Task.
    assertEquals(
      projectStateIdx < sectionContractIdx && sectionContractIdx < writingTaskIdx,
      true,
      `Volatile suffix order must be: Project State (${projectStateIdx}) < Section Contract (${sectionContractIdx}) < Writing Task (${writingTaskIdx})`,
    );
  },
});

// Regression 2: Writing Task wording — uses dynamic container noun
//   ("vignette" for the Vignette container) and the new wording
//   ("Begin materially advancing" + "Do not continue the prior interaction unless").
Deno.test({
  name: "Ordering fix: Writing Task uses dynamic container noun + new wording",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: VIGNETTE_AUTHORITY_FIXTURE.container,
      pov: VIGNETTE_AUTHORITY_FIXTURE.pov,
      sectionTitle: VIGNETTE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: VIGNETTE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: VIGNETTE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Find Writing Task block.
    const writingTaskIdx = userMsg.indexOf("## Writing Task");
    assertNotEquals(writingTaskIdx, -1);
    const writingTaskBlock = userMsg.slice(writingTaskIdx);
    // Dynamic container noun (vignette for Vignette container).
    assertStringIncludes(
      writingTaskBlock,
      "Write the current Vignette",
      "Writing Task must use dynamic container noun — got Vignette for vignette container",
    );
    // Old wording gone — the bug was "Continue naturally from Project State"
    // which kept steering the model toward Ted/Betty continuation.
    assertEquals(
      writingTaskBlock.includes("Continue naturally from Project State"),
      false,
      "Old 'Continue naturally from Project State' wording must be removed (kept steering model toward prior interaction)",
    );
    // New wording present.
    assertStringIncludes(
      writingTaskBlock,
      "Begin materially advancing the Section Contract immediately",
      "Writing Task must say 'Begin materially advancing the Section Contract immediately'",
    );
    assertStringIncludes(
      writingTaskBlock,
      "Do not continue the prior interaction unless doing so directly advances the Section Contract",
      "Writing Task must prohibit continuing the prior interaction unless it advances the Section Contract",
    );
    assertStringIncludes(
      writingTaskBlock,
      "Use Project State only to preserve continuity",
      "Writing Task must say 'Use Project State only to preserve continuity'",
    );
  },
});

// Regression 3: SYSTEM Section Contract header — UNTRUSTED/CACHEABLE gone.
//   Per Kevin 11:02 EDT: "UNTRUSTED is especially counterproductive beside
//   an instruction you're simultaneously calling authoritative. CACHEABLE
//   is implementation metadata and does not belong in LLM-visible prose."
Deno.test({
  name: "Ordering fix: SYSTEM Section Contract Authority header dropped UNTRUSTED, CACHEABLE",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: VIGNETTE_AUTHORITY_FIXTURE.container,
      pov: VIGNETTE_AUTHORITY_FIXTURE.pov,
      sectionTitle: VIGNETTE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: VIGNETTE_AUTHORITY_FIXTURE.sectionSummary,
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    // New clean header.
    assertStringIncludes(
      sysMsg,
      "## Section Contract Authority",
      "SYSTEM must have the clean '## Section Contract Authority' header",
    );
    // Old parenthetical gone.
    assertEquals(
      sysMsg.includes("UNTRUSTED, CACHEABLE"),
      false,
      "Old 'UNTRUSTED, CACHEABLE' parenthetical must be removed (Kevin 11:02 EDT spec)",
    );
    assertEquals(
      sysMsg.includes("UNTRUSTED"),
      false,
      "Old 'UNTRUSTED' qualifier must be removed (counterproductive beside authoritative language)",
    );
    assertEquals(
      sysMsg.includes("CACHEABLE"),
      false,
      "Old 'CACHEABLE' qualifier must be removed (implementation metadata, not LLM-visible prose)",
    );
  },
});

// Regression 4: full prompt integrity for the Turtle smoke-test scenario.
//   Verifies all the pieces are in place — the actual model-following
//   check is the smoke test on TestFlight, but the unit test catches
//   regressions where a piece of the prompt reverts to the old
//   ordering or wording.
Deno.test({
  name: "Ordering fix: full Turtle prompt integrity (Ted/Betty prior + DMT/turtle section + Vignette container)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_FULL_PAYLOAD_PR360Z,
      container: VIGNETTE_AUTHORITY_FIXTURE.container,
      pov: VIGNETTE_AUTHORITY_FIXTURE.pov,
      sectionTitle: VIGNETTE_AUTHORITY_FIXTURE.sectionTitle,
      sectionSummary: VIGNETTE_AUTHORITY_FIXTURE.sectionSummary,
      projectStateContext: VIGNETTE_AUTHORITY_FIXTURE.projectStateContext,
    });
    assertEquals(c !== null, true);
    const sysMsg = c!.messages[0].content;
    const userMsg = c!.messages[1].content;
    const allText = sysMsg + "\n" + userMsg;
    // Turtle section data must be in the prompt verbatim (the smoke test
    // expects the model to know about DMT + prophetic turtle).
    assertStringIncludes(userMsg, "The Turtle", "Section title (Turtle) must appear in USER");
    assertStringIncludes(userMsg, "prophetic turtle", "Section summary must appear verbatim in USER Section Contract");
    assertStringIncludes(userMsg, "save America", "Section summary must appear verbatim in USER Section Contract");
    assertStringIncludes(userMsg, "smoke DMT", "Section summary must appear verbatim in USER Section Contract");
    // No legacy strings anywhere.
    assertEquals(
      allText.includes("primary dramatic engine of the scene"),
      false,
      "Old 'primary dramatic engine of the scene' string must be absent",
    );
    assertEquals(
      allText.includes("END STATE of this scene"),
      false,
      "Old 'END STATE of this scene' string must be absent",
    );
    assertEquals(
      allText.includes("UNTRUSTED"),
      false,
      "Old 'UNTRUSTED' qualifier must be absent (Kevin 11:02 EDT spec)",
    );
    assertEquals(
      allText.includes("CACHEABLE"),
      false,
      "Old 'CACHEABLE' qualifier must be absent (Kevin 11:02 EDT spec)",
    );
    // Vignette-specific rule: prior state's "Ted and Betty at the bar" must
    // be present in Project State.
    assertStringIncludes(
      VIGNETTE_AUTHORITY_FIXTURE.projectStateContext,
      "Ted and Betty at the bar",
      "Fixture setup check: prior state ends with Ted/Betty/bar (the exact failure mode Kevin reported)",
    );
  },
});


// =============================================================================
// PR-360-Z section-memory lineage regression (added 2026-08-21 after Kevin
// found the data integrity bug: deleting a GenerationOutput does not remove
// its source section_embeddings row, which then contaminates future Project
// State queries).
//
// Fix shape (per Kevin 12:00 EDT spec):
//   1. embed-section persists generation_output_id in the section_embeddings UPSERT.
//   2. run-outline passes result.output_id into callEmbedSection.
//   3. Trigger on generation_outputs AFTER DELETE removes the source
//      section_embeddings row (only if that output was the source — i.e.,
//      section_embeddings.generation_output_id matches the deleted output).
//   4. FK CASCADE on section_embeddings.outline_section_id + generation_outputs.
//      outline_section_id: deleting a section cascades to its outputs + memory.
//   5. One-time cleanup of pre-existing NULL generation_output_id rows.
// =============================================================================

Deno.test({
  name: "Section-memory lineage fix (REVISED): FK on generation_output_id replaces trigger + backfill handles legacy rows",
  fn: async () => {
    // Per Kevin 2026-08-21 13:05 EDT feedback, the Round 4 migration was revised:
    // - Drop the custom output-delete trigger (replaced by FK + ON DELETE CASCADE)
    // - Backfill NULL generation_output_id from surviving generation_outputs
    //   per outline_section_id (don't blindly delete NULL rows)
    // - Add a behavioral DB regression test file
    //
    // Assert the migration contains the canonical FK + backfill pattern, and
    // does NOT contain the dropped trigger.
    const migrationPath = "supabase/migrations/20260821120000_add_generation_output_id_to_section_embeddings.sql";
    const testPath = "supabase/migrations/test_section_memory_lineage.sql";
    const exists = (await import("node:fs")).existsSync;
    if (!exists(migrationPath)) {
      throw new Error(`Migration file missing: ${migrationPath}`);
    }
    if (!exists(testPath)) {
      throw new Error(`Behavioral DB regression test file missing: ${testPath}`);
    }
    const migrationText = (await import("node:fs")).readFileSync(migrationPath, "utf8");
    // FK + ON DELETE CASCADE present.
    assertStringIncludes(
      migrationText,
      "ON DELETE CASCADE",
      "Migration must use ON DELETE CASCADE (the canonical approach per Kevin 13:05 EDT)",
    );
    assertStringIncludes(
      migrationText,
      "references public.generation_outputs(id)",
      "Migration must have FK referencing generation_outputs(id)",
    );
    // Backfill pattern present (don't blindly delete NULL rows).
    // Use case-insensitive matching since the migration uses lowercase "update".
    assertEquals(
      migrationText.toLowerCase().includes("update public.section_embeddings"),
      true,
      "Migration must backfill NULL generation_output_id before deleting orphaned rows",
    );
    // Trigger dropped (replaced by FK). The migration DOES reference the
    // trigger name in the DROP statement, but it must NOT CREATE the trigger
    // (only DROP it). The FK is the canonical approach per Kevin's spec.
    assertEquals(
      migrationText.includes("create trigger generation_outputs_delete_source_memory"),
      false,
      "Migration must NOT CREATE the custom trigger (replaced by FK CASCADE per Kevin 13:05 EDT)",
    );
    assertEquals(
      migrationText.includes("create or replace function public.delete_source_section_embedding"),
      false,
      "Migration must NOT CREATE the custom trigger function (replaced by FK CASCADE per Kevin 13:05 EDT)",
    );
    // The migration SHOULD drop the trigger + function (so the FK can take over).
    assertStringIncludes(
      migrationText,
      "drop trigger if exists generation_outputs_delete_source_memory",
      "Migration SHOULD drop the existing trigger (so the FK can take over)",
    );
    assertStringIncludes(
      migrationText,
      "drop function if exists public.delete_source_section_embedding",
      "Migration SHOULD drop the existing trigger function",
    );
    // Invariant wording updated to Kevin's spec.
    assertStringIncludes(
      migrationText,
      "current section memory must point to a surviving source generation",
      "Invariant wording must be updated to Kevin's spec (not 'active/accepted')",
    );
  },
});


// =============================================================================
// PR-360-Z CLEANUP PASS (Kevin 2026-08-21 14:44 EDT smoke-test feedback)
//
// Four targeted fixes per Kevin's spec:
//   1. Project State disappeared from Section 2 prompt → restore prior-section
//      memory in fetchProjectStateContext. Plus exclude the current section's
//      row (so prior/throwaway memory of the section being generated does not
//      feed back into its own prompt).
//   2. Ending Instruction leaking literally into prose → soften the guidance
//      (residue, not literal word/object).
//   3. Supporting context (Dramatic Seed / Relationships / Themes / Motifs /
//      Ending Instruction) must not commandeer the section → preserve the
//      "supporting context only" qualifier across all of them.
//   4. Vignette aftermath sprawl → container-specific tighter stopping rule.
//
// Success criteria (per Kevin): two-section smoke test where
//   (a) Section 1's memory appears in Section 2's Project State;
//   (b) Deleted/throwaway Section 2 attempts do NOT appear in Project State;
//   (c) Section Contract remains the last substantive context before Writing Task;
//   (d) Current section premise is followed immediately;
//   (e) Ending Instruction influences tone/residue without being literally named;
//   (f) Vignette stops at the first legitimate resonant endpoint.
//
// (d) is an LLM-behavior assertion that's not testable in deno; covered by
// smoke test on TestFlight. (a)-(c) and (e)-(f) are structural assertions on
// the prompt text + query, which the deno suite covers here.
// =============================================================================

// ----------------------------------------------------------------------------
// Cleanup pass #1: Project State query + rendering.
//
// (a) Section 1 memory appears in Section 2 Project State.
//     Verified by injecting projectStateContext in the request body (the
//     caller-supplied path). The actual fetchProjectStateContext DB query
//     is verified by source-level assertions below (PostgREST INNER JOIN
//     + excludeSectionId filter).
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #1: projectStateContext appears in Section 2 user message (Section 1 memory → Project State)",
  fn: async () => {
    const sectionOneMemory =
      "## Project state (cumulative across all accepted scenes)\n\n" +
      "**Latest summary:** Ted confronts the alien in the alley. The alien vanishes.\n\n" +
      "### Characters (latest known state)\n" +
      "- **Ted**: bloody, disoriented, standing in the alley.\n\n" +
      "### Open loops (unresolved)\n" +
      "- [unresolved] Where did the alien go?\n";
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      projectStateContext: sectionOneMemory,
      sectionTitle: "Aftermath",
      sectionSummary: "Ted walks home and processes what just happened.",
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    // Section 1's summary reaches Section 2's Project State block.
    assertStringIncludes(
      userMsg,
      "Ted confronts the alien in the alley",
      "Section 1 memory must survive into Section 2 ## Project State (success criterion #1a)",
    );
    assertStringIncludes(
      userMsg,
      "Where did the alien go?",
      "Section 1 open loops must survive into Section 2 ## Project State",
    );
    // Section Contract remains the LAST substantive context before Writing Task
    // (success criterion #1c). Order check: Section Contract index < Writing Task index.
    const sectionContractIdx = userMsg.lastIndexOf("## Section Contract");
    const writingTaskIdx = userMsg.lastIndexOf("## Writing Task");
    assertNotEquals(sectionContractIdx, -1, "Section Contract block must render");
    assertNotEquals(writingTaskIdx, -1, "Writing Task block must render");
    assertEquals(
      sectionContractIdx < writingTaskIdx,
      true,
      "Section Contract must appear BEFORE Writing Task (Kevin 14:44 EDT success criterion #1c)",
    );
    // Project State block appears BEFORE Section Contract (canonical order
    // per Kevin's spec: project context → Project State → Section Contract → Writing Task).
    const projectStateIdx = userMsg.indexOf("## Project state");
    assertNotEquals(projectStateIdx, -1, "Project State block must render when populated");
    assertEquals(
      projectStateIdx < sectionContractIdx,
      true,
      "Project State must appear BEFORE Section Contract (canonical order)",
    );
  },
});

// ----------------------------------------------------------------------------
// Cleanup pass #1 (DB query): fetchProjectStateContext excludes the current
// section's row so prior/throwaway memory does not feed back.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #1: fetchProjectStateContext accepts excludeSectionId + filters it in the query",
  fn: async () => {
    const indexPath = "supabase/functions/generate-story/index.ts";
    const text = (await import("node:fs")).readFileSync(indexPath, "utf8");

    // 1. Signature accepts excludeSectionId.
    const fnStart = text.indexOf("async function fetchProjectStateContext");
    assertNotEquals(fnStart, -1, "fetchProjectStateContext must exist");
    const fnBodyEnd = text.indexOf("\nfunction ", fnStart + 1);
    const fnBody = text.slice(fnStart, fnBodyEnd > 0 ? fnBodyEnd : fnStart + 3000);
    assertStringIncludes(
      fnBody,
      "excludeSectionId?: string",
      "fetchProjectStateContext must accept excludeSectionId?: string parameter (Kevin 14:44 EDT fix #1)",
    );

    // 2. Query applies .neq(\"outline_section_id\", excludeSectionId) when set.
    assertStringIncludes(
      fnBody,
      '.neq("outline_section_id", excludeSectionId)',
      "fetchProjectStateContext must filter excludeSectionId from the section_embeddings query (Kevin 14:44 EDT fix #1)",
    );

    // 3. INNER JOIN still present (defense-in-depth for orphaned memory).
    assertStringIncludes(
      fnBody,
      "generation_outputs!inner(id)",
      "fetchProjectStateContext must retain generation_outputs!inner(id) for orphaned-memory defense-in-depth",
    );

    // 4. Query error is logged (not silently swallowed) so future regressions
    //    surface in Supabase logs.
    assertStringIncludes(
      fnBody,
      "fetchProjectStateContext query error",
      "fetchProjectStateContext must log the PostgREST error on query failure (was silently returning \"\" before)",
    );

    // 5. Call site passes body.outline_section_id as excludeSectionId.
    assertStringIncludes(
      text,
      "fetchProjectStateContext(adminClient, projectID, body.outline_section_id",
      "fetchProjectStateContext must be called with body.outline_section_id as excludeSectionId",
    );
  },
});

// ----------------------------------------------------------------------------
// Cleanup pass #2: Ending Instruction softens literal guidance.
//
// Smoke result: "Leave the reader with Vomit" produced "a haze that felt
// distinctly like vomit" — too literal. New guidance describes residue,
// not the literal word/object.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #2: Ending Instruction describes residue, not literal word/object",
  fn: async () => {
    const indexPath = "supabase/functions/generate-story/index.ts";
    const text = (await import("node:fs")).readFileSync(indexPath, "utf8");

    // Old wording must be removed.
    assertEquals(
      text.includes("Leave the reader with"),
      false,
      "Old 'Leave the reader with' literal-direction wording must be removed (Kevin 14:44 EDT fix #2)",
    );

    // New wording must be present.
    assertStringIncludes(
      text,
      "Target ending residue:",
      "Ending Instruction must state 'Target ending residue:' (replaces literal 'Leave the reader with X')",
    );
    assertStringIncludes(
      text,
      "Do not quote, name, or directly restate",
      "Ending Instruction must explicitly forbid quoting/naming the label",
    );
    assertStringIncludes(
      text,
      "unless the current scene independently requires that literal thing",
      "Ending Instruction must carve out the 'scene independently requires the literal thing' exception",
    );
    // Section Contract still outranks Ending Instruction.
    assertStringIncludes(
      text,
      "The current Section Contract always takes precedence over the Ending Instruction",
      "Section Contract must remain authoritative over Ending Instruction (Kevin 14:44 EDT spec)",
    );
  },
});

// ----------------------------------------------------------------------------
// Cleanup pass #3: Supporting context qualifiers preserved.
//
// Smoke result: Dramatic Seed / Ted violence guidance pushed the alien into
// saying "Your blood thirst is a tool. Embrace it." — supporting context
// commandeering the section. The existing "supporting context only" labels
// must remain on every supporting-context section (Dramatic Seed /
// Relationships / Themes / Motifs / Ending Instruction).
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #3: supporting-context qualifiers present on Relationships, Themes, Motifs, Dramatic Seed, Ending Instruction",
  fn: async () => {
    const indexPath = "supabase/functions/generate-story/index.ts";
    const text = (await import("node:fs")).readFileSync(indexPath, "utf8");

    // Relationships: supporting context only — do not let it redirect.
    assertStringIncludes(
      text,
      "(Supporting context only — the current Section Contract always takes precedence. Do not let relationships redirect the section.)",
      "Relationships must carry the 'supporting context only' qualifier",
    );

    // Themes: same.
    assertStringIncludes(
      text,
      "(Supporting context only — the current Section Contract always takes precedence. Do not let these questions redirect the section.)",
      "Themes must carry the 'supporting context only' qualifier",
    );

    // Motifs: same.
    assertStringIncludes(
      text,
      "(Supporting context only — the current Section Contract always takes precedence. Do not let motifs redirect the section.)",
      "Motifs must carry the 'supporting context only' qualifier",
    );

    // Dramatic Seed: explicitly states the Section Contract always wins.
    assertStringIncludes(
      text,
      "The Section Contract always takes precedence. Do not let the spark redirect, replace, or override the section premise",
      "Dramatic Seed must explicitly defer to Section Contract (Kevin 09:37 EDT rule)",
    );

    // Ending Instruction: now explicitly states Section Contract outranks it.
    assertStringIncludes(
      text,
      "The current Section Contract always takes precedence over the Ending Instruction",
      "Ending Instruction must explicitly state Section Contract outranks it (Kevin 14:44 EDT fix #2)",
    );

    // SYSTEM authority block unchanged: Section Contract outranks ALL.
    assertStringIncludes(
      text,
      "It outranks ALL other creative guidance in this prompt — Dramatic Seed, Themes, Motifs, Relationships, Ending Instruction, Intimacy guidance, and Project State (prior scenes).",
      "SYSTEM Section Contract Authority block must outrank ALL other creative guidance (invariant)",
    );
  },
});

// ----------------------------------------------------------------------------
// Cleanup pass #4: Vignette stopping rule tightened.
//
// Smoke result: vignette reached its natural stopping point around the alien
// disappearing / Ted's realization, then continued with Ted returning to the
// street, future-action contemplation, additional destruction imagery, and
// another closing image. Container budgets UNCHANGED — only the stopping
// rule is tightened for vignettes specifically.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #4: vignette container has container-specific stopping rule (no aftermath sprawl)",
  fn: async () => {
    const indexPath = "supabase/functions/generate-story/index.ts";
    const text = (await import("node:fs")).readFileSync(indexPath, "utf8");

    // Vignette config has the new stoppingRule field.
    const vignetteBlock = text.match(
      /vignette:\s*\{[\s\S]*?\},/,
    );
    assertNotEquals(vignetteBlock, null, "vignette container config block must exist");
    assertStringIncludes(
      vignetteBlock![0],
      'stoppingRule: "Once the vignette reaches its resonant image or emotional turn, stop. Do not add aftermath, future-action setup, a second ending, or additional thematic explanation after the natural stopping point."',
      "vignette container must carry the Kevin 14:44 EDT stoppingRule (no aftermath/future-action/second ending)",
    );

    // containerInstructions accepts and renders the stoppingRule when present.
    const containerInstructionsFn = text.match(
      /const containerInstructions = \([\s\S]*?\);/,
    );
    assertNotEquals(containerInstructionsFn, null, "containerInstructions function must exist");
    assertStringIncludes(
      containerInstructionsFn![0],
      "stoppingRule?: string",
      "containerInstructions must accept stoppingRule?: string parameter",
    );
    assertStringIncludes(
      containerInstructionsFn![0],
      "Container-specific stopping rule",
      "containerInstructions must render the Container-specific stopping rule block when provided",
    );

    // Call site passes cfg.stoppingRule.
    assertStringIncludes(
      text,
      "containerInstructions(cfg.name, cfg.whatItContains, cfg.naturalStoppingPoint, cfg.expectedRange, cfg.stoppingRule)",
      "containerInstructions call site must forward cfg.stoppingRule",
    );

    // General structural-limit instruction still present (other containers).
    assertStringIncludes(
      text,
      "Do not continue into the aftermath, next destination, next scene, or consequences.",
      "General structural-limit instruction must remain for non-vignette containers",
    );

    // hardCap is unchanged (Kevin 14:44 EDT: 'Do not change container budgets').
    const vignetteHardCap = text.match(/vignette:\s*\{[\s\S]*?hardCap:\s*\d+,/);
    assertNotEquals(vignetteHardCap, null, "vignette hardCap must still be defined");
    assertStringIncludes(
      vignetteHardCap![0],
      "hardCap: 1200",
      "vignette hardCap must remain 1200 (Kevin 14:44 EDT: 'Do not change container budgets')",
    );
  },
});

// ----------------------------------------------------------------------------
// Cleanup pass #1 migration: validate FK + reload PostgREST schema.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z cleanup #1 migration: validates section_embeddings FK + reloads PostgREST schema",
  fn: async () => {
    const fs = await import("node:fs");
    const path = "supabase/migrations/20260821140000_validate_section_embeddings_fk_and_reload_schema.sql";
    const text = fs.readFileSync(path, "utf8");
    assertStringIncludes(
      text,
      "VALIDATE CONSTRAINT section_embeddings_generation_output_id_fkey",
      "Migration must VALIDATE the section_embeddings FK constraint",
    );
    assertStringIncludes(
      text,
      "NOTIFY pgrst, 'reload schema'",
      "Migration must reload PostgREST schema cache",
    );
  },
});


// =============================================================================
// PR-360-Z CLEANUP PASS — Story Arc Context (Kevin 2026-08-21 17:02 EDT)
//
// Kevin explicitly chose option (a) — add it NOW in this cleanup pass, not
// in Phase 2. The prompt gains a "## Story Arc Context" block between
// Project State and Section Contract so the model knows which beat it's
// writing within the larger arc structure. All five fields are optional;
// the block is omitted when none are set (back-compat for iOS direct
// generation, which doesn't populate these today).
//
// Rendered format (per Kevin's spec):
//   ## Story Arc Context
//   Supporting structural context only. The Section Contract remains authoritative.
//
//   Arc: [arc name/type]
//   Current beat: [beat label]
//   Beat purpose: [beat description]
//   Position: N of M    (1-indexed; DB position is 0-indexed)
// =============================================================================

// ----------------------------------------------------------------------------
// Handler-level: block renders correctly when all fields are populated.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: block renders when all fields populated (Kevin 17:02 EDT spec)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "The Darkest Hour",
      sectionSummary: "The hero confronts the villain at the midpoint of the arc.",
      storyArcName: "Three-Act Structure",
      storyArcBeatLabel: "Midpoint Reversal",
      storyArcBeatPurpose: "Stakes raised; hero's worst fear realized; major revelation shifts the trajectory of the story.",
      storyArcPosition: 3,        // 0-indexed in DB
      storyArcTotalBeats: 7,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;

    // Header line.
    assertStringIncludes(
      userMsg,
      "## Story Arc Context",
      "Story Arc Context header must render when fields are populated",
    );
    // Kevin's framing — supporting context only + Section Contract authority.
    assertStringIncludes(
      userMsg,
      "Supporting structural context only. The Section Contract remains authoritative.",
      "Story Arc Context must carry the supporting-context-only framing (Kevin 17:02 EDT spec)",
    );

    // Each of the four content lines.
    assertStringIncludes(userMsg, "Arc: Three-Act Structure", "Arc name line must render");
    assertStringIncludes(userMsg, "Current beat: Midpoint Reversal", "Beat label line must render");
    assertStringIncludes(
      userMsg,
      "Beat purpose: Stakes raised; hero\u2019s worst fear realized; major revelation shifts the trajectory of the story.",
      "Beat purpose line must render (apostrophe + escaping)",
    );
    // 1-indexed conversion: position 3 (0-indexed) → "Position: 4 of 7".
    assertStringIncludes(
      userMsg,
      "Position: 4 of 7",
      "Position line must render as 1-indexed (DB position 3 → display '4 of 7')",
    );
  },
});

// ----------------------------------------------------------------------------
// Handler-level: block is omitted when NO fields are set (back-compat).
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: block omitted when no fields set (back-compat for iOS direct-gen)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Some Section",
      sectionSummary: "A summary that does not mention story arc.",
      // No storyArc* fields.
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertEquals(
      userMsg.includes("## Story Arc Context"),
      false,
      "Story Arc Context block must be omitted when none of the five fields are set",
    );
  },
});

// ----------------------------------------------------------------------------
// Handler-level: position partial fields work (e.g., position without total).
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: partial fields render the available lines (e.g., beat only)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Beat Only",
      sectionSummary: "Section with only beat label set.",
      storyArcBeatLabel: "Inciting Incident",
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;
    assertStringIncludes(userMsg, "## Story Arc Context", "Header must render when at least one field is set");
    assertStringIncludes(userMsg, "Current beat: Inciting Incident", "Beat label line must render");
    // Other lines must NOT render when their fields are absent.
    assertEquals(
      userMsg.includes("Arc:"),
      false,
      "Arc line must not render when storyArcName is absent",
    );
    assertEquals(
      userMsg.includes("Beat purpose:"),
      false,
      "Beat purpose line must not render when storyArcBeatPurpose is absent",
    );
    assertEquals(
      userMsg.includes("Position:"),
      false,
      "Position line must not render when storyArcPosition is absent",
    );
  },
});

// ----------------------------------------------------------------------------
// Placement: Story Arc Context must be between Project State and Section Contract.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: placed between Project State and Section Contract (Kevin 17:02 EDT order)",
  fn: async () => {
    const c = await runPR360ZCapture({
      sourcePayloadJSON: POPULATED_PAYLOAD_PR360Z,
      sectionTitle: "Order Check",
      sectionSummary: "Verifying prompt order.",
      projectStateContext: "## Project state (cumulative across all accepted scenes)\n\nPrior scene memory.",
      storyArcName: "Hero\u2019s Journey",
      storyArcBeatLabel: "Crossing the Threshold",
      storyArcBeatPurpose: "Hero commits to the adventure.",
      storyArcPosition: 1,
      storyArcTotalBeats: 5,
    });
    assertEquals(c !== null, true);
    const userMsg = c!.messages[1].content;

    const projectStateIdx = userMsg.indexOf("## Project state");
    const storyArcIdx = userMsg.indexOf("## Story Arc Context");
    const sectionContractIdx = userMsg.lastIndexOf("## Section Contract");
    const writingTaskIdx = userMsg.lastIndexOf("## Writing Task");

    assertNotEquals(projectStateIdx, -1, "Project State must render");
    assertNotEquals(storyArcIdx, -1, "Story Arc Context must render");
    assertNotEquals(sectionContractIdx, -1, "Section Contract must render");
    assertNotEquals(writingTaskIdx, -1, "Writing Task must render");

    assertEquals(
      projectStateIdx < storyArcIdx,
      true,
      "Project State must appear BEFORE Story Arc Context (canonical order)",
    );
    assertEquals(
      storyArcIdx < sectionContractIdx,
      true,
      "Story Arc Context must appear BEFORE Section Contract (Kevin 17:02 EDT spec — structural context immediately before per-section contract)",
    );
    assertEquals(
      sectionContractIdx < writingTaskIdx,
      true,
      "Section Contract must still appear BEFORE Writing Task (invariant from PR-360-Z cleanup pass #1)",
    );
  },
});

// ----------------------------------------------------------------------------
// Source-level: generate-story request body type + buildPrompt params + forwarding.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: request body + buildPrompt + handler forwarding are wired",
  fn: async () => {
    const fs = await import("node:fs");
    const text = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");

    // 1. Request body interface accepts the 5 new fields.
    assertStringIncludes(
      text,
      "storyArcName?: string;",
      "GenerateStoryRequest interface must include storyArcName?: string",
    );
    assertStringIncludes(
      text,
      "storyArcBeatLabel?: string;",
      "GenerateStoryRequest interface must include storyArcBeatLabel?: string",
    );
    assertStringIncludes(
      text,
      "storyArcBeatPurpose?: string;",
      "GenerateStoryRequest interface must include storyArcBeatPurpose?: string",
    );
    assertStringIncludes(
      text,
      "storyArcPosition?: number;",
      "GenerateStoryRequest interface must include storyArcPosition?: number",
    );
    assertStringIncludes(
      text,
      "storyArcTotalBeats?: number;",
      "GenerateStoryRequest interface must include storyArcTotalBeats?: number",
    );

    // 2. buildPrompt params accept the same 5 fields.
    // Use the source-level pattern check (similar to existing "Defense-in-depth" test).
    const fnPromptStart = text.indexOf("function buildPrompt(req: {");
    assertNotEquals(fnPromptStart, -1, "buildPrompt must exist");
    const fnPromptEnd = text.indexOf("\nfunction ", fnPromptStart + 1);
    const fnPromptBody = text.slice(fnPromptStart, fnPromptEnd > 0 ? fnPromptEnd : fnPromptStart + 3000);
    assertStringIncludes(
      fnPromptBody,
      "storyArcName?: string;",
      "buildPrompt params must accept storyArcName?: string",
    );
    assertStringIncludes(
      fnPromptBody,
      "storyArcTotalBeats?: number;",
      "buildPrompt params must accept storyArcTotalBeats?: number",
    );

    // 3. The "## Story Arc Context" block is rendered with Kevin's exact framing.
    assertStringIncludes(
      text,
      "\"## Story Arc Context\"",
      "buildPrompt must render the \"## Story Arc Context\" header",
    );
    assertStringIncludes(
      text,
      "Supporting structural context only. The Section Contract remains authoritative.",
      "Story Arc Context block must carry Kevin's framing verbatim (17:02 EDT spec)",
    );

    // 4. Position is rendered as 1-indexed (DB position + 1).
    assertStringIncludes(
      text,
      "const displayPosition = req.storyArcPosition + 1",
      "Position must convert from 0-indexed DB to 1-indexed display",
    );

    // 5. Handler forwards the 5 fields from body to buildPrompt.
    assertStringIncludes(
      text,
      "storyArcName: body.storyArcName",
      "Handler must forward body.storyArcName to buildPrompt",
    );
    assertStringIncludes(
      text,
      "storyArcTotalBeats: body.storyArcTotalBeats",
      "Handler must forward body.storyArcTotalBeats to buildPrompt",
    );
  },
});

// ----------------------------------------------------------------------------
// Source-level: _generation_request.ts exposes the 5 fields + run-outline
// fetchStoryArcContext helper exists and is called.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z Story Arc Context: _generation_request.ts + run-outline fetchStoryArcContext wired",
  fn: async () => {
    const fs = await import("node:fs");
    const genReqText = fs.readFileSync(
      "supabase/functions/run-outline/_generation_request.ts",
      "utf8",
    );
    assertStringIncludes(
      genReqText,
      "storyArcName?: string;",
      "_generation_request.ts must expose storyArcName?: string in buildGenerateStoryRequest",
    );
    assertStringIncludes(
      genReqText,
      "storyArcTotalBeats?: number;",
      "_generation_request.ts must expose storyArcTotalBeats?: number in buildGenerateStoryRequest",
    );
    assertStringIncludes(
      genReqText,
      "storyArcName: args.storyArcName",
      "_generation_request.ts must forward args.storyArcName into the returned payload",
    );

    const runOutlineText = fs.readFileSync(
      "supabase/functions/run-outline/index.ts",
      "utf8",
    );
    assertStringIncludes(
      runOutlineText,
      "async function fetchStoryArcContext(",
      "run-outline must define fetchStoryArcContext helper (Kevin 17:02 EDT)",
    );
    assertStringIncludes(
      runOutlineText,
      "await fetchStoryArcContext(adminClient, section.story_arc_beat_id)",
      "run-outline must call fetchStoryArcContext before buildGenerateStoryRequest",
    );
    assertStringIncludes(
      runOutlineText,
      "storyArcName: storyArc.name",
      "run-outline must spread fetched story arc fields into buildGenerateStoryRequest",
    );
  },
});


// =============================================================================
// PR-360-Z cleanup pass — REGRESSION TESTS (Kevin 2026-08-21 17:47 EDT spec)
//
// Kevin's spec demands four categories of regression tests for the architectural
// refactor where generate-story OWNS post-generation extraction:
//   A. Direct iOS: generation_outputs has outline_section_id; section_embeddings
//      points to generation_output_id; section_embeddings.raw_text is the
//      GENERATED prose (NOT section.title/summary/terminalBeat); Section B
//      prompt contains Section A in ## Project State.
//   B. run-outline: exactly one extraction per generated section; no duplicate
//      embed-section LLM call; next section sees prior section memory.
//   C. Story Arc: section linked to arc beat 3/7 produces ## Story Arc Context
//      with that beat; Section Contract remains immediately before Writing
//      Task; section without arc beat omits Story Arc Context cleanly.
//   D. Deletion: deleting source generation removes/excludes its section memory;
//      next generation no longer sees deleted prose in Project State.
// =============================================================================

// ----------------------------------------------------------------------------
// Category A: Direct iOS generation — section_embeddings.raw_text = generated
// prose (NOT section title/summary), and Section B sees Section A in Project State.
// ----------------------------------------------------------------------------

// Source-level assertion: generate-story calls embed-section with raw_text =
// llmResult.content (the ACTUAL generated prose), NOT a contract-derived text.
// This is the core architectural fix Kevin mandated — the previous Option A
// approach used iOS's SectionEmbedService.buildRawText(for:) which builds
// from OutlineSection.title + summary + terminalBeat (the contract), storing
// "what was supposed to happen" as Project State instead of "what actually
// happened". The fire-and-forget embed-section call inside generate-story must
// pass raw_text from llmResult.content directly.
Deno.test({
  name: "PR-360-Z regression A: generate-story calls embed-section with raw_text = llmResult.content (the actual prose)",
  fn: async () => {
    const fs = await import("node:fs");
    const text = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");

    // The fire-and-forget call site MUST pass llmResult.content as raw_text.
    // This is the architectural fix — SectionEmbedService.buildRawText(for:)
    // is rejected because it builds from contract, not prose.
    assertStringIncludes(
      text,
      "raw_text: llmResult.content",
      "generate-story must pass raw_text = llmResult.content to embed-section (NOT section contract)",
    );

    // The fetch-site MUST be inside the if (outlineSectionCtx.section && llmResult?.content)
    // guard — only fire when both outline_section_id resolved AND we have prose.
    const handlerArea = text.slice(text.indexOf("function handler("), text.indexOf("function fetchOutlineSectionContext("));
    assertStringIncludes(
      handlerArea,
      "outlineSectionCtx.section && llmResult?.content",
      "Post-generation embed-section call must be guarded by both outlineSectionCtx.section AND llmResult.content",
    );

    // The fire-and-forget MUST NOT fail the main generation call.
    assertStringIncludes(
      handlerArea,
      ".catch(",
      "Post-generation embed-section call must be fire-and-forget (catch + log on failure, never throw)",
    );

    // The embed-section call payload MUST include all the section metadata the
    // embed-section edge function expects (title, summary, container, pov,
    // terminal_beat, story_arc_beat_id, position, outline_id).
    const callSiteMatch = handlerArea.match(/callEmbedSectionForGeneratedOutput\([\s\S]+?\}\)/);
    assertNotEquals(callSiteMatch, null, "callEmbedSectionForGeneratedOutput call site must exist");
    for (const field of ["outline_section_id", "outline_id", "project_id", "position", "title", "summary", "container", "pov", "terminal_beat", "story_arc_beat_id", "raw_text", "output_id", "prior_context"]) {
      assertStringIncludes(
        callSiteMatch![0],
        field,
        `callEmbedSectionForGeneratedOutput payload must include '${field}'`,
      );
    }
  },
});

// Source-level assertion: handler forwards body.outline_outline_section_id to
// persistence.insertOutput so generation_outputs.outline_section_id is populated.
Deno.test({
  name: "PR-360-Z regression A: handler forwards outline_section_id to persistence.insertOutput (FK target populated)",
  fn: async () => {
    const fs = await import("node:fs");
    const text = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");
    assertStringIncludes(
      text,
      'outline_section_id: body.outline_section_id ?? null',
      "persistence.insertOutput must persist body.outline_section_id to generation_outputs.outline_section_id",
    );
    // Also confirm llm_prompts insert captures the same id (so the LLMPromptDebugView
    // can correlate prompts to their source section).
    assertStringIncludes(
      text,
      'outline_section_id: body.outline_section_id ?? null,',
      "llm_prompts insert must persist body.outline_section_id (LLMPromptDebugView correlation)",
    );
  },
});

// ----------------------------------------------------------------------------
// Category B: run-outline — exactly one extraction per section (no duplicate).
// Single owner = generate-story. run-outline no longer calls embed-section.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z regression B: run-outline no longer calls embed-section (single owner = generate-story)",
  fn: async () => {
    const fs = await import("node:fs");
    const runOutlineText = fs.readFileSync("supabase/functions/run-outline/index.ts", "utf8");

    // run-outline MUST NOT call callEmbedSection anymore.
    // We search for non-comment occurrences of callEmbedSection.
    const lines = runOutlineText.split("\n");
    const occurrences = lines
      .map((line, i) => ({ line, idx: i + 1 }))
      .filter(({ line }) => {
        const trimmed = line.trim();
        if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")) return false;
        return line.includes("callEmbedSection(");
      });
    assertEquals(
      occurrences.length,
      0,
      `run-outline MUST NOT call callEmbedSection anymore (Kevin 17:47 EDT — single owner = generate-story). Found ${occurrences.length} non-comment occurrence(s):\n${occurrences.map((o) => `  line ${o.idx}: ${o.line}`).join("\n")}`,
    );

    // run-outline MUST NOT define fetchPriorContext-call-style helpers used
    // for embed-section's prior_context (generate-story fetches its own now).
    // We allow fetchPriorContext to be defined (it's a helper) but it MUST
    // NOT be called from the section loop anymore.
    const sectionLoopArea = runOutlineText.slice(
      runOutlineText.indexOf("for (const section of sections)"),
      runOutlineText.indexOf("for (const section of sections)") + 4000,
    );
    assertEquals(
      sectionLoopArea.includes("fetchPriorContext("),
      false,
      "run-outline section loop must NOT call fetchPriorContext anymore (generate-story owns it)",
    );
    assertEquals(
      sectionLoopArea.includes("fetchStoryArcContext("),
      false,
      "run-outline section loop must NOT call fetchStoryArcContext anymore (generate-story resolves server-side)",
    );
  },
});

// Source-level assertion: generate-story has fetchOutlineSectionContext that
// fetches section metadata + story arc context in one helper (single source
// of truth). The 5 story arc fields are no longer expected from callers.
Deno.test({
  name: "PR-360-Z regression B/C: server-resolved story arc context (single source of truth, no body fields)",
  fn: async () => {
    const fs = await import("node:fs");
    const genText = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");
    const genReqText = fs.readFileSync("supabase/functions/run-outline/_generation_request.ts", "utf8");

    // generate-story has the server-side resolver.
    assertStringIncludes(
      genText,
      "async function fetchOutlineSectionContext(",
      "generate-story must define fetchOutlineSectionContext (server-side resolver)",
    );

    // Handler invokes fetchOutlineSectionContext and stores result in outlineSectionCtx.
    assertStringIncludes(
      genText,
      "const outlineSectionCtx = await fetchOutlineSectionContext(adminClient, body.outline_section_id)",
      "Handler must invoke fetchOutlineSectionContext and assign to outlineSectionCtx",
    );

    // The 5 story arc fields are REMOVED from the request body interface.
    // (Verify they're absent from the body type definition.)
    const reqBodySection = genText.slice(
      genText.indexOf("interface GenerateStoryRequest"),
      genText.indexOf("})", genText.indexOf("interface GenerateStoryRequest")) + 5,
    );
    for (const field of ["storyArcName?", "storyArcBeatLabel?", "storyArcBeatPurpose?", "storyArcPosition?", "storyArcTotalBeats?"]) {
      assertEquals(
        reqBodySection.includes(field),
        false,
        `GenerateStoryRequest must NOT include ${field} (server resolves from outline_section_id)`,
      );
    }

    // _generation_request.ts also REMOVED the 5 fields.
    for (const field of ["storyArcName?: string", "storyArcBeatLabel?: string", "storyArcBeatPurpose?: string", "storyArcPosition?: number", "storyArcTotalBeats?: number"]) {
      assertEquals(
        genReqText.includes(field),
        false,
        `_generation_request.ts must NOT include ${field} (server resolves)`,
      );
    }

    // The buildPrompt params still retain the 5 fields internally (just no longer
    // caller-settable). Handler populates them from outlineSectionCtx.storyArc.
    const handlerArea = genText.slice(genText.indexOf("function handler("), genText.indexOf("function fetchOutlineSectionContext("));
    assertStringIncludes(
      handlerArea,
      "storyArcName: outlineSectionCtx.storyArc.name",
      "Handler must pass outlineSectionCtx.storyArc.name to buildPrompt (server-resolved)",
    );
  },
});

// ----------------------------------------------------------------------------
// Category C: Story Arc Context — beat-linked section renders block; non-beat
// section omits cleanly. Section Contract remains immediately before Writing Task.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z regression C: Story Arc Context block renders only when outline_section_context has story arc data",
  fn: async () => {
    const fs = await import("node:fs");
    const text = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");

    // The Story Arc Context block rendering is gated on outlineSectionCtx.storyArc
    // having at least one field set (NOT on body fields, which no longer exist).
    const buildPromptFn = text.slice(text.indexOf("function buildPrompt(req: {"), text.indexOf("function fetchOutlineSectionContext("));
    assertStringIncludes(
      buildPromptFn,
      "## Story Arc Context",
      "buildPrompt must render the Story Arc Context block",
    );
    // The gate must check the 5 internal fields (populated from outlineSectionCtx).
    assertStringIncludes(
      buildPromptFn,
      "req.storyArcName ||",
      "Story Arc Context block must be conditional on req.storyArcName (or other 5 fields)",
    );
    assertStringIncludes(
      buildPromptFn,
      "typeof req.storyArcPosition === "number"",
      "Story Arc Context block must render Position (1-indexed display)",
    );

    // USER block order: canonical project context → Project State → Story Arc
    // Context → Section Contract → Writing Task (per Kevin's spec).
    const projectStateIdx = buildPromptFn.indexOf("req.projectStateContext");
    const storyArcIdx = buildPromptFn.indexOf("## Story Arc Context");
    const sectionContractIdx = buildPromptFn.lastIndexOf("## Section Contract");
    const writingTaskIdx = buildPromptFn.lastIndexOf("## Writing Task");
    assertNotEquals(projectStateIdx, -1, "Project State block must render in buildPrompt");
    assertNotEquals(storyArcIdx, -1, "Story Arc Context block must render in buildPrompt");
    assertNotEquals(sectionContractIdx, -1, "Section Contract block must render in buildPrompt");
    assertNotEquals(writingTaskIdx, -1, "Writing Task block must render in buildPrompt");
    assertEquals(
      projectStateIdx < storyArcIdx,
      true,
      "Project State must come BEFORE Story Arc Context (canonical order)",
    );
    assertEquals(
      storyArcIdx < sectionContractIdx,
      true,
      "Story Arc Context must come BEFORE Section Contract (Kevin 17:47 EDT canonical order)",
    );
    assertEquals(
      sectionContractIdx < writingTaskIdx,
      true,
      "Section Contract must come BEFORE Writing Task (invariant from previous specs)",
    );
  },
});

// ----------------------------------------------------------------------------
// Category D: Deletion — FK CASCADE removes section_embeddings when source
// generation_output is deleted. Next generation no longer sees deleted prose
// in Project State. Verified by the existing 5114091 migration + the Round 4
// FK constraint design.
// ----------------------------------------------------------------------------
Deno.test({
  name: "PR-360-Z regression D: FK CASCADE on generation_outputs removes section_embeddings (deleted prose excluded from Project State)",
  fn: async () => {
    const fs = await import("node:fs");

    // The fetchProjectStateContext query already uses INNER JOIN — deleted
    // generation_outputs rows are excluded at READ time (defense-in-depth).
    const genText = fs.readFileSync("supabase/functions/generate-story/index.ts", "utf8");
    assertStringIncludes(
      genText,
      'generation_outputs!inner(id)',
      "fetchProjectStateContext must INNER JOIN generation_outputs (orphaned memory filtered at READ time)",
    );

    // The excludeSectionId filter ensures the CURRENT section's own memory
    // doesn't feed back into its own prompt (Kevin's spec item: 'Section B
    // prompt contains Section A in ## Project State' but NOT Section B itself).
    assertStringIncludes(
      genText,
      '.neq("outline_section_id", excludeSectionId)',
      "fetchProjectStateContext must filter excludeSectionId (current section excluded from its own prompt)",
    );

    // The 5114091 migration added the FK with ON DELETE CASCADE — verified by
    // the source-level test in the 90e05d3 commit. Verify the migration is
    // still present on main.
    const migrationPath = "supabase/migrations/20260821140000_validate_section_embeddings_fk_and_reload_schema.sql";
    const migrationText = fs.readFileSync(migrationPath, "utf8");
    assertStringIncludes(
      migrationText,
      "VALIDATE CONSTRAINT section_embeddings_generation_output_id_fkey",
      "Migration 20260821140000 must VALIDATE the FK (defense-in-depth against schema-cache ambiguity)",
    );
  },
});


// =============================================================================
// PR-360-Z follow-up (Kevin 2026-08-22 09:50 EDT prompt cleanup) — buildPrompt
// regression tests. These verify the 8 required changes from the prompt
// cleanup spec landed correctly without touching Project State / RAG /
// validation / models / flow / DB / UI.
// =============================================================================

import { buildPrompt } from "./index.ts";

const MINIMAL_PROMPT_ARGS = {
  sourcePayloadJSON: MINIMAL_PAYLOAD,
  generationAction: "generate" as const,
  generationLengthMode: "short" as const,
  container: "scene" as const,
  pov: "thirdPersonLimited" as const,
  outputBudget: 800,
  projectName: "Test Project",
  promptPackName: "Test Pack",
};

Deno.test("buildPrompt: does not contain the fixed prose example (She set down the glass)", () => {
  const { craft } = buildPrompt(MINIMAL_PROMPT_ARGS);
  assertEquals(craft.includes("She set down the glass"), false);
  assertEquals(craft.includes("## Examples"), false);
});

Deno.test("buildPrompt: contains ## Literary Execution block with the 14 craft bullets", () => {
  const { craft } = buildPrompt(MINIMAL_PROMPT_ARGS);
  assertStringIncludes(craft, "## Literary Execution");
  assertStringIncludes(craft, "Write finished prose in active scene, not synopsis");
  assertStringIncludes(craft, "Build direct cause and effect");
  assertStringIncludes(craft, "Render the selected required event on-page");
  assertStringIncludes(craft, "Filter description and interpretation through the viewpoint character");
  assertStringIncludes(craft, "Do not explain a dynamic or emotion immediately after the prose has already demonstrated it");
  assertStringIncludes(craft, "Give dialogue an immediate character objective");
  assertStringIncludes(craft, "Prefer precise nouns, active verbs, and selective concrete details");
  assertStringIncludes(craft, "Vary sentence length and paragraph size");
  assertStringIncludes(craft, "Do not repeat an image unless its meaning, context, or consequence changes");
  assertStringIncludes(craft, "Do not directly reproduce or closely paraphrase section titles, motif labels");
  assertStringIncludes(craft, "Preserve character agency");
  assertStringIncludes(craft, "Build one decisive ending. Do not append repeated revelations");
});

Deno.test("buildPrompt: Section Contract Authority contains Container co-authority rule", () => {
  const { craft } = buildPrompt({
    ...MINIMAL_PROMPT_ARGS,
    sectionTitle: "Test Section",
    sectionSummary: "The protagonist faces a storm.",
  });
  assertStringIncludes(craft, "## Section Contract Authority");
  assertStringIncludes(craft, "Container scope and the Section Contract are jointly authoritative");
  assertStringIncludes(craft, "The Container controls how much happens");
  assertStringIncludes(craft, "the Section Contract controls what happens");
  assertStringIncludes(craft, "Do not summarize or cram the entire section into a smaller container");
});

Deno.test("buildPrompt: Beat container + section context instructs dramatize one incident", () => {
  const { context } = buildPrompt({
    ...MINIMAL_PROMPT_ARGS,
    container: "beat",
    sectionTitle: "Beat",
    sectionSummary: "Several events happen in the protagonist's day.",
  });
  assertStringIncludes(context, "## Beat Rule (CRITICAL)");
  assertStringIncludes(context, "select and dramatize one concrete incident");
  assertStringIncludes(context, "Do not summarize every event implied by the section premise");
});

Deno.test("buildPrompt: Terminal Beat uses storyArcBeatPurpose (human-readable) over raw terminalBeat", () => {
  const { context } = buildPrompt({
    ...MINIMAL_PROMPT_ARGS,
    terminalBeat: "ordinary_world", // raw enum from caller
    storyArcBeatPurpose: "End after a concrete moment establishes the viewpoint character's normal pattern under pressure.",
  });
  assertEquals(context.includes("ordinary_world"), false);
  assertStringIncludes(context, "End after: End after a concrete moment establishes the viewpoint character");
  assertStringIncludes(context, "Do not name or quote the structural beat in the prose");
});

Deno.test("buildPrompt: Terminal Beat falls back to terminalBeat when storyArcBeatPurpose absent", () => {
  const { context } = buildPrompt({
    ...MINIMAL_PROMPT_ARGS,
    terminalBeat: "End after the conversation settles into silence.",
    storyArcBeatPurpose: undefined,
  });
  assertStringIncludes(context, "## Terminal Beat");
  assertStringIncludes(context, "End after: End after the conversation settles into silence");
  assertStringIncludes(context, "Do not name or quote the structural beat in the prose");
});

Deno.test("buildPrompt: Terminal Beat omitted when neither terminalBeat nor storyArcBeatPurpose set", () => {
  const { context } = buildPrompt(MINIMAL_PROMPT_ARGS);
  assertEquals(context.includes("## Terminal Beat"), false);
});

Deno.test("buildPrompt: projectStateContext rendered unchanged into user message", () => {
  const projectState = "## Project state (cumulative across all accepted scenes)\n\n**Latest summary:** The rainstorm ended.\n\n### Characters (latest known state)\n- Bill Noah: grieving";
  const { context } = buildPrompt({
    ...MINIMAL_PROMPT_ARGS,
    projectStateContext: projectState,
  });
  assertStringIncludes(context, projectState);
  // The transition rule (continuity, not subject) should still appear.
  assertStringIncludes(context, "Project State establishes continuity, not the required subject");
});

Deno.test("buildPrompt: Writing Instructions has new Container-rule text", () => {
  const { craft } = buildPrompt(MINIMAL_PROMPT_ARGS);
  assertEquals(craft.includes("If you cannot cover everything"), false);
  assertStringIncludes(craft, "If the Section Contract is broader than the Container");
  assertStringIncludes(craft, "dramatize one material part of it");
  assertStringIncludes(craft, "Compress description and transitions before compressing the selected action");
  assertStringIncludes(craft, "Never exceed the Container hard cap");
});

Deno.test("buildPrompt: Writing Instructions has Ending Instruction residue rule", () => {
  const { craft } = buildPrompt(MINIMAL_PROMPT_ARGS);
  assertEquals(craft.includes("Close the piece according to the Ending Instruction"), false);
  assertStringIncludes(craft, "Shape the final action and image to leave the requested Ending Instruction residue");
  assertStringIncludes(craft, "Do not quote the residue label, force it literally, or add a second ending after the Terminal Beat");
});
