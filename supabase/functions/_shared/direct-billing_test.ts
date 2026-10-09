import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  DirectBillingInsufficientCreditsError,
  preflightDirectUsage,
  settleDirectUsage,
} from "./direct-billing.ts";
import type { GenerationModel } from "../generate-story/_generation_models.ts";
import type { CreditStore } from "../generate-story/_credits.ts";

const EMBEDDING_MODEL: GenerationModel = {
  id: "text-embedding-3-small",
  provider: "openai",
  provider_model: "text-embedding-3-small",
  display_name: "text-embedding-3-small",
  description: null,
  input_credit_rate: 0,
  output_credit_rate: 0,
  minimum_charge_credits: 0.25,
  max_output_tokens: null,
  enabled: true,
  sort_order: 1,
  provider_available: true,
  model_kind: "embedding",
  pricing_state: "verified",
  pricing_verified_at: "2026-09-17T00:00:00Z",
  cache_write_pricing_required: false,
  billing_multiplier: 4,
  provider_input_usd_per_1m: 0.02,
  provider_cached_input_usd_per_1m: 0.02,
  provider_cache_write_usd_per_1m: null,
  provider_output_usd_per_1m: 0,
  pricing_effective_at: "2026-09-17T23:00:00Z",
  cacheMode: "none",
};

const TEXT_GENERATION_MODEL: GenerationModel = {
  ...EMBEDDING_MODEL,
  id: "gpt-4o-mini",
  provider_model: "gpt-4o-mini",
  display_name: "GPT-4o mini",
  model_kind: "text_generation",
  provider_output_usd_per_1m: 0.6,
};

function makeContext(
  model: GenerationModel = EMBEDDING_MODEL,
  rpcError: { message: string } | null = null,
  availableCreditBalance = 100,
) {
  const rpcCalls: string[] = [];
  const rpcPayloads: Record<string, unknown>[] = [];
  const adminClient = {
    from: () => ({
      select: () => ({
        eq: () => ({
          eq: () => ({
            maybeSingle: () => Promise.resolve({ data: model, error: null }),
          }),
          maybeSingle: () => Promise.resolve({ data: model, error: null }),
        }),
      }),
    }),
    rpc: (name: string, params: Record<string, unknown>) => {
      rpcCalls.push(name);
      rpcPayloads.push(params);
      return Promise.resolve({
        data: rpcError ? null : [{ id: "usage-1", charge: 0.25 }],
        error: rpcError,
      });
    },
  };
  const creditStore = {
    loadOrDefault: () =>
      Promise.resolve({
        monthly_credit_allowance: availableCreditBalance,
        purchased_credit_balance: 0,
      }),
  } as unknown as CreditStore;
  return {
    context: {
      userID: "user-1",
      action: "embed",
      outputID: "output-1",
      adminClient,
      creditStore,
    },
    rpcCalls,
    rpcPayloads,
  };
}

Deno.test("direct billing: embedding resolves and settles through embedding pricing", async () => {
  const { context, rpcCalls, rpcPayloads } = makeContext();
  await preflightDirectUsage(
    context,
    "text-embedding-3-small",
    100,
    0,
    "embedding",
    "scene-memory-embedding",
  );
  const charge = await settleDirectUsage(
    context,
    "scene-memory-embedding",
    "text-embedding-3-small",
    100,
    0,
    "embedding",
  );
  assertEquals(charge, 0.00016);
  assertEquals(rpcCalls, ["settle_scene_memory_stage"]);
  assertEquals(rpcPayloads[0].p_charge, 0.00016);
});

Deno.test("direct billing: Tartaria embedding usage charges at 4x provider cost", async () => {
  const { context, rpcPayloads } = makeContext();
  const charge = await settleDirectUsage(
    context,
    "scene-memory-embedding",
    "text-embedding-3-small",
    73_555,
    0,
    "embedding",
  );
  assertEquals(charge, 0.117688);
  assertEquals(rpcPayloads[0].p_charge, 0.117688);
});

Deno.test("direct billing: embedding preflight uses the same floor-free estimate", async () => {
  const { context } = makeContext(EMBEDDING_MODEL, null, 0.001);
  await preflightDirectUsage(
    context,
    "text-embedding-3-small",
    100,
    0,
    "embedding",
    "scene-memory-embedding",
  );
});

Deno.test("direct billing: extraction retains the catalog minimum", async () => {
  const { context } = makeContext(TEXT_GENERATION_MODEL);
  const charge = await settleDirectUsage(
    context,
    "scene-memory-extraction",
    "gpt-4o-mini",
    100,
    0,
  );
  assertEquals(charge, 0.25);
});

Deno.test("direct billing: embedding never passes the text-generation resolver", async () => {
  const { context } = makeContext();
  await assertRejects(
    () => preflightDirectUsage(context, "text-embedding-3-small", 100, 0),
    Error,
    "billing model unavailable",
  );
});

Deno.test("direct billing: 270001 estimated input is rejected before entitlement mutation", async () => {
  const { context, rpcCalls } = makeContext();
  await assertRejects(
    () =>
      preflightDirectUsage(
        context,
        "text-embedding-3-small",
        270_001,
        0,
        "embedding",
      ),
    Error,
    "input_token_limit_exceeded",
  );
  assertEquals(rpcCalls.length, 0);
});

Deno.test("direct billing: provider usage over 270K still settles after dispatch", async () => {
  const { context, rpcCalls } = makeContext();
  const charge = await settleDirectUsage(
    context,
    "scene-memory-embedding",
    "text-embedding-3-small",
    270_001,
    0,
    "embedding",
  );
  assertEquals(charge, 0.432002);
  assertEquals(rpcCalls, ["settle_scene_memory_stage"]);
});

Deno.test("direct billing: atomic insufficient-credit race has canonical classification", async () => {
  const { context } = makeContext(EMBEDDING_MODEL, {
    message: "insufficient credits for stage",
  });
  await assertRejects(
    () =>
      settleDirectUsage(
        context,
        "scene-memory-embedding",
        "text-embedding-3-small",
        100,
        0,
        "embedding",
      ),
    DirectBillingInsufficientCreditsError,
    "Insufficient credits for the next billable stage.",
  );
});
