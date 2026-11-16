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
import { processEmbedSection } from "../_shared/section-embedding.ts";
import { isCurrentMemoryPipelineVersion } from "../_shared/memory-pipeline.ts";

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

type SynopsisOperationClaim = {
  claim_status: "claimed" | "complete" | "ready" | "in_progress";
  claim_token: string | null;
  synopsis: string | null;
  provider_model: string | null;
  provider_input_tokens: number | null;
  provider_output_tokens: number | null;
  provider_cached_input_tokens: number | null;
  provider_cache_write_input_tokens: number | null;
  provider_tool_cost_usd: number | null;
};

async function claimSynopsisOperation(
  userID: string,
  request: SynopsisRequest,
  fingerprint: string,
  deps: SynopsisDependencies,
): Promise<SynopsisOperationClaim> {
  const { data, error } = await deps.adminClient.rpc(
    "claim_epub_synopsis_operation",
    {
      p_user_id: userID,
      p_operation_id: request.operation_id,
      p_project_id: request.project_id,
      p_title: request.title,
      p_source_fingerprint: fingerprint,
    },
  );
  if (error) {
    throw new Error(`synopsis operation claim failed: ${error.message}`);
  }
  const row = (Array.isArray(data) ? data[0] : data) as
    | SynopsisOperationClaim
    | null;
  if (!row?.claim_status) {
    throw new Error("synopsis operation claim returned no status");
  }
  return row;
}

async function checkpointSynopsis(
  userID: string,
  request: SynopsisRequest,
  fingerprint: string,
  claimToken: string,
  providerResult: BillableProviderResult,
  synopsis: string,
  deps: SynopsisDependencies,
): Promise<void> {
  const { data, error } = await deps.adminClient.from(
    "epub_synopsis_operations",
  )
    .update({
      source_fingerprint: fingerprint,
      synopsis,
      provider_model: providerResult.modelName,
      provider_input_tokens: providerResult.inputTokens,
      provider_output_tokens: providerResult.outputTokens,
      provider_cached_input_tokens: providerResult.cachedInputTokens,
      provider_cache_write_input_tokens: providerResult.cacheWriteInputTokens,
      provider_tool_cost_usd: providerResult.toolCostUsd,
    }).eq("user_id", userID).eq("operation_id", request.operation_id)
    .eq("claim_token", claimToken).eq("status", "pending")
    .select("operation_id").maybeSingle();
  if (error) throw new Error(`synopsis checkpoint failed: ${error.message}`);
  if (!data) throw new Error("synopsis checkpoint lost operation ownership");
}

async function completeSynopsis(
  userID: string,
  operationID: string,
  claimToken: string,
  synopsis: string,
  deps: SynopsisDependencies,
): Promise<void> {
  const { data, error } = await deps.adminClient.from(
    "epub_synopsis_operations",
  )
    .update({
      synopsis,
      status: "complete",
      completed_at: new Date().toISOString(),
    })
    .eq("user_id", userID)
    .eq("operation_id", operationID)
    .eq("claim_token", claimToken)
    .eq("status", "pending")
    .select("operation_id").maybeSingle();
  if (error) throw new Error(`synopsis completion failed: ${error.message}`);
  if (!data) throw new Error("synopsis completion lost operation ownership");
}

async function releaseSynopsisClaim(
  userID: string,
  operationID: string,
  claimToken: string | null | undefined,
  deps: SynopsisDependencies,
): Promise<void> {
  if (!claimToken) return;
  await deps.adminClient.from("epub_synopsis_operations").update({
    claim_token: null,
    claimed_at: null,
  }).eq("user_id", userID).eq("operation_id", operationID)
    .eq("claim_token", claimToken).eq("status", "pending");
}

async function loadSettledSynopsis(
  userID: string,
  key: string,
  deps: SynopsisDependencies,
): Promise<boolean> {
  const { data, error } = await deps.adminClient.from("generation_usage_events")
    .select("status")
    .eq("user_id", userID)
    .eq("idempotency_key", key)
    .eq("purpose", "epub-synopsis")
    .maybeSingle();
  if (error) {
    throw new Error(`synopsis billing lookup failed: ${error.message}`);
  }
  return data?.status === "complete";
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
  request: SynopsisRequest,
  userID: string,
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
  if (
    request.generation_output_id &&
    outputIDs.length === 1 &&
    ((data?.length ?? 0) === 0 ||
      (data ?? []).some((row: SynopsisMemoryRow) =>
        !isCurrentMemoryPipelineVersion(row.memory_pipeline_version)
      ))
  ) {
    if (request.action === "estimate") {
      throw new SynopsisMemoryError(
        "memory_missing",
        "standalone scene memory must be extracted before estimating synopsis generation",
      );
    }
    const openaiKey = Deno.env.get("OPENAI_API_KEY");
    if (!openaiKey) {
      throw new SynopsisMemoryError(
        "memory_missing",
        "standalone scene memory extraction is unavailable",
      );
    }
    await processEmbedSection(
      {
        outline_section_id: request.generation_output_id,
        outline_id: request.generation_output_id,
        project_id: request.project_id,
        position: 0,
        title: outline.title,
        container: "chapter",
        raw_text: outline.chapters[0]?.sections[0]?.body ?? "",
        output_id: request.generation_output_id,
        forceExtract: (data?.length ?? 0) > 0,
      },
      userID,
      deps.adminClient,
      openaiKey,
    );
    const refreshed = await deps.adminClient.from("section_embeddings")
      .select(
        "outline_section_id, generation_output_id, memory_pipeline_version, extracted_summary, character_deltas, plot_thread_deltas, continuity_facts, open_loops, scene_ending_state",
      ).in("generation_output_id", outputIDs);
    if (refreshed.error || !refreshed.data?.length) {
      throw new SynopsisMemoryError(
        "memory_missing",
        "standalone scene memory was not persisted",
      );
    }
    return buildSynopsisMemoryContext(
      outline,
      refreshed.data as SynopsisMemoryRow[],
    );
  }
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

function synopsisResponse(synopsis: string): Response {
  return new Response(JSON.stringify({ synopsis }), {
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
    sourceText = await resolveSynopsisSource(request, userID, outline, deps);
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
  const key = await idempotencyKey(userID, request);
  let claim: SynopsisOperationClaim | null = null;
  try {
    if (request.action === "generate") {
      claim = await claimSynopsisOperation(userID, request, fingerprint, deps);
    }
    if (claim?.claim_status === "complete" && claim.synopsis) {
      return synopsisResponse(claim.synopsis);
    }
    if (claim?.claim_status === "in_progress") {
      return errorResponse(
        "synopsis_in_progress",
        "This synopsis request is already being completed.",
        409,
      );
    }
    if (
      claim?.claim_status === "ready" && claim.synopsis && claim.claim_token
    ) {
      if (await loadSettledSynopsis(userID, key, deps)) {
        await completeSynopsis(
          userID,
          request.operation_id,
          claim.claim_token,
          claim.synopsis,
          deps,
        );
        return synopsisResponse(claim.synopsis);
      }
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
    await releaseSynopsisClaim(
      userID,
      request.operation_id,
      claim?.claim_token,
      deps,
    );
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
    await releaseSynopsisClaim(
      userID,
      request.operation_id,
      claim?.claim_token,
      deps,
    );
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
    await releaseSynopsisClaim(
      userID,
      request.operation_id,
      claim?.claim_token,
      deps,
    );
    return errorResponse(
      "insufficient_credits",
      "Not enough credits for a story synopsis.",
      402,
    );
  }

  const recovery = claim?.claim_status === "ready" && Boolean(claim.synopsis);
  const recoveryResult = recovery
    ? {
      content: claim!.synopsis!,
      modelName: claim!.provider_model ?? model.provider_model,
      inputTokens: claim!.provider_input_tokens ?? estimatedInputTokens,
      outputTokens: claim!.provider_output_tokens ?? MAX_OUTPUT_TOKENS,
      cachedInputTokens: claim!.provider_cached_input_tokens ?? 0,
      cacheWriteInputTokens: claim!.provider_cache_write_input_tokens ?? 0,
      finishReason: "stop" as const,
      toolCostUsd: claim!.provider_tool_cost_usd ?? 0,
    }
    : null;
  const billingProvider = recoveryResult
    ? {
      complete: async () => recoveryResult,
    }
    : deps.provider;
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
        uncachedInputTokens: recoveryResult
          ? Math.max(
            0,
            recoveryResult.inputTokens - recoveryResult.cachedInputTokens -
              recoveryResult.cacheWriteInputTokens,
          )
          : estimatedInputTokens,
        cachedInputTokens: recoveryResult?.cachedInputTokens ?? 0,
        cacheWriteInputTokens: recoveryResult?.cacheWriteInputTokens ?? 0,
        outputTokens: recoveryResult?.outputTokens ?? MAX_OUTPUT_TOKENS,
        toolCostUsd: recoveryResult?.toolCostUsd ?? 0,
      },
      onProviderSuccess: async (providerResult: BillableProviderResult) => {
        return {
          synopsis: recoveryResult?.content ??
            validateSynopsisContent(providerResult.content),
        };
      },
      beforeSettlement: recovery
        ? undefined
        : async (featureResult, providerResult) => {
          await checkpointSynopsis(
            userID,
            request,
            fingerprint,
            claim!.claim_token!,
            providerResult,
            featureResult.synopsis,
            deps,
          );
        },
    }, {
      adminClient: deps.adminClient,
      provider: billingProvider,
      creditStore: deps.creditStore,
    });
    await completeSynopsis(
      userID,
      request.operation_id,
      claim!.claim_token!,
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
    if (claim?.claim_status === "claimed") {
      try {
        await releaseSynopsisClaim(
          userID,
          request.operation_id,
          claim.claim_token,
          deps,
        );
      } catch (releaseError) {
        console.error(`synopsis claim release failed: ${String(releaseError)}`);
      }
    }
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
