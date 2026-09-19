export type AdminUsageDb = {
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): PromiseLike<{
    data: unknown;
    error: { message?: string; code?: string } | null;
  }>;
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

const COST_SOURCE = "openai_organization_costs_api";
const USAGE_SOURCE = "openai_organization_usage_completions_api";

class ProviderPayloadError extends Error {
  constructor() {
    super("provider_payload_invalid");
  }
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const asObject = (value: unknown): JsonObject | null =>
  value && typeof value === "object" && !Array.isArray(value)
    ? value as JsonObject
    : null;

function requiredNumber(value: unknown): number {
  const number = typeof value === "number"
    ? value
    : typeof value === "string" && value.trim() !== ""
    ? Number(value)
    : NaN;
  if (!Number.isFinite(number)) throw new ProviderPayloadError();
  return number;
}

function optionalNumber(value: unknown): number {
  if (value == null) return 0;
  return requiredNumber(value);
}

function requiredText(value: unknown): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new ProviderPayloadError();
  }
  return value;
}

const optionalText = (value: unknown): string =>
  typeof value === "string" ? value : "";

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
  start.setUTCDate(start.getUTCDate() - 8);
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
      if (!row) throw new Error("provider_payload_invalid");
      buckets.push(row);
    }
    if (payload.has_more !== true) return buckets;
    const next = optionalText(payload.next_page);
    if (!next) throw new Error("provider_pagination_invalid");
    page = next;
  }
  throw new Error("provider_pagination_limit");
}

function bucketTimes(
  bucket: JsonObject,
): { start: string; end: string; date: string } {
  const start = requiredNumber(bucket.start_time);
  const end = requiredNumber(bucket.end_time);
  const startDate = new Date(start * 1000);
  const endDate = new Date(end * 1000);
  if (
    Number.isNaN(startDate.getTime()) || Number.isNaN(endDate.getTime()) ||
    endDate <= startDate
  ) throw new ProviderPayloadError();
  return {
    start: startDate.toISOString(),
    end: endDate.toISOString(),
    date: startDate.toISOString().slice(0, 10),
  };
}

function results(bucket: JsonObject): unknown[] {
  if (!Object.prototype.hasOwnProperty.call(bucket, "results")) {
    throw new ProviderPayloadError();
  }
  if (!Array.isArray(bucket.results)) throw new ProviderPayloadError();
  return bucket.results;
}

function projectValue(result: JsonObject, projectId: string): string {
  const value = result.project_id == null
    ? projectId
    : requiredText(result.project_id);
  if (value !== projectId) throw new ProviderPayloadError();
  return value;
}

export async function parseCostRows(
  buckets: JsonObject[],
  projectId: string,
  syncedAt: string,
): Promise<JsonObject[]> {
  const rows: JsonObject[] = [];
  for (const bucket of buckets) {
    const times = bucketTimes(bucket);
    for (const raw of results(bucket)) {
      const result = asObject(raw);
      if (!result) throw new ProviderPayloadError();
      const amount = asObject(result.amount);
      if (!amount) throw new ProviderPayloadError();
      const quantity = result.quantity == null
        ? null
        : requiredNumber(result.quantity);
      rows.push({
        bucket_start: times.start,
        bucket_end: times.end,
        bucket_date: times.date,
        project_id: projectValue(result, projectId),
        line_item: requiredText(result.line_item),
        amount_value: requiredNumber(amount.value),
        amount_currency: requiredText(amount.currency).toLowerCase(),
        quantity,
        quantity_unit: result.quantity_unit == null
          ? null
          : requiredText(result.quantity_unit),
        synced_at: syncedAt,
        source: COST_SOURCE,
        source_result_hash: await hash(result),
        raw_metadata: result,
      });
    }
  }
  return rows;
}

export async function parseUsageRows(
  buckets: JsonObject[],
  projectId: string,
  syncedAt: string,
): Promise<JsonObject[]> {
  const rows: JsonObject[] = [];
  for (const bucket of buckets) {
    const times = bucketTimes(bucket);
    for (const raw of results(bucket)) {
      const result = asObject(raw);
      if (!result) throw new ProviderPayloadError();
      rows.push({
        bucket_start: times.start,
        bucket_end: times.end,
        bucket_date: times.date,
        project_id: projectValue(result, projectId),
        model: optionalText(result.model),
        service_tier: optionalText(result.service_tier),
        batch: optionalText(result.batch),
        num_model_requests: Math.trunc(
          optionalNumber(result.num_model_requests),
        ),
        input_tokens: Math.trunc(optionalNumber(result.input_tokens)),
        input_uncached_tokens: Math.trunc(
          optionalNumber(result.input_uncached_tokens),
        ),
        input_cached_tokens: Math.trunc(
          optionalNumber(result.input_cached_tokens),
        ),
        input_cache_write_tokens: Math.trunc(
          optionalNumber(result.input_cache_write_tokens),
        ),
        output_tokens: Math.trunc(optionalNumber(result.output_tokens)),
        synced_at: syncedAt,
        source: USAGE_SOURCE,
        source_result_hash: await hash(result),
      });
    }
  }
  return rows;
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
    // Both complete provider responses are fetched and validated before the
    // single service-role RPC. A provider or database failure leaves both
    // tables at their previous converged state.
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
    const { data, error } = await deps.db.rpc(
      "reconcile_openai_admin_usage",
      {
        p_project_id: deps.projectId,
        p_window_start: window.start.toISOString(),
        p_window_end: window.end.toISOString(),
        p_cost_rows: costRows,
        p_usage_rows: usageRows,
      },
    );
    if (error) throw new Error("database_reconciliation_failed");
    const counts = asObject(data) ?? {};
    return json({
      status: "complete",
      window_start: window.start.toISOString(),
      window_end: window.end.toISOString(),
      costs_upserted: requiredNumber(counts.costs_upserted ?? costRows.length),
      usage_upserted: requiredNumber(counts.usage_upserted ?? usageRows.length),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    const code = message === "provider_payload_invalid"
      ? "provider_payload_invalid"
      : message === "provider_pagination_invalid"
      ? "provider_pagination_invalid"
      : message === "database_reconciliation_failed"
      ? "database_reconciliation_failed"
      : "provider_request_failed";
    return json(
      { errorCode: code },
      code === "database_reconciliation_failed" ? 500 : 502,
    );
  }
}
