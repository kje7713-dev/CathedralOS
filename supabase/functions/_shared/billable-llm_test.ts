// =============================================================================
// _shared/billable-llm_test.ts
//
// Unit tests for the shared billable-LLM runner. Verifies the invariants
// called out in the PR #407 merge-blocking revision:
//   - Insufficient credits fail before the provider is called.
//   - Provider failure creates no 'complete' usage event and no customer
//     charge; a 'failed' usage event IS recorded by the runner.
//   - Successful call records the provider model and actual token counts.
//   - purpose and action reach the usage event unchanged.
//   - Successful newly-inserted usage event charges exactly once.
//   - Confirmed unique-violation on usage event INSERT does NOT charge again.
//   - Non-uniqueness DB error is NOT treated as duplicate — it propagates.
//   - Missing inserted row data with no error is treated as a failure.
//   - Credit charge exception throws credit_charge_failed (NOT a silent
//     charged:false return — that was the free-output escape hatch).
//   - onProviderSuccess callback exception propagates WITHOUT recording a
//     'complete' event (preserves generate-story's behavior).
//   - Cached tokens are NOT double-counted: uncached = total - cached.
//   - providerOptions are forwarded to provider.complete().
//   - Idempotency key is forwarded to the usage event INSERT row.
//   - recordFailedUsageEvent logs returned PostgREST errors without throwing.
// =============================================================================

import {
  assertEquals,
  assertExists,
  assertRejects,
  assertStrictEquals,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  type BillableLLMDependencies,
  BillableLLMError,
  type BillableLLMRequest,
  type FailedUsageEventInput,
  recordFailedUsageEvent,
  runBillableLLM,
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
  // PR-372: cache-write rate default = standard input × 1.25 (GPT-5.6+ contract).
  provider_cache_write_usd_per_1m: 0.1875,
  provider_output_usd_per_1m: 0.60,
  pricing_effective_at: "2026-01-01T00:00:00Z",
  // PR-372: default cache capability (automatic prefix matching with
  // prompt_cache_key). Override to "explicit" for supported models.
  cacheMode: "implicit",
};

/** Model with distinct cached vs uncached rates for exact-charge billing
 * tests. snapshotPricing() yields:
 *   inputCreditRatePer1k       = 50 * 2.0 / 10 = 10
 *   cachedInputCreditRatePer1k = 10 * 2.0 / 10 = 2
 *   outputCreditRatePer1k      = 100 * 2.0 / 10 = 20
 *   minimumChargeCredits        = 0
 */
const EXACT_BILLING_MODEL: GenerationModel = {
  ...TEST_MODEL,
  billing_multiplier: 2.0,
  provider_input_usd_per_1m: 50,
  provider_cached_input_usd_per_1m: 10,
  provider_output_usd_per_1m: 100,
  minimum_charge_credits: 0,
};

const USER_ID = "00000000-0000-0000-0000-000000000001";

function makeLLMResponse(overrides: Partial<LLMResponse> = {}): LLMResponse {
  return {
    content: '{"warnings":[]}',
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

type AnyResult = unknown;

interface MockAdminUsageEventRow {
  user_id: string;
  generation_output_id: string | null;
  action: string;
  purpose: string;
  model_name: string;
  input_tokens: number | null;
  output_tokens: number | null;
  generation_length_mode: string;
  output_budget: number | null;
  status: string;
  credit_revenue_usd: number | null;
  idempotency_key: string | null;
}

interface MockAdminCall {
  table: string;
  row: MockAdminUsageEventRow;
}

interface MockAdminClient {
  insertCalls: MockAdminCall[];
  resultsByCall: unknown[];
  from(table: string): {
    insert(row: unknown): unknown;
  };
}

function makeMockAdmin(opts: {
  insertResults?: unknown[];
} = {}): MockAdminClient {
  const insertCalls: MockAdminCall[] = [];
  const results = opts.insertResults ??
    [{ data: { id: "row-1" }, error: null }];
  let idx = 0;
  return {
    insertCalls,
    resultsByCall: results,
    from(table: string) {
      return {
        insert(row: unknown) {
          // The mock admin types insert as `unknown` to keep lint quiet;
          // narrow to the expected row shape so test assertions are typed.
          insertCalls.push({
            table,
            row: row as MockAdminUsageEventRow,
          });
          const result = results[idx] ?? results[results.length - 1];
          idx++;
          return {
            select: () => ({
              maybeSingle: () => Promise.resolve(result),
            }),
            then: (resolve: (v: unknown) => void) =>
              Promise.resolve(resolve(result)),
          };
        },
      };
    },
  };
}

function makeProvider(response: LLMResponse | Error): LLMProvider {
  return {
    complete: (
      _messages: LLMMessage[],
      _maxTokens: number,
      _model?: string,
      _options?: unknown,
    ) => {
      if (response instanceof Error) {
        return Promise.reject(response);
      }
      return Promise.resolve(response);
    },
  };
}

function makeCreditStore(opts: {
  availableCredits?: number;
  chargeShouldThrow?: boolean;
} = {}): CreditStore & { chargeCalls: number[] } {
  const availableCredits = opts.availableCredits ?? 100;
  const chargeCalls: number[] = [];
  return {
    chargeCalls,
    loadOrDefault: (_userId: string) =>
      Promise.resolve({
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
    charge: async (
      _userId: string,
      cost: number,
      _ent: unknown,
      _outputId: string | null,
    ) => {
      await Promise.resolve();
      if (opts.chargeShouldThrow) {
        throw new Error("simulated charge failure");
      }
      chargeCalls.push(cost);
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
  } as unknown as CreditStore & { chargeCalls: number[] };
}

function makeRequest(
  overrides: Partial<BillableLLMRequest<unknown>> = {},
): BillableLLMRequest<unknown> {
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
    onProviderSuccess: (_result) => Promise.resolve(null),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Billing & invariant tests
// ---------------------------------------------------------------------------

Deno.test("runBillableLLM: insufficient credits throws BEFORE the provider is called", async () => {
  const admin = makeMockAdmin();
  let providerCalls = 0;
  const provider: LLMProvider = {
    complete: () => {
      providerCalls++;
      return Promise.resolve(makeLLMResponse());
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
  assertEquals(providerCalls, 0);
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
    complete: (_msgs, _tokens, _model, options) => {
      capturedOptions = options;
      return Promise.resolve(makeLLMResponse());
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

Deno.test("runBillableLLM: providerOptions absent is preserved as undefined", async () => {
  let capturedOptions: unknown = "sentinel";
  const provider: LLMProvider = {
    complete: (_msgs, _tokens, _model, options) => {
      capturedOptions = options;
      return Promise.resolve(makeLLMResponse());
    },
  };
  const deps: BillableLLMDependencies = {
    adminClient: makeMockAdmin(),
    provider,
    creditStore: makeCreditStore(),
  };
  await runBillableLLM(makeRequest({ providerOptions: undefined }), deps);
  assertEquals(capturedOptions, undefined);
});

Deno.test("runBillableLLM: confirmed unique-violation does NOT charge again", async () => {
  const admin = makeMockAdmin({
    insertResults: [
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
  // creditStore.charge must NOT have been called — chargeCalls is empty.
  assertEquals(creditStore.chargeCalls.length, 0);
  assertEquals(admin.insertCalls.length, 1);
});

Deno.test("runBillableLLM: non-uniqueness DB error propagates as BillableLLMError (NOT silent duplicate)", async () => {
  const admin = makeMockAdmin({
    insertResults: [
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

Deno.test("runBillableLLM: missing inserted row data (no error) throws usage_event_insert_failed", async () => {
  // Supabase/PostgREST returned { data: null, error: null } — a contract
  // violation. The runner must NOT proceed to charging as if persistence
  // succeeded.
  const admin = makeMockAdmin({
    insertResults: [{ data: null, error: null }],
  });
  const creditStore = makeCreditStore();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore,
  };
  const err = await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    BillableLLMError,
  );
  assertEquals(err.code, "usage_event_insert_failed");
  assertEquals(creditStore.chargeCalls.length, 0);
  assertEquals(admin.insertCalls.length, 1);
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
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].row;
  assertEquals(row.status, "failed");
  assertEquals(row.purpose, "coherence-check");
  assertEquals(row.action, "check");
  assertEquals(row.idempotency_key, null);
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
      onProviderSuccess: (_r) => Promise.resolve(expectedResult),
    }),
    deps,
  );
  assertStrictEquals(result.featureResult, expectedResult);
});

Deno.test("runBillableLLM: onProviderSuccess throw propagates WITHOUT recording 'complete' usage event", async () => {
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
          onProviderSuccess: () =>
            Promise.reject(new Error("persistence failed")),
        }),
        deps,
      ),
    Error,
    "persistence failed",
  );
  assertEquals(admin.insertCalls.length, 0);
});

Deno.test("runBillableLLM: credit charge exception throws credit_charge_failed (NOT a silent free-output path)", async () => {
  const admin = makeMockAdmin();
  const creditStore = makeCreditStore({ chargeShouldThrow: true });
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(makeLLMResponse()),
    creditStore,
  };
  const err = await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    BillableLLMError,
  );
  assertEquals(err.code, "credit_charge_failed");
  // The usage event IS inserted (audit trail preserved), but the charge
  // failed — surface as a non-2xx response, NOT as a 200 + free output.
  assertEquals(admin.insertCalls.length, 1);
  assertEquals(creditStore.chargeCalls.length, 0);
});

Deno.test("runBillableLLM: cached tokens NOT double-counted — total=1500, cached=500 (PR-372: no customer cache discount)", async () => {
  // EXACT_BILLING_MODEL yields (after PR-372):
  //   inputCreditRatePer1k = 10  → ALL input tokens (uncached + cached +
  //                                 cacheWrite) charged at this normal
  //                                 rate. NO customer discount on cache
  //                                 hits — cache savings stay Cathedral's
  //                                 margin.
  //   outputCreditRatePer1k = 20
  //   minimumChargeCredits = 0
  // With total=1500, cached=500, cacheWrite=0, output=0:
  //   uncached = max(0, 1500 - 500 - 0) = 1000
  //   cached   = 500
  //   total input at normal rate = (1000 + 500 + 0) × 10 / 1000 = 15 credits
  //   output                   = 0
  //   total                    = 15 credits (was 11 with the pre-PR-372
  //                              cached-discount behavior)
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: 1500,
      cachedInputTokens: 500,
      outputTokens: 0,
    }),
  );
  const creditStore = makeCreditStore();
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore,
  };
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    deps,
  );
  assertEquals(result.actualCharge, 15);
  assertEquals(result.charged, true);
});

Deno.test("runBillableLLM: cached token count absent → uncached = total", async () => {
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: 1500,
      // cachedInputTokens undefined / omitted
      outputTokens: 0,
    }),
  );
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  };
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    deps,
  );
  // uncached = 1500, cached = 0 → 1500 * 10 / 1000 + 0 = 15 credits
  assertEquals(result.actualCharge, 15);
});

Deno.test("runBillableLLM: cached token count zero → uncached = total, cached = 0", async () => {
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: 1500,
      cachedInputTokens: 0,
      outputTokens: 0,
    }),
  );
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  };
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    deps,
  );
  assertEquals(result.actualCharge, 15);
});

Deno.test("runBillableLLM: cached > total is clamped safely (no negative uncached)", async () => {
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: 1000,
      cachedInputTokens: 5000, // pathological: provider says more cached than total
      outputTokens: 0,
    }),
  );
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  };
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    deps,
  );
  // clamped: uncached = max(0, 1000 - 5000 - 0) = 0; cached = min(1000, 5000) = 1000.
  // PR-372: NO customer cache discount. All input (uncached + cached) at
  // normal rate. charge = (0 + 1000) * 10 / 1000 = 10 credits
  // (was 2 with the pre-PR-372 cached-discount behavior).
  assertEquals(result.actualCharge, 10);
});

Deno.test("runBillableLLM: negative provider token values cannot produce negative billable usage", async () => {
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: -100 as unknown as number,
      cachedInputTokens: -50 as unknown as number,
      outputTokens: -25 as unknown as number,
    }),
  );
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  };
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    deps,
  );
  // Math.max(0, -100) = 0 total; Math.max(0, min(0, -50)) = 0 cached
  // → uncached = 0 - 0 = 0, cached = 0, output = 0 → charge = 0
  assertEquals(result.actualCharge, 0);
});

// ---------------------------------------------------------------------------
// recordFailedUsageEvent
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

Deno.test("recordFailedUsageEvent: returned PostgREST error is logged + does NOT throw over original error", async () => {
  const logs: string[] = [];
  const originalConsoleError = console.error;
  console.error = (msg: string) => logs.push(msg);
  try {
    const admin = makeMockAdmin({
      insertResults: [
        { data: null, error: { code: "42P01", message: "undefined_table" } },
      ],
    });
    await recordFailedUsageEvent(admin, {
      userID: USER_ID,
      purpose: "generate",
      action: "generate",
      modelName: "gpt-4o-mini",
    });
  } finally {
    console.error = originalConsoleError;
  }
  // The PostgREST error was logged.
  assertEquals(logs.length >= 1, true);
  assertStringIncludes(logs[0], "[billable-llm] failed-usage insert failed");
});

Deno.test("recordFailedUsageEvent: swallow thrown errors (audit must not crash caller)", async () => {
  const broken: { from: () => unknown } = {
    from: () => {
      throw new Error("db unreachable");
    },
  };
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function assertStringIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(
      `Expected string to include ${JSON.stringify(expected)} but got ${
        JSON.stringify(actual)
      }`,
    );
  }
}
