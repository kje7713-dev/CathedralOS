import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { type CatalogSyncDb, handler } from "./_handler.ts";

const request = () =>
  new Request("https://test.example.com/sync-openai-model-catalog", {
    method: "POST",
  });
const dbWith = (
  result: { data: unknown; error: { message?: string } | null },
): CatalogSyncDb => ({
  rpc: (_name, _args) => Promise.resolve(result),
});

Deno.test("sync: reconciles a complete provider inventory", async () => {
  let called = false;
  const db: CatalogSyncDb = {
    rpc: (name, args) => {
      called = name === "reconcile_openai_model_catalog" &&
        Array.isArray(args.p_models) &&
        (args.p_models as unknown[]).length === 2;
      return Promise.resolve({
        data: { models_seen: 2, models_inserted: 1 },
        error: null,
      });
    },
  };
  const res = await handler(request(), {
    db,
    authorized: true,
    apiKey: "test-key",
    now: () => new Date("2026-09-17T00:00:00Z"),
    fetchImpl: () =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            data: [
              { id: "gpt-4o-mini", created: 1, owned_by: "openai" },
              { id: "gpt-6-astra", owned_by: "openai" },
            ],
          }),
          { status: 200 },
        ),
      ),
  });
  assertEquals(res.status, 200);
  assertEquals(called, true);
  assertEquals(await res.json(), {
    status: "complete",
    models_seen: 2,
    models_inserted: 1,
  });
});

Deno.test("sync: rejects malformed or partial provider responses before reconciliation", async () => {
  let calls = 0;
  const res = await handler(request(), {
    db: dbWith({ data: null, error: null }),
    authorized: true,
    apiKey: "test-key",
    fetchImpl: () =>
      Promise.resolve(
        new Response(JSON.stringify({ data: [{ created: 1 }] }), {
          status: 200,
        }),
      ),
  });
  calls++;
  assertEquals(res.status, 502);
  assertEquals(calls, 1);
});

Deno.test("sync: provider failure preserves catalog by skipping reconciliation", async () => {
  let reconciled = false;
  const db: CatalogSyncDb = {
    rpc: () => {
      reconciled = true;
      return Promise.resolve({ data: null, error: null });
    },
  };
  const res = await handler(request(), {
    db,
    authorized: true,
    apiKey: "test-key",
    fetchImpl: () => Promise.resolve(new Response("upstream", { status: 503 })),
  });
  assertEquals(res.status, 502);
  assertEquals(reconciled, false);
});

Deno.test("sync: new inventory remains protected behind service-role authorization", async () => {
  const res = await handler(request(), {
    db: dbWith({ data: null, error: null }),
    authorized: false,
    apiKey: "test-key",
  });
  assertEquals(res.status, 401);
});
