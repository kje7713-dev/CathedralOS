// =============================================================================
// backend-health — Supabase Edge Function
//
// Lightweight operational health check for the CathedralOS backend.
// Returns non-secret status information useful for diagnosing configuration
// and connectivity issues without exposing any secret values.
//
// Response includes:
//   - Whether each required secret env var is configured (true/false only)
//   - The configured OpenAI model name (non-secret)
//   - Whether the database is reachable (simple connectivity check)
//   - Current server timestamp
//
// This function does NOT require user authentication so it can be called by
// developers and automated monitoring without needing a user session.
//
// Security notes:
//   - No secret values (API keys, passwords) are included in the response.
//   - No user data is queried or returned.
//   - The anon key embedded in the iOS app is sufficient to call this endpoint.
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

function corsResponse(body: string, init: ResponseInit = {}): Response {
  return new Response(body, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...(init.headers ?? {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return corsResponse("", { status: 204 });
  }

  if (req.method !== "GET") {
    return corsResponse(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405 },
    );
  }

  // -------------------------------------------------------------------------
  // Env var presence checks (never expose values — only true/false)
  // -------------------------------------------------------------------------

  const openaiKeyPresent = Boolean(Deno.env.get("OPENAI_API_KEY"));
  const supabaseURLPresent = Boolean(Deno.env.get("SUPABASE_URL"));
  const serviceRoleKeyPresent = Boolean(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));

  // Report the configured model name (this is not a secret).
  const openaiModel = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-4o-mini (default)";

  // -------------------------------------------------------------------------
  // Database connectivity check
  // -------------------------------------------------------------------------

  let dbReachable = false;
  let dbError: string | null = null;

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (supabaseURL && serviceRoleKey) {
    try {
      const adminClient = createClient(supabaseURL, serviceRoleKey);
      // A simple count query against generation_request_logs is a lightweight
      // connectivity check that does not return any user data.
      const { error } = await adminClient
        .from("generation_request_logs")
        .select("id", { count: "exact", head: true })
        .limit(1);

      if (error) {
        dbError = `DB query error: ${error.message}`;
      } else {
        dbReachable = true;
      }
    } catch (err) {
      dbError = `DB connection error: ${err instanceof Error ? err.message : String(err)}`;
    }
  } else {
    dbError = "SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not configured";
  }

  // -------------------------------------------------------------------------
  // Overall status
  // -------------------------------------------------------------------------

  const generationFunctionConfigured = openaiKeyPresent && serviceRoleKeyPresent && dbReachable;

  const healthPayload = {
    status: generationFunctionConfigured ? "ok" : "degraded",
    timestamp: new Date().toISOString(),
    checks: {
      openaiKeyConfigured: openaiKeyPresent,
      openaiModel,
      supabaseURLConfigured: supabaseURLPresent,
      serviceRoleKeyConfigured: serviceRoleKeyPresent,
      databaseReachable: dbReachable,
    },
    generationFunctionConfigured,
    // Include a brief error summary when degraded (never includes secret values).
    ...(dbError ? { dbError } : {}),
  };

  return corsResponse(
    JSON.stringify(healthPayload),
    { status: generationFunctionConfigured ? 200 : 503 },
  );
});
