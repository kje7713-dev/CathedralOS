import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { createRunOutlineToken } from "../_shared/run-outline-auth.ts";
import { handler } from "./index.ts";
import type {
  LLMMessage,
  LLMProvider,
  LLMProviderOptions,
} from "./_provider.ts";

const USER_ID = "00000000-0000-0000-0000-000000000001";
const RUN_ID = "00000000-0000-0000-0000-000000000010";
const SECTION_ID = "00000000-0000-0000-0000-000000000011";
const OUTLINE_ID = "00000000-0000-0000-0000-000000000012";
const SECRET = "test-service-role-key";

const canon =
  `## Project State\nCharacters:\n- **Ilya**: {"location":"the long hut at Willow Refuge","injuries":"shoulder wound being treated","character_name":"Ilya","status":"alive"}`;
const baseContract = {
  title: "The final count",
  summary: "Miran learns that Ilya is missing from the final convoy count.",
  entryState: "The convoy reaches the marsh landing.",
  dramaticEvent: "Miran discovers Ilya never completed the crossing.",
  resultingChange: "The count remains unresolved.",
  terminalState: "Ilya is missing.",
};

function makeAdminMock() {
  const settleCalls: Array<Record<string, unknown>> = [];
  let sectionReads = 0;
  const section = {
    id: SECTION_ID,
    title: baseContract.title,
    summary: baseContract.summary,
    container: "scene",
    pov: "thirdPersonLimited",
    terminal_beat: null,
    position: 50,
    outline_id: OUTLINE_ID,
    story_arc_beat_id: null,
  };
  const run = {
    id: RUN_ID,
    status: "running",
    user_id: USER_ID,
    outline_id: OUTLINE_ID,
    sections: [{ id: SECTION_ID }],
  };
  const builderFor = (table: string) => {
    const chain: any = {
      select: () => chain,
      eq: () => chain,
      neq: () => chain,
      lt: () => chain,
      in: () => chain,
      order: () => chain,
      limit: () => chain,
      update: () => chain,
      insert: () => chain,
      single: async () => ({ data: { id: "attempt-1" }, error: null }),
      maybeSingle: async () => {
        if (table === "chapter_runs") return { data: run, error: null };
        if (table === "outlines") {
          return {
            data: { id: OUTLINE_ID, local_project_id: USER_ID },
            error: null,
          };
        }
        if (table === "outline_sections") {
          sectionReads++;
          return {
            data: sectionReads === 1 ? section : null,
            error: null,
          };
        }
        return { data: null, error: null };
      },
      then: (resolve: (value: unknown) => unknown) =>
        Promise.resolve(resolve({ data: null, error: null })),
    };
    return chain;
  };
  return {
    settleCalls,
    from: (table: string) => builderFor(table),
    rpc: async (name: string, params: Record<string, unknown>) => {
      if (name === "settle_billable_usage") {
        settleCalls.push(params);
        return {
          data: [{
            settlement_status: "settled",
            usage_event_id: `usage-${settleCalls.length}`,
            ledger_id: `ledger-${settleCalls.length}`,
            remaining_credits: 90,
          }],
          error: null,
        };
      }
      return { data: null, error: null };
    },
  };
}

function makeCreditStore(): any {
  return {
    loadOrDefault: async () => ({
      monthly_credit_allowance: 100,
      purchased_credit_balance: 0,
      monthly_credit_reset_at: null,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
      user_id: USER_ID,
      plan_name: "test",
      is_pro: false,
      updated_at: new Date().toISOString(),
    }),
    charge: async (userId: string, cost: number, ent: unknown) => ent,
  };
}

function makeRateLimitStore() {
  return {
    checkLimits: async () => ({ allowed: true }),
    recordRequest: async () => undefined,
  };
}

function makeModelStore(): any {
  return {
    getEnabledModelById: async () => ({
      id: "gpt-4o-mini",
      provider: "openai",
      provider_model: "gpt-4o-mini",
      display_name: "gpt-4o-mini",
      description: null,
      input_credit_rate: 1,
      output_credit_rate: 1,
      minimum_charge_credits: 1,
      max_output_tokens: null,
      enabled: true,
      provider_available: true,
      model_kind: "text_generation",
      pricing_state: "verified",
      pricing_verified_at: "2026-09-17T00:00:00Z",
      cache_write_pricing_required: false,
      provider_cache_write_usd_per_1m: 0,
      cacheMode: "implicit",
      sort_order: 0,
      billing_multiplier: 2,
      provider_input_usd_per_1m: 5,
      provider_cached_input_usd_per_1m: 0,
      provider_output_usd_per_1m: 5,
      pricing_effective_at: new Date(0).toISOString(),
    }),
    listEnabledModels: async () => [],
  };
}

function makePersistenceStore() {
  return {
    insertOutput: async () => ({
      data: { id: "00000000-0000-0000-0000-000000000099" },
      error: null,
    }),
    insertUsageEvent: async () => ({ error: null }),
  };
}

async function runScenario(
  contract: Record<string, string>,
  provider: LLMProvider,
) {
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", SECRET);
  const token = await createRunOutlineToken(
    SECRET,
    USER_ID,
    RUN_ID,
    SECTION_ID,
  );
  const calls: Array<{ messages: LLMMessage[]; options?: LLMProviderOptions }> =
    [];
  const wrappedProvider: LLMProvider = {
    complete: async (messages, maxTokens, model, options) => {
      calls.push({ messages, options });
      return provider.complete(messages, maxTokens, model, options);
    },
  };
  const admin = makeAdminMock();
  const response = await handler(
    new Request("https://test.example.com/generate-story", {
      method: "POST",
      headers: {
        Authorization: "Bearer fake-jwt",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        sourcePayloadJSON: {
          schema: "cathedralos.prompt_pack_export",
          version: 1,
          project: { id: USER_ID, name: "Test" },
          promptPack: { id: "pack-1", name: "Pack", prompts: [] },
        },
        generationAction: "generate",
        generationLengthMode: "short",
        outputBudget: 800,
        projectID: USER_ID,
        projectStateContext: canon,
        run_id: RUN_ID,
        run_outline_token: token,
        outline_section_id: SECTION_ID,
        sectionTitle: contract.title,
        sectionSummary: contract.summary,
        sectionEntryState: contract.entryState,
        sectionDramaticEvent: contract.dramaticEvent,
        sectionResultingChange: contract.resultingChange,
        sectionTerminalState: contract.terminalState,
        futureOutlineContext:
          "## Future Outline Obligations\n- The refuge stabilizes",
      }),
    }),
    {
      provider: wrappedProvider,
      creditStore: makeCreditStore(),
      rateLimitStore: makeRateLimitStore(),
      generationModelStore: makeModelStore(),
      persistenceStore: makePersistenceStore(),
      authenticatedUserId: USER_ID,
      adminClient: admin,
    },
  );
  return { response, calls, settleCalls: admin.settleCalls };
}

Deno.test("handler continuity: billable repair runs once before prose and repaired contract is used", async () => {
  const repaired = {
    ...baseContract,
    summary: "Miran confirms Ilya's safe arrival at Willow Refuge.",
    dramaticEvent:
      "Miran reconciles the convoy count with Ilya's safe arrival.",
    resultingChange: "The convoy record is corrected.",
    terminalState: "Ilya rests in the long hut at Willow Refuge.",
  };
  const result = await runScenario(baseContract, {
    complete: async (_messages, _max, _model, options) => ({
      content: options?.responseFormatTarget === "chat"
        ? JSON.stringify({
          conflict: true,
          reason: "stale",
          contract: repaired,
        })
        : "The count was corrected, and Ilya rested in the hut.",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 25,
    }),
  });
  assertEquals(result.response.status, 200);
  assertEquals(result.calls.length, 2);
  assertEquals(result.calls[0].options?.responseFormatTarget, "chat");
  assertEquals(result.calls[1].options?.responseFormatTarget, undefined);
  const prosePrompt = JSON.stringify(result.calls[1].messages);
  assertStringIncludes(prosePrompt, repaired.summary);
  const futureIndex = prosePrompt.indexOf("## Future Outline Obligations");
  const contractIndex = prosePrompt.lastIndexOf("## Section Contract");
  assertEquals(futureIndex >= 0 && futureIndex < contractIndex, true);
  assertEquals(result.settleCalls.length, 2);
  assertEquals(result.settleCalls[0].p_purpose, "coherence-check");
  assertEquals(result.settleCalls[0].p_action, "section-contract-repair");
  assertEquals(
    result.settleCalls[0].p_idempotency_key,
    `${RUN_ID}:${SECTION_ID}:section-contract-repair`,
  );
});

Deno.test("handler continuity: legitimate alive-to-death transition skips repair", async () => {
  const transition = {
    ...baseContract,
    summary: "Enemy raiders attack the refuge and Ilya is killed defending it.",
    dramaticEvent: "Ilya dies defending the long hut.",
    terminalState: "Ilya is dead after the attack.",
  };
  const result = await runScenario(transition, {
    complete: async () => ({
      content: "Ilya defended the hut until the raiders broke through.",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 25,
    }),
  });
  assertEquals(result.response.status, 200);
  assertEquals(result.calls.length, 1);
  assertEquals(result.settleCalls.length, 1);
  assertEquals(result.settleCalls[0].p_purpose, "generate");
});

Deno.test("handler continuity: conflict=false cannot rewrite the contract", async () => {
  const result = await runScenario(baseContract, {
    complete: async (_messages, _max, _model, options) => ({
      content: options?.responseFormatTarget === "chat"
        ? JSON.stringify({
          conflict: false,
          reason: "No contradiction",
          contract: { ...baseContract, summary: "Unauthorized rewrite" },
        })
        : "should not generate",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 25,
    }),
  });
  const body = await result.response.json();
  assertEquals(result.response.status, 422);
  assertEquals(body.errorCode, "section_contract_continuity_conflict");
  assertEquals(result.calls.length, 1);
});

Deno.test("handler continuity: a still-suspicious repair fails without retry or prose", async () => {
  const result = await runScenario(baseContract, {
    complete: async (_messages, _max, _model, options) => ({
      content: options?.responseFormatTarget === "chat"
        ? JSON.stringify({
          conflict: true,
          reason: "Still contradictory",
          contract: baseContract,
        })
        : "should not generate",
      modelName: "mock-model",
      inputTokens: 10,
      outputTokens: 25,
    }),
  });
  const body = await result.response.json();
  assertEquals(result.response.status, 422);
  assertEquals(body.errorCode, "section_contract_continuity_conflict");
  assertEquals(result.calls.length, 1);
  assertEquals(result.settleCalls.length, 1);
});
