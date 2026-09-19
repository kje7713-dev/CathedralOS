import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { handler } from "./_handler.ts";
import {
  parseOfficialPricing,
  reconcileOfficialPricingSources,
} from "./_parser.ts";

const page = (model = "gpt-4o-mini", rates = ["0.15", "0.075", "0.60"]) =>
  `# ${model}\n\nModel ID: \`${model}\`\n\n## Pricing\n\n### Text tokens\n\n| Metric | Price | Unit |\n| --- | ---: | --- |\n| Input | $${
    rates[0]
  } | 1M tokens |\n| Cached input | $${rates[1]} | 1M tokens |\n| Output | $${
    rates[2]
  } | 1M tokens |`;

Deno.test("pricing parser accepts the exact model and labeled rates", () => {
  assertEquals(parseOfficialPricing(page(), "gpt-4o-mini"), {
    provider_model: "gpt-4o-mini",
    status: "verified",
    input_usd_per_1m: 0.15,
    cached_input_usd_per_1m: 0.075,
    cache_write_usd_per_1m: null,
    output_usd_per_1m: 0.6,
    long_context_threshold_tokens: null,
    long_context_input_multiplier: null,
    long_context_output_multiplier: null,
    error_code: null,
  });
});

Deno.test("pricing parser rejects a page for the wrong model", () => {
  assertEquals(
    parseOfficialPricing(page("gpt-4o"), "gpt-4o-mini").error_code,
    "wrong_model",
  );
});

Deno.test("pricing parser rejects incomplete and ambiguous rate tables", () => {
  assertEquals(
    parseOfficialPricing(
      page("gpt-4o-mini", ["0.15", "0.075", ""]),
      "gpt-4o-mini",
    ).error_code,
    "required_rate_missing",
  );
  const duplicate = page() + "\n| Input | $0.20 | 1M tokens |";
  assertEquals(
    parseOfficialPricing(duplicate, "gpt-4o-mini").error_code,
    "required_rate_missing",
  );
});

Deno.test("pricing parser captures cache-write and long-context metadata", () => {
  const markdown =
    `${page()}\n\n> Above 272K tokens, input 2x output 1.5x\n\n| Cache write | $0.20 | 1M tokens |`;
  const parsed = parseOfficialPricing(markdown, "gpt-4o-mini");
  assertEquals(parsed.status, "verified");
  assertEquals(parsed.cache_write_usd_per_1m, 0.2);
  assertEquals(parsed.long_context_threshold_tokens, 272000);
  assertEquals(parsed.long_context_input_multiplier, 2);
  assertEquals(parsed.long_context_output_multiplier, 1.5);
});

Deno.test("source disagreement becomes conflict and cannot promote", () => {
  const primary = parseOfficialPricing(page(), "gpt-4o-mini");
  const secondary = parseOfficialPricing(
    page("gpt-4o-mini", ["0.20", "0.10", "0.80"]),
    "gpt-4o-mini",
  );
  assertEquals(
    reconcileOfficialPricingSources(primary, secondary).status,
    "conflict",
  );
});

Deno.test("sync records parser failure without overwriting known-good rates", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const db = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return Promise.resolve({ data: { promoted: false }, error: null });
    },
  };
  const response = await handler(
    new Request("https://test.example.com/sync-openai-pricing", {
      method: "POST",
    }),
    {
      db,
      authorized: true,
      models: ["gpt-4o-mini"],
      now: () => new Date("2026-09-19T00:00:00Z"),
      fetchImpl: () =>
        Promise.resolve(new Response("not a model page", { status: 200 })),
    },
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).failed, 1);
  const observation = calls[0].args.p_observation as Record<string, unknown>;
  assertEquals(observation.status, "unsupported");
  assertEquals(observation.error_code, "wrong_model");
  assertStringIncludes(String(observation.source_url), "developers.openai.com");
});
