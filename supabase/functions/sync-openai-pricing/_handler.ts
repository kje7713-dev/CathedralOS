import {
  normalizedPricingEvidence,
  type ParsedPricing,
  parseOfficialPricing,
} from "./_parser.ts";

export interface PricingSyncDb {
  from(table: string): any;
  rpc(name: string, args: Record<string, unknown>): PromiseLike<{
    data: unknown;
    error: { message?: string; code?: string } | null;
  }>;
}

interface CatalogModel {
  provider_model: string;
  cache_write_pricing_required: boolean;
}

export interface PricingSyncDependencies {
  db: PricingSyncDb;
  authorized?: boolean;
  fetchImpl?: typeof fetch;
  now?: () => Date;
  models?: Array<string | CatalogModel>;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function officialUrl(providerModel: string): string | null {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(providerModel)) return null;
  return `https://developers.openai.com/api/docs/models/${
    encodeURIComponent(providerModel)
  }.md`;
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function catalogModels(db: PricingSyncDb): Promise<CatalogModel[]> {
  const { data, error } = await db.from("generation_models")
    .select("provider_model, cache_write_pricing_required")
    .eq("provider", "openai")
    .eq("model_kind", "text_generation");
  if (error || !Array.isArray(data)) throw new Error("catalog_lookup_failed");
  return [
    ...new Map(
      data
        .map((row: Record<string, unknown>) => {
          const providerModel = String(row.provider_model ?? "");
          return [
            providerModel,
            {
              provider_model: providerModel,
              cache_write_pricing_required:
                row.cache_write_pricing_required === true,
            } satisfies CatalogModel,
          ] as const;
        })
        .filter(([providerModel]) => providerModel),
    ).values(),
  ];
}

function observationPayload(
  parsed: ParsedPricing,
  observedAt: string,
  sourceUrl: string,
  sourceHash: string,
  evidenceHash: string,
): Record<string, unknown> {
  return {
    provider_model: parsed.provider_model,
    observed_at: observedAt,
    source_url: sourceUrl,
    source_hash: sourceHash,
    normalized_evidence_hash: evidenceHash,
    parser_version: "pricing-page-markdown-v2",
    status: parsed.status,
    input_usd_per_1m: parsed.input_usd_per_1m,
    cached_input_usd_per_1m: parsed.cached_input_usd_per_1m,
    cache_write_usd_per_1m: parsed.cache_write_usd_per_1m,
    output_usd_per_1m: parsed.output_usd_per_1m,
    long_context_threshold_tokens: parsed.long_context_threshold_tokens,
    long_context_input_multiplier: parsed.long_context_input_multiplier,
    long_context_output_multiplier: parsed.long_context_output_multiplier,
    error_code: parsed.error_code,
    sanitized_error: parsed.error_code,
  };
}

export async function handler(
  req: Request,
  deps: PricingSyncDependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  if (req.method !== "POST") {
    return json({ errorCode: "method_not_allowed" }, 405);
  }
  if (!deps.authorized) return json({ errorCode: "unauthenticated" }, 401);

  const now = (deps.now ?? (() => new Date()))().toISOString();
  let models: CatalogModel[];
  try {
    models = deps.models
      ? deps.models.map((model) =>
        typeof model === "string"
          ? { provider_model: model, cache_write_pricing_required: false }
          : model
      )
      : await catalogModels(deps.db);
  } catch {
    return json({ errorCode: "catalog_lookup_failed" }, 500);
  }
  if (models.length === 0) return json({ errorCode: "empty_catalog" }, 422);

  const fetchImpl = deps.fetchImpl ?? fetch;
  const counters = {
    models_seen: models.length,
    verified: 0,
    failed: 0,
    promoted: 0,
  };
  for (const model of models) {
    const providerModel = model.provider_model;
    const sourceUrl = officialUrl(providerModel);
    let parsed: ParsedPricing;
    let body = "";
    if (!sourceUrl) {
      parsed = {
        provider_model: providerModel,
        status: "unsupported",
        input_usd_per_1m: null,
        cached_input_usd_per_1m: null,
        cache_write_usd_per_1m: null,
        output_usd_per_1m: null,
        long_context_threshold_tokens: null,
        long_context_input_multiplier: null,
        long_context_output_multiplier: null,
        error_code: "provider_model_unsupported",
      };
    } else {
      try {
        const response = await fetchImpl(sourceUrl);
        body = await response.text();
        parsed = response.ok
          ? parseOfficialPricing(
            body,
            providerModel,
            model.cache_write_pricing_required,
          )
          : {
            ...parseOfficialPricing(
              "",
              providerModel,
              model.cache_write_pricing_required,
            ),
            status: "fetch_failed",
            error_code: "official_page_fetch_failed",
          };
      } catch {
        parsed = {
          ...parseOfficialPricing(
            "",
            providerModel,
            model.cache_write_pricing_required,
          ),
          status: "fetch_failed",
          error_code: "official_page_fetch_failed",
        };
      }
    }
    const sourceHash = await sha256(body);
    const evidenceHash = await sha256(normalizedPricingEvidence(parsed));
    try {
      const { data, error } = await deps.db.rpc(
        "record_openai_pricing_observation",
        {
          p_observation: observationPayload(
            parsed,
            now,
            sourceUrl ?? "",
            sourceHash,
            evidenceHash,
          ),
        },
      );
      if (error) throw new Error("observation_write_failed");
      const result = (data ?? {}) as Record<string, unknown>;
      if (parsed.status === "verified") counters.verified += 1;
      else counters.failed += 1;
      if (result.promoted === true) counters.promoted += 1;
    } catch {
      return json({ errorCode: "observation_write_failed", ...counters }, 500);
    }
  }
  return json({ status: "complete", ...counters });
}
