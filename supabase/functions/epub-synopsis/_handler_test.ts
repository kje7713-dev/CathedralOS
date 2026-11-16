import {
  buildMessages,
  handleSynopsis,
  idempotencyKey,
  validateSynopsisContent,
  validateSynopsisRequest,
} from "./_handler.ts";
import type { ProjectOutline } from "../export-epub/_section_walker.ts";
import { ProviderError } from "../generate-story/_provider.ts";
import { CURRENT_MEMORY_PIPELINE_VERSION } from "../_shared/memory-pipeline.ts";
import {
  buildSynopsisMemoryContext,
  MAX_SYNOPSIS_CONTEXT_CHARS,
} from "./_memory_context.ts";

const TEST_REQUEST = {
  action: "generate" as const,
  project_id: "project",
  title: "The Glass Orchard",
  operation_id: "operation-a",
};

function validSynopsis(): string {
  return Array.from({ length: 100 }, (_, index) => `synopsis${index}`).join(
    " ",
  );
}

function makeSynopsisDependencies(options: {
  availableCredits: number;
  providerError?: Error;
  settlementFailures?: number;
  providerDelayMs?: number;
}) {
  let operationRow: Record<string, unknown> | null = null;
  let providerCalls = 0;
  let settlementFailures = options.settlementFailures ?? 0;
  const model = {
    id: "model-id",
    provider: "openai",
    provider_model: "gpt-test",
    display_name: "Test model",
    description: null,
    input_credit_rate: 1,
    output_credit_rate: 1,
    minimum_charge_credits: 1,
    max_output_tokens: 320,
    enabled: true,
    provider_available: true,
    model_kind: "text_generation",
    pricing_state: "verified",
    pricing_verified_at: "2026-01-01T00:00:00Z",
    billing_multiplier: 1,
    provider_input_usd_per_1m: 1,
    provider_cached_input_usd_per_1m: 1,
    provider_cache_write_usd_per_1m: 1,
    provider_output_usd_per_1m: 1,
    cache_write_pricing_required: false,
    cacheMode: "none",
    pricing_effective_at: "2026-01-01T00:00:00Z",
    sort_order: 0,
  };
  const snapshot = {
    id: "snapshot",
    snapshot_json: {
      project: { summary: "An orchard keeper inherits a dangerous secret." },
      outlines: [{
        id: "outline",
        localProjectID: "project",
        name: "The Glass Orchard",
        sections: [{
          id: "section",
          title: "Opening",
          summary: "The central conflict begins.",
          container: "scene",
          position: 0,
          parentID: null,
        }],
      }],
      storyArcs: [],
    },
  };
  const admin = {
    from(table: string) {
      if (table === "generation_models") {
        return {
          select: () => ({
            eq: () => ({
              maybeSingle: () => Promise.resolve({ data: model, error: null }),
            }),
          }),
        };
      }
      if (table === "project_snapshots") {
        const chain = {
          eq: () => chain,
          maybeSingle: () => Promise.resolve({ data: snapshot, error: null }),
        };
        return { select: () => chain };
      }
      if (table === "generation_outputs") {
        return {
          select: () => ({
            in: () => ({
              order: () =>
                Promise.resolve({
                  data: [{
                    id: "output-section",
                    outline_section_id: "section",
                    output_text: "Canonical prose",
                    created_at: "2026-01-01",
                  }],
                  error: null,
                }),
            }),
          }),
        };
      }
      if (table === "section_embeddings") {
        return {
          select: () => ({
            in: () =>
              Promise.resolve({
                data: [{
                  outline_section_id: "section",
                  generation_output_id: "output-section",
                  memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
                  extracted_summary:
                    "The orchard keeper discovers the secret and chooses to protect it.",
                  character_deltas: [{
                    character_name: "Mara",
                    relationship_delta: "trusts the heir",
                  }],
                  plot_thread_deltas: [{
                    thread_name: "The orchard secret",
                    status: "advanced",
                    description: "The hidden inheritance draws danger.",
                  }],
                  continuity_facts: [{
                    fact: "The hidden key belongs to Mara.",
                    active: true,
                  }],
                  open_loops: [{
                    description: "Who sent the warning?",
                    status: "open",
                  }],
                  scene_ending_state: {
                    immediate_pressure: "Rivals arrive at the gate.",
                  },
                }],
                error: null,
              }),
          }),
        };
      }
      if (table === "epub_synopsis_operations") {
        let pendingUpdate: Record<string, unknown> = {};
        const builder: any = {
          eq: () => builder,
          select: () => builder,
          maybeSingle: () => {
            operationRow = { ...operationRow, ...pendingUpdate };
            return Promise.resolve({
              data: { operation_id: "operation" },
              error: null,
            });
          },
        };
        return {
          update: (row: Record<string, unknown>) => {
            pendingUpdate = row;
            return builder;
          },
        };
      }
      if (table === "generation_usage_events") {
        return {
          select: () => ({
            eq: () => ({
              eq: () => ({
                eq: () => ({
                  maybeSingle: () =>
                    Promise.resolve({ data: null, error: null }),
                }),
              }),
            }),
          }),
        };
      }
      if (table === "generation_provider_attempts") {
        return {
          insert: () => ({
            select: () => ({
              single: () =>
                Promise.resolve({ data: { id: "attempt" }, error: null }),
            }),
          }),
          update: () => ({
            eq: () => Promise.resolve({ data: null, error: null }),
          }),
        };
      }
      return { insert: () => Promise.resolve({ data: null, error: null }) };
    },
    rpc(name: string) {
      if (name === "claim_epub_synopsis_operation") {
        if (operationRow?.status === "complete") {
          return Promise.resolve({
            data: [{
              claim_status: "complete",
              synopsis: operationRow.synopsis,
            }],
            error: null,
          });
        }
        if (operationRow?.synopsis) {
          return Promise.resolve({
            data: [{
              claim_status: "ready",
              claim_token: "claim",
              synopsis: operationRow.synopsis,
            }],
            error: null,
          });
        }
        if (operationRow?.status === "pending") {
          return Promise.resolve({
            data: [{ claim_status: "in_progress" }],
            error: null,
          });
        }
        operationRow = { status: "pending", claim_token: "claim" };
        return Promise.resolve({
          data: [{ claim_status: "claimed", claim_token: "claim" }],
          error: null,
        });
      }
      if (name === "settle_billable_usage") {
        if (settlementFailures > 0) {
          settlementFailures--;
          return Promise.resolve({
            data: null,
            error: { message: "temporary settlement interruption" },
          });
        }
        return Promise.resolve({
          data: [{
            settlement_status: "settled",
            usage_event_id: "usage",
            ledger_id: "ledger",
            remaining_credits: 10,
          }],
          error: null,
        });
      }
      return Promise.resolve({ data: null, error: null });
    },
  };
  const provider = {
    complete: async () => {
      providerCalls++;
      if (options.providerDelayMs) {
        await new Promise((resolve) =>
          setTimeout(resolve, options.providerDelayMs)
        );
      }
      return options.providerError
        ? Promise.reject(options.providerError)
        : Promise.resolve({
          content: validSynopsis(),
          modelName: "gpt-test",
          inputTokens: 100,
          outputTokens: 100,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          finishReason: "stop",
          toolCostUsd: 0,
        });
    },
  };
  const creditStore = {
    loadOrDefault: () =>
      Promise.resolve({
        user_id: "user",
        plan_name: "free",
        is_pro: false,
        monthly_credit_allowance: options.availableCredits,
        purchased_credit_balance: 0,
        current_period_start: null,
        current_period_end: null,
        entitlement_source: "test",
        updated_at: "2026-01-01",
      }),
    charge: () => Promise.reject(new Error("runner should use settlement RPC")),
  };
  return {
    adminClient: admin,
    provider,
    creditStore,
    defaultModel: "gpt-test",
    providerCalls: () => providerCalls,
  } as any;
}

Deno.test("synopsis request validation requires an operation identity", () => {
  let failed = false;
  try {
    validateSynopsisRequest({
      project_id: "p",
      title: "Book",
    });
  } catch (error) {
    failed = error instanceof Error &&
      error.message === "operation_id required";
  }
  if (!failed) throw new Error("expected operation_id validation failure");
});

Deno.test("synopsis prompt requests bounded, spoiler-free back-cover copy", () => {
  const messages = buildMessages({
    action: "generate",
    project_id: "p",
    title: "The Glass Orchard",
    operation_id: "op-1",
  }, "Canonical story content");
  const system = messages[0].content;
  if (!system.includes("80 to 180 words")) {
    throw new Error("word range missing");
  }
  if (!system.includes("without summarizing the ending")) {
    throw new Error("spoiler rule missing");
  }
  if (!system.includes("Return only one polished synopsis")) {
    throw new Error("plain-text rule missing");
  }
});

Deno.test("memory context follows export lineage and preserves lifecycle fields", () => {
  const outline: ProjectOutline = {
    id: "outline",
    title: "Memory Orchard",
    chapters: [{
      id: "chapter",
      title: "Chapter",
      position: 0,
      sections: [{
        id: "section",
        generation_output_id: "output-a",
        title: "Climax",
        container: "scene",
        pov: null,
        body: "selected prose",
        position: 0,
        parent_id: null,
        story_arc_beat_id: null,
        story_arc_role: null,
      }],
    }],
    parts: [],
    storyBrief: { setting: "A glass orchard" },
  };
  const context = buildSynopsisMemoryContext(outline, [{
    outline_section_id: "section",
    generation_output_id: "output-a",
    memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
    extracted_summary: "The selected section changes the central conflict.",
    character_deltas: [{
      character_name: "Mara",
      relationship_delta: "chooses trust",
    }],
    plot_thread_deltas: [{
      thread_name: "The secret",
      status: "resolved",
      description: "The secret is revealed.",
    }],
    continuity_facts: [{ fact: "The key is destroyed.", active: true }],
    open_loops: [{ description: "An unresolved warning", status: "open" }],
    scene_ending_state: { immediate_pressure: "The gate breaks." },
  }]);
  if (!context.includes("The selected section changes")) {
    throw new Error("summary missing");
  }
  if (!context.includes("resolved") || !context.includes("The gate breaks")) {
    throw new Error("structured memory missing");
  }
});

Deno.test("memory context rejects stale or unrelated memory", () => {
  const outline: ProjectOutline = {
    id: "outline",
    title: "Memory Orchard",
    chapters: [{
      id: "chapter",
      title: "Chapter",
      position: 0,
      sections: [{
        id: "section",
        generation_output_id: "output-a",
        title: "Opening",
        container: "scene",
        pov: null,
        body: "selected prose",
        position: 0,
        parent_id: null,
        story_arc_beat_id: null,
        story_arc_role: null,
      }],
    }],
    parts: [],
  };
  for (
    const row of [
      {
        generation_output_id: "other",
        memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
      },
      {
        generation_output_id: "output-a",
        memory_pipeline_version: "legacy-v1",
      },
    ]
  ) {
    try {
      buildSynopsisMemoryContext(outline, [{
        outline_section_id: "section",
        generation_output_id: row.generation_output_id,
        memory_pipeline_version: row.memory_pipeline_version,
        extracted_summary: "old",
        character_deltas: [],
        plot_thread_deltas: [],
        continuity_facts: [],
        open_loops: [],
        scene_ending_state: null,
      }]);
      throw new Error("expected memory rejection");
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes("memory")) {
        throw error;
      }
    }
  }
});

Deno.test("lifecycle aggregation removes resolved hooks and superseded facts", () => {
  const sections = [0, 1].map((index) => ({
    id: `life-section-${index}`,
    generation_output_id: `life-output-${index}`,
    title: `Life ${index}`,
    container: "scene" as const,
    pov: null,
    body: `body-${index}`,
    position: index,
    parent_id: null,
    story_arc_beat_id: null,
    story_arc_role: null,
  }));
  const context = buildSynopsisMemoryContext({
    id: "life-outline",
    title: "Lifecycle Story",
    chapters: [{ id: "chapter", title: "Chapter", position: 0, sections }],
    parts: [],
  }, [
    {
      outline_section_id: sections[0].id,
      generation_output_id: sections[0].generation_output_id,
      memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
      extracted_summary: "The mystery opens.",
      character_deltas: [],
      plot_thread_deltas: [{
        reference: "thread:mystery",
        thread_name: "Mystery",
        status: "introduced",
        description: "A hidden signal.",
      }],
      continuity_facts: [{
        reference: "fact:key",
        fact: "The key is hidden.",
        active: true,
      }],
      open_loops: [{
        reference: "loop:signal",
        description: "Who sent the signal?",
        status: "open",
      }],
      scene_ending_state: null,
    },
    {
      outline_section_id: sections[1].id,
      generation_output_id: sections[1].generation_output_id,
      memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
      extracted_summary: "The mystery is resolved.",
      character_deltas: [],
      plot_thread_deltas: [{
        reference: "thread:mystery",
        thread_name: "Mystery",
        status: "resolved",
        description: "The signal is explained.",
      }],
      continuity_facts: [{
        reference: "fact:key",
        fact: "The key is destroyed.",
        active: false,
      }],
      open_loops: [{
        reference: "loop:signal",
        description: "Who sent the signal?",
        status: "resolved",
      }],
      scene_ending_state: null,
    },
  ]);
  if (!context.includes("Mystery (resolved)")) {
    throw new Error("final thread state missing");
  }
  if (context.includes("Open narrative loops: Who sent the signal?")) {
    throw new Error("resolved loop remained open");
  }
  if (context.includes("Active consequential facts: The key is destroyed.")) {
    throw new Error("superseded fact was treated as active");
  }
});

for (const count of [100, 150, 200, 1000]) {
  Deno.test(`scene memory context remains bounded for ${count} sections`, () => {
    const sections = Array.from({ length: count }, (_, index) => ({
      id: `section-${index}`,
      generation_output_id: `output-${index}`,
      title: `Section ${index}`,
      container: "scene" as const,
      pov: null,
      body: `body-${index}`,
      position: index,
      parent_id: null,
      story_arc_beat_id: null,
      story_arc_role: null,
    }));
    const context = buildSynopsisMemoryContext(
      {
        id: "large-outline",
        title: "Large Story",
        chapters: [{ id: "chapter", title: "Chapter", position: 0, sections }],
        parts: [],
      },
      sections.map((section, index) => ({
        outline_section_id: section.id,
        generation_output_id: section.generation_output_id!,
        memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
        extracted_summary: `${
          index === 0
            ? "BEGINNING"
            : index === Math.floor(count / 2)
            ? "MIDDLE"
            : index === Math.floor(count * 0.75)
            ? "CLIMAX"
            : index === count - 1
            ? "ENDING"
            : "Scene"
        } event ${index} `.repeat(20),
        character_deltas: [{
          character_name: `Character ${index}`,
          relationship_delta: "relationship change ".repeat(40),
          knowledge_delta: "new knowledge ".repeat(40),
          goals: "urgent goal ".repeat(40),
          emotional_stance: "volatile stance ".repeat(40),
        }],
        plot_thread_deltas: [{
          reference: `thread-${index}`,
          thread_name: `Conflict ${index}`,
          status: index === count - 1 ? "resolved" : "advanced",
          description: "conflict progression ".repeat(60),
        }],
        continuity_facts: [{
          reference: `fact-${index}`,
          fact: "consequential event ".repeat(60),
          active: index % 3 !== 0,
        }],
        open_loops: [{
          reference: `loop-${index}`,
          description: "narrative hook ".repeat(60),
          status: index % 4 === 0 ? "resolved" : "open",
        }],
        scene_ending_state: {
          immediate_pressure: "ending pressure ".repeat(60),
          character_positions: [{
            character: `Character ${index}`,
            location: "location ".repeat(40),
            immediate_state: "state ".repeat(40),
          }],
        },
      })),
    );
    if (context.length > MAX_SYNOPSIS_CONTEXT_CHARS) {
      throw new Error(`context exceeded budget for ${count}`);
    }
    for (const marker of ["BEGINNING", "MIDDLE", "CLIMAX", "ENDING"]) {
      if (!context.includes(marker)) {
        throw new Error(`${marker} coverage missing for ${count}`);
      }
    }
  });
}

Deno.test("scene memory context bounds oversized story metadata", () => {
  const section = {
    id: "metadata-section",
    generation_output_id: "metadata-output",
    title: "Opening",
    container: "scene" as const,
    pov: null,
    body: "generated prose",
    position: 0,
    parent_id: null,
    story_arc_beat_id: null,
    story_arc_role: null,
  };
  const context = buildSynopsisMemoryContext({
    id: "metadata-outline",
    title: "Metadata Story",
    storyBrief: { summary: "x".repeat(70_000) },
    chapters: [{
      id: "chapter",
      title: "Chapter",
      position: 0,
      sections: [section],
    }],
    parts: [],
  } as any, [{
    outline_section_id: section.id,
    generation_output_id: section.generation_output_id,
    memory_pipeline_version: CURRENT_MEMORY_PIPELINE_VERSION,
    extracted_summary: "The story begins.",
    character_deltas: [],
    plot_thread_deltas: [],
    continuity_facts: [],
    open_loops: [],
    scene_ending_state: null,
  }]);
  if (context.length > MAX_SYNOPSIS_CONTEXT_CHARS) {
    throw new Error("oversized story metadata exceeded context budget");
  }
});

Deno.test("synopsis validation matches the prompt's 80–180 word contract", () => {
  const valid = Array.from({ length: 80 }, (_, index) => `word${index}`).join(
    " ",
  );
  if (validateSynopsisContent(valid) !== valid) {
    throw new Error("valid synopsis rejected");
  }
  for (const count of [79, 181]) {
    const content = Array.from({ length: count }, (_, index) => `word${index}`)
      .join(" ");
    try {
      validateSynopsisContent(content);
      throw new Error(`expected ${count}-word synopsis to fail`);
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes("80 and 180")) {
        throw error;
      }
    }
  }
});

Deno.test("operation identity separates intentional regeneration from retries", async () => {
  const base = {
    action: "generate" as const,
    project_id: "p",
    title: "Same title",
    operation_id: "operation-a",
  };
  const retry = await idempotencyKey("user", base);
  const deliberateRegeneration = await idempotencyKey("user", {
    ...base,
    operation_id: "operation-b",
  });
  if (retry !== await idempotencyKey("user", base)) {
    throw new Error("same operation did not remain idempotent");
  }
  if (retry === deliberateRegeneration) {
    throw new Error("new operation reused the retry idempotency key");
  }
});

Deno.test("handler rejects insufficient credits before provider dispatch", async () => {
  let providerCalls = 0;
  const deps = makeSynopsisDependencies({ availableCredits: 0 });
  const provider = deps.provider;
  deps.provider = {
    complete: (...args: unknown[]) => {
      providerCalls++;
      return provider.complete(...args as never[]);
    },
  };
  const response = await handleSynopsis("user", TEST_REQUEST, deps);
  if (response.status !== 402) {
    throw new Error(`expected 402, got ${response.status}`);
  }
  if (providerCalls !== 0) {
    throw new Error("provider dispatched despite insufficient credits");
  }
});

Deno.test("handler maps provider failure without settling credits", async () => {
  const deps = makeSynopsisDependencies({
    availableCredits: 100,
    providerError: new ProviderError(
      "temporarily overloaded",
      "provider_overloaded",
      true,
    ),
  });
  const response = await handleSynopsis("user", TEST_REQUEST, deps);
  if (response.status !== 502) {
    throw new Error(`expected 502, got ${response.status}`);
  }
});

Deno.test("handler settles a successful synopsis through shared billing", async () => {
  let settlementCalls = 0;
  const deps = makeSynopsisDependencies({
    availableCredits: 100,
    providerDelayMs: 10,
  });
  const originalRPC = deps.adminClient.rpc;
  deps.adminClient.rpc = (name: string, params: unknown) => {
    if (name === "settle_billable_usage") settlementCalls++;
    return originalRPC(name, params);
  };
  const response = await handleSynopsis("user", TEST_REQUEST, deps);
  if (response.status !== 200) {
    throw new Error(`expected 200, got ${response.status}`);
  }
  if (settlementCalls !== 1) {
    throw new Error("successful synopsis did not settle exactly once");
  }
  const body = await response.json();
  if (body.synopsis !== validSynopsis()) {
    throw new Error("synopsis content was not returned");
  }
});

Deno.test("completed operation returns its persisted synopsis without provider dispatch", async () => {
  const deps = makeSynopsisDependencies({ availableCredits: 100 });
  const first = await handleSynopsis("user", TEST_REQUEST, deps);
  if (first.status !== 200) {
    throw new Error(`expected first success, got ${first.status}`);
  }
  const callsAfterFirst = deps.providerCalls();
  const second = await handleSynopsis("user", TEST_REQUEST, deps);
  if (second.status !== 200) {
    throw new Error(`expected replay success, got ${second.status}`);
  }
  if (deps.providerCalls() !== callsAfterFirst) {
    throw new Error("completed replay dispatched provider");
  }
  if ((await second.json()).synopsis !== validSynopsis()) {
    throw new Error("replay did not return persisted synopsis");
  }
});

Deno.test("already-paid replay bypasses credit preflight", async () => {
  const deps = makeSynopsisDependencies({ availableCredits: 100 });
  const first = await handleSynopsis("user", TEST_REQUEST, deps);
  if (first.status !== 200) {
    throw new Error(`expected initial success, got ${first.status}`);
  }
  deps.creditStore.loadOrDefault = () =>
    Promise.resolve({
      user_id: "user",
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: 0,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "test",
      updated_at: "2026-01-01",
    });
  const replay = await handleSynopsis("user", TEST_REQUEST, deps);
  if (replay.status !== 200) {
    throw new Error(`paid replay was preflight-rejected: ${replay.status}`);
  }
  if (deps.providerCalls() !== 1) {
    throw new Error("paid replay dispatched provider");
  }
});

Deno.test("concurrent operation claims allow only one provider dispatch", async () => {
  const deps = makeSynopsisDependencies({
    availableCredits: 100,
    providerDelayMs: 10,
  });
  const [first, second] = await Promise.all([
    handleSynopsis("user", TEST_REQUEST, deps),
    handleSynopsis("user", TEST_REQUEST, deps),
  ]);
  if (![first.status, second.status].includes(409)) {
    throw new Error(
      `expected one concurrent request to be rejected, got ${first.status}/${second.status}`,
    );
  }
  if (deps.providerCalls() !== 1) {
    throw new Error("concurrent claim dispatched provider twice");
  }
});

Deno.test("settlement interruption recovers persisted synopsis without provider redispatch", async () => {
  const deps = makeSynopsisDependencies({
    availableCredits: 100,
    settlementFailures: 1,
  });
  const first = await handleSynopsis("user", TEST_REQUEST, deps);
  if (first.status !== 502) {
    throw new Error(
      `expected interrupted settlement failure, got ${first.status}`,
    );
  }
  const second = await handleSynopsis("user", TEST_REQUEST, deps);
  if (second.status !== 200) {
    throw new Error(`expected recovery success, got ${second.status}`);
  }
  if (deps.providerCalls() !== 1) {
    throw new Error("recovery redispatched provider");
  }
});

Deno.test("different operation IDs remain independent regeneration requests", async () => {
  const firstDeps = makeSynopsisDependencies({ availableCredits: 100 });
  const secondDeps = makeSynopsisDependencies({ availableCredits: 100 });
  const first = await handleSynopsis("user", TEST_REQUEST, firstDeps);
  const second = await handleSynopsis("user", {
    ...TEST_REQUEST,
    operation_id: "operation-b",
  }, secondDeps);
  if (first.status !== 200 || second.status !== 200) {
    throw new Error("regeneration operation failed");
  }
  if (firstDeps.providerCalls() !== 1 || secondDeps.providerCalls() !== 1) {
    throw new Error("regeneration did not dispatch independently");
  }
});
