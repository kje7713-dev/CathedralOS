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
  if (!Array.isArray(data)) return null;
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

  const fetchImpl = deps.fetchImpl ?? fetch;
  const startedAt = (deps.now ?? (() => new Date()))().toISOString();
  let response: Response;
  try {
    response = await fetchImpl("https://api.openai.com/v1/models", {
      headers: { Authorization: `Bearer ${deps.apiKey}` },
    });
  } catch {
    return json({ errorCode: "provider_fetch_failed" }, 502);
  }
  if (!response.ok) return json({ errorCode: "provider_fetch_failed" }, 502);

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    return json({ errorCode: "provider_payload_invalid" }, 502);
  }
  const models = parseModels(payload);
  if (!models) return json({ errorCode: "provider_payload_invalid" }, 502);

  const { data, error } = await deps.db.rpc("reconcile_openai_model_catalog", {
    p_models: models,
    p_started_at: startedAt,
  });
  if (error) return json({ errorCode: "catalog_reconciliation_failed" }, 500);
  return json({ status: "complete", ...((data ?? {}) as object) });
}
