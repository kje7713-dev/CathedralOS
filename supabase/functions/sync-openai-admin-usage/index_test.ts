import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
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

type RpcCall = { name: string; args: Record<string, unknown> };
function db(calls: RpcCall[], failure = false): AdminUsageDb {
  return {
    rpc(name, args) {
      calls.push({ name, args });
      return Promise.resolve({
        data: { costs_upserted: 1, usage_upserted: 1 },
        error: failure ? { message: "secret db detail" } : null,
      });
    },
  };
}

function deps(
  calls: RpcCall[],
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

const bucket = (results: unknown[]) => ({
  start_time: 1726108800,
  end_time: 1726195200,
  results,
});

Deno.test("unauthorized requests stop before provider fetch or reconciliation", async () => {
  const calls: RpcCall[] = [];
  let requests = 0;
  const res = await handler(
    request(),
    deps(calls, () => {
      requests++;
      return Promise.reject(new Error("must not request"));
    }, { authorized: false }),
  );
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { errorCode: "unauthenticated" });
  assertEquals(requests, 0);
  assertEquals(calls.length, 0);
});

Deno.test("PR4 window is current UTC day plus previous seven UTC days", () => {
  const window = utcWindow(NOW);
  assertEquals(window.start.toISOString(), "2026-09-12T00:00:00.000Z");
  assertEquals(window.end.toISOString(), "2026-09-20T00:00:00.000Z");
  assertEquals(
    utcWindow(new Date("2026-01-01T00:01:00Z")).start.toISOString(),
    "2025-12-25T00:00:00.000Z",
  );
  assertEquals(
    utcWindow(new Date("2026-03-01T00:01:00Z")).start.toISOString(),
    "2026-02-22T00:00:00.000Z",
  );
});

Deno.test("PR4 parses representative Costs data[].results[] and preserves decimals", async () => {
  const rows = await parseCostRows(
    [bucket([{
      project_id: "proj-test",
      line_item: "gpt-5.6-luna",
      amount: { value: "0.123456789", currency: "USD" },
      quantity: "12.5",
      quantity_unit: "tokens",
    }])],
    "proj-test",
    NOW.toISOString(),
  );
  assertEquals(rows.length, 1);
  assertEquals(rows[0].amount_value, 0.123456789);
  assertEquals(rows[0].amount_currency, "usd");
  assertEquals(rows[0].line_item, "gpt-5.6-luna");
});

Deno.test("PR4 parses representative completions Usage data[].results[] including cache fields", async () => {
  const rows = await parseUsageRows(
    [bucket([{
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
    }])],
    "proj-test",
    NOW.toISOString(),
  );
  assertEquals(rows.length, 1);
  assertEquals(rows[0].input_cached_tokens, 30);
  assertEquals(rows[0].input_cache_write_tokens, 5);
});

Deno.test("PR4 distinguishes valid empty results from missing or malformed results", async () => {
  assertEquals(
    (await parseCostRows([bucket([])], "proj-test", NOW.toISOString())).length,
    0,
  );
  await assertRejects(
    () =>
      parseCostRows(
        [{ ...bucket([]), results: undefined }],
        "proj-test",
        NOW.toISOString(),
      ),
    Error,
    "provider_payload_invalid",
  );
  await assertRejects(
    () =>
      parseUsageRows(
        [bucket([{ input_tokens: "not-a-number" }])],
        "proj-test",
        NOW.toISOString(),
      ),
    Error,
    "provider_payload_invalid",
  );
});

Deno.test("PR4 fails before provider request when credentials/config are missing", async () => {
  for (const option of [{ adminKey: "" }, { projectId: "" }]) {
    let requests = 0;
    const res = await handler(
      request(),
      deps([], () => {
        requests++;
        return Promise.reject(new Error("must not request"));
      }, option),
    );
    assertEquals(res.status, 500);
    assertEquals(requests, 0);
  }
});

Deno.test("PR4 fetches both real-shaped endpoints, paginates, and persists atomically through one RPC", async () => {
  const calls: RpcCall[] = [];
  const requests: string[] = [];
  const fetchImpl = (input: RequestInfo | URL) => {
    const url = String(input);
    requests.push(url);
    const isUsage = url.includes("usage/completions");
    const isNext = url.includes("page=next-page");
    const data = isUsage
      ? [
        bucket([{
          project_id: "proj-test",
          model: "gpt-5.6-luna",
          input_tokens: 1,
        }]),
      ]
      : [
        bucket([{
          project_id: "proj-test",
          line_item: "gpt-5.6-luna",
          amount: { value: "0.10", currency: "usd" },
        }]),
      ];
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
  assertEquals((await res.json()).window_start, "2026-09-12T00:00:00.000Z");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].name, "reconcile_openai_admin_usage");
  assertEquals(requests.length, 4);
  assertEquals(
    requests.every((url) =>
      new URL(url).searchParams.get("project_ids[]") === "proj-test"
    ),
    true,
  );
  assertEquals(
    requests.every((url) =>
      new URL(url).searchParams.get("start_time") === "1789171200"
    ),
    true,
  );
  assertEquals(
    requests.every((url) =>
      new URL(url).searchParams.get("end_time") === "1789862400"
    ),
    true,
  );
  const costsUrl = requests.find((url) => url.includes("/costs"))!;
  assertEquals(
    new URL(costsUrl).searchParams.get("project_ids[]"),
    "proj-test",
  );
  assertEquals(new URL(costsUrl).searchParams.get("limit"), "100");
  assertEquals(new URL(costsUrl).searchParams.getAll("group_by[]"), [
    "project_id",
    "line_item",
  ]);
  const usageUrl = requests.find((url) => url.includes("/usage/completions"))!;
  assertEquals(new URL(usageUrl).searchParams.get("limit"), "31");
  assertEquals(new URL(usageUrl).searchParams.getAll("group_by[]"), [
    "project_id",
    "model",
    "service_tier",
    "batch",
  ]);
});

Deno.test("PR4 rejects ungrouped null-line-item Costs before reconciliation", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(
    request(),
    deps(calls, (input) => {
      const isUsage = String(input).includes("usage/completions");
      const result = isUsage
        ? { project_id: "proj-test", model: "gpt-5.6-luna", input_tokens: 1 }
        : {
          project_id: null,
          line_item: null,
          amount: { value: "0.10", currency: "usd" },
        };
      return Promise.resolve(
        new Response(
          JSON.stringify({ data: [bucket([result])], has_more: false }),
          { status: 200 },
        ),
      );
    }),
  );
  assertEquals(res.status, 502);
  assertEquals(await res.json(), { errorCode: "provider_payload_invalid" });
  assertEquals(calls.length, 0);
});

Deno.test("PR4 provider failure and malformed payload do not call persistence", async () => {
  const calls: RpcCall[] = [];
  const failed = await handler(
    request(),
    deps(calls, () => Promise.resolve(new Response("no", { status: 503 }))),
  );
  assertEquals(failed.status, 502);
  assertEquals(calls.length, 0);
  const malformed = await handler(
    request(),
    deps(calls, () =>
      Promise.resolve(
        new Response(
          JSON.stringify({ data: [bucket([{ amount: { value: "bad" } }])] }),
          { status: 200 },
        ),
      )),
  );
  assertEquals(malformed.status, 502);
  assertEquals(await malformed.json(), {
    errorCode: "provider_payload_invalid",
  });
  assertEquals(calls.length, 0);
});

Deno.test("PR4 database failure is sanitized after one atomic persistence attempt", async () => {
  const calls: RpcCall[] = [];
  const res = await handler(request(), {
    ...deps(calls, (input) => {
      const isUsage = String(input).includes("usage/completions");
      const result = isUsage
        ? { project_id: "proj-test", model: "gpt-5.6-luna", input_tokens: 1 }
        : {
          project_id: "proj-test",
          line_item: "gpt-5.6-luna",
          amount: { value: "0.10", currency: "usd" },
        };
      return Promise.resolve(
        new Response(
          JSON.stringify({ data: [bucket([result])], has_more: false }),
          { status: 200 },
        ),
      );
    }),
    db: db(calls, true),
  });
  assertEquals(res.status, 500);
  assertEquals(await res.json(), {
    errorCode: "database_reconciliation_failed",
  });
  assertEquals(calls.length, 1);
});

Deno.test("PR4 operator refresh sends an empty result set to remove stale provider groupings", async () => {
  const calls: RpcCall[] = [];
  const empty = () =>
    Promise.resolve(
      new Response(JSON.stringify({ data: [bucket([])], has_more: false }), {
        status: 200,
      }),
    );
  await handler(request(), deps(calls, empty));
  assertEquals((calls[0].args.p_cost_rows as unknown[]).length, 0);
  assertEquals((calls[0].args.p_usage_rows as unknown[]).length, 0);
});
