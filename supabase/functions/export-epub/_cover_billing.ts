import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// gpt-image-1 1024x1536/high is a material provider call. Keep this in one
// place so the iOS confirmation copy and server enforcement cannot drift.
export const AI_COVER_CREDIT_COST = 25;
export const AI_COVER_MODEL = "gpt-image-1";

export class AiCoverInsufficientCreditsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AiCoverInsufficientCreditsError";
  }
}

export async function reserveAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
  modelName = Deno.env.get("OPENAI_IMAGE_MODEL") ?? AI_COVER_MODEL,
): Promise<{ remainingCredits: number; alreadyReserved: boolean }> {
  const { data, error } = await client.rpc("reserve_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
    p_cost: AI_COVER_CREDIT_COST,
    p_model_name: modelName,
  }).maybeSingle();
  if (error) {
    if (error.message?.includes("insufficient_ai_cover_credits")) {
      throw new AiCoverInsufficientCreditsError(error.message);
    }
    throw new Error(`AI cover credit reservation failed: ${error.message}`);
  }
  if (!data) throw new Error("AI cover credit reservation returned no result");
  const result = data as { available_credits?: number; already_reserved?: boolean };
  return {
    remainingCredits: Number(result.available_credits ?? 0),
    alreadyReserved: Boolean(result.already_reserved),
  };
}

export async function completeAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
): Promise<void> {
  const { error } = await client.rpc("complete_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
  });
  if (error) throw new Error(`AI cover credit completion failed: ${error.message}`);
}

export async function refundAiCoverCredits(
  client: SupabaseClient,
  userId: string,
  exportJobId: string,
): Promise<void> {
  const { error } = await client.rpc("refund_ai_cover_credits", {
    p_user_id: userId,
    p_export_job_id: exportJobId,
  });
  if (error) console.error("AI cover credit refund failed:", error.message);
}
