import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  durableRunContainsSection,
  internalAuthHeader,
  isTrustedInternalRequest,
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

  Deno.test("section ownership is derived from durable run sections", () => {
    const run = { sections: [{ id: "section-a" }, { id: "section-b" }] };
    assert(durableRunContainsSection(run, "section-a"));
    assertFalse(durableRunContainsSection(run, "section-z"));
    assertEquals(internalAuthHeader("k"), "Bearer k");
  });
}
