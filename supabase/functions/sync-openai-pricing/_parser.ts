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

const MONEY = /^\$\s*([0-9]+(?:\.[0-9]+)?)$/;
const MODEL_ID = /^Model ID:\s*`?([^`\s]+)`?\s*$/m;

type Table = { headers: string[]; rows: string[][] };

function numberFromMoney(value: string): number | null {
  const match = value.trim().match(MONEY);
  if (!match) return null;
  const parsed = Number(match[1]);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function section(markdown: string, heading: string): string | null {
  const headingPattern = new RegExp(
    `^(#{1,3})\\s+${heading}\\s*$`,
    "mi",
  );
  const match = markdown.match(headingPattern);
  if (!match || match.index == null) return null;
  const level = match[1].length;
  const contentStart = match.index + match[0].length;
  const rest = markdown.slice(contentStart);
  const next = rest.search(new RegExp(`^#{1,${level}}\\s+`, "mi"));
  return next >= 0 ? rest.slice(0, next) : rest;
}

function tables(markdown: string): Table[] {
  const lines = markdown.split(/\r?\n/);
  const result: Table[] = [];
  for (let index = 0; index < lines.length - 1; index += 1) {
    const header = lines[index].match(/^\|(.+)\|\s*$/);
    const separator = lines[index + 1].match(/^\|(?:\s*:?-+:?\s*\|)+\s*$/);
    if (!header || !separator) continue;
    const headers = header[1].split("|").map((cell) =>
      cell.trim().toLowerCase()
    );
    const rows: string[][] = [];
    for (let rowIndex = index + 2; rowIndex < lines.length; rowIndex += 1) {
      const row = lines[rowIndex].match(/^\|(.+)\|\s*$/);
      if (!row) break;
      rows.push(row[1].split("|").map((cell) => cell.trim()));
    }
    result.push({ headers, rows });
  }
  return result;
}

function rateFromTable(
  table: Table,
  metric: string,
): {
  value: number | null;
  found: boolean;
  conflict: boolean;
  unitValid: boolean;
} {
  const metricIndex = table.headers.indexOf("metric");
  const priceIndex = table.headers.indexOf("price");
  const unitIndex = table.headers.indexOf("unit");
  if (metricIndex < 0 || priceIndex < 0 || unitIndex < 0) {
    return { value: null, found: false, conflict: false, unitValid: false };
  }
  const rows = table.rows
    .filter((row) => row[metricIndex]?.trim().toLowerCase() === metric);
  if (rows.length === 0) {
    return { value: null, found: false, conflict: false, unitValid: true };
  }
  const values = rows.map((row) => numberFromMoney(row[priceIndex] ?? ""));
  const units = rows.map((row) =>
    row[unitIndex]?.trim().toLowerCase().replace(/\s+/g, " ")
  );
  const unitValid = units.every((unit) =>
    /^(?:per )?1m tokens?$/.test(unit ?? "")
  );
  if (!unitValid || values.some((value) => value == null)) {
    return { value: null, found: true, conflict: rows.length > 1, unitValid };
  }
  const unique = [...new Set(values)];
  return {
    value: unique[0] ?? null,
    found: true,
    conflict: rows.length > 1 || unique.length > 1,
    unitValid: true,
  };
}

function longContext(markdown: string): Pick<
  ParsedPricing,
  | "long_context_threshold_tokens"
  | "long_context_input_multiplier"
  | "long_context_output_multiplier"
> {
  const match = markdown.match(
    /(?:prompts?\s+with\s+)?(?:>|over|above)\s*([\d,]+)\s*K[^\n]*?priced\s+at\s*([0-9]+(?:\.[0-9]+)?)x\s+input\s+and\s*([0-9]+(?:\.[0-9]+)?)x\s+output/i,
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

function cacheWriteRate(markdown: string, input: number): number | null {
  const match = markdown.match(
    /cache\s+writes?\s+are\s+billed\s+at\s*([0-9]+(?:\.[0-9]+)?)x\s+the\s+uncached\s+input\s+token\s+rate/i,
  );
  if (!match) return null;
  const multiplier = Number(match[1]);
  return Number.isFinite(multiplier) && multiplier >= 0
    ? input * multiplier
    : null;
}

export function parseOfficialPricing(
  markdown: string,
  expectedModel: string,
  cacheWriteRequired = false,
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
  const identity = markdown.match(MODEL_ID)?.[1];
  if (identity !== expectedModel) {
    return { ...base, status: "unsupported", error_code: "wrong_model" };
  }
  const textTokens = section(markdown, "Text tokens");
  const table = textTokens ? tables(textTokens)[0] : null;
  if (!table) return { ...base, error_code: "pricing_table_missing" };

  const input = rateFromTable(table, "input");
  const cached = rateFromTable(table, "cached input");
  const output = rateFromTable(table, "output");
  if (input.conflict || cached.conflict || output.conflict) {
    return { ...base, status: "conflict", error_code: "contradictory_pricing" };
  }
  if (!input.unitValid || !cached.unitValid || !output.unitValid) {
    return { ...base, error_code: "invalid_rate_unit" };
  }
  if (
    !input.found || input.value == null ||
    !cached.found || cached.value == null ||
    !output.found || output.value == null
  ) {
    return { ...base, error_code: "required_rate_missing" };
  }
  const cacheWrite = cacheWriteRate(markdown, input.value);
  if (cacheWriteRequired && cacheWrite == null) {
    return { ...base, error_code: "required_cache_write_rate_missing" };
  }
  return {
    ...base,
    status: "verified",
    input_usd_per_1m: input.value,
    cached_input_usd_per_1m: cached.value,
    cache_write_usd_per_1m: cacheWrite,
    output_usd_per_1m: output.value,
  };
}

export function normalizedPricingEvidence(parsed: ParsedPricing): string {
  return JSON.stringify({
    provider_model: parsed.provider_model,
    status: parsed.status,
    input_usd_per_1m: parsed.input_usd_per_1m,
    cached_input_usd_per_1m: parsed.cached_input_usd_per_1m,
    cache_write_usd_per_1m: parsed.cache_write_usd_per_1m,
    output_usd_per_1m: parsed.output_usd_per_1m,
    long_context_threshold_tokens: parsed.long_context_threshold_tokens,
    long_context_input_multiplier: parsed.long_context_input_multiplier,
    long_context_output_multiplier: parsed.long_context_output_multiplier,
    error_code: parsed.error_code,
  });
}
