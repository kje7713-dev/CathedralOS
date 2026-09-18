import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { type CatalogSyncDb, handler, parseModels } from "./_handler.ts";

const RUN_ID = "11111111-1111-4111-8111-111111111111";
const request = () =>
  new Request("https://test.example.com/sync-openai-model-catalog", {
    method: "POST",
  });

type RpcCall = { name: string; args: Record<string, unknown> };
type DbOptions = {
  reconcile?: { data: unknown; error: { message?: string } | null };
  finish?: { data: unknown; error: { message?: string } | null };
};
function testDb(options: DbOptions, calls: RpcCall[]): CatalogSyncDb {
  return {
    rpc: (name, args) => {
      calls.push({ name, args });
      if (name === "start_openai_model_sync_run") {
        return Promise.resolve({ data: RUN_ID, error: null });
      }
      if (name === "finish_openai_model_sync_run") {
        return Promise.resolve(options.finish ?? { data: null, error: null });
      }
      return Promise.resolve(options.reconcile ?? { data: null, error: null });
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

const validResponse = () =>
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
  );

Deno.test("parser accepts exact IDs and preserves them", () => {
  assertEquals(parseModels({ data: [{ id: "gpt-5.6-luna" }] }), [
    { id: "gpt-5.6-luna" },
  ]);
});

Deno.test("parser rejects leading or trailing whitespace in provider IDs", () => {
  assertEquals(parseModels({ data: [{ id: " gpt-5.6-luna" }] }), null);
  assertEquals(parseModels({ data: [{ id: "gpt-5.6-luna " }] }), null);
});

Deno.test("parser rejects duplicate provider IDs", () => {
  assertEquals(
    parseModels({ data: [{ id: "gpt-5.6-luna" }, { id: "gpt-5.6-luna" }] }),
    null,
  );
});

Deno.test("sync: successful reconciliation returns its atomic counters", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        reconcile: {
          data: {
            run_id: RUN_ID,
            models_seen: 2,
            models_inserted: 1,
            models_marked_available: 0,
            models_marked_unavailable: 0,
          },
          error: null,
        },
      }, calls),
      validResponse,
    ),
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    status: "complete",
    run_id: RUN_ID,
    models_seen: 2,
    models_inserted: 1,
    models_marked_available: 0,
    models_marked_unavailable: 0,
  });
  assertEquals(calls.map((call) => call.name), [
    "start_openai_model_sync_run",
    "reconcile_openai_model_catalog",
  ]);
  assertEquals(calls[1].args.p_run_id, RUN_ID);
});

Deno.test("sync: provider/network failure marks the started run failed", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({}, calls),
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

Deno.test("sync: failed-run finalization errors are reported safely", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        finish: { data: null, error: { message: "secret DB details" } },
      }, calls),
      () => Promise.reject(new Error("provider secret must not escape")),
    ),
  );
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { errorCode: "sync_run_finalize_failed" });
});

Deno.test("sync: malformed payload marks the started run failed before reconciliation", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({}, calls),
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
      testDb({}, calls),
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

Deno.test("sync: reconciliation failure marks the same run failed", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        reconcile: {
          data: null,
          error: { message: "database secrets must not escape" },
        },
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

Deno.test("sync: reconciliation finalization failure is not hidden", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(
      testDb({
        reconcile: { data: null, error: { message: "raw DB error" } },
        finish: { data: null, error: { message: "audit write failed" } },
      }, calls),
      validResponse,
    ),
  );
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { errorCode: "sync_run_finalize_failed" });
});

Deno.test("sync: service-role authorization remains required", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(request(), {
    db: testDb({}, calls),
    authorized: false,
    apiKey: "test-key",
  });
  assertEquals(res.status, 401);
  assertEquals(calls, []);
});
