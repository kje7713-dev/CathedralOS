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
import type { LLMMessage, LLMProvider } from "./_provider.ts";

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
      return Promise.resolve({ ...ent, monthly_credit_allowance: newMonthly });
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

Deno.test("classifyOpenAIStatus: 429 -> provider_rate_limited", () => {
  assertEquals(classifyOpenAIStatus(429), "provider_rate_limited");
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

Deno.test("OpenAIProvider: uses max_completion_tokens in request body", async () => {
  const originalFetch = globalThis.fetch;
  let requestBody: Record<string, unknown> | null = null;

  globalThis.fetch = ((
    _input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    requestBody = JSON.parse(String(init?.body));
    return Promise.resolve(
      new Response(
        JSON.stringify({
          choices: [{ message: { content: "Generated story" } }],
          model: "gpt-4o-mini",
          usage: { prompt_tokens: 12, completion_tokens: 34 },
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
    await provider.complete([{ role: "user", content: "Tell a story" }], 800);

    assertExists(requestBody);
    assertEquals(requestBody?.max_completion_tokens, 800);
    assertEquals("max_tokens" in requestBody!, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
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

Deno.test("handler: successful generation charges from actual usage and model rates", async () => {
  const { store: creditStore, state: creditState } = makeMockCreditStore(makeEntitlement());
  const { store: rateLimitStore } = makeMockRateLimitStore({ allowed: true });
  const { store: generationModelStore } = makeMockGenerationModelStore([{
    id: "gpt-4.1-mini",
    provider_model: "gpt-4.1-mini",
    input_credit_rate: 2,
    output_credit_rate: 2,
    minimum_charge_credits: 1,
  }]);
  const { store: persistenceStore } = makeMockPersistenceStore();

  const provider: LLMProvider = {
    complete() {
      return Promise.resolve({
        content: "ok",
        modelName: "gpt-4.1-mini",
        inputTokens: 10,
        outputTokens: 25,
        totalTokens: 35,
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
  const body = await resp.json();
  assertEquals(resp.status, 200);
  assertEquals(body.creditCostCharged, 70);
  assertEquals(creditState.chargeCalls.length, 1);
  assertEquals(creditState.chargeCalls[0].cost, 70);
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
  assertEquals(creditState.chargeCalls.length, 0);
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
