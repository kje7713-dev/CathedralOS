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
import { buildSynopsisMemoryContext } from "./_memory_context.ts";

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
}) {
  let operationRow: Record<string, unknown> | null = null;
  let providerCalls = 0;
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
        const chain = {
          eq: () => chain,
          maybeSingle: () =>
            Promise.resolve({ data: operationRow, error: null }),
        };
        return {
          select: () => chain,
          upsert: (row: Record<string, unknown>) => {
            operationRow = { ...operationRow, ...row };
            return Promise.resolve({ error: null });
          },
          update: (row: Record<string, unknown>) => ({
            eq: () => ({
              eq: () => {
                operationRow = { ...operationRow, ...row };
                return Promise.resolve({ error: null });
              },
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
      if (name === "settle_billable_usage") {
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
    complete:
      () => (providerCalls++,
        options.providerError
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
          })),
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
  const deps = makeSynopsisDependencies({ availableCredits: 100 });
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
