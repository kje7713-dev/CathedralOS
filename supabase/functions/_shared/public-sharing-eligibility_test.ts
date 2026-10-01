import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  checkPublicSharingEligibility,
  PUBLIC_SHARING_MODERATION_MODEL,
  PUBLIC_SHARING_RESTRICTION_REASON,
  sha256Hex,
} from "./public-sharing-eligibility.ts";

Deno.test("public-sharing eligibility restricts only sexual/minors", async () => {
  const calls: Request[] = [];
  const result = await checkPublicSharingEligibility(
    "fictional section",
    "test-key",
    async (input, init) => {
      calls.push(new Request(input, init));
      return new Response(
        JSON.stringify({
          results: [{
            categories: {
              "sexual/minors": true,
              violence: true,
              profanity: true,
            },
          }],
        }),
        { status: 200 },
      );
    },
  );
  assertEquals(result.eligible, false);
  assertEquals(result.restrictionReason, PUBLIC_SHARING_RESTRICTION_REASON);
  assertEquals(
    JSON.parse(await calls[0].text()).model,
    PUBLIC_SHARING_MODERATION_MODEL,
  );
});

Deno.test("non-minors moderation categories remain eligible", async () => {
  const result = await checkPublicSharingEligibility(
    "fictional section",
    "test-key",
    async () =>
      new Response(
        JSON.stringify({
          results: [{ categories: { violence: true, "sexual/minors": false } }],
        }),
        { status: 200 },
      ),
  );
  assertEquals(result.eligible, true);
  assertEquals(result.restrictionReason, null);
});

Deno.test("content hash is deterministic", async () => {
  assertEquals(await sha256Hex("same"), await sha256Hex("same"));
  assertEquals((await sha256Hex("same")) !== await sha256Hex("changed"), true);
});

Deno.test("provider failure is not converted into an eligible result", async () => {
  await assertRejects(
    () =>
      checkPublicSharingEligibility(
        "fictional section",
        "test-key",
        async () => new Response("upstream", { status: 503 }),
      ),
    Error,
    "moderation request failed",
  );
});
