import {
  assert,
  assertEquals,
  assertNotEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import { handler } from "./_handler.ts";
import { normalizedPricingEvidence, parseOfficialPricing } from "./_parser.ts";

const lunaPage = `# GPT-5.6 Luna

Model ID: \`gpt-5.6-luna\`

## Pricing

### Text tokens

| Metric | Price | Unit |
| --- | ---: | --- |
| Input | $0.2 | 1M tokens |
| Cached input | $0.02 | 1M tokens |
| Output | $1.2 | 1M tokens |

- Prompts with >272K input tokens are priced at 2x input and 1.5x output for the full request.
- Cache writes are billed at 1.25x the uncached input token rate.

## Endpoints
`;

Deno.test("real official Luna Markdown parses required pricing", () => {
  const parsed = parseOfficialPricing(lunaPage, "gpt-5.6-luna", true);
  assertEquals(parsed.status, "verified");
  assertEquals(parsed.input_usd_per_1m, 0.2);
  assertEquals(parsed.cached_input_usd_per_1m, 0.02);
  assertEquals(parsed.output_usd_per_1m, 1.2);
  assertEquals(parsed.cache_write_usd_per_1m, 0.25);
  assertEquals(parsed.long_context_threshold_tokens, 272000);
  assertEquals(parsed.long_context_input_multiplier, 2);
  assertEquals(parsed.long_context_output_multiplier, 1.5);
});

Deno.test("required rates accept only explicit 1M-token units", () => {
  const wrongUnit = lunaPage.replace(
    "| Input | $0.2 | 1M tokens |",
    "| Input | $0.2 | 1K tokens |",
  );
  assertEquals(
    parseOfficialPricing(wrongUnit, "gpt-5.6-luna", true).error_code,
    "invalid_rate_unit",
  );

  const missingUnit = lunaPage.replace(
    "| Metric | Price | Unit |",
    "| Metric | Price |",
  );
  assertEquals(
    parseOfficialPricing(missingUnit, "gpt-5.6-luna", true).error_code,
    "invalid_rate_unit",
  );

  const duplicateUnit = lunaPage.replace(
    "| Input | $0.2 | 1M tokens |",
    "| Input | $0.2 | 1M tokens |\n| Input | $0.2 | 1K tokens |",
  );
  const duplicate = parseOfficialPricing(duplicateUnit, "gpt-5.6-luna", true);
  assertEquals(duplicate.status, "conflict");
  assertEquals(duplicate.error_code, "contradictory_pricing");
});

Deno.test("malformed Text tokens cannot be rescued by a later table", () => {
  const drifted = lunaPage.replace(
    "| Output | $1.2 | 1M tokens |",
    "| Result | $1.2 | 1M tokens |",
  ) + `

## Unrelated section

### Text tokens

| Metric | Price | Unit |
| --- | ---: | --- |
| Input | $0.2 | 1M tokens |
| Cached input | $0.02 | 1M tokens |
| Output | $1.2 | 1M tokens |`;
  assertEquals(
    parseOfficialPricing(drifted, "gpt-5.6-luna", true).error_code,
    "required_rate_missing",
  );
});

Deno.test("parser verifies model identity and fails closed on source drift", () => {
  assertEquals(
    parseOfficialPricing(lunaPage, "gpt-5.6-terra", true).error_code,
    "wrong_model",
  );
  assertEquals(
    parseOfficialPricing(
      lunaPage.replace("| Output | $1.2", "| Result | $1.2"),
      "gpt-5.6-luna",
      true,
    ).error_code,
    "required_rate_missing",
  );
  assertEquals(
    parseOfficialPricing(
      lunaPage.replace("### Text tokens", "### Tokens"),
      "gpt-5.6-luna",
      true,
    ).error_code,
    "pricing_table_missing",
  );
});

Deno.test("internal contradictory pricing is a real conflict", () => {
  const contradictory = lunaPage.replace(
    "| Output | $1.2 | 1M tokens |",
    "| Output | $1.2 | 1M tokens |\n| Output | $1.3 | 1M tokens |",
  );
  const parsed = parseOfficialPricing(contradictory, "gpt-5.6-luna", true);
  assertEquals(parsed.status, "conflict");
  assertEquals(parsed.error_code, "contradictory_pricing");
});

Deno.test("normalized evidence is stable across unrelated source noise", () => {
  const first = parseOfficialPricing(lunaPage, "gpt-5.6-luna", true);
  const second = parseOfficialPricing(
    "Build timestamp: 2026-09-19\n" + lunaPage + "\nFooter build hash: abc123",
    "gpt-5.6-luna",
    true,
  );
  assertEquals(
    normalizedPricingEvidence(first),
    normalizedPricingEvidence(second),
  );
});

Deno.test("incomplete observation is recorded without promotion or pricing mutation", async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const db = {
    from: () => ({}),
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
      models: [{
        provider_model: "gpt-5.6-luna",
        cache_write_pricing_required: true,
      }],
      now: () => new Date("2026-09-19T00:00:00Z"),
      fetchImpl: () =>
        Promise.resolve(
          new Response(
            lunaPage.replace(
              "Cache writes are billed at 1.25x the uncached input token rate.",
              "Cache writes are billed according to the current pricing policy.",
            ),
            { status: 200 },
          ),
        ),
    },
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).promoted, 0);
  const observation = calls[0].args.p_observation as Record<string, unknown>;
  assertEquals(observation.status, "incomplete");
  assertEquals(observation.error_code, "required_cache_write_rate_missing");
  assertStringIncludes(String(observation.source_url), ".md");
  assertNotEquals(observation.source_hash, "");
  assertNotEquals(observation.normalized_evidence_hash, "");
});

Deno.test("failed fetch records an observation without promotion", async () => {
  const calls: Array<Record<string, unknown>> = [];
  const response = await handler(
    new Request("https://test.example.com/sync-openai-pricing", {
      method: "POST",
    }),
    {
      db: {
        from: () => ({}),
        rpc: (_name: string, args: Record<string, unknown>) => {
          calls.push(args.p_observation as Record<string, unknown>);
          return Promise.resolve({ data: { promoted: false }, error: null });
        },
      },
      authorized: true,
      models: ["gpt-5.6-luna"],
      fetchImpl: () => Promise.reject(new Error("network")),
    },
  );
  assertEquals(response.status, 200);
  assertEquals(calls[0].status, "fetch_failed");
  assertEquals(
    calls[0].source_hash,
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(""),
    ).then((bytes) =>
      [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0"))
        .join("")
    ),
  );
});

Deno.test("unknown provider model cannot report promotion", async () => {
  let observation: Record<string, unknown> | undefined;
  const response = await handler(
    new Request("https://test.example.com/sync-openai-pricing", {
      method: "POST",
    }),
    {
      db: {
        from: () => ({}),
        rpc: (_name: string, args: Record<string, unknown>) => {
          observation = args.p_observation as Record<string, unknown>;
          return Promise.resolve({ data: { promoted: false }, error: null });
        },
      },
      authorized: true,
      models: [{
        provider_model: "gpt-does-not-exist",
        cache_write_pricing_required: false,
      }],
      fetchImpl: () =>
        Promise.resolve(
          new Response(
            lunaPage.replaceAll("gpt-5.6-luna", "gpt-does-not-exist"),
            { status: 200 },
          ),
        ),
    },
  );
  assertEquals(response.status, 200);
  assertEquals(observation?.status, "verified");
  assert(observation?.provider_model === "gpt-does-not-exist");
});
