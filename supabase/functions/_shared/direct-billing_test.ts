import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
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
  billing_multiplier: 2,
  provider_input_usd_per_1m: 0.02,
  provider_cached_input_usd_per_1m: 0.02,
  provider_cache_write_usd_per_1m: null,
  provider_output_usd_per_1m: 0,
  pricing_effective_at: "2026-09-17T23:00:00Z",
  cacheMode: "none",
};

function makeContext(model: GenerationModel = EMBEDDING_MODEL) {
  const rpcCalls: string[] = [];
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
    rpc: (name: string) => {
      rpcCalls.push(name);
      return Promise.resolve({
        data: [{ id: "usage-1", charge: 0.25 }],
        error: null,
      });
    },
  };
  const creditStore = {
    loadOrDefault: () => Promise.resolve({ monthly_credit_allowance: 100, purchased_credit_balance: 0 }),
  } as unknown as CreditStore;
  return { context: { userID: "user-1", action: "embed", outputID: "output-1", adminClient, creditStore }, rpcCalls };
}

Deno.test("direct billing: embedding resolves and settles through embedding pricing", async () => {
  const { context, rpcCalls } = makeContext();
  await preflightDirectUsage(context, "text-embedding-3-small", 100, 0, "embedding");
  const charge = await settleDirectUsage(
    context,
    "scene-memory-embedding",
    "text-embedding-3-small",
    100,
    0,
    "embedding",
  );
  assertEquals(charge, 0.25);
  assertEquals(rpcCalls, ["settle_scene_memory_stage"]);
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
    () => preflightDirectUsage(context, "text-embedding-3-small", 270_001, 0, "embedding"),
    Error,
    "input_token_limit_exceeded",
  );
  assertEquals(rpcCalls.length, 0);
});
