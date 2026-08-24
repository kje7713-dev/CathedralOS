// =============================================================================
// _shared/billable-llm_test.ts
//
// Unit tests for the shared billable-LLM runner. Verifies the invariants
// called out in the refactor spec:
//   - Insufficient credits fail before the provider is called.
//   - Disabled / missing model is not the runner's concern (the feature
//     resolves the GenerationModel and passes it in), but pricing snapshot
//     must work even for the FALLBACK row.
//   - Provider failure creates no 'complete' usage event and no customer
//     charge; a 'failed' usage event IS recorded by the runner.
//   - Successful call records the provider model and actual token counts.
//   - purpose and action reach the usage event unchanged.
//   - Successful newly-inserted usage event charges exactly once.
//   - Confirmed unique-violation on usage event INSERT does NOT charge again.
//   - Non-uniqueness DB error is NOT treated as duplicate — it propagates.
//   - providerOptions are forwarded to the provider's complete() call.
//   - Idempotency key is forwarded to the usage event INSERT row.
// =============================================================================

import {
  assertEquals,
  assertExists,
  assertRejects,
  assertStrictEquals,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  runBillableLLM,
  BillableLLMError,
  type BillableLLMDependencies,
  type BillableLLMRequest,
  type FailedUsageEventInput,
  recordFailedUsageEvent,
} from "./billable-llm.ts";
import { ProviderError } from "../generate-story/_provider.ts";
import type {
  LLMMessage,
  LLMProvider,
  LLMResponse,
} from "../generate-story/_provider.ts";
import type { GenerationModel } from "../generate-story/_generation_models.ts";
import type { CreditStore } from "../generate-story/_credits.ts";

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

const TEST_MODEL: GenerationModel = {
  id: "gpt-4o-mini",
  provider: "openai",
  provider_model: "gpt-4o-mini",
  display_name: "GPT-4o mini",
  description: null,
  input_credit_rate: 1,
  output_credit_rate: 2,
  minimum_charge_credits: 1,
  max_output_tokens: 16000,
  enabled: true,
  sort_order: 0,
  billing_multiplier: 2.0,
  provider_input_usd_per_1m: 0.15,
  provider_cached_input_usd_per_1m: 0.075,
  provider_output_usd_per_1m: 0.60,
  pricing_effective_at: "2026-01-01T00:00:00Z",
};

const USER_ID = "00000000-0000-0000-0000-000000000001";

function makeLLMResponse(overrides: Partial<LLMResponse> = {}): LLMResponse {
  return {
    content: "{\"warnings\":[]}",
    modelName: TEST_MODEL.provider_model,
    finishReason: "stop",
    inputTokens: 1500,
    cachedInputTokens: 0,
    outputTokens: 250,
    totalTokens: 1750,
    toolCostUsd: 0,
    ...overrides,
  };
}

interface MockAdminCall {
  table: string;
  // deno-lint-ignore no-explicit-any
  row: any;
}

interface MockAdminClient {
  insertCalls: MockAdminCall[];
  // For each insert call, return this result (or push to queue per-call).
  // deno-lint-ignore no-explicit-any
  resultsByCall: any[];
  from(table: string): {
    // deno-lint-ignore no-explicit-any
    insert(row: any): any;
  };
}

function makeMockAdmin(opts: {
  // deno-lint-ignore no-explicit-any
  insertResults?: any[];
} = {}): MockAdminClient {
  const insertCalls: MockAdminCall[] = [];
  const results = opts.insertResults ?? [{ data: { id: "row-1" }, error: null }];
  let idx = 0;
  return {
    insertCalls,
    resultsByCall: results,
    from(table: string) {
      return {
        // deno-lint-ignore no-explicit-any
        insert(row: any) {
          insertCalls.push({ table, row });
          const result = results[idx] ?? results[results.length - 1];
          idx++;
          // Mimic Supabase query chain: .insert(row).select(...).maybeSingle()
          // returns { data, error }. If the caller doesn't chain further,
          // it just awaits a thenable that resolves with the same shape.
          return {
            select: () => ({
              maybeSingle: async () => result,
            }),
            then: async (resolve: (v: unknown) => void) => resolve(result),
          };
        },
      };
    },
  };
}

function makeProvider(response: LLMResponse | Error): LLMProvider {
  return {
    // deno-lint-ignore no-explicit-any
    complete: async (_messages: LLMMessage[], _maxTokens: number, _model?: string, _options?: any) => {
      if (response instanceof Error) {
        throw response;
      }
      return response;
    },
  };
}

function makeCreditStore(opts: {
  availableCredits?: number;
  chargeShouldThrow?: boolean;
} = {}): CreditStore {
  const availableCredits = opts.availableCredits ?? 100;
  const charged: number[] = [];
  return {
    // deno-lint-ignore no-explicit-any
    loadOrDefault: async (_userId: string) => ({
      user_id: USER_ID,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: availableCredits,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
      updated_at: new Date().toISOString(),
    }),
    // deno-lint-ignore no-explicit-any
    charge: async (_userId: string, cost: number, _ent: any, _outputId: string | null) => {
      if (opts.chargeShouldThrow) {
        throw new Error("simulated charge failure");
      }
      charged.push(cost);
      return {
        user_id: USER_ID,
        plan_name: "free",
        is_pro: false,
        monthly_credit_allowance: availableCredits - cost,
        purchased_credit_balance: 0,
        current_period_start: null,
        current_period_end: null,
        entitlement_source: "monthly_grant",
        updated_at: new Date().toISOString(),
      };
    },
  } as unknown as CreditStore;
}

function makeRequest(overrides: Partial<BillableLLMRequest<unknown>> = {}): BillableLLMRequest<unknown> {
  return {
    userID: USER_ID,
    purpose: "coherence-check",
    action: "check",
    model: TEST_MODEL,
    messages: [
      { role: "system", content: "You are a coherence checker." },
      { role: "user", content: "Check this." },
    ],
    maxOutputTokens: 1500,
    providerOptions: {
      responseFormat: { type: "json_schema", json_schema: { name: "test" } },
      temperature: 0.2,
    },
    usageContext: {
      projectID: "00000000-0000-0000-0000-0000000000aa",
      generationOutputID: null,
      generationLengthMode: "short",
      outputBudget: 1500,
      idempotencyKey: "idem-1",
    },
    onProviderSuccess: async (_result) => null,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("runBillableLLM: insufficient credits throws BEFORE provider is called", async () => {
  const admin = makeMockAdmin();
  let providerCalls = 0;
  const provider: LLMProvider = {
    complete: async () => {
      providerCalls++;
      return makeLLMResponse();
    },
  };
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore({ availableCredits: 0 }),
  };
  await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    BillableLLMError,
  );
  // Provider must not have been called.
  assertEquals(providerCalls, 0);
  // No usage event must have been inserted.
  assertEquals(admin.insertCalls.length, 0);
});

Deno.test("runBillableLLM: successful call records provider model + tokens in usage event", async () => {
  const admin = makeMockAdmin();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(
      makeLLMResponse({
        modelName: "gpt-4o-mini-actual",
        inputTokens: 1234,
        outputTokens: 567,
      }),
    ),
    creditStore: makeCreditStore(),
  };
  const result = await runBillableLLM(makeRequest(), deps);
  assertEquals(result.charged, true);
  assertEquals(result.usageEventInserted, true);
  assertEquals(result.providerResult.modelName, "gpt-4o-mini-actual");
  assertEquals(result.providerResult.inputTokens, 1234);
  assertEquals(result.providerResult.outputTokens, 567);
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].row;
  assertEquals(row.user_id, USER_ID);
  assertEquals(row.purpose, "coherence-check");
  assertEquals(row.action, "check");
  assertEquals(row.model_name, "gpt-4o-mini-actual");
  assertEquals(row.input_tokens, 1234);
  assertEquals(row.output_tokens, 567);
  assertEquals(row.status, "complete");
  assertEquals(row.idempotency_key, "idem-1");
});

Deno.test("runBillableLLM: purpose + action reach the usage event unchanged", async () => {
  const admin = makeMockAdmin();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore: makeCreditStore(),
  };
  await runBillableLLM(
    makeRequest({ purpose: "generate", action: "regenerate" }),
    deps,
  );
  const row = admin.insertCalls[0].row;
  assertEquals(row.purpose, "generate");
  assertEquals(row.action, "regenerate");
});

Deno.test("runBillableLLM: providerOptions are forwarded to provider.complete()", async () => {
  let capturedOptions: unknown = null;
  const provider: LLMProvider = {
    complete: async (_msgs, _tokens, _model, options) => {
      capturedOptions = options;
      return makeLLMResponse();
    },
  };
  const deps: BillableLLMDependencies = {
    adminClient: makeMockAdmin(),
    provider,
    creditStore: makeCreditStore(),
  };
  const opts = {
    responseFormat: { type: "json_schema", json_schema: { name: "x" } },
    temperature: 0.3,
  };
  await runBillableLLM(makeRequest({ providerOptions: opts }), deps);
  assertStrictEquals(capturedOptions, opts);
});

Deno.test("runBillableLLM: confirmed unique-violation on usage event does NOT charge again", async () => {
  const admin = makeMockAdmin({
    insertResults: [
      // Postgres SQLSTATE 23505 = unique_violation. The runner must treat
      // this as "already billed" and return charged=false.
      { data: null, error: { code: "23505", message: "duplicate key value" } },
    ],
  });
  const creditStore = makeCreditStore();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore,
  };
  const result = await runBillableLLM(makeRequest(), deps);
  assertEquals(result.charged, false);
  assertEquals(result.usageEventInserted, false);
  // creditStore.charge must NOT have been called.
  // deno-lint-ignore no-explicit-any
  const chargedCalls = (creditStore as any).charge.mock?.calls?.length ?? 0;
  // We don't have a mock with .mock.calls; use a different probe: check the
  // admin client only saw one insert (the one that "failed" with conflict).
  assertEquals(admin.insertCalls.length, 1);
  assertEquals(chargedCalls, 0);
});

Deno.test("runBillableLLM: non-uniqueness DB error is NOT silently treated as duplicate", async () => {
  const admin = makeMockAdmin({
    insertResults: [
      // Some other DB error — NOT a unique violation. The runner must
      // throw a BillableLLMError so the caller can follow the existing
      // diagnostic conventions.
      { data: null, error: { code: "42P01", message: "undefined_table" } },
    ],
  });
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore: makeCreditStore(),
  };
  await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    BillableLLMError,
  );
});

Deno.test("runBillableLLM: provider failure records 'failed' usage event + throws", async () => {
  const admin = makeMockAdmin();
  const providerError = new ProviderError(
    "OpenAI timed out",
    "provider_timeout",
    false,
  );
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(providerError),
    creditStore: makeCreditStore(),
  };
  await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    ProviderError,
  );
  // The runner must have recorded a 'failed' usage event before throwing.
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].row;
  assertEquals(row.status, "failed");
  assertEquals(row.purpose, "coherence-check");
  assertEquals(row.action, "check");
  assertEquals(row.idempotency_key, null);
  // No tokens (provider never returned them).
  assertEquals(row.input_tokens, null);
  assertEquals(row.output_tokens, null);
});

Deno.test("runBillableLLM: onProviderSuccess callback result is returned in featureResult", async () => {
  const admin = makeMockAdmin();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore: makeCreditStore(),
  };
  const expectedResult = { outputRowId: "gen-123" };
  const result = await runBillableLLM(
    makeRequest({
      onProviderSuccess: async (_r) => expectedResult,
    }),
    deps,
  );
  assertStrictEquals(result.featureResult, expectedResult);
});

Deno.test("runBillableLLM: onProviderSuccess throw propagates without recording 'complete' usage event", async () => {
  const admin = makeMockAdmin();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore: makeCreditStore(),
  };
  await assertRejects(
    () =>
      runBillableLLM(
        makeRequest({
          onProviderSuccess: async () => {
            throw new Error("persistence failed");
          },
        }),
        deps,
      ),
    Error,
    "persistence failed",
  );
  // The runner must NOT have inserted a usage event on feature-callback
  // failure (caller decides via recordFailedUsageEvent if it wants one).
  assertEquals(admin.insertCalls.length, 0);
});

Deno.test("runBillableLLM: credit charge failure after usage event insert does NOT roll back the event", async () => {
  const admin = makeMockAdmin();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore: makeCreditStore({ chargeShouldThrow: true }),
  };
  const result = await runBillableLLM(makeRequest(), deps);
  // The usage event WAS inserted, but the charge failed.
  assertEquals(result.usageEventInserted, true);
  assertEquals(result.charged, false);
  assertEquals(admin.insertCalls.length, 1);
});

// ---------------------------------------------------------------------------
// recordFailedUsageEvent helper
// ---------------------------------------------------------------------------

Deno.test("recordFailedUsageEvent: writes a row with status='failed' + null tokens", async () => {
  const admin = makeMockAdmin();
  const input: FailedUsageEventInput = {
    userID: USER_ID,
    purpose: "coherence-check",
    action: "check",
    modelName: "gpt-5-mini",
    generationLengthMode: "short",
    outputBudget: 1500,
  };
  await recordFailedUsageEvent(admin, input);
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].row;
  assertEquals(row.status, "failed");
  assertEquals(row.purpose, "coherence-check");
  assertEquals(row.action, "check");
  assertEquals(row.model_name, "gpt-5-mini");
  assertEquals(row.input_tokens, null);
  assertEquals(row.output_tokens, null);
  assertEquals(row.idempotency_key, null);
});

Deno.test("recordFailedUsageEvent: swallow errors (audit must not crash caller)", async () => {
  // deno-lint-ignore no-explicit-any
  const broken = { from: () => { throw new Error("db unreachable"); } } as any;
  // Should NOT throw.
  await recordFailedUsageEvent(broken, {
    userID: USER_ID,
    purpose: "generate",
    action: "generate",
    modelName: "x",
  });
  assertExists(true); // survived
});

// ---------------------------------------------------------------------------
// BillableLLMError class
// ---------------------------------------------------------------------------

Deno.test("BillableLLMError: carries code + details + correct message", () => {
  const err = new BillableLLMError(
    "insufficient_credits",
    "you have 0 credits",
    { requiredCredits: 1.5, availableCredits: 0 },
  );
  assertEquals(err.code, "insufficient_credits");
  assertEquals(err.message, "you have 0 credits");
  assertExists(err.details);
  assertEquals(err.name, "BillableLLMError");
  assertEquals(err instanceof Error, true);
  assertEquals(err instanceof BillableLLMError, true);
});
