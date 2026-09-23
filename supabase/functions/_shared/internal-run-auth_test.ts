import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  durableRunContainsSection,
  internalAuthHeader,
  isTrustedInternalRequest,
  loadDurableRunOwner,
  trustedResumeRunId,
} from "./internal-run-auth.ts";

defaultTest();

function defaultTest() {
  Deno.test("trusted internal mode requires exact service credential", () => {
    const key = "service-key";
    const req = new Request("https://example.test", {
      headers: { Authorization: internalAuthHeader(key) },
    });
    assert(isTrustedInternalRequest(req, key));
    assertFalse(isTrustedInternalRequest(req, "other-key"));
    assertFalse(isTrustedInternalRequest(
      new Request("https://example.test", {
        headers: { Authorization: "Bearer user-jwt" },
      }),
      key,
    ));
  });

  Deno.test("trusted continuation ignores body user identity and requires a run id", () => {
    const key = "service-key";
    const request = new Request("https://example.test", {
      headers: { Authorization: internalAuthHeader(key) },
    });
    assertEquals(
      trustedResumeRunId(request, key, {
        resume_run_id: " run-1 ",
        user_id: "attacker-controlled",
      }),
      "run-1",
    );
    assertEquals(trustedResumeRunId(request, key, { user_id: "user-1" }), null);
    assertEquals(
      trustedResumeRunId(
        new Request("https://example.test", {
          headers: { Authorization: "Bearer user-jwt" },
        }),
        key,
        { resume_run_id: "run-1" },
      ),
      null,
    );
  });

  Deno.test("durable owner lookup rejects missing runs and returns chapter owner", async () => {
    const client = {
      from: () => ({
        select: () => ({
          eq: () => ({
            maybeSingle: async () => ({
              data: {
                id: "run-1",
                user_id: "owner-1",
                outline_id: "outline-1",
                status: "running",
                sections: [{ id: "section-a" }],
              },
              error: null,
            }),
          }),
        }),
      }),
    } as never;
    const owner = await loadDurableRunOwner(client, "run-1");
    assertEquals(owner?.user_id, "owner-1");
    assertEquals(owner?.sections, [{ id: "section-a" }]);

    const missingClient = {
      from: () => ({
        select: () => ({
          eq: () => ({
            maybeSingle: async () => ({ data: null, error: null }),
          }),
        }),
      }),
    } as never;
    assertEquals(await loadDurableRunOwner(missingClient, "missing"), null);
  });

  Deno.test("section ownership is derived from durable run sections", () => {
    const run = { sections: [{ id: "section-a" }, { id: "section-b" }] };
    assert(durableRunContainsSection(run, "section-a"));
    assertFalse(durableRunContainsSection(run, "section-z"));
    assertEquals(internalAuthHeader("k"), "Bearer k");
  });
}
