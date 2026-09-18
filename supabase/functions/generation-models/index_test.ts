import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { handler } from "./index.ts";
import {
  SupabaseGenerationModelStore,
  type GenerationModelStore,
} from "../generate-story/_generation_models.ts";

const mockModelStore: GenerationModelStore = {
  getEnabledModelById() {
    return Promise.resolve(null);
  },
  listEnabledModels() {
    return Promise.resolve([
      {
        id: "gpt-4o-mini",
        display_name: "GPT-4o mini",
        description: "Fast",
        input_credit_rate: 1,
        output_credit_rate: 1,
        minimum_charge_credits: 1,
        max_output_tokens: null,
        sort_order: 10,
      },
    ]);
  },
};

Deno.test("generation-models: returns only enabled model list payload", async () => {
  Deno.env.set("SUPABASE_URL", "https://fake.supabase.co");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fake-service-role-key");

  const req = new Request("https://test.example.com/generation-models", {
    method: "GET",
  });
  const res = await handler(req, {
    modelStore: mockModelStore,
    authenticatedUserId: "00000000-0000-0000-0000-000000000001",
  });
  const body = await res.json();

  assertEquals(res.status, 200);
  assertEquals(body.status, "complete");
  assertEquals(body.models.length, 1);
  assertEquals(body.models[0].id, "gpt-4o-mini");
});


function rawModel(providerModel: string, overrides: Record<string, unknown> = {}) {
  return {
    id: providerModel,
    provider: "openai",
    provider_model: providerModel,
    display_name: providerModel,
    description: null,
    input_credit_rate: 1,
    output_credit_rate: 2,
    minimum_charge_credits: 0.25,
    max_output_tokens: 4096,
    sort_order: 1,
    enabled: true,
    provider_available: true,
    model_kind: "text_generation",
    pricing_state: "verified",
    pricing_verified_at: "2026-09-17T00:00:00Z",
    cache_write_pricing_required: false,
    billing_multiplier: 2,
    provider_input_usd_per_1m: 0.15,
    provider_cached_input_usd_per_1m: 0.075,
    provider_cache_write_usd_per_1m: 0.1875,
    provider_output_usd_per_1m: 0.6,
    pricing_effective_at: "2026-09-17T23:00:00Z",
    cache_mode: "implicit",
    ...overrides,
  };
}

Deno.test("generation-models: real store filters mixed invalid rows before picker payload", async () => {
  const rows = [
    rawModel("gpt-4o-mini"),
    rawModel("unpriced-model", { pricing_state: "unverified", provider_input_usd_per_1m: null }),
    rawModel("disabled-model", { enabled: false }),
    rawModel("embedding-model", { model_kind: "embedding" }),
  ];
  const db = {
    from() {
      return {
        select() {
          return {
            eq(_column: string, _value: unknown) { return this; },
            order(_column: string, _options: unknown) { return this; },
            then(resolve: (value: unknown) => unknown) {
              return Promise.resolve(resolve({ data: rows, error: null }));
            },
          };
        },
      };
    },
  };
  const store = new SupabaseGenerationModelStore(db);
  const models = await store.listEnabledModels();
  assertEquals(models.map((model) => model.id), ["gpt-4o-mini"]);
});
