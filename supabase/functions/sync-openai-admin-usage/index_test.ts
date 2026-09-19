import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  type AdminUsageDb,
  handler,
  parseCostRows,
  parseUsageRows,
  utcWindow,
} from "./_handler.ts";

const NOW = new Date("2026-09-19T12:34:56Z");
const request = () =>
  new Request("https://test.example/sync", { method: "POST" });

type Call = { table: string; rows: unknown[]; onConflict: string };
function db(calls: Call[], failure = false): AdminUsageDb {
  return {
    from(table) {
      return {
        upsert(rows, options) {
          calls.push({ table, rows, onConflict: options.onConflict });
          return Promise.resolve({
            error: failure ? { message: "secret db detail" } : null,
          });
        },
      };
    },
  };
}

function deps(
  calls: Call[],
  fetchImpl: typeof fetch,
  options: Partial<Parameters<typeof handler>[1]> = {},
) {
  return {
    db: db(calls),
    authorized: true,
    adminKey: "admin-secret",
    projectId: "proj-test",
    now: () => NOW,
    fetchImpl,
    ...options,
  } as Parameters<typeof handler>[1];
}

Deno.test("PR4 UTC window refreshes current day plus previous seven days", () => {
  const window = utcWindow(NOW);
  assertEquals(window.start.toISOString(), "2026-09-13T00:00:00.000Z");
  assertEquals(window.end.toISOString(), "2026-09-20T00:00:00.000Z");
});

Deno.test("PR4 cost parser preserves decimal amount and provider identity", async () => {
  const rows = await parseCostRows(
    [{
      start_time: 1726108800,
      end_time: 1726195200,
      result: [{
        project_id: "proj-test",
        line_item: "gpt-5.6-luna",
        amount: { value: "0.123456789", currency: "USD" },
        quantity: "12.5",
        quantity_unit: "tokens",
      }],
    }],
    "proj-test",
    NOW.toISOString(),
  );
  assertEquals(rows[0].amount_value, 0.123456789);
  assertEquals(rows[0].amount_currency, "usd");
  assertEquals(rows[0].line_item, "gpt-5.6-luna");
  assertEquals(typeof rows[0].source_result_hash, "string");
});

Deno.test("PR4 usage parser persists model grouping and cached/cache-write tokens", async () => {
  const rows = await parseUsageRows(
    [{
      start_time: 1726108800,
      end_time: 1726195200,
      result: [{
        project_id: "proj-test",
        model: "gpt-5.6-luna",
        service_tier: "default",
        batch: null,
        num_model_requests: 3,
        input_tokens: 100,
        input_uncached_tokens: 70,
        input_cached_tokens: 30,
        input_cache_write_tokens: 5,
        output_tokens: 40,
      }],
    }],
    "proj-test",
    NOW.toISOString(),
  );
  assertEquals(rows[0].model, "gpt-5.6-luna");
  assertEquals(rows[0].service_tier, "default");
  assertEquals(rows[0].batch, "");
  assertEquals(rows[0].input_cached_tokens, 30);
  assertEquals(rows[0].input_cache_write_tokens, 5);
});

Deno.test("PR4 missing admin key fails before any provider request", async () => {
  let requests = 0;
  const res = await handler(
    request(),
    deps([], () => {
      requests++;
      return Promise.reject(new Error("must not request"));
    }, { adminKey: "" }),
  );
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { errorCode: "admin_key_missing" });
  assertEquals(requests, 0);
});

Deno.test("PR4 missing project ID fails closed before any provider request", async () => {
  let requests = 0;
  const res = await handler(
    request(),
    deps([], () => {
      requests++;
      return Promise.reject(new Error("must not request"));
    }, { projectId: "" }),
  );
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { errorCode: "project_id_missing" });
  assertEquals(requests, 0);
});

Deno.test("PR4 paginates costs and usage then upserts both tables", async () => {
  const calls: Call[] = [];
  const requests: string[] = [];
  const fetchImpl = (input: RequestInfo | URL) => {
    const url = String(input);
    requests.push(url);
    const isUsage = url.includes("usage/completions");
    const isNext = url.includes("page=next-page");
    const data = isUsage
      ? [{
        start_time: 1726108800,
        end_time: 1726195200,
        result: [{ model: "gpt-5.6-luna", input_tokens: 1 }],
      }]
      : [{
        start_time: 1726108800,
        end_time: 1726195200,
        result: [{ amount: { value: "0.10", currency: "usd" } }],
      }];
    return Promise.resolve(
      new Response(
        JSON.stringify({
          data,
          has_more: !isNext,
          next_page: isNext ? null : "next-page",
        }),
        { status: 200 },
      ),
    );
  };
  const res = await handler(request(), deps(calls, fetchImpl));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.costs_upserted, 2);
  assertEquals(calls.map((call) => call.table), [
    "openai_daily_costs",
    "openai_daily_completion_usage",
  ]);
  assertEquals(requests.length, 4);
  assertEquals(
    requests.every((url) => url.includes("project_ids%5B%5D=proj-test")),
    true,
  );
  assertEquals(requests.every((url) => url.includes("bucket_width=1d")), true);
});

Deno.test("PR4 provider error preserves existing data by not upserting", async () => {
  const calls: Call[] = [];
  const res = await handler(
    request(),
    deps(calls, () => Promise.resolve(new Response("no", { status: 503 }))),
  );
  assertEquals(res.status, 502);
  assertEquals(await res.json(), { errorCode: "provider_request_failed" });
  assertEquals(calls.length, 0);
});

Deno.test("PR4 database error is sanitized", async () => {
  const calls: Call[] = [];
  const failingDb = db(calls, true);
  const res = await handler(request(), {
    ...deps(
      calls,
      (input) => {
        const isUsage = String(input).includes("usage/completions");
        const result = isUsage
          ? { model: "gpt-5.6-luna", input_tokens: 1 }
          : { amount: { value: "0.10", currency: "usd" } };
        return Promise.resolve(
          new Response(
            JSON.stringify({
              data: [{
                start_time: 1726108800,
                end_time: 1726195200,
                result: [result],
              }],
              has_more: false,
            }),
            { status: 200 },
          ),
        );
      },
    ),
    db: failingDb,
  });
  assertEquals(res.status, 500);
  assertEquals(await res.json(), { errorCode: "database_upsert_failed" });
});

Deno.test("PR4 rejects malformed provider pagination", async () => {
  const calls: Call[] = [];
  const res = await handler(
    request(),
    deps(calls, () =>
      Promise.resolve(
        new Response(JSON.stringify({ data: [], has_more: true }), {
          status: 200,
        }),
      )),
  );
  assertEquals(res.status, 502);
  assertEquals(await res.json(), { errorCode: "provider_pagination_invalid" });
  assertEquals(calls.length, 0);
});

Deno.test("PR4 unauthorized request does not reach provider", async () => {
  const res = await handler(
    request(),
    deps([], () => Promise.reject(new Error("must not request")), {
      authorized: false,
    }),
  );
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { errorCode: "unauthenticated" });
});
