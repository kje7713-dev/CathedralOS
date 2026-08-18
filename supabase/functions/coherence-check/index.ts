// =============================================================================
// coherence-check Edge Function (Phase 7 per docs/novel-building.md)
//
// Pre-generation soft-warn check. Compares a proposed outline section's
// premise against the project's already-accepted sections, and surfaces
// genuine contradictions as a non-blocking warning list.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// Cost: NO credit charge. This is a free pre-check that runs before the
// user commits credits to the actual generation run.
//
// Request:  POST {
//             project_id,
//             section: { title, summary, container?, pov?, beat_label?,
//                        characters?, prompt_pack_notes? },
//             top_k?: 1..10    (default 5)
//           }
// Response: 200 { warnings: [{ section_id, section_title, reason, severity }] }
//
// No content is persisted. No embeddings are computed. We compare against
// the 200-500 token summaries stored in section_embeddings.summary
// (per Phase 3 locked design rule).
//
// Edge cases:
//   - 0 accepted neighbors       -> { warnings: [] }    (200, not an error)
//   - LLM returns no warnings    -> { warnings: [] }    (200)
//   - LLM returns garbage        -> 502 "LLM returned invalid JSON"
//   - OpenAI 5xx / rate-limit    -> 502 with body surfaced (do not mask)
//   - Auth missing/invalid       -> 401
//   - Wrong method / bad JSON    -> 400/405
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5-mini";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, {
    ...init,
    headers: { ...CORS_HEADERS, ...(init.headers ?? {}) },
  });

const errorResponse = (code: string, message: string, status: number): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

interface CoherenceSectionInput {
  title: string;
  summary: string;
  container?: string;
  pov?: string;
  beat_label?: string;
  characters?: string[];
  prompt_pack_notes?: string;
}

interface CoherenceCheckRequest {
  project_id: string;
  section: CoherenceSectionInput;
  top_k?: number;
}

interface CoherenceWarning {
  section_id: string;
  section_title: string;
  reason: string;
  severity: "warn";
}

// OpenAI Structured Outputs schema — strict, no additional properties.
// Mirrors the SCENE_MEMORY_RESPONSE_FORMAT pattern from embed-section/index.ts.
const COHERENCE_RESPONSE_FORMAT = {
  type: "json_schema",
  json_schema: {
    name: "coherence_warnings",
    strict: true,
    schema: {
      type: "object",
      properties: {
        warnings: {
          type: "array",
          items: {
            type: "object",
            properties: {
              section_id: { type: "string" },
              section_title: { type: "string" },
              reason: { type: "string" },
            },
            required: ["section_id", "section_title", "reason"],
            additionalProperties: false,
          },
        },
      },
      required: ["warnings"],
      additionalProperties: false,
    },
  },
} as const;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth via user's JWT (service role is never accepted)
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

  // 2. Parse + validate request body
  let body: CoherenceCheckRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  if (!body.project_id || typeof body.project_id !== "string") {
    return errorResponse("invalid_body", "project_id required", 400);
  }
  if (
    !body.section ||
    typeof body.section.title !== "string" ||
    typeof body.section.summary !== "string"
  ) {
    return errorResponse(
      "invalid_body",
      "section.title and section.summary required",
      400,
    );
  }
  const topK = Math.max(1, Math.min(body.top_k ?? 5, 10));

  // 3. Fetch accepted-section neighbors for this project.
  //
  // Phase 7 fix (Kevin 2026-08-17 20:01 EDT): pull the structured memory
  // layers too (character_deltas, continuity_facts, plot_thread_deltas,
  // scene_ending_state). The LLM distillation in `extracted_summary` is
  // 200-500 tokens and routinely loses character-state facts like
  // "Fred is alive and eating breakfast at the diner". When the user
  // proposes "all the characters are dead", the LLM has nothing to
  // compare against without these structured fields. (Per migration
  // 20260809200500_add_scene_memory_layers.sql.)
  const { data: neighborRows, error: qErr } = await userClient
    .from("section_embeddings")
    .select(`
      outline_section_id,
      summary,
      character_deltas,
      continuity_facts,
      plot_thread_deltas,
      scene_ending_state,
      created_at,
      outline_sections!inner(
        id,
        title,
        position,
        status,
        project_id
      )
    `)
    .eq("outline_sections.project_id", body.project_id)
    .eq("outline_sections.status", "accepted")
    .order("created_at", { ascending: false })
    .limit(topK);

  if (qErr) {
    return errorResponse(
      "neighbor_query_failed",
      `Could not load accepted sections: ${qErr.message}`,
      500,
    );
  }

  const neighbors = neighborRows ?? [];
  if (neighbors.length === 0) {
    // No accepted neighbors yet — nothing to contradict against.
    return corsResponse(JSON.stringify({ warnings: [] }), { status: 200 });
  }

  // 4. Build the prompt. Include the structured memory layers (character_deltas,
  // continuity_facts, plot_thread_deltas, scene_ending_state) so the LLM has
  // concrete character-state facts to compare against. The extracted_summary
  // alone (200-500 tokens) routinely drops alive/dead/injury facts — that's
  // how "all the characters are dead" was missed against alive characters in
  // accepted scenes. (Per Phase 7 fix, Kevin 2026-08-17 20:01 EDT.)
  const formatCharacterDelta = (c: any): string => {
    if (!c || typeof c !== "object") return "";
    const name = c.character_name ?? c.name ?? "(unnamed)";
    const parts: string[] = [`  - ${name}:`];
    if (c.location) parts.push(`location=${c.location}`);
    if (c.injuries) parts.push(`injuries=${c.injuries}`);
    if (c.knowledge_delta) parts.push(`knowledge=${c.knowledge_delta}`);
    if (c.relationship_delta) parts.push(`relationships=${c.relationship_delta}`);
    if (c.goals) parts.push(`goals=${c.goals}`);
    if (c.possessions) parts.push(`possessions=${c.possessions}`);
    if (c.emotional_stance) parts.push(`stance=${c.emotional_stance}`);
    return parts.join(" ");
  };
  const formatSceneEndingState = (s: any): string => {
    if (!s || typeof s !== "object" || !Array.isArray(s.character_positions)) {
      return "";
    }
    const positions = s.character_positions
      .map((p: any) => {
        if (!p || typeof p !== "object") return "";
        const who = p.character ?? "(unnamed)";
        const where = p.location ? ` @ ${p.location}` : "";
        const state = p.immediate_state ? ` (${p.immediate_state})` : "";
        return `  - ${who}${where}${state}`;
      })
      .filter((s: string) => s.length > 0)
      .join("\n");
    const pressure = s.immediate_pressure ? `\n  Pressure: ${s.immediate_pressure}` : "";
    return positions.length > 0 ? `Character positions at end:\n${positions}${pressure}` : "";
  };

  const neighborText = neighbors
    .map((row: any, i: number) => {
      const sec = row.outline_sections;
      const sections: string[] = [
        `[#${i + 1}] "${sec.title}" (id: ${sec.id}, position ${sec.position})`,
        `Summary: ${row.summary ?? "(no summary available)"}`,
      ];
      // Structured memory: this is what catches "characters alive vs dead" misses.
      if (Array.isArray(row.character_deltas) && row.character_deltas.length > 0) {
        const charLines = row.character_deltas
          .map(formatCharacterDelta)
          .filter((s: string) => s.length > 0);
        if (charLines.length > 0) {
          sections.push(`Characters:\n${charLines.join("\n")}`);
        }
      }
      if (Array.isArray(row.continuity_facts) && row.continuity_facts.length > 0) {
        const factLines = row.continuity_facts
          .filter((f: any) => typeof f === "string" && f.length > 0)
          .map((f: string) => `  - ${f}`);
        if (factLines.length > 0) {
          sections.push(`Continuity facts:\n${factLines.join("\n")}`);
        }
      }
      if (Array.isArray(row.plot_thread_deltas) && row.plot_thread_deltas.length > 0) {
        const threadLines = row.plot_thread_deltas
          .filter((t: any) => t && typeof t === "object" && (t.thread_name || t.description))
          .map((t: any) => `  - [${t.status ?? "?"}] ${t.thread_name ?? "(unnamed)"}: ${t.description ?? ""}`);
        if (threadLines.length > 0) {
          sections.push(`Plot threads:\n${threadLines.join("\n")}`);
        }
      }
      const ending = formatSceneEndingState(row.scene_ending_state);
      if (ending.length > 0) sections.push(ending);
      return sections.join("\n\n");
    })
    .join("\n\n");

  const proposedDesc = [
    `Title: ${body.section.title}`,
    `Summary: ${body.section.summary}`,
    body.section.container ? `Container: ${body.section.container}` : null,
    body.section.pov ? `POV: ${body.section.pov}` : null,
    body.section.beat_label ? `Beat: ${body.section.beat_label}` : null,
    body.section.characters?.length
      ? `Characters: ${body.section.characters.join(", ")}`
      : null,
    body.section.prompt_pack_notes ? `Prompt pack notes: ${body.section.prompt_pack_notes}` : null,
  ].filter(Boolean).join("\n");

  // Phase 7 fix (Kevin 2026-08-17 20:01 EDT): lead with character-state checks.
  // Before this fix the LLM only saw 200-500 token summaries that routinely
  // dropped alive/dead/injury facts, so "all the characters are dead" was
  // missed against scenes where the characters were explicitly alive. Now
  // the prompt carries per-character state (location, knowledge, injuries,
  // goals, possessions, emotional_stance) + continuity facts + scene-ending
  // state, so a proposed dead-character claim MUST be checked against each
  // character's last known state.
  const systemPrompt = `You are a story-coherence assistant. Compare a proposed outline section against the project's already-accepted sections.

PRIORITY contradiction checks (always run these first):
1. Character-state contradictions: a proposed section claims a character is dead / gone / injured / has lost knowledge, but earlier scenes show that character alive, healthy, or in possession of that knowledge. Cite the section whose character state is contradicted.
2. Continuity-fact contradictions: the proposed section asserts a fact that breaks an established continuity fact from an earlier scene.
3. Scene-ending-state contradictions: the proposed section starts from a location or situation that does not match where characters were at the end of the prior accepted scene.
4. POV drift: the proposed section shifts POV without justification.
5. Plot-thread contradictions: a thread the earlier scenes marked as resolved is reopened, or vice versa, without setup.

Do NOT surface: stylistic preferences, weak thematic echoes, speculative concerns, "this could be inconsistent in some interpretation" worries. Only real, specific, citation-backed contradictions.

If there are no real contradictions, return {"warnings": []}. Be sparing and accurate — every warning you emit will be shown to the writer as a soft-warn before they commit credits to a generation run, so false positives are costly.`;

  const userPrompt = `PROPOSED SECTION:
${proposedDesc}

ACCEPTED SECTIONS (most recent first):
${neighborText}

For each real contradiction, return one warning with:
- section_id: the UUID (in the parenthesis above) of the contradicting accepted section
- section_title: that section's title
- reason: one-sentence plain-English explanation

Return JSON {"warnings": []} if no genuine conflicts.`;

  // 5. Call OpenAI with Structured Outputs (strict schema).
  let openaiRes: Response;
  try {
    openaiRes = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL_DEFAULT,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userPrompt },
        ],
        response_format: COHERENCE_RESPONSE_FORMAT,
        max_completion_tokens: 1500,
        temperature: 0.2,
      }),
    });
  } catch (e) {
    return errorResponse(
      "openai_unreachable",
      `OpenAI request failed: ${(e as Error).message}`,
      502,
    );
  }

  if (!openaiRes.ok) {
    const errText = await openaiRes.text();
    return corsResponse(
      JSON.stringify({
        errorCode: "openai_error",
        message: `OpenAI error ${openaiRes.status}: ${errText}`,
      }),
      { status: 502 },
    );
  }

  const openaiData = await openaiRes.json();
  const content = openaiData.choices?.[0]?.message?.content;
  if (typeof content !== "string") {
    return errorResponse("openai_empty", "OpenAI returned no content", 502);
  }

  let parsed: {
    warnings?: Array<{
      section_id?: string;
      section_title?: string;
      reason?: string;
    }>;
  };
  try {
    parsed = JSON.parse(content);
  } catch (e) {
    return errorResponse(
      "openai_invalid_json",
      `LLM returned invalid JSON: ${(e as Error).message}`,
      502,
    );
  }

  // 6. Validate, clamp severity, drop warnings that reference sections we
  //    didn't actually pass to the LLM (LLM hallucination guard).
  const validIds = new Set<string>(
    neighbors.map((row: any) => row.outline_sections.id as string),
  );
  const warnings: CoherenceWarning[] = (parsed.warnings ?? [])
    .filter((w) =>
      typeof w.section_id === "string" &&
      validIds.has(w.section_id) &&
      typeof w.reason === "string" &&
      w.reason.length > 0
    )
    .map((w) => ({
      section_id: w.section_id as string,
      section_title: typeof w.section_title === "string" && w.section_title.length > 0
        ? (w.section_title as string)
        : "(untitled)",
      reason: w.reason as string,
      severity: "warn" as const,
    }));

  return corsResponse(JSON.stringify({ warnings }), { status: 200 });
});
