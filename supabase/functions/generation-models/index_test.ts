import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { handler } from "./index.ts";
import type { GenerationModelStore } from "../generate-story/_generation_models.ts";

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

  const req = new Request("https://test.example.com/generation-models", { method: "GET" });
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
