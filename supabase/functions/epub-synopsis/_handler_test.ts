import {
  buildMessages,
  buildSynopsisSource,
  handleSynopsis,
  idempotencyKey,
  validateSynopsisContent,
  validateSynopsisRequest,
} from "./_handler.ts";
import type { ProjectOutline } from "../export-epub/_section_walker.ts";
import { ProviderError } from "../generate-story/_provider.ts";

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
    complete: () =>
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
        }),
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

Deno.test("canonical synopsis source preserves complete ordered export content", () => {
  const outline: ProjectOutline = {
    id: "outline",
    title: "The Glass Orchard",
    storyBrief: {
      projectSummary: "An orchard keeper inherits a dangerous secret.",
    },
    parts: [],
    chapters: [
      {
        id: "chapter-2",
        title: "Second",
        position: 1,
        sections: [{
          id: "section-2",
          title: "Aftermath",
          container: "scene",
          pov: null,
          body: "THE SECOND HALF OF THE STORY",
          position: 0,
          parent_id: null,
          story_arc_beat_id: null,
          story_arc_role: null,
        }],
      },
      {
        id: "chapter-1",
        title: "First",
        position: 0,
        sections: [{
          id: "section-1",
          title: "Beginning",
          container: "scene",
          pov: null,
          body: "THE COMPLETE OPENING AND CENTRAL CONFLICT",
          position: 0,
          parent_id: null,
          story_arc_beat_id: null,
          story_arc_role: null,
        }],
      },
    ],
  };
  const source = buildSynopsisSource(outline);
  if (
    source.indexOf("THE COMPLETE OPENING") > source.indexOf("THE SECOND HALF")
  ) {
    throw new Error("chapters were not ordered canonically");
  }
  if (!source.includes("THE SECOND HALF OF THE STORY")) {
    throw new Error("later canonical content was omitted");
  }
  if (!source.includes("An orchard keeper inherits")) {
    throw new Error("story metadata was omitted");
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
