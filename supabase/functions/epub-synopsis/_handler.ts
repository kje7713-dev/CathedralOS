import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  computeMaxChargeCredits,
  estimateTokensFromMessages,
  type GenerationModel,
  inputTokenLimitDetails,
  isBillableGenerationModel,
  snapshotPricing,
} from "../generate-story/_generation_models.ts";
import {
  availableCredits,
  checkCredits,
  type CreditStore,
} from "../generate-story/_credits.ts";
import {
  BillableLLMError,
  type BillableProviderResult,
  runBillableLLM,
} from "../_shared/billable-llm.ts";
import type { LLMMessage, LLMProvider } from "../generate-story/_provider.ts";
import {
  buildStandaloneOutputOutline,
  StandaloneOutputSourceError,
} from "../export-epub/_single_output_source.ts";
import {
  type ProjectOutline,
  walkSections,
} from "../export-epub/_section_walker.ts";
import {
  buildSynopsisMemoryContext,
  SynopsisMemoryError,
  type SynopsisMemoryRow,
} from "./_memory_context.ts";

export interface SynopsisRequest {
  action?: "estimate" | "generate";
  project_id: string;
  title: string;
  operation_id: string;
  generation_output_id?: string;
}

export interface SynopsisDependencies {
  adminClient: SupabaseClient;
  provider: LLMProvider;
  creditStore: CreditStore;
  defaultModel: string;
}

const MAX_OUTPUT_TOKENS = 320;

export function validateSynopsisRequest(body: unknown): SynopsisRequest {
  const value = body as Partial<SynopsisRequest> | null;
  if (
    value?.action !== undefined && value.action !== "estimate" &&
    value.action !== "generate"
  ) {
    throw new Error("action must be estimate or generate");
  }
  if (typeof value?.project_id !== "string" || !value.project_id.trim()) {
    throw new Error("project_id required");
  }
  if (typeof value?.title !== "string" || !value.title.trim()) {
    throw new Error("title required");
  }
  if (typeof value?.operation_id !== "string" || !value.operation_id.trim()) {
    throw new Error("operation_id required");
  }
  if (
    value.generation_output_id !== undefined &&
    (typeof value.generation_output_id !== "string" ||
      !value.generation_output_id.trim())
  ) {
    throw new Error("generation_output_id must be a non-empty string");
  }
  return {
    action: value.action ?? "generate",
    project_id: value.project_id.trim(),
    title: value.title.trim().slice(0, 300),
    operation_id: value.operation_id.trim().slice(0, 200),
    generation_output_id: value.generation_output_id?.trim(),
  };
}

function buildMessages(
  request: SynopsisRequest,
  sourceText: string,
): LLMMessage[] {
  return [
    {
      role: "system",
      content: [
        "You write back-cover copy for a completed fiction story.",
        "Return only one polished synopsis in plain text, with no heading, bullets, quotation marks, or commentary.",
        "Write 80 to 180 words.",
        "Establish the protagonist, central situation, setting, genre or tone, and main hook.",
        "Create curiosity without summarizing the ending or inventing facts not supported by the story.",
      ].join(" "),
    },
    {
      role: "user",
      content: `Title: ${request.title}\n\nStory source:\n${sourceText}`,
    },
  ];
}

export function validateSynopsisContent(content: string): string {
  const synopsis = content.trim().replace(/^['"]|['"]$/g, "");
  const words = synopsis.split(/\s+/).filter(Boolean).length;
  if (words < 80 || words > 180) {
    throw new Error("Synopsis must be between 80 and 180 words");
  }
  return synopsis;
}

async function idempotencyKey(
  userID: string,
  request: SynopsisRequest,
): Promise<string> {
  const payload = `${userID}|epub-synopsis|${request.operation_id}`;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(payload),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function sourceFingerprint(
  sourceText: string,
  request: SynopsisRequest,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(
      `${request.project_id}|${request.title}|${sourceText}`,
    ),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function loadCompletedSynopsis(
  userID: string,
  request: SynopsisRequest,
  fingerprint: string,
  deps: SynopsisDependencies,
): Promise<string | null> {
  const { data, error } = await deps.adminClient
    .from("epub_synopsis_operations")
    .select("project_id, title, source_fingerprint, synopsis, status")
    .eq("user_id", userID)
    .eq("operation_id", request.operation_id)
    .maybeSingle();
  if (error) {
    throw new Error(`synopsis operation lookup failed: ${error.message}`);
  }
  if (!data || data.status !== "complete") return null;
  if (
    data.project_id !== request.project_id || data.title !== request.title ||
    data.source_fingerprint !== fingerprint
  ) {
    throw new Error(
      "synopsis operation identity was reused for different source",
    );
  }
  return typeof data.synopsis === "string" ? data.synopsis : null;
}

async function checkpointSynopsis(
  userID: string,
  request: SynopsisRequest,
  fingerprint: string,
  synopsis: string,
  deps: SynopsisDependencies,
): Promise<void> {
  const { error } = await deps.adminClient.from("epub_synopsis_operations")
    .upsert({
      user_id: userID,
      operation_id: request.operation_id,
      project_id: request.project_id,
      title: request.title,
      source_fingerprint: fingerprint,
      synopsis,
      status: "pending",
    }, { onConflict: "user_id,operation_id" });
  if (error) throw new Error(`synopsis checkpoint failed: ${error.message}`);
}

async function completeSynopsis(
  userID: string,
  operationID: string,
  synopsis: string,
  deps: SynopsisDependencies,
): Promise<void> {
  const { error } = await deps.adminClient.from("epub_synopsis_operations")
    .update({
      synopsis,
      status: "complete",
      completed_at: new Date().toISOString(),
    })
    .eq("user_id", userID)
    .eq("operation_id", operationID);
  if (error) throw new Error(`synopsis completion failed: ${error.message}`);
}

async function resolveExportOutline(
  request: SynopsisRequest,
  userID: string,
  deps: SynopsisDependencies,
): Promise<ProjectOutline> {
  const { data: project, error } = await deps.adminClient
    .from("project_snapshots")
    .select("id")
    .eq("user_id", userID)
    .eq("local_project_id", request.project_id)
    .maybeSingle();
  if (error || !project) throw new Error("project_not_found");
  if (request.generation_output_id) {
    return await buildStandaloneOutputOutline(
      deps.adminClient,
      userID,
      request.project_id,
      String(project.id),
      request.generation_output_id,
      request.title,
    );
  }
  return await walkSections(
    deps.adminClient,
    userID,
    request.project_id,
    String(project.id),
  );
}

async function resolveSynopsisSource(
  outline: ProjectOutline,
  deps: SynopsisDependencies,
): Promise<string> {
  const outputIDs = outline.chapters.flatMap((chapter) => chapter.sections)
    .filter((section) => section.body.trim())
    .map((section) => section.generation_output_id)
    .filter((id): id is string => Boolean(id));
  if (!outputIDs.length) {
    throw new SynopsisMemoryError(
      "memory_missing",
      "export has no generated output lineage",
    );
  }
  const { data, error } = await deps.adminClient
    .from("section_embeddings")
    .select(
      "outline_section_id, generation_output_id, memory_pipeline_version, extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state",
    )
    .in("generation_output_id", outputIDs);
  if (error) throw new SynopsisMemoryError("memory_missing", error.message);
  return buildSynopsisMemoryContext(
    outline,
    (data ?? []) as SynopsisMemoryRow[],
  );
}

async function resolveModel(
  deps: SynopsisDependencies,
): Promise<GenerationModel | null> {
  const result = await deps.adminClient.from("generation_models").select("*")
    .eq("provider_model", deps.defaultModel).maybeSingle();
  return result.data as GenerationModel | null;
}

function errorResponse(
  code: string,
  message: string,
  status: number,
): Response {
  return new Response(JSON.stringify({ errorCode: code, message }), {
    status,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Content-Type": "application/json",
    },
  });
}

export async function handleSynopsis(
  userID: string,
  request: SynopsisRequest,
  deps: SynopsisDependencies,
): Promise<Response> {
  let outline: ProjectOutline;
  let sourceText: string;
  try {
    outline = await resolveExportOutline(request, userID, deps);
    sourceText = await resolveSynopsisSource(outline, deps);
  } catch (error) {
    if (error instanceof StandaloneOutputSourceError) {
      return errorResponse(error.code, error.message, 404);
    }
    if (error instanceof Error && error.message === "project_not_found") {
      return errorResponse(
        "project_not_found",
        "The story project could not be found.",
        404,
      );
    }
    if (error instanceof SynopsisMemoryError) {
      return errorResponse(
        error.code,
        "Structured scene memory for the exported story is unavailable or stale. Regenerate the affected story sections before creating a synopsis.",
        422,
      );
    }
    return errorResponse(
      "source_selection_failed",
      "The exported story content could not be selected.",
      422,
    );
  }
  if (!sourceText.trim()) {
    return errorResponse(
      "source_selection_failed",
      "The exported story has no generated content.",
      422,
    );
  }
  const fingerprint = await sourceFingerprint(sourceText, request);
  try {
    const completed = await loadCompletedSynopsis(
      userID,
      request,
      fingerprint,
      deps,
    );
    if (completed !== null && request.action === "generate") {
      return new Response(JSON.stringify({ synopsis: completed }), {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Content-Type": "application/json",
        },
      });
    }
  } catch (error) {
    if (
      error instanceof Error && error.message.includes("identity was reused")
    ) {
      return errorResponse("operation_conflict", error.message, 409);
    }
    return errorResponse(
      "source_selection_failed",
      "The synopsis operation could not be loaded.",
      422,
    );
  }
  const model = await resolveModel(deps);
  if (!model || !isBillableGenerationModel(model)) {
    return errorResponse(
      "model_unavailable_or_unpriced",
      "The synopsis model is unavailable or has unverified pricing.",
      400,
    );
  }
  const messages = buildMessages(request, sourceText);
  const estimatedInputTokens = estimateTokensFromMessages(messages);
  const inputLimit = inputTokenLimitDetails(estimatedInputTokens);
  if (inputLimit) {
    return errorResponse(
      "input_token_limit_exceeded",
      `Estimated input is ${inputLimit.estimatedInputTokens} tokens; Cathedral's hard limit is ${inputLimit.limit} tokens`,
      413,
    );
  }

  const estimatedCredits = computeMaxChargeCredits({
    uncachedInputTokens: estimatedInputTokens,
    cachedInputTokens: 0,
    cacheWriteInputTokens: 0,
    outputTokens: MAX_OUTPUT_TOKENS,
    toolCostUsd: 0,
  }, snapshotPricing(model));
  const entitlement = await deps.creditStore.loadOrDefault(userID);
  const creditCheck = checkCredits(entitlement, estimatedCredits);
  if (request.action === "estimate") {
    return new Response(
      JSON.stringify({
        estimated_credits: estimatedCredits,
        available_credits: availableCredits(entitlement),
        allowed: creditCheck.allowed,
      }),
      {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Content-Type": "application/json",
        },
      },
    );
  }
  if (!creditCheck.allowed) {
    return errorResponse(
      "insufficient_credits",
      "Not enough credits for a story synopsis.",
      402,
    );
  }

  const key = await idempotencyKey(userID, request);
  try {
    const result = await runBillableLLM<{ synopsis: string }>({
      userID,
      purpose: "epub-synopsis",
      action: "generate",
      model,
      messages,
      maxOutputTokens: MAX_OUTPUT_TOKENS,
      usageContext: {
        projectID: request.project_id,
        generationLengthMode: "short",
        outputBudget: MAX_OUTPUT_TOKENS,
        idempotencyKey: key,
      },
      preflightUsageOverride: {
        uncachedInputTokens: estimatedInputTokens,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: MAX_OUTPUT_TOKENS,
        toolCostUsd: 0,
      },
      onProviderSuccess: async (providerResult: BillableProviderResult) => {
        return { synopsis: validateSynopsisContent(providerResult.content) };
      },
      beforeSettlement: async (featureResult) => {
        await checkpointSynopsis(
          userID,
          request,
          fingerprint,
          featureResult.synopsis,
          deps,
        );
      },
    }, {
      adminClient: deps.adminClient,
      provider: deps.provider,
      creditStore: deps.creditStore,
    });
    await completeSynopsis(
      userID,
      request.operation_id,
      result.featureResult.synopsis,
      deps,
    );
    return new Response(JSON.stringify(result.featureResult), {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Content-Type": "application/json",
      },
    });
  } catch (error) {
    if (
      error instanceof BillableLLMError && error.code === "insufficient_credits"
    ) return errorResponse("insufficient_credits", error.message, 402);
    const code = (error as { errorCode?: string })?.errorCode;
    if (code === "provider_timeout") {
      return errorResponse(
        code,
        "The synopsis provider timed out. No credits were charged.",
        504,
      );
    }
    return errorResponse(
      "synopsis_generation_failed",
      error instanceof Error ? error.message : String(error),
      502,
    );
  }
}

export { buildMessages, idempotencyKey, MAX_OUTPUT_TOKENS };
