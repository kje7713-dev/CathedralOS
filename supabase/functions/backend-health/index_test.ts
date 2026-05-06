// =============================================================================
// index_test.ts — backend-health Edge Function tests
//
// Tests:
//   1.  OPTIONS preflight returns 204
//   2.  Non-GET method returns 405
//   3.  All checks pass → status "ok", generationFunctionConfigured: true
//   4.  Missing OPENAI_API_KEY → status "degraded", generationFunctionConfigured: false
//   5.  Missing SUPABASE_SERVICE_ROLE_KEY → db probe skipped, dbError set
//   6.  Missing SUPABASE_URL → db probe skipped, dbError set
//   7.  DB probe returns non-ok HTTP → databaseReachable: false, structured dbError
//   8.  DB probe response body parsed for code and hint
//   9.  DB probe fetch throws → databaseReachable: false, dbError.message set
//   10. generationFunctionConfigured requires all four vars + db reachable
//   11. status is "ok" only when generationFunctionConfigured is true
//   12. Response always includes required top-level keys
//
// All tests use mock fetch. No live Supabase or OpenAI calls.
// =============================================================================

import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.208.0/assert/mod.ts";

import { handler } from "./index.ts";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Sets all env vars required for a fully-healthy check. */
function setAllEnvVars() {
  Deno.env.set("OPENAI_API_KEY", "fake-openai-key");
  Deno.env.set("SUPABASE_URL", "https://fake.supabase.co");
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "fake-service-key");
}

/** Clears the three env vars controlled by the health check tests. */
function clearEnvVars() {
  Deno.env.delete("OPENAI_API_KEY");
  Deno.env.delete("SUPABASE_URL");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.delete("OPENAI_MODEL_DEFAULT");
}

/** Returns a mock fetch that responds to the health_check_ping RPC probe. */
function makePingFetch(
  opts: { ok?: boolean; status?: number; body?: string } = {},
): typeof fetch {
  const { ok = true, status = 200, body = "true" } = opts;
  return async (
    _url: string | URL | Request,
    _init?: RequestInit,
  ): Promise<Response> => {
    return new Response(body, { status: ok ? 200 : status });
  };
}

/** Returns a mock fetch that throws a network error. */
function makeThrowFetch(message: string): typeof fetch {
  return async (
    _url: string | URL | Request,
    _init?: RequestInit,
  ): Promise<Response> => {
    throw new Error(message);
  };
}

function makeGetRequest(): Request {
  return new Request("https://test.example.com/backend-health", {
    method: "GET",
  });
}

// ---------------------------------------------------------------------------
// 1. OPTIONS preflight
// ---------------------------------------------------------------------------

Deno.test("handler: OPTIONS returns 204", async () => {
  setAllEnvVars();
  const req = new Request("https://test.example.com/backend-health", {
    method: "OPTIONS",
  });
  const res = await handler(req, makePingFetch());
  assertEquals(res.status, 204);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 2. Non-GET method returns 405
// ---------------------------------------------------------------------------

Deno.test("handler: POST returns 405", async () => {
  setAllEnvVars();
  const req = new Request("https://test.example.com/backend-health", {
    method: "POST",
  });
  const res = await handler(req, makePingFetch());
  assertEquals(res.status, 405);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 3. All checks pass → status "ok"
// ---------------------------------------------------------------------------

Deno.test("handler: all checks pass returns ok status", async () => {
  setAllEnvVars();
  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  assertEquals(res.status, 200);

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "ok");
  assertEquals((body.checks as Record<string, unknown>).openaiKeyConfigured, true);
  assertEquals((body.checks as Record<string, unknown>).supabaseURLConfigured, true);
  assertEquals((body.checks as Record<string, unknown>).serviceRoleKeyConfigured, true);
  assertEquals((body.checks as Record<string, unknown>).databaseReachable, true);
  assertEquals(body.generationFunctionConfigured, true);
  assertEquals(body.dbError, undefined);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 4. Missing OPENAI_API_KEY → degraded
// ---------------------------------------------------------------------------

Deno.test("handler: missing OPENAI_API_KEY returns degraded", async () => {
  setAllEnvVars();
  Deno.env.delete("OPENAI_API_KEY");

  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  assertEquals(res.status, 200);

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "degraded");
  assertEquals((body.checks as Record<string, unknown>).openaiKeyConfigured, false);
  assertEquals(body.generationFunctionConfigured, false);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 5. Missing SUPABASE_SERVICE_ROLE_KEY → db probe skipped
// ---------------------------------------------------------------------------

Deno.test("handler: missing SUPABASE_SERVICE_ROLE_KEY skips db probe", async () => {
  setAllEnvVars();
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");

  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "degraded");
  assertEquals((body.checks as Record<string, unknown>).databaseReachable, false);
  assertEquals(body.generationFunctionConfigured, false);

  // dbError should be set because the probe was skipped due to missing config.
  assertExists(body.dbError);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 6. Missing SUPABASE_URL → db probe skipped
// ---------------------------------------------------------------------------

Deno.test("handler: missing SUPABASE_URL skips db probe and marks degraded", async () => {
  setAllEnvVars();
  Deno.env.delete("SUPABASE_URL");

  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "degraded");
  assertEquals((body.checks as Record<string, unknown>).supabaseURLConfigured, false);
  assertEquals((body.checks as Record<string, unknown>).databaseReachable, false);
  assertEquals(body.generationFunctionConfigured, false);
  assertExists(body.dbError);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 7. DB probe returns non-ok HTTP → structured dbError
// ---------------------------------------------------------------------------

Deno.test("handler: db probe HTTP error returns degraded with dbError", async () => {
  setAllEnvVars();
  const errorBody = JSON.stringify({
    message: 'relation "health_check_ping" does not exist',
    code: "42883",
    hint: null,
    details: null,
  });
  const res = await handler(
    makeGetRequest(),
    makePingFetch({ ok: false, status: 404, body: errorBody }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "degraded");
  assertEquals((body.checks as Record<string, unknown>).databaseReachable, false);
  assertExists(body.dbError);

  const dbErr = body.dbError as Record<string, unknown>;
  assertEquals(dbErr.message, 'relation "health_check_ping" does not exist');
  assertEquals(dbErr.code, "42883");
  assertEquals(dbErr.hint, undefined); // null hint should be omitted
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 8. DB probe error body parsed for code and hint
// ---------------------------------------------------------------------------

Deno.test("handler: db probe error body includes hint when present", async () => {
  setAllEnvVars();
  const errorBody = JSON.stringify({
    message: "permission denied",
    code: "42501",
    hint: "Grant EXECUTE on the function",
    details: null,
  });
  const res = await handler(
    makeGetRequest(),
    makePingFetch({ ok: false, status: 403, body: errorBody }),
  );
  const body = await res.json() as Record<string, unknown>;
  const dbErr = body.dbError as Record<string, unknown>;
  assertEquals(dbErr.code, "42501");
  assertEquals(dbErr.hint, "Grant EXECUTE on the function");
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 9. DB probe fetch throws → dbError.message set
// ---------------------------------------------------------------------------

Deno.test("handler: db probe fetch throws returns degraded with error message", async () => {
  setAllEnvVars();
  const res = await handler(
    makeGetRequest(),
    makeThrowFetch("Connection refused"),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.status, "degraded");
  assertEquals((body.checks as Record<string, unknown>).databaseReachable, false);

  const dbErr = body.dbError as Record<string, unknown>;
  assertEquals(dbErr.message, "Connection refused");
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 10. generationFunctionConfigured requires all four vars + db
// ---------------------------------------------------------------------------

Deno.test("handler: generationFunctionConfigured false when db unreachable even with all keys", async () => {
  setAllEnvVars();
  const res = await handler(
    makeGetRequest(),
    makePingFetch({ ok: false, status: 503, body: '{"message":"unavailable","code":"503"}' }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.generationFunctionConfigured, false);
  assertEquals(body.status, "degraded");
  clearEnvVars();
});

Deno.test("handler: generationFunctionConfigured true only when all keys set and db reachable", async () => {
  setAllEnvVars();
  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const body = await res.json() as Record<string, unknown>;
  assertEquals(body.generationFunctionConfigured, true);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 11. status "ok" only when generationFunctionConfigured is true
// ---------------------------------------------------------------------------

Deno.test("handler: status is ok iff generationFunctionConfigured is true", async () => {
  // Healthy path
  setAllEnvVars();
  const okRes = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const okBody = await okRes.json() as Record<string, unknown>;
  assertEquals(okBody.status, "ok");
  assertEquals(okBody.generationFunctionConfigured, true);

  // Degrade by removing OPENAI_API_KEY
  Deno.env.delete("OPENAI_API_KEY");
  const degradedRes = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const degradedBody = await degradedRes.json() as Record<string, unknown>;
  assertEquals(degradedBody.status, "degraded");
  assertEquals(degradedBody.generationFunctionConfigured, false);
  clearEnvVars();
});

// ---------------------------------------------------------------------------
// 12. Response always includes required top-level keys
// ---------------------------------------------------------------------------

Deno.test("handler: response always includes required top-level keys", async () => {
  setAllEnvVars();
  const res = await handler(makeGetRequest(), makePingFetch({ ok: true }));
  const body = await res.json() as Record<string, unknown>;

  assertExists(body.status);
  assertExists(body.timestamp);
  assertExists(body.checks);
  // generationFunctionConfigured must always be present (boolean)
  assertEquals(typeof body.generationFunctionConfigured, "boolean");
  clearEnvVars();
});
