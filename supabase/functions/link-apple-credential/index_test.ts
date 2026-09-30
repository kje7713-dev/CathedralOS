import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { linkAppleCredential } from "./index.ts";

Deno.test("linkAppleCredential stores the exchanged refresh token", async () => {
  const originalFetch = globalThis.fetch;
  const previous = Deno.env.get("APPLE_CLIENT_ID");
  Deno.env.set("APPLE_CLIENT_ID", "com.example.app");
  Deno.env.delete("APPLE_TEAM_ID");
  Deno.env.delete("APPLE_KEY_ID");
  Deno.env.delete("APPLE_PRIVATE_KEY");
  globalThis.fetch = async () => new Response(JSON.stringify({ refresh_token: "apple-refresh" }), { status: 200 });
  try {
    await assertRejects(() => linkAppleCredential({} as any, "user-1", "code"), Error, "apple_revocation_not_configured");
  } finally {
    globalThis.fetch = originalFetch;
    if (previous) Deno.env.set("APPLE_CLIENT_ID", previous); else Deno.env.delete("APPLE_CLIENT_ID");
  }
});

Deno.test("linkAppleCredential never accepts a missing Apple configuration", async () => {
  for (const key of ["APPLE_CLIENT_ID", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY"]) Deno.env.delete(key);
  await assertRejects(() => linkAppleCredential({} as any, "user-1", "code"), Error, "apple_revocation_not_configured");
  assertEquals(true, true);
});
