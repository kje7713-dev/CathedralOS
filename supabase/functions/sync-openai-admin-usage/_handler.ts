export type AdminUsageDb = {
  from(table: string): {
    upsert(rows: unknown[], options: { onConflict: string }): PromiseLike<{
      error: { message?: string; code?: string } | null;
    }>;
  };
};

export type AdminUsageDependencies = {
  db: AdminUsageDb;
  fetchImpl?: typeof fetch;
  authorized?: boolean;
  adminKey?: string;
  projectId?: string;
  now?: () => Date;
};

type JsonObject = Record<string, unknown>;
export type SyncWindow = { start: Date; end: Date };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const asObject = (value: unknown): JsonObject | null =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : null;

const asNumber = (value: unknown, fallback = 0): number =>
  typeof value === "number" && Number.isFinite(value)
    ? value
    : typeof value === "string" && value.trim() !== "" &&
        Number.isFinite(Number(value))
    ? Number(value)
    : fallback;

const asText = (value: unknown, fallback = ""): string =>
  typeof value === "string" ? value : fallback;

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  const object = asObject(value);
  if (!object) return JSON.stringify(value);
  return `{${
    Object.keys(object).sort().map((key) =>
      `${JSON.stringify(key)}:${stableJson(object[key])}`
    ).join(",")
  }}`;
}

async function hash(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(stableJson(value));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export function utcWindow(now: Date): SyncWindow {
  const end = new Date(now);
  end.setUTCHours(24, 0, 0, 0);
  const start = new Date(end);
  start.setUTCDate(start.getUTCDate() - 7);
  return { start, end };
}

function pageUrl(
  path: string,
  window: SyncWindow,
  projectId: string,
  page?: string,
): string {
  const url = new URL(`https://api.openai.com/v1/organization/${path}`);
  url.searchParams.set("bucket_width", "1d");
  url.searchParams.set(
    "start_time",
    String(Math.floor(window.start.getTime() / 1000)),
  );
  url.searchParams.set(
    "end_time",
    String(Math.floor(window.end.getTime() / 1000)),
  );
  url.searchParams.append("project_ids[]", projectId);
  url.searchParams.set("limit", "100");
  if (page) url.searchParams.set("page", page);
  if (path === "usage/completions") {
    for (const group of ["project_id", "model", "service_tier", "batch"]) {
      url.searchParams.append("group_by[]", group);
    }
  }
  return url.toString();
}

async function fetchPages(
  path: string,
  window: SyncWindow,
  projectId: string,
  adminKey: string,
  fetchImpl: typeof fetch,
): Promise<JsonObject[]> {
  const buckets: JsonObject[] = [];
  let page: string | undefined;
  for (let count = 0; count < 100; count++) {
    const response = await fetchImpl(pageUrl(path, window, projectId, page), {
      headers: { Authorization: `Bearer ${adminKey}` },
    });
    if (!response.ok) throw new Error("provider_request_failed");
    const payload = asObject(await response.json());
    if (!payload || !Array.isArray(payload.data)) {
      throw new Error("provider_payload_invalid");
    }
    for (const item of payload.data) {
      const row = asObject(item);
      if (row) buckets.push(row);
    }
    if (payload.has_more !== true) return buckets;
    const next = asText(payload.next_page);
    if (!next) throw new Error("provider_pagination_invalid");
    page = next;
  }
  throw new Error("provider_pagination_limit");
}

function bucketTimes(
  bucket: JsonObject,
): { start: string; end: string; date: string } | null {
  const start = asNumber(bucket.start_time, NaN);
  const end = asNumber(bucket.end_time, NaN);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  const startDate = new Date(start * 1000);
  const endDate = new Date(end * 1000);
  if (Number.isNaN(startDate.getTime()) || Number.isNaN(endDate.getTime())) {
    return null;
  }
  return {
    start: startDate.toISOString(),
    end: endDate.toISOString(),
    date: startDate.toISOString().slice(0, 10),
  };
}

export async function parseCostRows(
  buckets: JsonObject[],
  projectId: string,
  syncedAt: string,
): Promise<JsonObject[]> {
  const rows: JsonObject[] = [];
  for (const bucket of buckets) {
    const times = bucketTimes(bucket);
    if (!times || !Array.isArray(bucket.result)) continue;
    for (const raw of bucket.result) {
      const result = asObject(raw);
      if (!result) continue;
      const amount = asObject(result.amount) ?? {};
      rows.push({
        bucket_start: times.start,
        bucket_end: times.end,
        bucket_date: times.date,
        project_id: asText(result.project_id, projectId),
        line_item: asText(result.line_item),
        amount_value: asNumber(amount.value, NaN),
        amount_currency: asText(amount.currency, "usd").toLowerCase(),
        quantity: result.quantity == null
          ? null
          : asNumber(result.quantity, NaN),
        quantity_unit: result.quantity_unit == null
          ? null
          : asText(result.quantity_unit),
        synced_at: syncedAt,
        source: "openai_organization_costs_api",
        source_result_hash: await hash(result),
        raw_metadata: result,
      });
    }
  }
  return rows.filter((row) => Number.isFinite(row.amount_value as number));
}

export async function parseUsageRows(
  buckets: JsonObject[],
  projectId: string,
  syncedAt: string,
): Promise<JsonObject[]> {
  const rows: JsonObject[] = [];
  for (const bucket of buckets) {
    const times = bucketTimes(bucket);
    if (!times || !Array.isArray(bucket.result)) continue;
    for (const raw of bucket.result) {
      const result = asObject(raw);
      if (!result) continue;
      rows.push({
        bucket_start: times.start,
        bucket_end: times.end,
        bucket_date: times.date,
        project_id: asText(result.project_id, projectId),
        model: asText(result.model),
        service_tier: asText(result.service_tier),
        batch: asText(result.batch),
        num_model_requests: Math.trunc(asNumber(result.num_model_requests)),
        input_tokens: Math.trunc(asNumber(result.input_tokens)),
        input_uncached_tokens: Math.trunc(
          asNumber(result.input_uncached_tokens),
        ),
        input_cached_tokens: Math.trunc(asNumber(result.input_cached_tokens)),
        input_cache_write_tokens: Math.trunc(
          asNumber(result.input_cache_write_tokens),
        ),
        output_tokens: Math.trunc(asNumber(result.output_tokens)),
        synced_at: syncedAt,
        source: "openai_organization_usage_completions_api",
        source_result_hash: await hash(result),
      });
    }
  }
  return rows;
}

async function upsert(
  db: AdminUsageDb,
  table: string,
  rows: JsonObject[],
  onConflict: string,
): Promise<void> {
  if (rows.length === 0) return;
  const { error } = await db.from(table).upsert(rows, { onConflict });
  if (error) throw new Error("database_upsert_failed");
}

export async function handler(
  req: Request,
  deps: AdminUsageDependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  if (req.method !== "POST") {
    return json({ errorCode: "method_not_allowed" }, 405);
  }
  if (!deps.authorized) return json({ errorCode: "unauthenticated" }, 401);
  if (!deps.adminKey) return json({ errorCode: "admin_key_missing" }, 500);
  if (!deps.projectId) return json({ errorCode: "project_id_missing" }, 500);

  const now = (deps.now ?? (() => new Date()))();
  const window = utcWindow(now);
  const syncedAt = now.toISOString();
  const fetchImpl = deps.fetchImpl ?? fetch;
  try {
    // Fetch the complete window before writing either table. A provider error
    // therefore preserves the previously converged rows.
    const [costBuckets, usageBuckets] = await Promise.all([
      fetchPages("costs", window, deps.projectId, deps.adminKey, fetchImpl),
      fetchPages(
        "usage/completions",
        window,
        deps.projectId,
        deps.adminKey,
        fetchImpl,
      ),
    ]);
    const [costRows, usageRows] = await Promise.all([
      parseCostRows(costBuckets, deps.projectId, syncedAt),
      parseUsageRows(usageBuckets, deps.projectId, syncedAt),
    ]);
    await upsert(
      deps.db,
      "openai_daily_costs",
      costRows,
      "bucket_start,bucket_end,bucket_date,project_id,line_item,amount_currency,source",
    );
    await upsert(
      deps.db,
      "openai_daily_completion_usage",
      usageRows,
      "bucket_start,bucket_end,bucket_date,project_id,model,service_tier,batch,source",
    );
    return json({
      status: "complete",
      window_start: window.start.toISOString(),
      window_end: window.end.toISOString(),
      costs_upserted: costRows.length,
      usage_upserted: usageRows.length,
    });
  } catch (error) {
    const code =
      error instanceof Error && error.message === "provider_payload_invalid"
        ? "provider_payload_invalid"
        : error instanceof Error &&
            error.message === "provider_pagination_invalid"
        ? "provider_pagination_invalid"
        : error instanceof Error && error.message === "database_upsert_failed"
        ? "database_upsert_failed"
        : "provider_request_failed";
    return json(
      { errorCode: code },
      code === "database_upsert_failed" ? 500 : 502,
    );
  }
}
