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
import {
  ProviderBillingUnavailableError,
  ProviderError,
} from "../generate-story/_provider.ts";
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
 *   inputCreditRatePer1k       = (50 / 1000) * 2.0 / 0.05 = 2
 *   cachedInputCreditRatePer1k = (10 / 1000) * 2.0 / 0.05 = 0.4
 *   outputCreditRatePer1k      = (100 / 1000) * 2.0 / 0.05 = 4
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

interface MockRpcCall {
  name: string;
  params: Record<string, unknown>;
}

interface MockAdminClient {
  rpcCalls: MockRpcCall[];
  insertCalls: MockRpcCall[];
  rpc(name: string, params: Record<string, unknown>): Promise<{
    data: unknown[] | null;
    error: { message?: string } | null;
  }>;
  from(table: string): {
    insert(row: unknown): Promise<unknown>;
  };
}

function makeMockAdmin(opts: {
  rpcResults?: unknown[];
  insertResults?: unknown[];
} = {}): MockAdminClient {
  const rpcCalls: MockRpcCall[] = [];
  const insertCalls: MockRpcCall[] = [];
  const rpcSeq = opts.rpcResults ?? [
    {
      data: [{
        settlement_status: "settled",
        usage_event_id: "row-1",
        ledger_id: "ledger-1",
        remaining_credits: 95,
      }],
      error: null,
    },
  ];
  const insertSeq = opts.insertResults ?? [{ data: null, error: null }];
  let rpcIdx = 0;
  let insertIdx = 0;
  return {
    rpcCalls,
    insertCalls,
    rpc(name: string, params: Record<string, unknown>) {
      rpcCalls.push({ name, params });
      const result = rpcSeq[rpcIdx] ?? rpcSeq[rpcSeq.length - 1];
      rpcIdx++;
      return Promise.resolve(
        result as {
          data: unknown[] | null;
          error: { message?: string } | null;
        },
      );
    },
    // recordFailedUsageEvent still uses the postgrest .from().insert()
    // shape; tests that exercise it call admin.rpcCalls to count both paths.
    from(_table: string) {
      return {
        insert(row: unknown) {
          insertCalls.push({
            name: "insert",
            params: row as Record<string, unknown>,
          });
          const result = insertSeq[insertIdx] ??
            insertSeq[insertSeq.length - 1];
          insertIdx++;
          return Promise.resolve(result);
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
  assertEquals(admin.rpcCalls.length, 0);
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
  assertEquals(admin.rpcCalls.length, 1);
  const params = admin.rpcCalls[0].params;
  assertEquals(params.p_user_id, USER_ID);
  assertEquals(params.p_purpose, "coherence-check");
  assertEquals(params.p_action, "check");
  assertEquals(params.p_model_name, "gpt-4o-mini-actual");
  assertEquals(params.p_input_tokens, 1234);
  assertEquals(params.p_output_tokens, 567);
  assertEquals(params.p_idempotency_key, "idem-1");
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
  const params = admin.rpcCalls[0].params;
  assertEquals(params.p_purpose, "generate");
  assertEquals(params.p_action, "regenerate");
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

Deno.test("runBillableLLM: RPC 'duplicate' status does NOT charge again (idempotent replay)", async () => {
  // PR5: idempotency moves into settle_billable_usage. The RPC returns
  // settlement_status='duplicate' for replays; the runner reports
  // charged=false / usageEventInserted=false without raising.
  const admin = makeMockAdmin({
    rpcResults: [
      {
        data: [{
          settlement_status: "duplicate",
          usage_event_id: "row-existing",
          ledger_id: null,
          remaining_credits: 95,
        }],
        error: null,
      },
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
  // creditStore.charge is no longer called from this path.
  assertEquals(creditStore.chargeCalls.length, 0);
  assertEquals(admin.rpcCalls.length, 1);
  assertEquals(admin.rpcCalls[0].name, "settle_billable_usage");
});

Deno.test("runBillableLLM: non-uniqueness DB error propagates as BillableLLMError (NOT silent duplicate)", async () => {
  const admin = makeMockAdmin({
    rpcResults: [
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
    rpcResults: [{ data: null, error: null }],
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
  assertEquals(admin.rpcCalls.length, 1);
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
  // PR5: provider failure writes a failed-status audit row via
  // recordFailedUsageEvent's .from().insert() path; the main settle RPC
  // is never reached.
  assertEquals(admin.rpcCalls.length, 0);
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].params;
  assertEquals(row.status, "failed");
  assertEquals(row.purpose, "coherence-check");
  assertEquals(row.action, "check");
  assertEquals(row.idempotency_key, null);
  assertEquals(row.input_tokens, null);
  assertEquals(row.output_tokens, null);
});

Deno.test("runBillableLLM: provider_billing_unavailable skips customer charge and failed usage event", async () => {
  const admin = makeMockAdmin();
  const creditStore = makeCreditStore();
  const providerError = new ProviderBillingUnavailableError({
    code: "organization_spend_limit_exceeded",
    message: "organization spend limit",
    status: 429,
  });
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider: makeProvider(providerError),
    creditStore,
  };

  await assertRejects(
    () => runBillableLLM(makeRequest(), deps),
    ProviderBillingUnavailableError,
  );
  assertEquals(creditStore.chargeCalls.length, 0);
  assertEquals(admin.rpcCalls.length, 0);
  assertEquals(admin.insertCalls.length, 0);
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
  assertEquals(admin.rpcCalls.length, 0);
});

Deno.test("runBillableLLM: RPC failure throws credit_charge_failed (atomicity preserved)", async () => {
  // PR5: when settle_billable_usage returns an error, the runner maps
  // non-idempotency failures to credit_charge_failed. The RPC owns the
  // usage_event INSERT + entitlement debit + ledger INSERT inside one
  // transaction, so no audit row is ever left behind when it fails.
  const admin = makeMockAdmin({
    rpcResults: [
      { data: null, error: { message: "connection terminated unexpectedly" } },
    ],
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
  assertEquals(err.code, "credit_charge_failed");
  assertEquals(admin.rpcCalls.length, 1);
  assertEquals(creditStore.chargeCalls.length, 0);
});

Deno.test("runBillableLLM: fractional customer charge survives settlement payload", async () => {
  const admin = makeMockAdmin();
  const provider = makeProvider(
    makeLLMResponse({
      inputTokens: 123,
      cachedInputTokens: 0,
      outputTokens: 17,
    }),
  );
  const result = await runBillableLLM(
    makeRequest({ model: EXACT_BILLING_MODEL }),
    {
      adminClient: admin,
      provider,
      creditStore: makeCreditStore(),
    },
  );
  assertEquals(result.actualCharge, 0.314);
  const settlement = admin.rpcCalls.find((call) =>
    call.name === "settle_billable_usage"
  );
  assertExists(settlement);
  assertEquals(settlement.params.p_charge_credits, 0.314);
});

Deno.test("runBillableLLM: cached tokens NOT double-counted — total=1500, cached=500 (PR-372: no customer cache discount)", async () => {
  // EXACT_BILLING_MODEL yields (after PR-372):
  //   inputCreditRatePer1k = 2  → ALL input tokens (uncached + cached +
  //                                 cacheWrite) charged at this normal
  //                                 rate. NO customer discount on cache
  //                                 hits — cache savings stay Cathedral's
  //                                 margin.
  //   outputCreditRatePer1k = 4
  //   minimumChargeCredits = 0
  // With total=1500, cached=500, cacheWrite=0, output=0:
  //   uncached = max(0, 1500 - 500 - 0) = 1000
  //   cached   = 500
  //   total input at normal rate = (1000 + 500 + 0) × 2 / 1000 = 3 credits
  //   output                   = 0
  //   total                    = 3 credits (was 11 with the pre-PR-372
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
  assertEquals(result.actualCharge, 3);
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
  // uncached = 1500, cached = 0 → 1500 * 2 / 1000 + 0 = 3 credits
  assertEquals(result.actualCharge, 3);
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
  assertEquals(result.actualCharge, 3);
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
  // normal rate. charge = (0 + 1000) * 2 / 1000 = 2 credits
  // (was 2 with the pre-PR-372 cached-discount behavior).
  assertEquals(result.actualCharge, 2);
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
  // PR5: recordFailedUsageEvent still uses the postgrest .from().insert()
  // path; the main settle RPC is not invoked on failure.
  assertEquals(admin.rpcCalls.length, 0);
  assertEquals(admin.insertCalls.length, 1);
  const row = admin.insertCalls[0].params;
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

Deno.test("outline provider attempt allocation failure prevents provider dispatch", async () => {
  let providerCalls = 0;
  const admin = {
    rpc: (name: string) =>
      name === "get_outline_stage_totals"
        ? Promise.resolve({
          data: [{ raw_charge_credits: 0, settled_charge_credits: 0 }],
          error: null,
        })
        : Promise.resolve({
          data: null,
          error: { message: "allocator unavailable" },
        }),
    from: (_table: string) => ({
      insert: (_row: unknown) => Promise.resolve({ data: null, error: null }),
    }),
  };
  const request = makeRequest({
    purpose: "outline-suggestion",
    action: "outline-suggestions-1",
    usageContext: {
      ...makeRequest().usageContext,
      featureRunID: "00000000-0000-0000-0000-0000000000bb",
      logicalStageKey: "run:stage",
    },
  });
  const provider = makeProvider(makeLLMResponse());
  const wrapped = {
    ...provider,
    complete: (...args: Parameters<typeof provider.complete>) => {
      providerCalls++;
      return provider.complete(...args);
    },
  };
  await assertRejects(
    () =>
      runBillableLLM(request, {
        adminClient: admin,
        provider: wrapped,
        creditStore: makeCreditStore(),
      }),
    BillableLLMError,
    "allocator unavailable",
  );
  assertEquals(providerCalls, 0);
});

Deno.test("non-outline replay creates one fresh provider-attempt row per dispatch while settlement stays idempotent", async () => {
  const attempts: Array<Record<string, unknown>> = [];
  const settlementCalls: Record<string, unknown>[] = [];
  let ledgerDebits = 0;
  let nextID = 1;
  const admin = {
    from: (table: string) => {
      if (table !== "generation_provider_attempts") {
        return {
          insert: (_row: unknown) =>
            Promise.resolve({ data: null, error: null }),
        };
      }
      return {
        select: (_columns: string) => ({}),
        insert: (row: Record<string, unknown>) => {
          const id = `attempt-${nextID++}`;
          attempts.push({ ...row, id });
          return {
            select: (_columns: string) => ({
              single: () => Promise.resolve({ data: { id }, error: null }),
            }),
          };
        },
        update: (patch: Record<string, unknown>) => ({
          eq: (_column: string, id: string) => {
            const row = attempts.find((candidate) => candidate.id === id);
            if (row) Object.assign(row, patch);
            return Promise.resolve({ data: null, error: null });
          },
        }),
      };
    },
    rpc: (name: string, params: Record<string, unknown>) => {
      if (name !== "settle_billable_usage") {
        throw new Error(`unexpected RPC ${name}`);
      }
      settlementCalls.push(params);
      const duplicate = settlementCalls.length > 1;
      if (!duplicate) ledgerDebits++;
      return Promise.resolve({
        data: [{
          settlement_status: duplicate ? "duplicate" : "settled",
          usage_event_id: duplicate ? "usage-1" : "usage-2",
          ledger_id: duplicate ? null : "ledger-1",
          remaining_credits: duplicate ? 98 : 97,
        }],
        error: null,
      });
    },
  };
  let providerCalls = 0;
  const provider: LLMProvider = {
    complete: () => {
      providerCalls++;
      return Promise.resolve(makeLLMResponse({
        inputTokens: providerCalls === 1 ? 111 : 222,
        outputTokens: providerCalls === 1 ? 11 : 22,
      }));
    },
  };
  const deps: BillableLLMDependencies = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  };

  const replayRequest = makeRequest({
    usageContext: {
      ...makeRequest().usageContext,
      providerAttemptKey: "explicit-attempt",
    },
  });
  await runBillableLLM(replayRequest, deps);
  await runBillableLLM(replayRequest, deps);

  assertEquals(providerCalls, 2);
  assertEquals(attempts.length, 2);
  assertEquals(new Set(attempts.map((row) => row.attempt_key)).size, 2);
  assertEquals(
    String(attempts[0].attempt_key).startsWith("explicit-attempt:dispatch:"),
    true,
  );
  assertEquals(
    String(attempts[1].attempt_key).startsWith("explicit-attempt:dispatch:"),
    true,
  );
  assertEquals(attempts[0].billing_idempotency_key, "idem-1");
  assertEquals(attempts[1].billing_idempotency_key, "idem-1");
  assertEquals(attempts[0].input_tokens, 111);
  assertEquals(attempts[1].input_tokens, 222);
  assertEquals(attempts[0].output_tokens, 11);
  assertEquals(attempts[1].output_tokens, 22);
  assertEquals(attempts[0].ledger_id, "ledger-1");
  assertEquals(attempts[1].ledger_id, undefined);
  assertEquals(ledgerDebits, 1);
  assertEquals(settlementCalls[0].p_idempotency_key, "idem-1");
  assertEquals(settlementCalls[1].p_idempotency_key, "idem-1");
});

Deno.test("outline retry allocates a distinct ordinal and key for each physical dispatch", async () => {
  const allocations: Record<string, unknown>[] = [];
  const settlements: Record<string, unknown>[] = [];
  const allocatedAttempts: Array<{ key: string; ordinal: number }> = [];
  let allocationOrdinal = 0;
  let providerCalls = 0;
  const admin = {
    rpc: (name: string, params: Record<string, unknown>) => {
      if (name === "get_outline_stage_totals") {
        return Promise.resolve({
          data: [{ raw_charge_credits: 0, settled_charge_credits: 0 }],
          error: null,
        });
      }
      if (name === "begin_outline_provider_attempt") {
        allocationOrdinal++;
        allocations.push(params);
        const attempt = {
          key: `stage:attempt:${allocationOrdinal}`,
          ordinal: allocationOrdinal,
        };
        allocatedAttempts.push(attempt);
        return Promise.resolve({
          data: [{
            attempt_id: `outline-attempt-${allocationOrdinal}`,
            attempt_key: attempt.key,
            attempt_ordinal: attempt.ordinal,
          }],
          error: null,
        });
      }
      if (name === "settle_outline_provider_attempt") {
        settlements.push(params);
        return Promise.resolve({
          data: [{
            settlement_status: "settled",
            usage_event_id: `outline-usage-${allocationOrdinal}`,
            ledger_id: `outline-ledger-${allocationOrdinal}`,
            remaining_credits: 100,
          }],
          error: null,
        });
      }
      if (name === "reconcile_outline_provider_attempts") {
        return Promise.resolve({ data: null, error: null });
      }
      throw new Error(`unexpected RPC ${name}`);
    },
    from: (_table: string) => ({
      update: (_patch: unknown) => ({
        eq: (_column: string, _value: unknown) =>
          Promise.resolve({ data: null, error: null }),
      }),
    }),
  };
  const provider: LLMProvider = {
    complete: () => {
      providerCalls++;
      return Promise.resolve(makeLLMResponse());
    },
  };
  const request = makeRequest({
    purpose: "outline-suggestion",
    action: "outline-suggestions-1",
    usageContext: {
      ...makeRequest().usageContext,
      featureRunID: "00000000-0000-0000-0000-0000000000bb",
      logicalStageKey: "stage",
    },
  });

  await runBillableLLM(request, {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  });
  await runBillableLLM(request, {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore(),
  });

  assertEquals(providerCalls, 2);
  assertEquals(allocations.length, 2);
  assertEquals(allocatedAttempts.map((attempt) => attempt.key), [
    "stage:attempt:1",
    "stage:attempt:2",
  ]);
  assertEquals(allocatedAttempts.map((attempt) => attempt.ordinal), [1, 2]);
  assertEquals(allocations[0].p_logical_stage_key, "stage");
  assertEquals(allocations[1].p_logical_stage_key, "stage");
  assertEquals(settlements.length, 2);
  assertEquals("p_idempotency_key" in settlements[0], false);
  assertEquals(settlements[0].p_attempt_key, "stage:attempt:1");
});

Deno.test("outline preflight charges only incremental actual-usage liability without a floor", async () => {
  const cases = [
    {
      name: "A",
      priorRaw: 1,
      priorSettled: 3,
      available: 0.5,
      allowed: true,
      expected: 0,
      inputTokens: 500,
    },
    {
      name: "B",
      priorRaw: 1,
      priorSettled: 3,
      available: 1,
      allowed: true,
      expected: 0,
      inputTokens: 3000,
    },
    {
      name: "C",
      priorRaw: 0,
      priorSettled: 0,
      available: 0.1,
      allowed: false,
      expected: 0.2,
      inputTokens: 1000,
    },
  ];
  for (const testCase of cases) {
    let providerCalls = 0;
    const rpcCalls: MockRpcCall[] = [];
    const admin = {
      rpc: (name: string, params: Record<string, unknown>) => {
        rpcCalls.push({ name, params });
        if (name === "get_outline_stage_totals") {
          return Promise.resolve({
            data: [{
              raw_charge_credits: testCase.priorRaw,
              settled_charge_credits: testCase.priorSettled,
            }],
            error: null,
          });
        }
        if (name === "begin_outline_provider_attempt") {
          return Promise.resolve({
            data: [{
              attempt_id: "a",
              attempt_key: "stage:attempt:1",
              attempt_ordinal: 1,
            }],
            error: null,
          });
        }
        if (name === "settle_outline_provider_attempt") {
          return Promise.resolve({
            data: [{
              settlement_status: "settled",
              usage_event_id: "u",
              ledger_id: "l",
              remaining_credits: 0,
            }],
            error: null,
          });
        }
        if (name === "reconcile_outline_provider_attempts") {
          return Promise.resolve({ data: null, error: null });
        }
        throw new Error(`unexpected RPC ${name}`);
      },
      from: (_table: string) => ({
        update: (_patch: unknown) => ({
          eq: (_column: string, _value: unknown) =>
            Promise.resolve({ data: null, error: null }),
        }),
      }),
    };
    const request = makeRequest({
      model: {
        ...TEST_MODEL,
        minimum_charge_credits: 3,
        provider_input_usd_per_1m: 5,
        provider_cached_input_usd_per_1m: 5,
        provider_cache_write_usd_per_1m: 6.25,
        provider_output_usd_per_1m: 0,
      },
      purpose: "outline-suggestion",
      action: `outline-suggestions-${testCase.name}`,
      maxOutputTokens: 0,
      preflightUsageOverride: {
        uncachedInputTokens: testCase.inputTokens,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 0,
        toolCostUsd: 0,
      },
      usageContext: {
        ...makeRequest().usageContext,
        featureRunID: "00000000-0000-0000-0000-0000000000bb",
        logicalStageKey: `run:${testCase.name}`,
      },
    });
    const provider: LLMProvider = {
      complete: () => {
        providerCalls++;
        return Promise.resolve(
          makeLLMResponse({ inputTokens: 0, outputTokens: 0 }),
        );
      },
    };
    if (testCase.allowed) {
      await runBillableLLM(request, {
        adminClient: admin,
        provider,
        creditStore: makeCreditStore({ availableCredits: testCase.available }),
      });
      assertEquals(providerCalls, 1);
    } else {
      const error = await assertRejects(
        () =>
          runBillableLLM(request, {
            adminClient: admin,
            provider,
            creditStore: makeCreditStore({
              availableCredits: testCase.available,
            }),
          }),
        BillableLLMError,
      );
      assertEquals(
        ((error as BillableLLMError).details as Record<string, unknown>)
          ?.requiredCredits,
        testCase.expected,
      );
      assertEquals(providerCalls, 0);
    }
    assertEquals(rpcCalls[0].name, "get_outline_stage_totals");
  }
});

Deno.test("packet families apply one minimum across routing, coverage repair, and enrichment", async () => {
  const families = [
    {
      family: "routing",
      actions: ["outline-route-batch-001", "outline-route-batch-002"],
    },
    {
      family: "coverage-repair",
      actions: [
        "outline-obligation-repair-beat-003-part-001",
        "outline-obligation-repair-beat-003-part-002",
      ],
    },
    {
      family: "enrichment",
      actions: [
        "story-material-enrichment-001",
        "story-material-gapfill-characters-001",
      ],
    },
  ];
  for (const group of families) {
    let dispatches = 0;
    const logicalKeys: unknown[] = [];
    const admin = {
      rpc: (name: string, params: Record<string, unknown>) => {
        if (name === "get_outline_stage_totals") {
          return Promise.resolve({
            data: [{
              raw_charge_credits: dispatches === 0 ? 0 : 1,
              settled_charge_credits: dispatches === 0 ? 0 : 3,
            }],
            error: null,
          });
        }
        if (name === "begin_outline_provider_attempt") {
          logicalKeys.push(params.p_logical_stage_key);
          dispatches++;
          return Promise.resolve({
            data: [{
              attempt_id: `a-${dispatches}`,
              attempt_key: `${group.family}:attempt:${dispatches}`,
              attempt_ordinal: dispatches,
            }],
            error: null,
          });
        }
        if (name === "settle_outline_provider_attempt") {
          return Promise.resolve({
            data: [{
              settlement_status: "settled",
              usage_event_id: `u-${dispatches}`,
              ledger_id: `l-${dispatches}`,
              remaining_credits: 0,
            }],
            error: null,
          });
        }
        if (name === "reconcile_outline_provider_attempts") {
          return Promise.resolve({ data: null, error: null });
        }
        throw new Error(`unexpected RPC ${name}`);
      },
      from: (_table: string) => ({
        update: (_patch: unknown) => ({
          eq: (_column: string, _value: unknown) =>
            Promise.resolve({ data: null, error: null }),
        }),
      }),
    };
    for (const action of group.actions) {
      const request = makeRequest({
        model: {
          ...TEST_MODEL,
          minimum_charge_credits: 3,
          provider_input_usd_per_1m: 5,
          provider_cached_input_usd_per_1m: 5,
          provider_cache_write_usd_per_1m: 6.25,
          provider_output_usd_per_1m: 0,
        },
        purpose: "outline-suggestion",
        action,
        preflightUsageOverride: {
          uncachedInputTokens: 1000,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 0,
          toolCostUsd: 0,
        },
        usageContext: {
          ...makeRequest().usageContext,
          featureRunID: "00000000-0000-0000-0000-0000000000bb",
          logicalStageKey: `run:${group.family}`,
        },
      });
      await runBillableLLM(request, {
        adminClient: admin,
        provider: makeProvider(
          makeLLMResponse({ inputTokens: 0, outputTokens: 0 }),
        ),
        creditStore: makeCreditStore({
          availableCredits: dispatches === 0 ? 3 : 0.5,
        }),
      });
    }
    assertEquals(logicalKeys, [`run:${group.family}`, `run:${group.family}`]);
  }
});

Deno.test("outline logical-stage preflight does not change generate/coherence minimum behavior", async () => {
  const admin = makeMockAdmin();
  const request = makeRequest({
    maxOutputTokens: 0,
    preflightUsageOverride: {
      uncachedInputTokens: 0,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 0,
      toolCostUsd: 0,
    },
  });
  const error = await assertRejects(
    () =>
      runBillableLLM(request, {
        adminClient: admin,
        provider: makeProvider(makeLLMResponse()),
        creditStore: makeCreditStore({ availableCredits: 0.99 }),
      }),
    BillableLLMError,
  );
  assertEquals(
    ((error as BillableLLMError).details as Record<string, unknown>)
      ?.requiredCredits,
    1,
  );
  assertEquals(admin.rpcCalls.length, 0);
});

Deno.test("outline reconciliation includes every terminal billable provider-attempt status", async () => {
  const migration = await Deno.readTextFile(
    new URL(
      "../../migrations/20260915191000_generation_provider_attempts.sql",
      import.meta.url,
    ),
  );
  assertStringIncludes(
    migration,
    "status in ('settled','feature_validation_failed','feature_persistence_failed')",
  );
});

Deno.test("outline settlement keeps RPC-authoritative logical-stage delta", async () => {
  const updates: Record<string, unknown>[] = [];
  const admin = {
    rpc: (name: string, _params: Record<string, unknown>) => {
      if (name === "get_outline_stage_totals") {
        return Promise.resolve({
          data: [{ raw_charge_credits: 0, settled_charge_credits: 0 }],
          error: null,
        });
      }
      if (name === "begin_outline_provider_attempt") {
        return Promise.resolve({
          data: [{
            attempt_id: "attempt-1",
            attempt_key: "stage:attempt:1",
            attempt_ordinal: 1,
          }],
          error: null,
        });
      }
      if (name === "settle_outline_provider_attempt") {
        return Promise.resolve({
          data: [{
            settlement_status: "settled",
            usage_event_id: "usage-1",
            ledger_id: "ledger-1",
            settled_charge_credits: 3,
            run_charge_credits: 3,
            remaining_credits: 97,
          }],
          error: null,
        });
      }
      if (name === "reconcile_outline_provider_attempts") {
        return Promise.resolve({ data: null, error: null });
      }
      throw new Error(`unexpected RPC ${name}`);
    },
    from: (_table: string) => ({
      update: (patch: Record<string, unknown>) => ({
        eq: (_column: string, _value: unknown) => {
          updates.push(patch);
          return Promise.resolve({ data: null, error: null });
        },
      }),
    }),
  };
  const request = makeRequest({
    purpose: "outline-suggestion",
    action: "outline-suggestions-beat-000-part-001",
    usageContext: {
      ...makeRequest().usageContext,
      featureRunID: "00000000-0000-0000-0000-0000000000bb",
      logicalStageKey: "stage",
    },
  });
  await runBillableLLM(request, {
    adminClient: admin,
    provider: { complete: () => Promise.resolve(makeLLMResponse()) },
    creditStore: makeCreditStore(),
  });
  assertEquals(
    updates.some((patch) =>
      Object.prototype.hasOwnProperty.call(patch, "settled_charge_credits")
    ),
    false,
  );
});

Deno.test("billing across two real worker-slice dispatches settles one logical-stage minimum", async () => {
  const allocations: Record<string, unknown>[] = [];
  const settlements: Record<string, unknown>[] = [];
  const providerAttempts: Record<string, unknown>[] = [];
  let dispatchOrdinal = 0;
  let providerCalls = 0;
  let ledgerTotal = 0;
  const admin = {
    rpc: (name: string, params: Record<string, unknown>) => {
      if (name === "get_outline_stage_totals") {
        return Promise.resolve({
          data: [{
            raw_charge_credits: dispatchOrdinal === 0 ? 0 : 1,
            settled_charge_credits: ledgerTotal,
          }],
          error: null,
        });
      }
      if (name === "begin_outline_provider_attempt") {
        dispatchOrdinal++;
        allocations.push(params);
        const attempt = {
          attempt_id: `attempt-${dispatchOrdinal}`,
          attempt_key: `run-billing:routing:attempt:${dispatchOrdinal}`,
          attempt_ordinal: dispatchOrdinal,
        };
        providerAttempts.push(attempt);
        return Promise.resolve({ data: [attempt], error: null });
      }
      if (name === "settle_outline_provider_attempt") {
        settlements.push(params);
        ledgerTotal = 3;
        return Promise.resolve({
          data: [{
            settlement_status: "settled",
            usage_event_id: `usage-${dispatchOrdinal}`,
            ledger_id: dispatchOrdinal === 1 ? "ledger-routing" : null,
            settled_charge_credits: 3,
            run_charge_credits: 3,
            remaining_credits: 97,
          }],
          error: null,
        });
      }
      if (name === "reconcile_outline_provider_attempts") {
        return Promise.resolve({ data: null, error: null });
      }
      throw new Error(`unexpected RPC ${name}`);
    },
    from: (_table: string) => ({
      update: (_patch: unknown) => ({
        eq: (_column: string, _value: unknown) =>
          Promise.resolve({ data: null, error: null }),
      }),
    }),
  };
  const provider: LLMProvider = {
    complete: () => {
      providerCalls++;
      return Promise.resolve(
        makeLLMResponse({ inputTokens: 1, outputTokens: 0 }),
      );
    },
  };
  const request = makeRequest({
    model: { ...TEST_MODEL, minimum_charge_credits: 3 },
    purpose: "outline-suggestion",
    action: "outline-route-batch-001",
    maxOutputTokens: 0,
    preflightUsageOverride: {
      uncachedInputTokens: 1,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 0,
      toolCostUsd: 0,
    },
    usageContext: {
      ...makeRequest().usageContext,
      featureRunID: "00000000-0000-0000-0000-0000000000cc",
      logicalStageKey: "00000000-0000-0000-0000-0000000000cc:routing",
    },
  });
  const deps = {
    adminClient: admin,
    provider,
    creditStore: makeCreditStore({ availableCredits: 3 }),
  };
  await runBillableLLM(request, deps);
  await runBillableLLM({ ...request, action: "outline-route-batch-002" }, deps);

  assertEquals(providerCalls, 2);
  assertEquals(providerAttempts.length, 2);
  assertEquals(allocations.map((row) => row.p_logical_stage_key), [
    "00000000-0000-0000-0000-0000000000cc:routing",
    "00000000-0000-0000-0000-0000000000cc:routing",
  ]);
  assertEquals(settlements.length, 2);
  assertEquals(ledgerTotal, 3);
  assertEquals(settlements.map((row) => row.p_attempt_key), [
    "run-billing:routing:attempt:1",
    "run-billing:routing:attempt:2",
  ]);
});

Deno.test("runBillableLLM: hard input ceiling allows 269999 and 270000, rejects 270001 before all side effects", async () => {
  const providerCalls: number[] = [];
  const provider: LLMProvider = {
    complete: () => {
      providerCalls.push(1);
      return Promise.resolve(makeLLMResponse());
    },
  };
  for (const inputTokens of [269_999, 270_000]) {
    const admin = makeMockAdmin();
    const creditStore = makeCreditStore();
    await runBillableLLM(
      makeRequest({
        preflightUsageOverride: {
          uncachedInputTokens: inputTokens,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 0,
          toolCostUsd: 0,
        },
      }),
      { adminClient: admin, provider, creditStore },
    );
    // Settlement is atomic through the RPC; the local CreditStore is not
    // mutated by this shared runner.
    assertEquals(creditStore.chargeCalls.length, 0);
    assertEquals(admin.rpcCalls.length, 1);
  }
  const admin = makeMockAdmin();
  const creditStore = makeCreditStore();
  const error = await assertRejects(
    () =>
      runBillableLLM(
        makeRequest({
          preflightUsageOverride: {
            uncachedInputTokens: 270_001,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            toolCostUsd: 0,
          },
        }),
        { adminClient: admin, provider, creditStore },
      ),
    BillableLLMError,
  );
  assertEquals(error.code, "input_token_limit_exceeded");
  assertEquals(providerCalls.length, 2);
  assertEquals(creditStore.chargeCalls.length, 0);
  assertEquals(admin.rpcCalls.length, 0);
});
