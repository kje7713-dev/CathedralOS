// =============================================================================
// run-outline Edge Function (Phase 8 per docs/multi-section-generation.md)
//
// Multi-section generation orchestrator. Kicks off a chapter run that walks
// outline_sections by parent_id (leaf = single; chapter parent = walks
// children in position order). Per-section generation calls generate-story
// with narrow prior-context queries against the 5 structured columns.
//
// v1 (Day 1 skeleton — Day 2 will add the actual outline-walker + per-section
// generation loop): auth, rate-limit, credit reserve, chapter_runs row
// creation. The synchronous response acknowledges kickoff; Day 2 adds
// GET /functions/v1/run-outline/:id/status for polling.
//
// Idempotency (Kevin 14:22 EDT Q6, picked simplest):
//   - column `idempotency_key` is UNIQUE (same client can't kickoff same anchor twice)
//   - partial unique index on (outline_id, start_parent_section_id) WHERE status='running'
//     — only one RUNNING run per anchor at a time, across all clients
// Duplicate kickoff returns 409 + existing run_id.
//
// Per RFC (docs/multi-section-generation.md): stop-the-chain on first
// failure (Day 2), per-section cost reserve at kickoff (released on completion).
//
// Request:  POST {
//             outline_id,
//             start_parent_section_id,  // leaf section OR chapter parent
//             model                      // optional, e.g. "gpt-5.6-luna"
//           }
// Response: 202 { run_id, status: "running", created_at }
//           409 { errorCode: "already_running", run_id }
//           400/401/500 per existing pattern (embed-section style)
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, { ...init, headers: { ...CORS_HEADERS, ...(init.headers ?? {}) } });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface RunOutlineRequest {
  outline_id: string;
  start_parent_section_id: string;
  model?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return corsResponse("", { status: 204 });
  }
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth: validate user JWT, extract user_id (mirrors embed-section v2 pattern).
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse("unauthorized", "missing Authorization header", 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse("unauthorized", "invalid JWT", 401);
  }
  const userId = userData.user.id;

  // 2. Parse + validate body.
  let body: RunOutlineRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  if (!body.outline_id || !body.start_parent_section_id) {
    return errorResponse(
      "invalid_body",
      "outline_id and start_parent_section_id required",
      400,
    );
  }

  // 3. Service-role client for writes (RLS bypassed). The user-id check
  //    on the RLS policy would also authorize user-scoped writes; service-role
  //    is consistent with embed-section's pattern.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  // 4. Idempotency: try insert; on 23505 (unique_violation) return the
  //    existing run_id with 409.
  const idempotencyKey =
    `${userId}:${body.outline_id}:${body.start_parent_section_id}`;
  const { data: run, error: insertErr } = await adminClient
    .from("chapter_runs")
    .insert({
      outline_id: body.outline_id,
      start_parent_section_id: body.start_parent_section_id,
      idempotency_key: idempotencyKey,
      status: "running",
      sections: [],
      cost_cents_reserved: 0, // Day 2 will estimate per-section cost and reserve here
    })
    .select()
    .single();

  if (insertErr) {
    if (insertErr.code === "23505") {
      const { data: existing } = await adminClient
        .from("chapter_runs")
        .select()
        .eq("idempotency_key", idempotencyKey)
        .eq("status", "running")
        .maybeSingle();
      if (existing) {
        return corsResponse(
          JSON.stringify({ errorCode: "already_running", run_id: existing.id }),
          { status: 409 },
        );
      }
    }
    console.error(`[run-outline] insert failed: ${insertErr.message}`);
    return errorResponse("db_error", insertErr.message, 500);
  }

  // 5. Day 2: kick off outline-walker + per-section loop here (calls
  //    generate-story). For Day 1 skeleton: just acknowledge, kickoff is
  //    logged so it shows up in the run history but no work happens yet.
  console.log(
    `[run-outline] kickoff run_id=${run.id} user=${userId} outline=${body.outline_id} parent=${body.start_parent_section_id} model=${body.model ?? "(default)"}`,
  );

  return corsResponse(
    JSON.stringify({
      run_id: run.id,
      status: run.status,
      created_at: run.created_at,
    }),
    { status: 202 },
  );
});
