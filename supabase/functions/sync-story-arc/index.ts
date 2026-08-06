// =============================================================================
// sync-story-arc Edge Function (long-term proper beat sync per PR #285)
//
// Called from iOS when StoryArc content changes — template pick, beat CRUD,
// reorder, or label/details edits. Closes the beat-sync gap that PR #284
// surfaced: iOS had local-only StoryArcBeat rows that the embed-section FK
// referenced, but the server never had those beats, so every accept hit a
// FK violation → 0/8 accepted.
//
// Replace-beats model: iOS sends the full current beat list every sync;
// server upserts present beats and deletes missing ones. FK ON DELETE SET NULL
// on outline_sections.story_arc_beat_id means any sections that referenced a
// removed beat auto-null-out — no orphan cleanup needed.
//
// Trigger model (caller-managed, see iOS code):
//   - Immediate sync on arc creation (template pick)
//   - Then hybrid: immediate on explicit Save, debounced (~500ms) on incremental edits
//   - Per-arc lastSyncedAt flag in iOS SwiftData so the embed-section call sites
//     can fire this as a safety net when the arc hasn't been synced yet (Q4c)
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Service-role key is used server-side only (never exposed to iOS).
//
// Request:  POST {
//             story_arc_id, template_id | null, local_project_id, lineage_id,
//             customizations, beats: [
//               { id, position, role, label, details }
//             ]
//           }
// Response: 200 { story_arc_id, beats_upserted, beats_deleted }
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, { ...init, headers: { ...CORS_HEADERS, ...(init.headers || {}) } });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (s: unknown): s is string => typeof s === "string" && UUID_RE.test(s);

interface BeatPayload {
  id?: string;
  position?: number;
  role?: string;
  label?: string;
  details?: string;
}

interface SyncArcRequest {
  story_arc_id?: string;
  template_id?: string | null;
  local_project_id?: string;
  lineage_id?: string;
  customizations?: Record<string, unknown>;
  beats?: BeatPayload[];
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") return errorResponse("method_not_allowed", "POST only", 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return errorResponse("not_authenticated", "Missing Authorization header", 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !supabaseAnonKey) {
    return errorResponse("not_configured", "Supabase URL or anon key missing", 500);
  }
  if (!supabaseServiceKey) {
    return errorResponse("not_configured", "SUPABASE_SERVICE_ROLE_KEY missing", 500);
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) {
    return errorResponse("not_authenticated", "Invalid token", 401);
  }

  let body: SyncArcRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_request", "Body must be JSON", 400);
  }

  // --- Validation ---
  if (!body.story_arc_id || !isUuid(body.story_arc_id)) {
    return errorResponse("invalid_request", "story_arc_id is required (UUID)", 400);
  }
  if (!body.local_project_id || typeof body.local_project_id !== "string" || body.local_project_id.length === 0) {
    return errorResponse("invalid_request", "local_project_id is required (text)", 400);
  }
  if (!body.lineage_id || !isUuid(body.lineage_id)) {
    return errorResponse("invalid_request", "lineage_id is required (UUID)", 400);
  }
  if (body.template_id != null && !isUuid(body.template_id)) {
    return errorResponse("invalid_request", "template_id must be UUID or null", 400);
  }
  const beats = body.beats ?? [];
  for (const b of beats) {
    if (!isUuid(b.id)) {
      return errorResponse("invalid_request", "beat.id must be UUID", 400);
    }
    if (typeof b.label !== "string" || b.label.length === 0) {
      return errorResponse("invalid_request", "beat.label must be non-empty string", 400);
    }
    if (typeof b.position !== "number" || !Number.isInteger(b.position) || b.position < 0) {
      return errorResponse("invalid_request", "beat.position must be non-negative integer", 400);
    }
  }

  console.log(`[sync-story-arc] start user=${user.id} arc=${body.story_arc_id} beats=${beats.length}`);

  const adminClient = createClient(supabaseUrl, supabaseServiceKey);

  // --- Step 1: UPSERT story_arc (id = client-provided, all fields). ---
  const { error: arcErr } = await adminClient.from("story_arcs").upsert({
    id: body.story_arc_id,
    user_id: user.id,
    template_id: body.template_id ?? null,
    local_project_id: body.local_project_id,
    lineage_id: body.lineage_id,
    customizations: body.customizations ?? {},
  }, { onConflict: "id" });
  if (arcErr) {
    console.error(`[sync-story-arc] story_arcs upsert failed: ${arcErr.message}`);
    return errorResponse("database_error", `story_arcs upsert failed: ${arcErr.message}`, 500);
  }
  console.log(`[sync-story-arc] story_arc upserted id=${body.story_arc_id}`);

  // --- Step 2: SELECT existing beat ids so step 4 can compute which to delete. ---
  const { data: existingBeats, error: listErr } = await adminClient
    .from("story_arc_beats")
    .select("id")
    .eq("story_arc_id", body.story_arc_id);
  if (listErr) {
    console.error(`[sync-story-arc] list existing beats failed: ${listErr.message}`);
    return errorResponse("database_error", `list existing beats failed: ${listErr.message}`, 500);
  }
  const existingIds = new Set((existingBeats ?? []).map(b => b.id));
  const incomingIds = new Set(beats.map(b => b.id));
  const toDelete = [...existingIds].filter(id => !incomingIds.has(id));
  console.log(`[sync-story-arc] beats incoming=${beats.length} existing=${existingIds.size} toDelete=${toDelete.length}`);

  // --- Step 3: UPSERT beats. ---
  let beatsUpserted = 0;
  if (beats.length > 0) {
    const rows = beats.map(b => ({
      id: b.id,
      story_arc_id: body.story_arc_id,
      position: b.position,
      role: b.role ?? "",
      label: b.label ?? "",
      details: b.details ?? "",
    }));
    const { error: beatsErr } = await adminClient.from("story_arc_beats").upsert(rows, { onConflict: "id" });
    if (beatsErr) {
      console.error(`[sync-story-arc] beats upsert failed: ${beatsErr.message}`);
      return errorResponse("database_error", `beats upsert failed: ${beatsErr.message}`, 500);
    }
    beatsUpserted = rows.length;
  }
  console.log(`[sync-story-arc] beats upserted=${beatsUpserted}`);

  // --- Step 4: DELETE beats no longer in the incoming list (replace model). ---
  // outline_sections has FK ON DELETE SET NULL on story_arc_beat_id, so any
  // sections that referenced a removed beat auto-null-out — no orphan cleanup.
  let beatsDeleted = 0;
  if (toDelete.length > 0) {
    const { error: delErr } = await adminClient
      .from("story_arc_beats")
      .delete()
      .in("id", toDelete);
    if (delErr) {
      console.error(`[sync-story-arc] beats delete failed: ${delErr.message}`);
      return errorResponse("database_error", `beats delete failed: ${delErr.message}`, 500);
    }
    beatsDeleted = toDelete.length;
  }
  console.log(`[sync-story-arc] beats deleted=${beatsDeleted}`);

  return corsResponse(
    JSON.stringify({
      story_arc_id: body.story_arc_id,
      beats_upserted: beatsUpserted,
      beats_deleted: beatsDeleted,
    }),
    { status: 200 }
  );
});
