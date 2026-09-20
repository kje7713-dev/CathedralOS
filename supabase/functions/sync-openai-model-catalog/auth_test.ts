import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { isAuthorized, readSupabaseSecretKey } from "./_auth.ts";

const key = "sb_secret_test";
const request = (headers: Record<string, string> = {}) =>
  new Request("https://test.example/sync", { method: "POST", headers });

Deno.test("scheduler apikey authenticates with the default secret key", () => {
  const expected = readSupabaseSecretKey(JSON.stringify({ default: key }));
  assertEquals(isAuthorized(request({ apikey: key }), expected), true);
});

Deno.test("missing or incorrect apikey is rejected", () => {
  const expected = readSupabaseSecretKey(JSON.stringify({ default: key }));
  assertEquals(isAuthorized(request(), expected), false);
  assertEquals(isAuthorized(request({ apikey: "wrong" }), expected), false);
});

Deno.test("missing, malformed, or incomplete secret-key configuration fails closed", () => {
  for (
    const raw of [
      undefined,
      "not-json",
      "[]",
      "{}",
      JSON.stringify({ default: "" }),
    ]
  ) {
    const expected = readSupabaseSecretKey(raw);
    assertEquals(expected, "");
    assertEquals(isAuthorized(request({ apikey: key }), expected), false);
  }
});

Deno.test("legacy Authorization bearer alone does not authenticate", () => {
  const expected = readSupabaseSecretKey(JSON.stringify({ default: key }));
  assertEquals(
    isAuthorized(
      request({ Authorization: "Bearer legacy-service-role" }),
      expected,
    ),
    false,
  );
});
