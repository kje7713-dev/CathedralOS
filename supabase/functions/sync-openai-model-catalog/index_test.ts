import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { type CatalogSyncDb, handler } from "./_handler.ts";

const RUN_ID = "11111111-1111-4111-8111-111111111111";
const request = () =>
  new Request("https://test.example.com/sync-openai-model-catalog", {
    method: "POST",
  });

type RpcCall = { name: string; args: Record<string, unknown> };
function testDb(
  reconcile: { data: unknown; error: { message?: string } | null },
  calls: RpcCall[],
): CatalogSyncDb {
  return {
    rpc: (name, args) => {
      calls.push({ name, args });
      if (name === "start_openai_model_sync_run") {
        return Promise.resolve({ data: RUN_ID, error: null });
      }
      if (name === "finish_openai_model_sync_run") {
        return Promise.resolve({ data: null, error: null });
      }
      return Promise.resolve(reconcile);
    },
  };
}

const deps = (
  db: CatalogSyncDb,
  fetchImpl: typeof fetch,
): Parameters<typeof handler>[1] => ({
  db,
  authorized: true,
  apiKey: "test-key",
  now: () => new Date("2026-09-17T00:00:00Z"),
  fetchImpl,
});

Deno.test("sync: successful reconciliation finalizes the started run", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        data: {
          run_id: RUN_ID,
          models_seen: 2,
          models_inserted: 1,
          models_marked_available: 0,
          models_marked_unavailable: 0,
        },
        error: null,
      }, calls),
      () =>
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
    ),
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "complete");
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "reconcile_openai_model_catalog",
    "finish_openai_model_sync_run",
  ]);
  assertEquals(calls[1].args.p_run_id, RUN_ID);
  assertEquals(calls[2].args.p_status, "complete");
  assertEquals(calls[2].args.p_models_seen, 2);
});

Deno.test("sync: provider/network failure marks the started run failed", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({ data: null, error: null }, calls),
      () => Promise.reject(new Error("network details must not escape")),
    ),
  );
  assertEquals(res.status, 502);
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "finish_openai_model_sync_run",
  ]);
  assertEquals(calls[1].args.p_status, "failed");
  assertEquals(calls[1].args.p_error_code, "provider_fetch_failed");
  assertEquals(calls[1].args.p_sanitized_error, "provider_fetch_failed");
});

Deno.test("sync: malformed payload marks the started run failed before reconciliation", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({ data: null, error: null }, calls),
      () =>
        Promise.resolve(
          new Response(JSON.stringify({ data: [{ created: 1 }] }), {
            status: 200,
          }),
        ),
    ),
  );
  assertEquals(res.status, 502);
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "finish_openai_model_sync_run",
  ]);
  assertEquals(calls[1].args.p_error_code, "provider_payload_invalid");
});

Deno.test("sync: empty inventory fails and never calls reconciliation", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({ data: null, error: null }, calls),
      () =>
        Promise.resolve(
          new Response(JSON.stringify({ data: [] }), { status: 200 }),
        ),
    ),
  );
  assertEquals(res.status, 502);
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "finish_openai_model_sync_run",
  ]);
  assertEquals(calls[1].args.p_error_code, "empty_inventory");
});

Deno.test("sync: reconciliation RPC failure marks the same run failed", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        data: null,
        error: { message: "database secrets must not escape" },
      }, calls),
      () =>
        Promise.resolve(
          new Response(JSON.stringify({ data: [{ id: "gpt-4o-mini" }] }), {
            status: 200,
          }),
        ),
    ),
  );
  assertEquals(res.status, 500);
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "reconcile_openai_model_catalog",
    "finish_openai_model_sync_run",
  ]);
  assertEquals(calls[2].args.p_run_id, RUN_ID);
  assertEquals(calls[2].args.p_error_code, "catalog_reconciliation_failed");
});

Deno.test("sync: new inventory remains protected behind service-role authorization", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(request(), {
    db: testDb({ data: null, error: null }, calls),
    authorized: false,
    apiKey: "test-key",
  });
  assertEquals(res.status, 401);
  assertEquals(calls, []);
});
