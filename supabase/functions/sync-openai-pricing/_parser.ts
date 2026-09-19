export type PricingObservationStatus =
  | "verified"
  | "incomplete"
  | "conflict"
  | "fetch_failed"
  | "unsupported";

export interface ParsedPricing {
  provider_model: string;
  status: PricingObservationStatus;
  input_usd_per_1m: number | null;
  cached_input_usd_per_1m: number | null;
  cache_write_usd_per_1m: number | null;
  output_usd_per_1m: number | null;
  long_context_threshold_tokens: number | null;
  long_context_input_multiplier: number | null;
  long_context_output_multiplier: number | null;
  error_code: string | null;
}

const DETAIL_ID = /^Model ID:\s*`([^`]+)`\s*$/m;
const MONEY = /^\$\s*([0-9]+(?:\.[0-9]+)?)$/;

function numberFromMoney(value: string): number | null {
  const match = value.trim().match(MONEY);
  if (!match) return null;
  const parsed = Number(match[1]);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function section(markdown: string, heading: string): string | null {
  const start = markdown.search(new RegExp(`^###\\s+${heading}\\s*$`, "mi"));
  if (start < 0) return null;
  const rest = markdown.slice(start);
  const next = rest.search(/^###\s+/mi);
  return next > 0 ? rest.slice(0, next) : rest;
}

function rows(markdown: string): Map<string, string[]> {
  const result = new Map<string, string[]>();
  for (const line of markdown.split(/\r?\n/)) {
    const match = line.match(/^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|/);
    if (!match || /^-+$/.test(match[1].trim())) continue;
    const label = match[1].trim().toLowerCase();
    const values = result.get(label) ?? [];
    values.push(match[2].trim());
    result.set(label, values);
  }
  return result;
}

function oneRate(
  table: Map<string, string[]>,
  labels: RegExp[],
): number | null {
  const matches = [...table.entries()]
    .filter(([label]) => labels.some((pattern) => pattern.test(label.trim())))
    .flatMap(([, values]) => values);
  if (matches.length !== 1) return null;
  return numberFromMoney(matches[0]);
}

function longContext(
  markdown: string,
): Pick<
  ParsedPricing,
  | "long_context_threshold_tokens"
  | "long_context_input_multiplier"
  | "long_context_output_multiplier"
> {
  const match = markdown.match(
    /(?:over|above|>)\s*([\d,]+)\s*K[^\n]*?(?:input\s*)?([0-9]+(?:\.[0-9]+)?)x?[^\n]*?(?:output\s*)?([0-9]+(?:\.[0-9]+)?)x?/i,
  );
  if (!match) {
    return {
      long_context_threshold_tokens: null,
      long_context_input_multiplier: null,
      long_context_output_multiplier: null,
    };
  }
  const threshold = Number(match[1].replaceAll(",", "")) * 1000;
  const input = Number(match[2]);
  const output = Number(match[3]);
  return {
    long_context_threshold_tokens: Number.isFinite(threshold)
      ? threshold
      : null,
    long_context_input_multiplier: Number.isFinite(input) ? input : null,
    long_context_output_multiplier: Number.isFinite(output) ? output : null,
  };
}

export function parseOfficialPricing(
  markdown: string,
  expectedModel: string,
): ParsedPricing {
  const base: ParsedPricing = {
    provider_model: expectedModel,
    status: "incomplete",
    input_usd_per_1m: null,
    cached_input_usd_per_1m: null,
    cache_write_usd_per_1m: null,
    output_usd_per_1m: null,
    ...longContext(markdown),
    error_code: null,
  };
  const identity = markdown.match(DETAIL_ID)?.[1];
  if (identity !== expectedModel) {
    return { ...base, status: "unsupported", error_code: "wrong_model" };
  }
  const textTokens = section(markdown, "Text tokens");
  if (!textTokens) {
    return { ...base, error_code: "text_pricing_section_missing" };
  }
  const table = rows(textTokens);
  const input = oneRate(table, [/^input$/]);
  const cached = oneRate(table, [/^cached input$/]);
  const output = oneRate(table, [/^output$/]);
  const cacheWrite = oneRate(table, [/cache\s*write/]);
  if (input == null || cached == null || output == null) {
    return { ...base, error_code: "required_rate_missing" };
  }
  return {
    ...base,
    status: "verified",
    input_usd_per_1m: input,
    cached_input_usd_per_1m: cached,
    output_usd_per_1m: output,
    cache_write_usd_per_1m: cacheWrite,
  };
}

export function reconcileOfficialPricingSources(
  primary: ParsedPricing,
  secondary: ParsedPricing | null,
): ParsedPricing {
  if (!secondary || secondary.status !== "verified") return primary;
  const fields: (keyof ParsedPricing)[] = [
    "input_usd_per_1m",
    "cached_input_usd_per_1m",
    "cache_write_usd_per_1m",
    "output_usd_per_1m",
  ];
  const disagreement = fields.some((field) => {
    const left = primary[field];
    const right = secondary[field];
    return left != null && right != null && left !== right;
  });
  return disagreement
    ? { ...primary, status: "conflict", error_code: "official_source_conflict" }
    : primary;
}
