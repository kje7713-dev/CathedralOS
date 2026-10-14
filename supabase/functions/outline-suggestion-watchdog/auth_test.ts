import { assertEquals } from "jsr:@std/assert@1";
import { isAuthorized, readSecretKey } from "./_auth.ts";

Deno.test("watchdog accepts only the configured operator apikey", () => {
  const key = readSecretKey(JSON.stringify({ default: "operator-secret" }));
  assertEquals(isAuthorized("operator-secret", key), true);
  assertEquals(isAuthorized("wrong-secret", key), false);
  assertEquals(isAuthorized("operator-secret", ""), false);
  assertEquals(readSecretKey("not-json"), "");
});
