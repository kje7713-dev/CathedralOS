import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  checkPublicSharingEligibility,
  PUBLIC_SHARING_MODERATION_MODEL,
  PUBLIC_SHARING_RESTRICTION_REASON,
  requireCurrentGenerationOutputEligibility,
  requireCurrentProjectEligibility,
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

Deno.test("generation-output eligibility requires the exact reviewed prose hash", async () => {
  const reviewed = "exact generated prose";
  const hash = await sha256Hex(reviewed);
  const client = {
    from() {
      return {
        select() {
          return {
            eq() {
              return {
                maybeSingle: async () => ({
                  data: {
                    outline_section_id: "section-1",
                    public_sharing_eligible: true,
                    public_sharing_checked_content_hash: hash,
                  },
                  error: null,
                }),
              };
            },
          };
        },
      };
    },
  };
  assertEquals(
    await requireCurrentGenerationOutputEligibility(
      client,
      "output-1",
      reviewed,
    ),
    { ok: true },
  );
  assertEquals(
    await requireCurrentGenerationOutputEligibility(
      client,
      "output-1",
      "different prose",
    ),
    {
      ok: false,
      reason: "public_sharing_eligibility_missing",
      sectionIDs: ["section-1"],
    },
  );
});

Deno.test("project eligibility uses current snapshot sections, not stale embeddings", async () => {
  const currentText = "current section";
  const currentHash = await sha256Hex(currentText);
  const client = {
    from(table: string) {
      if (table === "project_snapshots") {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: async () => ({
                    data: {
                      snapshot_json: {
                        outlines: [{ sections: [{ id: "section-current" }] }],
                      },
                    },
                    error: null,
                  }),
                };
              },
            };
          },
        };
      }
      return {
        select() {
          return {
            in: async () => ({
              data: [{
                outline_section_id: "section-current",
                raw_text: currentText,
                public_sharing_eligible: true,
                public_sharing_checked_content_hash: currentHash,
              }, {
                outline_section_id: "stale-deleted-section",
                raw_text: "old text",
                public_sharing_eligible: false,
                public_sharing_checked_content_hash: "old-hash",
              }],
              error: null,
            }),
          };
        },
      };
    },
  };

  assertEquals(
    await requireCurrentProjectEligibility(client, "snapshot-id"),
    { ok: true },
  );
});

Deno.test("project eligibility reports missing current snapshot sections", async () => {
  const client = {
    from(table: string) {
      if (table === "project_snapshots") {
        return {
          select() {
            return {
              eq() {
                return {
                  maybeSingle: async () => ({
                    data: {
                      snapshot_json: {
                        outlines: [{ sections: [{ id: "section-current" }] }],
                      },
                    },
                    error: null,
                  }),
                };
              },
            };
          },
        };
      }
      return {
        select() {
          return {
            in: async () => ({ data: [], error: null }),
          };
        },
      };
    },
  };

  assertEquals(
    await requireCurrentProjectEligibility(client, "snapshot-id"),
    {
      ok: false,
      reason: "public_sharing_eligibility_missing",
      sectionIDs: ["section-current"],
    },
  );
});
