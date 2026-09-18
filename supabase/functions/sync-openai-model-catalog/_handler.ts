export interface CatalogSyncDb {
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{
    data: unknown;
    error: { message?: string; code?: string } | null;
  }>;
}

export interface OpenAIModelRecord {
  id: string;
  created?: number;
  owned_by?: string;
}

export interface CatalogSyncDependencies {
  db: CatalogSyncDb;
  fetchImpl?: typeof fetch;
  authorized?: boolean;
  apiKey?: string;
  now?: () => Date;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function parseModels(payload: unknown): OpenAIModelRecord[] | null {
  if (!payload || typeof payload !== "object") return null;
  const data = (payload as { data?: unknown }).data;
  if (!Array.isArray(data) || data.length === 0) return null;
  const models: OpenAIModelRecord[] = [];
  for (const item of data) {
    if (!item || typeof item !== "object") return null;
    const row = item as Record<string, unknown>;
    if (typeof row.id !== "string" || row.id.trim() === "") return null;
    if (
      row.created != null &&
      (typeof row.created !== "number" || !Number.isFinite(row.created))
    ) {
      return null;
    }
    if (row.owned_by != null && typeof row.owned_by !== "string") return null;
    models.push({
      id: row.id.trim(),
      ...(row.created == null ? {} : { created: row.created }),
      ...(row.owned_by == null ? {} : { owned_by: row.owned_by }),
    });
  }
  const ids = new Set(models.map((model) => model.id));
  return ids.size === models.length ? models : null;
}

async function startSyncRun(
  db: CatalogSyncDb,
  startedAt: string,
): Promise<string | null> {
  const { data, error } = await db.rpc("start_openai_model_sync_run", {
    p_started_at: startedAt,
  });
  if (error || typeof data !== "string" || data.length === 0) return null;
  return data;
}

async function finishSyncRun(
  db: CatalogSyncDb,
  runId: string,
  status: "complete" | "failed",
  counters: Record<string, number> = {},
  errorCode: string | null = null,
): Promise<void> {
  await db.rpc("finish_openai_model_sync_run", {
    p_run_id: runId,
    p_status: status,
    p_models_seen: counters.models_seen ?? 0,
    p_models_inserted: counters.models_inserted ?? 0,
    p_models_marked_available: counters.models_marked_available ?? 0,
    p_models_marked_unavailable: counters.models_marked_unavailable ?? 0,
    p_error_code: errorCode,
    p_sanitized_error: errorCode,
  });
}

export async function handler(
  req: Request,
  deps: CatalogSyncDependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  if (req.method !== "POST") {
    return json({ errorCode: "method_not_allowed" }, 405);
  }
  if (!deps.authorized) return json({ errorCode: "unauthenticated" }, 401);
  if (!deps.apiKey) return json({ errorCode: "backend_config_missing" }, 500);

  const startedAt = (deps.now ?? (() => new Date()))().toISOString();
  const runId = await startSyncRun(deps.db, startedAt);
  if (!runId) return json({ errorCode: "sync_run_start_failed" }, 500);
  const fail = async (errorCode: string, status: number) => {
    await finishSyncRun(deps.db, runId, "failed", {}, errorCode);
    return json({ errorCode }, status);
  };

  const fetchImpl = deps.fetchImpl ?? fetch;
  let response: Response;
  try {
    response = await fetchImpl("https://api.openai.com/v1/models", {
      headers: { Authorization: `Bearer ${deps.apiKey}` },
    });
  } catch {
    return fail("provider_fetch_failed", 502);
  }
  if (!response.ok) return fail("provider_fetch_failed", 502);

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return fail("provider_payload_invalid", 502);
  }
  const models = parseModels(payload);
  if (!models) {
    return fail(
      payload && typeof payload === "object" &&
        Array.isArray((payload as { data?: unknown }).data) &&
        (payload as { data: unknown[] }).data.length === 0
        ? "empty_inventory"
        : "provider_payload_invalid",
      502,
    );
  }

  const { data, error } = await deps.db.rpc("reconcile_openai_model_catalog", {
    p_run_id: runId,
    p_models: models,
    p_started_at: startedAt,
  });
  if (error) {
    await finishSyncRun(
      deps.db,
      runId,
      "failed",
      {},
      "catalog_reconciliation_failed",
    );
    return json({ errorCode: "catalog_reconciliation_failed" }, 500);
  }
  const counters = (data ?? {}) as Record<string, number>;
  await finishSyncRun(deps.db, runId, "complete", counters);
  return json({ status: "complete", ...counters });
}
