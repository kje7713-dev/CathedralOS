export const DEFAULT_GENERATION_MODEL_ID = "gpt-4o-mini";

export interface GenerationModel {
  id: string;
  provider: string;
  provider_model: string;
  display_name: string;
  description: string | null;
  input_credit_rate: number;
  output_credit_rate: number;
  minimum_charge_credits: number;
  max_output_tokens: number | null;
  enabled: boolean;
  sort_order: number;
}

export type PublicGenerationModel = Pick<
  GenerationModel,
  | "id"
  | "display_name"
  | "description"
  | "input_credit_rate"
  | "output_credit_rate"
  | "minimum_charge_credits"
  | "max_output_tokens"
  | "sort_order"
>;

export interface GenerationModelStore {
  getEnabledModelById(modelId: string): Promise<GenerationModel | null>;
  listEnabledModels(): Promise<PublicGenerationModel[]>;
}

function toNumber(value: unknown, fallback = 0): number {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function mapModelRow(row: Record<string, unknown>): GenerationModel {
  return {
    id: String(row.id ?? ""),
    provider: String(row.provider ?? "openai"),
    provider_model: String(row.provider_model ?? ""),
    display_name: String(row.display_name ?? ""),
    description: row.description == null ? null : String(row.description),
    input_credit_rate: toNumber(row.input_credit_rate, 1),
    output_credit_rate: toNumber(row.output_credit_rate, 1),
    minimum_charge_credits: Math.max(0, Math.round(toNumber(row.minimum_charge_credits, 1))),
    max_output_tokens: row.max_output_tokens == null
      ? null
      : Math.max(1, Math.round(toNumber(row.max_output_tokens, 1))),
    enabled: Boolean(row.enabled),
    sort_order: Math.round(toNumber(row.sort_order, 0)),
  };
}

// deno-lint-ignore no-explicit-any
export class SupabaseGenerationModelStore implements GenerationModelStore {
  // deno-lint-ignore no-explicit-any
  constructor(private readonly db: any) {}

  async getEnabledModelById(modelId: string): Promise<GenerationModel | null> {
    const { data, error } = await this.db
      .from("generation_models")
      .select("*")
      .eq("id", modelId)
      .eq("enabled", true)
      .single();

    if (error || !data) return null;
    return mapModelRow(data as Record<string, unknown>);
  }

  async listEnabledModels(): Promise<PublicGenerationModel[]> {
    const { data, error } = await this.db
      .from("generation_models")
      .select(
        "id, display_name, description, input_credit_rate, output_credit_rate, minimum_charge_credits, max_output_tokens, sort_order",
      )
      .eq("enabled", true)
      .order("sort_order", { ascending: true })
      .order("id", { ascending: true });

    if (error || !data) return [];
    return (data as Record<string, unknown>[]).map((row) => {
      const mapped = mapModelRow({ ...row, provider: "openai", provider_model: "", enabled: true });
      return {
        id: mapped.id,
        display_name: mapped.display_name,
        description: mapped.description,
        input_credit_rate: mapped.input_credit_rate,
        output_credit_rate: mapped.output_credit_rate,
        minimum_charge_credits: mapped.minimum_charge_credits,
        max_output_tokens: mapped.max_output_tokens,
        sort_order: mapped.sort_order,
      };
    });
  }
}

export function normalizedModelId(selectedModelId: unknown): string {
  if (typeof selectedModelId === "string" && selectedModelId.trim().length > 0) {
    return selectedModelId.trim();
  }
  return DEFAULT_GENERATION_MODEL_ID;
}

export function estimateTokensFromText(text: string): number {
  if (!text.trim()) return 0;
  // Conservative heuristic to avoid under-estimating preflight charge.
  // Uses ~3 chars/token plus 25% safety headroom.
  // This is intentionally dependency-free for Edge runtime portability; switch
  // to a provider-specific tokenizer if exact preflight estimates are required.
  const baseEstimate = Math.ceil(text.length / 3);
  return Math.max(1, Math.ceil(baseEstimate * 1.25));
}

export function computeEstimatedCharge(
  estimatedInputTokens: number,
  maxCompletionTokens: number,
  model: GenerationModel,
): number {
  const raw = (estimatedInputTokens * model.input_credit_rate) +
    (maxCompletionTokens * model.output_credit_rate);
  return Math.max(model.minimum_charge_credits, Math.ceil(raw));
}

export function computeActualCharge(
  inputTokens: number,
  outputTokens: number,
  model: GenerationModel,
): number {
  const raw = (inputTokens * model.input_credit_rate) + (outputTokens * model.output_credit_rate);
  return Math.max(model.minimum_charge_credits, Math.ceil(raw));
}
