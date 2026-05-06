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
//   - Whether the database is reachable (health_check_ping() RPC probe)
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

// Structured error details returned when the DB probe fails.
// Contains only sanitized, non-secret values (message, Postgres error code,
// and hint from the PostgREST response body — never raw SQL or credentials).
interface DbErrorDetail {
  message: string;
  code?: string;
  hint?: string;
}

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

// ---------------------------------------------------------------------------
// Handler — exported for unit testing; Deno.serve wires it up below.
// ---------------------------------------------------------------------------

export async function handler(
  req: Request,
  fetchFn: typeof fetch = globalThis.fetch,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
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
  // Database connectivity check via health_check_ping() RPC
  //
  // We call the dedicated health_check_ping() SQL function (added in
  // 20260506000000_add_health_check_ping.sql) rather than querying a
  // user-data table, so the probe is guaranteed to succeed once the DB is
  // reachable regardless of whether any application rows exist.
  // -------------------------------------------------------------------------

  let dbReachable = false;
  let dbError: DbErrorDetail | null = null;

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (supabaseURL && serviceRoleKey) {
    try {
      const probeURL = `${supabaseURL}/rest/v1/rpc/health_check_ping`;
      const probeRes = await fetchFn(probeURL, {
        method: "POST",
        headers: {
          "apikey": serviceRoleKey,
          "Authorization": `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: "{}",
      });

      if (probeRes.ok) {
        dbReachable = true;
      } else {
        // Extract sanitized diagnostic fields from the PostgREST error body.
        // PostgREST errors are JSON with { message, code, details, hint }.
        // We surface message/code/hint only — never raw SQL or stack traces.
        const rawBody = await probeRes.text();
        try {
          const errJson = JSON.parse(rawBody) as Record<string, unknown>;
          dbError = {
            message: typeof errJson.message === "string"
              ? errJson.message
              : `HTTP ${probeRes.status}`,
            ...(typeof errJson.code === "string" ? { code: errJson.code } : {}),
            ...(typeof errJson.hint === "string" && errJson.hint
              ? { hint: errJson.hint }
              : {}),
          };
        } catch {
          dbError = { message: `HTTP ${probeRes.status}` };
        }
      }
    } catch (err) {
      dbError = {
        message: err instanceof Error ? err.message : String(err),
      };
    }
  } else {
    dbError = { message: "SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not configured" };
  }

  // -------------------------------------------------------------------------
  // Overall status
  //
  // generationFunctionConfigured is true only when every dependency of the
  // generate-story Edge Function is confirmed present and reachable.
  // -------------------------------------------------------------------------

  const generationFunctionConfigured =
    openaiKeyPresent && supabaseURLPresent && serviceRoleKeyPresent && dbReachable;

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
    // Include structured error details when degraded (no secret values).
    ...(dbError ? { dbError } : {}),
  };

  console.log("[backend-health]", JSON.stringify(healthPayload));

  // Return 200 even when degraded so the Supabase dashboard test panel
  // surfaces the JSON body instead of hiding it behind a generic 503.
  return corsResponse(
    JSON.stringify(healthPayload),
    { status: 200 },
  );
}

Deno.serve((req: Request) => handler(req));
