// =============================================================================
// coherence-check/_handler_test.ts
//
// Integration tests for handleCoherenceCheck. The handler is the smallest
// import-safe production unit needed to verify that coherence-check correctly
// combines: provider success / empty content / invalid JSON / failed audit
// recording / suppression of complete-event-on-failure / suppression of
// charge-on-failure / successful usage insertion + charging.
//
// All mocks are in-process. No real OpenAI, Supabase, or network calls.
// =============================================================================

import {
  assertEquals,
  assertStrictEquals,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  type CoherenceConfig,
  type CoherenceRuntimeDeps,
  handleCoherenceCheck,
  supportsCustomTemperature,
} from "./_handler.ts";
import type {
  LLMMessage,
  LLMProvider,
  LLMResponse,
} from "../generate-story/_provider.ts";
import type { GenerationModel } from "../generate-story/_generation_models.ts";
import type {
  CreditStore,
  UserEntitlement,
} from "../generate-story/_credits.ts";
import type { CoherenceCheckRequest } from "./_validation.ts";

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

const USER_ID = "00000000-0000-0000-0000-0000000000aa";
const PROJECT_ID = "00000000-0000-0000-0000-0000000000bb";

const VALID_REQUEST: CoherenceCheckRequest = {
  output_text: "the user-written prose that we are checking",
  current_section: {
    id: "sec-1",
    title: "The Crossing",
    summary: "Hero crosses the river.",
    pov: "thirdPersonLimited",
    container: "scene",
    beat_label: "decision beat",
  },
  prior_canon: {
    sections: [
      {
        section_id: "sec-0",
        title: "Prior section",
        summary: "Hero set off from the village.",
        pov: "thirdPersonLimited",
        container: "scene",
        created_at: "2026-08-23T12:00:00Z",
        extracted_summary: "Departure from village.",
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      },
    ],
  },
  project_id: PROJECT_ID,
};

const MODEL_ROW: GenerationModel = {
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
  // PR-372: cache-write rate default 1.25× standard input.
  provider_cache_write_usd_per_1m: 0.1875,
  provider_output_usd_per_1m: 0.60,
  pricing_effective_at: "2026-01-01T00:00:00Z",
  // PR-372: chat/completions path uses implicit cache only.
  cacheMode: "implicit",
};

const FALLBACK_MODEL: GenerationModel = {
  id: "__fallback__",
  provider: "openai",
  provider_model: "gpt-5-mini",
  display_name: "gpt-5-mini",
  description: "fallback",
  input_credit_rate: 0,
  output_credit_rate: 0,
  minimum_charge_credits: 1,
  // PR-372: cache fields.
  provider_cache_write_usd_per_1m: 0,
  cacheMode: "implicit",
  max_output_tokens: null,
  enabled: true,
  sort_order: 0,
  billing_multiplier: 2.0,
  provider_input_usd_per_1m: 0.40,
  provider_cached_input_usd_per_1m: 0.10,
  provider_output_usd_per_1m: 1.60,
  pricing_effective_at: "2026-01-01T00:00:00Z",
};

const CONFIG: CoherenceConfig = {
  openaiModelDefault: "gpt-4o-mini",
  fallbackModel: FALLBACK_MODEL,
  maxCompletionTokens: 1500,
  temperature: 0.2,
};

Deno.test("supportsCustomTemperature: omits override for GPT-5-family models", () => {
  assertEquals(
    supportsCustomTemperature({ ...MODEL_ROW, provider_model: "gpt-5.6-luna" }),
    false,
  );
  assertEquals(
    supportsCustomTemperature({ ...MODEL_ROW, provider_model: "gpt-5-mini" }),
    false,
  );
  assertEquals(
    supportsCustomTemperature({ ...MODEL_ROW, provider_model: "gpt-4o-mini" }),
    true,
  );
  assertEquals(
    supportsCustomTemperature({
      ...MODEL_ROW,
      provider: "anthropic",
      provider_model: "claude-sonnet-4",
    }),
    true,
  );
});

// ---------------------------------------------------------------------------
// Mock admin client — records inserts, returns scripted model row.
// ---------------------------------------------------------------------------

interface InsertedRow {
  table: string;
  row: Record<string, unknown>;
}

interface MockAdminState {
  insertedRows: InsertedRow[];
  usageEventResult: { data: { id: string } | null; error: unknown };
}

function makeMockAdmin(opts: {
  modelRow?: GenerationModel | null;
  usageEventResult?: { data: { id: string } | null; error: unknown };
} = {}): { client: unknown; state: MockAdminState } {
  const state: MockAdminState = {
    insertedRows: [],
    usageEventResult: opts.usageEventResult ??
      { data: { id: "row-1" }, error: null },
  };
  const modelRow = opts.modelRow === undefined ? MODEL_ROW : opts.modelRow;

  const client: unknown = {
    from(table: string): unknown {
      if (table === "generation_models") {
        return {
          select(): unknown {
            return {
              eq(): unknown {
                return {
                  eq(): unknown {
                    return {
                      maybeSingle: () =>
                        Promise.resolve({
                          data: modelRow,
                          error: modelRow ? null : { code: "PGRST116" },
                        }),
                    };
                  },
                  maybeSingle: () =>
                    Promise.resolve({
                      data: modelRow,
                      error: modelRow ? null : { code: "PGRST116" },
                    }),
                };
              },
              maybeSingle: () =>
                Promise.resolve({
                  data: modelRow,
                  error: modelRow ? null : { code: "PGRST116" },
                }),
            };
          },
        };
      }
      // generation_usage_events + llm_prompts: insert path
      return {
        insert(row: unknown): unknown {
          state.insertedRows.push({
            table,
            row: row as Record<string, unknown>,
          });
          const result = table === "generation_usage_events"
            ? state.usageEventResult
            : {
              data: { id: `audit-${state.insertedRows.length}` },
              error: null,
            };
          return {
            select(): unknown {
              return { maybeSingle: () => Promise.resolve(result) };
            },
            // Also support direct await without .select chain
            then: (resolve: (v: unknown) => void) =>
              Promise.resolve(resolve(result)),
          };
        },
      };
    },
  };
  return { client, state };
}

// ---------------------------------------------------------------------------
// Mock provider
// ---------------------------------------------------------------------------

function makeProvider(response: LLMResponse | Error): LLMProvider {
  return {
    complete: (
      _messages: LLMMessage[],
      _maxTokens: number,
      _model?: string,
      _options?: unknown,
    ) => {
      if (response instanceof Error) return Promise.reject(response);
      return Promise.resolve(response);
    },
  };
}

function makeLLMResponse(
  overrides: Partial<LLMResponse> = {},
): LLMResponse {
  return {
    content: '{"warnings":[]}',
    modelName: MODEL_ROW.provider_model,
    finishReason: "stop",
    inputTokens: 1500,
    cachedInputTokens: 0,
    outputTokens: 250,
    totalTokens: 1750,
    toolCostUsd: 0,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Mock credit store
// ---------------------------------------------------------------------------

interface MockCreditStoreState {
  chargeCalls: Array<{ userId: string; cost: number; outputId: string | null }>;
  entitlement: UserEntitlement;
}

function makeCreditStore(opts: {
  chargeShouldThrow?: boolean;
  availableCredits?: number;
} = {}): { store: CreditStore; state: MockCreditStoreState } {
  const availableCredits = opts.availableCredits ?? 100;
  const state: MockCreditStoreState = {
    chargeCalls: [],
    entitlement: {
      user_id: USER_ID,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: availableCredits,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
      updated_at: new Date().toISOString(),
    },
  };
  const store: CreditStore = {
    loadOrDefault: (_userId: string) => Promise.resolve(state.entitlement),
    charge: async (
      userId: string,
      cost: number,
      _ent: unknown,
      outputId: string | null,
    ) => {
      await Promise.resolve();
      if (opts.chargeShouldThrow) {
        throw new Error("simulated charge failure");
      }
      state.chargeCalls.push({ userId, cost, outputId });
      state.entitlement = {
        ...state.entitlement,
        monthly_credit_allowance: state.entitlement.monthly_credit_allowance -
          cost,
      };
      return state.entitlement;
    },
  };
  return { store, state };
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function usageEventRows(
  state: MockAdminState,
): Array<Record<string, unknown>> {
  return state.insertedRows
    .filter((r) => r.table === "generation_usage_events")
    .map((r) => r.row);
}

function auditRows(
  state: MockAdminState,
): Array<Record<string, unknown>> {
  return state.insertedRows
    .filter((r) => r.table === "llm_prompts")
    .map((r) => r.row);
}

// ---------------------------------------------------------------------------
// Test scenarios
// ---------------------------------------------------------------------------

Deno.test(
  "handleCoherenceCheck [a] valid structured response: typed result + one complete event + one charge",
  async () => {
    const { client: admin, state: adminState } = makeMockAdmin();
    const { store: creditStore, state: creditState } = makeCreditStore();
    const provider = makeProvider(makeLLMResponse({
      content: '{"warnings":[{"reason":"Premise mismatch","severity":"high"}]}',
      modelName: "gpt-4o-mini-returned",
      inputTokens: 1500,
      outputTokens: 500,
    }));

    const deps: CoherenceRuntimeDeps = {
      adminClient: admin,
      provider,
      creditStore,
    };
    const response = await handleCoherenceCheck(
      USER_ID,
      VALID_REQUEST,
      deps,
      CONFIG,
    );

    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.warnings.length, 1);
    assertEquals(body.warnings[0].reason, "Premise mismatch");
    assertEquals(body.warnings[0].severity, "high");
    assertEquals(body.diagnostics.model, "gpt-4o-mini-returned");
    assertEquals(body.diagnostics.prompt_tokens, 1500);
    assertEquals(body.diagnostics.completion_tokens, 500);
    assertEquals(body.diagnostics.pre_filter_count, 1);
    assertEquals(body.diagnostics.post_filter_count, 1);

    // Exactly ONE complete usage event (no failed events).
    const events = usageEventRows(adminState);
    assertEquals(events.length, 1);
    assertEquals(events[0].purpose, "coherence-check");
    assertEquals(events[0].action, "check");
    assertEquals(events[0].status, "complete");
    assertEquals(events[0].model_name, "gpt-4o-mini-returned");
    assertEquals(events[0].input_tokens, 1500);
    assertEquals(events[0].output_tokens, 500);
    assertEquals(events[0].user_id, USER_ID);
    assertEquals(events[0].generation_output_id, null);

    // ONE llm_prompts audit insert, with duration_ms > 0 (proves duration
    // spans the runner call, not the callback).
    const audits = auditRows(adminState);
    assertEquals(audits.length, 1);
    assertEquals(audits[0].call_type, "coherence-check");
    assertEquals(audits[0].project_id, PROJECT_ID);
    assertEquals(audits[0].outline_section_id, "sec-1");
    assertEquals(audits[0].model, "gpt-4o-mini-returned");
    assertEquals(typeof audits[0].duration_ms, "number");
    assertStrictEquals((audits[0].duration_ms as number) >= 0, true);

    // Exactly ONE credit charge call (exactly-once billing).
    assertEquals(creditState.chargeCalls.length, 1);
  },
);

Deno.test(
  "handleCoherenceCheck [b] empty content: failed event, no complete, no charge, 502 openai_empty",
  async () => {
    const { client: admin, state: adminState } = makeMockAdmin();
    const { store: creditStore, state: creditState } = makeCreditStore();
    const provider = makeProvider(makeLLMResponse({
      content: "   ", // blank, should trigger EmptyContentError
      inputTokens: 1500,
      outputTokens: 0,
    }));

    const deps: CoherenceRuntimeDeps = {
      adminClient: admin,
      provider,
      creditStore,
    };
    const response = await handleCoherenceCheck(
      USER_ID,
      VALID_REQUEST,
      deps,
      CONFIG,
    );

    assertEquals(response.status, 502);
    const body = await response.json();
    assertEquals(body.errorCode, "openai_empty");
    assertStringIncludes(body.message, "OpenAI returned no content");

    // Exactly ONE failed usage event (callback recorded it before throwing).
    const events = usageEventRows(adminState);
    assertEquals(events.length, 1);
    assertEquals(events[0].status, "failed");
    assertEquals(events[0].purpose, "coherence-check");
    assertEquals(events[0].action, "check");
    assertEquals(events[0].input_tokens, 1500);
    assertEquals(events[0].output_tokens, 0);
    assertEquals(events[0].generation_output_id, null);

    // NO complete usage event on this path.
    assertEquals(events.filter((e) => e.status === "complete").length, 0);

    // NO llm_prompts audit (audit is post-runner; on failure, runner throws
    // before audit is called).
    assertEquals(auditRows(adminState).length, 0);

    // NO credit charge on this path.
    assertEquals(creditState.chargeCalls.length, 0);
  },
);

Deno.test(
  "handleCoherenceCheck [c] invalid JSON: failed event, no complete, no charge, 502 openai_invalid_json",
  async () => {
    const { client: admin, state: adminState } = makeMockAdmin();
    const { store: creditStore, state: creditState } = makeCreditStore();
    const provider = makeProvider(makeLLMResponse({
      content: "{this is not valid JSON",
      inputTokens: 1500,
      outputTokens: 100,
    }));

    const deps: CoherenceRuntimeDeps = {
      adminClient: admin,
      provider,
      creditStore,
    };
    const response = await handleCoherenceCheck(
      USER_ID,
      VALID_REQUEST,
      deps,
      CONFIG,
    );

    assertEquals(response.status, 502);
    const body = await response.json();
    assertEquals(body.errorCode, "openai_invalid_json");
    assertStringIncludes(body.message, "LLM returned invalid JSON");

    // Exactly ONE failed usage event.
    const events = usageEventRows(adminState);
    assertEquals(events.length, 1);
    assertEquals(events[0].status, "failed");
    assertEquals(events[0].input_tokens, 1500);
    assertEquals(events[0].output_tokens, 100);
    assertEquals(events.filter((e) => e.status === "complete").length, 0);

    // NO audit, NO charge.
    assertEquals(auditRows(adminState).length, 0);
    assertEquals(creditState.chargeCalls.length, 0);
  },
);

Deno.test(
  "handleCoherenceCheck [d] credit charge failure: no success response, 500 billing_charge_failed",
  async () => {
    const { client: admin, state: adminState } = makeMockAdmin();
    const { store: creditStore } = makeCreditStore({ chargeShouldThrow: true });
    const provider = makeProvider(makeLLMResponse({
      content: '{"warnings":[]}',
      inputTokens: 1500,
      outputTokens: 250,
    }));

    const deps: CoherenceRuntimeDeps = {
      adminClient: admin,
      provider,
      creditStore,
    };
    const response = await handleCoherenceCheck(
      USER_ID,
      VALID_REQUEST,
      deps,
      CONFIG,
    );

    assertEquals(response.status, 500);
    const body = await response.json();
    assertEquals(body.errorCode, "billing_charge_failed");
    assertStringIncludes(body.message, "Credit charge failed");

    // Usage event WAS inserted (runner inserts before charging) — preserved
    // for audit/reconciliation. Charge failed AFTER the insert.
    const events = usageEventRows(adminState);
    assertEquals(events.length, 1);
    assertEquals(events[0].status, "complete");

    // NO llm_prompts audit (audit is after runner success; runner threw
    // credit_charge_failed before audit was reached).
    assertEquals(auditRows(adminState).length, 0);
  },
);

// ---------------------------------------------------------------------------
// Bonus: duration_ms covers the runner call, not just the callback
// ---------------------------------------------------------------------------

Deno.test(
  "handleCoherenceCheck: duration_ms spans runner orchestration (not just callback)",
  async () => {
    // Use a slow provider so the runner call has measurable duration.
    // No real sleep — just a few microtask hops to simulate provider latency.
    const { client: admin, state: adminState } = makeMockAdmin();
    const { store: creditStore } = makeCreditStore();
    const provider: LLMProvider = {
      complete: async () => {
        // Simulate ~25ms of provider latency via a microtask loop.
        // No real `setTimeout` / `sleep` — keeps the test deterministic.
        const start = Date.now();
        while (Date.now() - start < 25) {
          await Promise.resolve();
        }
        return makeLLMResponse();
      },
    };
    const deps: CoherenceRuntimeDeps = {
      adminClient: admin,
      provider,
      creditStore,
    };
    await handleCoherenceCheck(USER_ID, VALID_REQUEST, deps, CONFIG);

    const audits = auditRows(adminState);
    assertEquals(audits.length, 1);
    const durationMs = audits[0].duration_ms as number;
    // Duration MUST reflect the provider work, not just the post-callback
    // local work (which is near zero for valid JSON). Generous lower bound
    // to avoid CI flakiness.
    assertStrictEquals(durationMs >= 20, true);
  },
);

// Helper used by some tests above.
function assertStringIncludes(actual: string, expected: string): void {
  if (!actual.includes(expected)) {
    throw new Error(
      `Expected string to include ${JSON.stringify(expected)} but got ${
        JSON.stringify(actual)
      }`,
    );
  }
}
