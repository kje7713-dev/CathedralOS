// =============================================================================
// embed-section Edge Function (Phase 4 redesign per locked RAG rules)
//
// Called from iOS on OutlineSection Accept. On-demand pipeline:
//   1. UPSERT outline (id = client-provided outline_id, project_id)
//   2. UPSERT outline_section (id = client-provided outline_section_id)
//   3. Accept producer-supplied scene memory, or run the legacy LLM extraction
//      pass when called independently (per Rule 1-3: no IDs,
//      no source_section_id, no status fields from the LLM; the function
//      adds these server-side)
//   4. Embed the summary (text-embedding-3-small, 1536-dim)
//   5. UPSERT into section_embeddings via service role with the new
//      shape: stable IDs, source_section_id, status, created_at, raw_text
//
// The function creates the outline + section on-demand. The iOS app does
// NOT need to sync them to supabase first — this was the v1 bug.
//
// Per Locked Design Rules (Kevin 2026-08-10 16:28 EDT, PR #306 RFC):
//   - Rule 1: keep the 5 structured memory layers
//   - Rule 2: character_deltas aggregate merges fields per character (not per-scene merge; the function emits per-scene character deltas and the aggregate does the merge)
//   - Rule 3: plot_thread_deltas + open_loops have stable IDs + explicit lifecycle
//   - Rule 4: continuity_facts have provenance + active/superseded
//   - Rule 8: pipeline order generate → persist → extract; this function is called AFTER the output is persisted by the caller (run-outline does the persist)
//   - Rule 9: raw_text is stored but not injected by default
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Service-role key is used server-side only (never exposed to iOS).
//
// Request:  POST {
//             outline_section_id, outline_id, project_id, position,
//             title, summary, container?, pov?, terminal_beat?,
//             story_arc_beat_id?, raw_text
//           }
// The HTTP adapter exposes { outline_section_id, extracted_summary, embedding_dim }.
// =============================================================================

import { canonicalUUID } from "./uuid.ts";
import {
  type DirectBillingContext,
  preflightDirectUsage,
  settleDirectUsage,
} from "./direct-billing.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import {
  normalizeSceneMemory,
  type SceneMemory,
  SCENE_MEMORY_RESPONSE_FORMAT,
} from "./scene-memory.ts";
import { loadPriorMemoryRows, reconcileSceneMemory } from "./memory-lifecycle.ts";

const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ??
  "gpt-4o-mini";
const OPENAI_EMBED_MODEL = "text-embedding-3-small";

// Keep extraction constrained to the shape consumed below. JSON mode can still
// return a truncated object when the completion budget is exhausted; Structured
// Outputs prevents syntactically invalid output and makes missing layers explicit.
export interface EmbedSectionRequest {
  outline_section_id?: string;
  outline_id?: string;
  project_id?: string;
  position?: number;
  title?: string;
  summary?: string;
  container?: string | null;
  pov?: string | null;
  terminal_beat?: string | null;
  story_arc_beat_id?: string | null;
  raw_text?: string;
  // When generation already returned structured memory, reuse it and skip the
  // second billable extraction pass.
  scene_memory?: Partial<SceneMemory>;
  // Optional: tag every llm_prompts row this call writes with this
  // generation output's id so the iOS debug box can show the prompt + response
  // for the output that triggered the embedding. PR-XXX-H.
  output_id?: string;
  // The prior context that run-outline generated for this section. Passed
  // to the LLM so it knows what is already stored (characters, threads,
  // active facts, open loops) and can decide what to add/update/supersede
  // in the new structured state. The LLM is the source of truth for
  // what to store; the prior context is its working memory.
  prior_context?: string;
}

// LLM returns semantic content only. The function adds IDs, source_section_id,
// status, timestamps, and provenance metadata server-side per the locked rules.

export class SectionEmbeddingError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "SectionEmbeddingError";
  }
}

export interface SectionEmbeddingResult {
  outlineSectionID: string;
  extractedSummary: string;
  embeddingDim: number;
}

export async function ensureOutlineAndSection(
  body: EmbedSectionRequest,
  userID: string,
  // deno-lint-ignore no-explicit-any
  adminClient: any,
): Promise<void> {
  // Step 1: UPSERT outline (id = client-provided, user_id from auth, local_project_id + lineage_id).
  const { error: outlineErr } = await adminClient.from("outlines").upsert({
    id: body.outline_id,
    user_id: userID,
    local_project_id: body.project_id!.toUpperCase(),
    lineage_id: body.project_id,
    name: "Outline",
  }, { onConflict: "id" });
  if (outlineErr) {
    console.error(
      `[embed-section] outline upsert failed: ${outlineErr.message}`,
    );
    throw new SectionEmbeddingError(
      "database_error",
      `outline upsert failed: ${outlineErr.message}`,
    );
  }
  console.log(`[embed-section] outline upserted id=${body.outline_id}`);

  // Step 1.5: Validate story_arc_beat_id exists in story_arc_beats before
  // the section upsert. Defensive: null the FK if bogus.
  let validatedBeatID: string | null = body.story_arc_beat_id
    ? canonicalUUID(body.story_arc_beat_id)
    : null;
  if (validatedBeatID) {
    const { data: beatExists, error: beatCheckErr } = await adminClient
      .from("story_arc_beats")
      .select("id")
      .eq("id", validatedBeatID)
      .maybeSingle();
    if (beatCheckErr) {
      console.warn(
        `[embed-section] beat check error (nulling FK): ${beatCheckErr.message}`,
      );
      validatedBeatID = null;
    } else if (!beatExists) {
      console.warn(
        `[embed-section] dropping bogus story_arc_beat_id: ${validatedBeatID}`,
      );
      validatedBeatID = null;
    }
  }

  // Step 2: UPSERT outline_section (id = client-provided, all fields).
  // status stays "draft" here — the iOS app flips it to "accepted" locally
  // on 200 response.
  const { error: sectionErr } = await adminClient.from("outline_sections")
    .upsert({
      id: body.outline_section_id,
      outline_id: body.outline_id,
      position: body.position ?? 0,
      title: body.title,
      summary: body.summary ?? "",
      container: body.container ?? null,
      pov: body.pov ?? null,
      terminal_beat: body.terminal_beat ?? null,
      story_arc_beat_id: validatedBeatID,
      status: "draft",
    }, { onConflict: "id" });
  if (sectionErr) {
    console.error(
      `[embed-section] section upsert failed: ${sectionErr.message}`,
    );
    throw new SectionEmbeddingError(
      "database_error",
      `outline_section upsert failed: ${sectionErr.message}`,
    );
  }
  console.log(`[embed-section] section upserted id=${body.outline_section_id}`);
}

export async function processSectionMemory(
  body: EmbedSectionRequest,
  // deno-lint-ignore no-explicit-any
  adminClient: any,
  openaiKey: string,
  billing?: DirectBillingContext,
): Promise<SectionEmbeddingResult> {
  // Step 3: extract the scene memory via LLM.
  //
  // Per the locked rules (PR #310 RFC), the LLM returns SEMANTIC content only:
  //   - extracted_summary
  //   - character_deltas (per-character state changes; aggregate merges across scenes)
  //   - plot_thread_deltas (thread_name, status, description — no IDs, no source_section_id)
  //   - continuity_facts (strings — no IDs, no source_section_id, no active flag)
  //   - open_loops (type, description — no IDs, no source_section_id)
  //   - scene_ending_state (character_positions, immediate_pressure)
  //
  // The function adds metadata server-side: stable UUIDs (Rule 3), source_section_id
  // (Rule 4), status defaults, created_at timestamps. Continuity_facts get active=true.
  //
  // Uses OpenAI Structured Outputs so a successful, complete response always
  // conforms to the scene-memory JSON schema.
  let sceneMemory: SceneMemory;
  if (body.scene_memory) {
    sceneMemory = normalizeSceneMemory(body.scene_memory);
    console.log(
      `[embed-section] using producer-supplied scene memory summary_len=${sceneMemory.extracted_summary.length}`,
    );
  } else {
    // PR-XXX-A: track LLM call duration for llm_prompts log
    const extractStartMs = Date.now();
    const extractionInput = body.prior_context
      ? `${body.prior_context}\n${body.raw_text ?? ""}`
      : (body.raw_text ?? "");
    if (billing) {
      await preflightDirectUsage(
        billing,
        OPENAI_MODEL_DEFAULT,
        Math.ceil(extractionInput.length / 4),
        8192,
      );
    }
    try {
      const ac = new AbortController();
      const t = setTimeout(() => ac.abort(), 120_000);
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${openaiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: OPENAI_MODEL_DEFAULT,
          messages: [
            {
              role: "system",
              content:
                "You are a fiction scene-memory extractor. Given a scene, output JSON with these 6 keys: " +
                "`extracted_summary` (200-500 token distillation of what happened), " +
                "`character_deltas` (array of {character_name, location?, knowledge_delta?, relationship_delta?, injuries?, goals?, possessions?, emotional_stance?}), " +
                "`plot_thread_deltas` (array of {thread_name, status in [introduced, advanced, resolved], description}), " +
                "`continuity_facts` (array of concrete fact strings future scenes must not contradict), " +
                "`open_loops` (array of {type in [promise, mystery, question, threat, pending_action], description}), " +
                "`scene_ending_state` ({character_positions: [{character, location, immediate_state}], immediate_pressure: string}). " +
                "Output ONLY valid JSON. Empty arrays/objects are fine when a layer has nothing.",
            },
            {
              role: "user",
              content: body.prior_context
                ? `Prior context (what the model already knows about prior sections — use this to inform what to add/update/supersede in the structured state):\n${body.prior_context}\n\nNow, from the current section's raw_text below, extract structured state:\n${body.raw_text}`
                : body.raw_text,
            },
          ],
          max_completion_tokens: 8192,
          temperature: 0.2,
          response_format: SCENE_MEMORY_RESPONSE_FORMAT,
        }),
        signal: ac.signal,
      });
      clearTimeout(t);
      if (!r.ok) {
        const errText = await r.text();
        throw new SectionEmbeddingError(
          "provider_error",
          `OpenAI extract ${r.status}: ${errText.slice(0, 500)}`,
        );
      }
      const data = await r.json();
      if (billing) {
        await settleDirectUsage(
          billing,
          "scene-memory-extraction",
          OPENAI_MODEL_DEFAULT,
          data.usage?.prompt_tokens ?? Math.ceil(extractionInput.length / 4),
          data.usage?.completion_tokens ?? 0,
        );
      }
      if (data.choices?.[0]?.finish_reason === "length") {
        throw new SectionEmbeddingError(
          "provider_error",
          "LLM extraction exceeded its completion budget",
        );
      }
      const raw = (data.choices?.[0]?.message?.content ?? "").trim();
      if (!raw) throw new SectionEmbeddingError("provider_error", "LLM extraction returned empty content");
      try {
        sceneMemory = normalizeSceneMemory(JSON.parse(raw));
      } catch {
        throw new SectionEmbeddingError("provider_error", "LLM extraction returned invalid JSON");
      }
      try {
        await adminClient.from("llm_prompts").insert({
          call_type: "embed-section-extract",
          output_id: body.output_id ?? null,
          project_id: body.project_id ?? null,
          outline_section_id: body.outline_section_id ?? null,
          model: OPENAI_MODEL_DEFAULT,
          prompt: JSON.stringify({ input: body.raw_text, prior_context: body.prior_context ?? null }),
          response: raw,
          prompt_tokens: data.usage?.prompt_tokens ?? null,
          completion_tokens: data.usage?.completion_tokens ?? null,
          total_tokens: data.usage?.total_tokens ?? null,
          duration_ms: Date.now() - extractStartMs,
        });
      } catch (logErr) {
        console.error(`[embed-section] llm_prompts insert failed: ${(logErr as Error).message}`);
      }
    } catch (err) {
      console.error(`[embed-section] LLM extract threw: ${String(err)}`);
      if (err instanceof SectionEmbeddingError) throw err;
      throw new SectionEmbeddingError("provider_error", String(err));
    }
  }
  if (!sceneMemory.extracted_summary) {
    throw new SectionEmbeddingError("provider_error", "scene memory returned empty summary");
  }
  console.log(
    `[embed-section] extract OK summary_len=${sceneMemory.extracted_summary.length} layers=6`,
  );

  // Step 3.5: wrap the LLM output with server-side metadata per the locked rules.
  // - Rule 3: stable UUIDs for plot_thread_deltas, open_loops
  // - Rule 4: source_section_id + active=true for continuity_facts
  // - status defaults for threads (introduced) and loops (open)
  // - created_at timestamp for all metadata-added items
  const nowIso = new Date().toISOString();
  const sourceSectionId = body.outline_section_id;
  const priorRows = await loadPriorMemoryRows(
    adminClient,
    body.project_id ?? "",
    sourceSectionId,
  );
  const reconciled = reconcileSceneMemory(
    priorRows,
    sceneMemory as unknown as Record<string, unknown>,
    sourceSectionId ?? "",
    nowIso,
  );
  const enrichedPlotThreads = reconciled.plot_thread_deltas;
  const enrichedOpenLoops = reconciled.open_loops;
  const enrichedContinuityFacts = reconciled.continuity_facts;

  // Step 4: embed the compressed scene memory string.
  // The vector encodes the structured state (per Locked Rule 9: raw_text is NOT
  // injected by default — only the compressed summary + structured fields).
  const compressedMemory = JSON.stringify({
    summary: sceneMemory.extracted_summary,
    character_deltas: reconciled.character_deltas,
    plot_thread_deltas: enrichedPlotThreads,
    open_loops: enrichedOpenLoops,
    ending_pressure: sceneMemory.scene_ending_state?.immediate_pressure ?? "",
  });

  let embedding: number[] = [];
  // PR-XXX-A: track embedding call duration
  const embedStartMs = Date.now();
  if (billing) {
    await preflightDirectUsage(
      billing,
      OPENAI_EMBED_MODEL,
      Math.ceil(compressedMemory.length / 4),
      0,
    );
  }
  try {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 60_000);
    const r = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openaiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: OPENAI_EMBED_MODEL,
        input: compressedMemory,
      }),
      signal: ac.signal,
    });
    clearTimeout(t);
    if (!r.ok) {
      const errText = await r.text();
      console.error(
        `[embed-section] OpenAI embed ${r.status}: ${errText.slice(0, 500)}`,
      );
      throw new SectionEmbeddingError(
        "provider_error",
        `OpenAI embed ${r.status}: ${errText.slice(0, 500)}`,
      );
    }
    const data = await r.json();
    if (billing) {
      await settleDirectUsage(
        billing,
        "scene-memory-embedding",
        OPENAI_EMBED_MODEL,
        data.usage?.prompt_tokens ?? Math.ceil(compressedMemory.length / 4),
        0,
      );
    }
    const vec = data.data?.[0]?.embedding;
    if (!Array.isArray(vec)) {
      console.error(`[embed-section] Embedding API returned invalid data`);
      throw new SectionEmbeddingError(
        "provider_error",
        "Embedding API returned invalid data",
      );
    }
    embedding = vec;

    // PR-XXX-A: log the embedding call to llm_prompts (best-effort)
    const embedDurationMs = Date.now() - embedStartMs;
    try {
      await adminClient.from("llm_prompts").insert({
        call_type: "embed-section-vectorize",
        output_id: body.output_id ?? null,
        project_id: body.project_id ?? null,
        outline_section_id: body.outline_section_id ?? null,
        model: OPENAI_EMBED_MODEL,
        prompt: JSON.stringify({
          input: compressedMemory,
        }),
        response: `embedding_dim=${vec.length}`,
        prompt_tokens: data.usage?.prompt_tokens ?? null,
        completion_tokens: null,
        total_tokens: data.usage?.total_tokens ?? null,
        duration_ms: embedDurationMs,
      });
    } catch (logErr) {
      console.error(
        `[embed-section] embeddings llm_prompts insert failed: ${
          (logErr as Error).message
        }`,
      );
    }
  } catch (err) {
    console.error(`[embed-section] embed threw: ${String(err)}`);
    throw new SectionEmbeddingError("provider_error", String(err));
  }
  console.log(`[embed-section] embed OK dim=${embedding.length}`);

  // Step 5: upsert into section_embeddings with the new shape.
  // Per Locked Rules:
  //   - plot_thread_deltas, open_loops: stable UUIDs + source_section_id + status + created_at + resolved_at
  //   - continuity_facts: stable UUIDs + source_section_id + active + superseded_by + created_at
  //   - raw_text: stored (Rule 9 — for re-extraction/debugging, NOT injected by default)
  //   - character_deltas: per-scene array (Rule 2 — aggregate merges across scenes)
  //   - scene_ending_state: same object shape
  const { error: upsertErr } = await adminClient.from("section_embeddings")
    .upsert({
      project_id: body.project_id,
      outline_section_id: body.outline_section_id,
      // Kevin 2026-08-21 12:00 EDT fix: lineage from section memory to the
      // generation output that produced it. The DELETE trigger on
      // generation_outputs uses this to clean up orphaned memory.
      generation_output_id: body.output_id ?? null,
      embedding,
      extracted_summary: sceneMemory.extracted_summary,
      raw_text: body.raw_text,
      container: body.container ?? null,
      pov: body.pov ?? null,
      character_deltas: reconciled.character_deltas,
      plot_thread_deltas: enrichedPlotThreads,
      continuity_facts: enrichedContinuityFacts,
      open_loops: enrichedOpenLoops,
      scene_ending_state: sceneMemory.scene_ending_state,
    }, { onConflict: "outline_section_id" });
  if (upsertErr) {
    console.error(
      `[embed-section] section_embeddings upsert failed: ${upsertErr.message}`,
    );
    throw new SectionEmbeddingError("database_error", upsertErr.message);
  }
  console.log(
    `[embed-section] section_embeddings upserted section=${body.outline_section_id} threads=${enrichedPlotThreads.length} loops=${enrichedOpenLoops.length} facts=${enrichedContinuityFacts.length}`,
  );

  return {
    outlineSectionID: body.outline_section_id!,
    extractedSummary: sceneMemory.extracted_summary,
    embeddingDim: embedding.length,
  };
}

export async function processEmbedSection(
  body: EmbedSectionRequest,
  userID: string,
  // deno-lint-ignore no-explicit-any
  adminClient: any,
  openaiKey: string,
): Promise<SectionEmbeddingResult> {
  await ensureOutlineAndSection(body, userID, adminClient);
  return processSectionMemory(body, adminClient, openaiKey, {
    userID,
    action: "embed-section",
    outputID: body.output_id ?? null,
    projectID: body.project_id,
    outlineSectionID: body.outline_section_id,
    adminClient,
    creditStore: new SupabaseCreditStore(adminClient),
  });
}
