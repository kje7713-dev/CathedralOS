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
//
// PR-360-X (Kevin 2026-08-17 21:03 EDT — Smoke Test repro):
//   - Positive-inference ALIVE/DEAD rendering: explicit ALIVE/DEAD/INJURED
//     lists per neighbor so the LLM has unambiguous character-state context.
//   - Explicit-claim extraction on the proposed side: regex pass over
//     title+summary to surface "X is dead" / "X killed Y" / "X is missing"
//     claims. Result is injected into the LLM prompt as a labelled block.
//   - Drop "be sparing" guardrail on explicit claims: explicit dead/killed/
//     missing claims MUST emit a high-confidence flag, never silently dropped.
//   - CANON MEMORY block in user prompt: explicit field surface so the LLM
//     sees what fields are available (and doesn't have to infer them).
//   - No deterministic fallback layer (trust the LLM with sharper prompt +
//     correct structured data).
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
  severity: "warn" | "high";
}

interface ExplicitClaim {
  character_name: string;
  claim_kind: "dead" | "killed" | "missing" | "dying" | "injured" | "location";
  source_text: string;
}

// OpenAI Structured Outputs schema — strict, no additional properties.
// Mirrors the SCENE_MEMORY_RESPONSE_FORMAT pattern from embed-section/index.ts.
// PR-360-X: `severity` is required: "warn" for stylistic/preference concerns,
// "high" for explicit claim contradictions (e.g., "X is dead" when X is alive).
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
              severity: {
                type: "string",
                enum: ["warn", "high"],
              },
            },
            required: ["section_id", "section_title", "reason", "severity"],
            additionalProperties: false,
          },
        },
      },
      required: ["warnings"],
      additionalProperties: false,
    },
  },
} as const;

// PR-360-X: Extract explicit claims from the proposed side.
//
// Regex pass over the proposed title + summary. Extracts character names
// from the surrounding +/-60 chars of each match. Result is injected into
// the LLM prompt as a labelled "EXPLICIT CLAIMS" block so the LLM
// compares against the ALIVE/DEAD/INJURED lists in canon memory.
//
// Smoke Test repro (2026-08-17 21:03 EDT):
//   "Ted and Fred and Betty are dead now" -> 3 dead claims
const SKIP_NAME_WORDS = new Set([
  "The", "A", "An", "In", "At", "On", "By", "For", "With", "From",
  "And", "Or", "But", "He", "She", "They", "It", "We", "I", "You",
  "His", "Her", "Their", "Its", "My", "Your", "Our", "This", "That",
  "Now", "Then", "Here", "There", "When", "Where", "Why", "How",
  "Of", "To", "As", "If", "So", "Not", "No", "Yes", "What", "Which",
  "Who", "Whom", "Whose", "After", "Before", "During", "Until",
]);

const extractNamesFromContext = (
  context: string,
  canonicalNames: Set<string>,
): string[] => {
  const names: string[] = [];
  const seen = new Set<string>();

  // Pass 1: Capitalized names (existing behavior — catches new characters like "Steve").
  const capPattern = /\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b/g;
  let nm: RegExpExecArray | null;
  while ((nm = capPattern.exec(context)) !== null) {
    const name = nm[1].trim();
    if (SKIP_NAME_WORDS.has(name)) continue;
    if (!seen.has(name)) {
      seen.add(name);
      names.push(name);
    }
  }

  // Pass 2 (hotfix): Case-insensitive match against canonical names from
  // neighbors. Catches typos like "ted" → "Ted" before any explicit claim
  // is even attached. Only matches if the lowercase form is in the canon.
  const lowerPattern = /\b([a-z]+)\b/g;
  while ((nm = lowerPattern.exec(context)) !== null) {
    const lowerName = nm[1].trim();
    if (SKIP_NAME_WORDS.has(lowerName)) continue;
    for (const canonical of canonicalNames) {
      if (canonical.toLowerCase() === lowerName) {
        if (!seen.has(canonical)) {
          seen.add(canonical);
          names.push(canonical);
        }
        break;
      }
    }
  }

  return names;
};

const extractExplicitClaims = (
  title: string,
  summary: string,
  canonicalNames: Set<string>,
): ExplicitClaim[] => {
  const text = `${title} ${summary}`;
  const claims: ExplicitClaim[] = [];
  const seen = new Set<string>();

  const claimKinds: Array<{ regex: RegExp; kind: ExplicitClaim["claim_kind"] }> = [
    // "X is dead / X are dead / X died / X is gone / X is missing / X is absent"
    { regex: /\b(is|are|dies|died|was|were)\s+(dead|dies|died|gone|missing|absent|deceased)\b/gi, kind: "dead" },
    // "X killed / X kills / X is murdered / X was executed / X was assassinated
    //  / X wiped out / X massacred / X destroyed / X slain / X slays"
    { regex: /\b(killed|kills|murdered|executed|assassinated|wiped(?:\s+out)?|massacred|destroyed|slain|slays)\b/gi, kind: "killed" },
    // "X is dying / X is injured / X is wounded"
    { regex: /\b(is|are|was|were)\s+(dying|injured|wounded)\b/gi, kind: "dying" },
    // HOTFIX: "X is in/at/on [Place]" — location shift from canon.
    // Matches "Ted and Fred are in Paris" / "Steve is at the cathedral".
    // Does NOT match malformed "are is paris" (no "in" preposition) — that's
    // caught by the LLM prompt's "be charitable with typos" rule.
    { regex: /\b(is|are|was|were)\s+(in|at|on|inside|outside|near)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b/g, kind: "location" },
  ];

  for (const { regex, kind } of claimKinds) {
    let m: RegExpExecArray | null;
    while ((m = regex.exec(text)) !== null) {
      const start = Math.max(0, m.index - 60);
      const end = Math.min(text.length, m.index + m[0].length + 60);
      const context = text.slice(start, end);
      const names = extractNamesFromContext(context, canonicalNames);
      for (const name of names) {
        const key = `${name}|${kind}`;
        if (seen.has(key)) continue;
        seen.add(key);
        claims.push({
          character_name: name,
          claim_kind: kind,
          source_text: m[0].trim(),
        });
      }
    }
  }

  return claims;
};

// PR-360-X: Classify characters into ALIVE/DEAD/INJURED lists.
//
// Rule: any character in character_deltas[].character_name with no
// explicit 'injuries'/'status' signal is treated as ALIVE.
// System-prompt rule: "absence of death signal = presumed alive".
const classifyCharacters = (
  row: any,
): { alive: string[]; dead: string[]; injured: string[] } => {
  const alive = new Set<string>();
  const dead = new Set<string>();
  const injured = new Set<string>();
  const seen = new Set<string>();

  if (Array.isArray(row.character_deltas)) {
    for (const c of row.character_deltas) {
      if (!c || typeof c !== "object") continue;
      const name = c.character_name ?? c.name;
      if (typeof name !== "string" || name.length === 0) continue;
      if (seen.has(name)) continue;
      seen.add(name);
      const injuries = (c.injuries ?? "").toString().toLowerCase();
      const status = (c.status ?? "").toString().toLowerCase();
      const isDead = status === "deceased" || status === "dead" ||
        injuries.includes("dead") || injuries.includes("deceased") ||
        injuries.includes("killed");
      const isInjured = !isDead && (
        status === "dying" || status === "injured" ||
        (injuries.length > 0 && injuries !== "none" && injuries !== "no")
      );
      if (isDead) dead.add(name);
      else if (isInjured) injured.add(name);
      else alive.add(name);
    }
  }

  // scene_ending_state can override ALIVE/INJURED with DEAD (subsequent scene
  // implies the character is dead). Don't add new ALIVE here.
  if (row.scene_ending_state && typeof row.scene_ending_state === "object") {
    const positions = row.scene_ending_state.character_positions;
    if (Array.isArray(positions)) {
      for (const p of positions) {
        if (!p || typeof p !== "object") continue;
        const name = p.character;
        if (typeof name !== "string" || name.length === 0) continue;
        const state = (p.immediate_state ?? "").toString().toLowerCase();
        const isDead = state.includes("dead") || state.includes("deceased") ||
          state.includes("killed");
        const isInjured = !isDead && (
          state.includes("injured") || state.includes("wounded") ||
          state.includes("dying")
        );
        if (isDead) {
          dead.add(name);
          alive.delete(name);
          injured.delete(name);
        } else if (isInjured && !dead.has(name)) {
          injured.add(name);
          alive.delete(name);
        }
      }
    }
  }

  return { alive: [...alive], dead: [...dead], injured: [...injured] };
};

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
    const pressure = s.immediate_pressure
      ? `\n  Pressure: ${s.immediate_pressure}`
      : "";
    return positions.length > 0
      ? `Character positions at end:\n${positions}${pressure}`
      : "";
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
          .map((t: any) =>
            `  - [${t.status ?? "?"}] ${t.thread_name ?? "(unnamed)"}: ${t.description ?? ""}`
          );
        if (threadLines.length > 0) {
          sections.push(`Plot threads:\n${threadLines.join("\n")}`);
        }
      }
      const ending = formatSceneEndingState(row.scene_ending_state);
      if (ending.length > 0) sections.push(ending);

      // PR-360-X: explicit ALIVE/DEAD/INJURED classification so the LLM has
      // unambiguous character-state context per accepted section.
      const { alive, dead, injured } = classifyCharacters(row);
      sections.push(
        `ALIVE / DEAD / INJURED (PR-360-X — positive-inference; ALIVE default unless structured memory says otherwise):\n` +
        `  ALIVE:\n` +
        (alive.length > 0
          ? alive.map((n) => `    - ${n}`).join("\n")
          : `    - (none)`) +
        `\n  DEAD:\n` +
        (dead.length > 0
          ? dead.map((n) => `    - ${n}`).join("\n")
          : `    - (none)`) +
        (injured.length > 0
          ? `\n  INJURED:\n` + injured.map((n) => `    - ${n}`).join("\n")
          : "")
      );

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
    body.section.prompt_pack_notes
      ? `Prompt pack notes: ${body.section.prompt_pack_notes}`
      : null,
  ].filter(Boolean).join("\n");

  // PR-360-X hotfix: extract canonical character names from neighbors so
  // case-insensitive name matching catches typos like "ted" → "Ted".
  const canonicalNames = new Set<string>();
  for (const row of neighbors) {
    if (Array.isArray(row.character_deltas)) {
      for (const c of row.character_deltas) {
        const name = c.character_name ?? c.name;
        if (typeof name === "string" && name.length > 0) {
          canonicalNames.add(name);
        }
      }
    }
    if (row.scene_ending_state && typeof row.scene_ending_state === "object") {
      const positions = row.scene_ending_state.character_positions;
      if (Array.isArray(positions)) {
        for (const p of positions) {
          const name = p.character;
          if (typeof name === "string" && name.length > 0) {
            canonicalNames.add(name);
          }
        }
      }
    }
  }

  // PR-360-X: Extract explicit claims from the proposed summary/title.
  const explicitClaims = extractExplicitClaims(
    body.section.title,
    body.section.summary,
    canonicalNames,
  );
  const explicitClaimsBlock = explicitClaims.length > 0
    ? `EXPLICIT CLAIMS DETECTED IN PROPOSED SECTION:\n` +
      explicitClaims
        .map(
          (c) =>
            `  - ${c.character_name} (claim="${c.claim_kind}", source="${c.source_text}")`,
        )
        .join("\n") +
      `\n`
    : `EXPLICIT CLAIMS DETECTED IN PROPOSED SECTION:\n  - (none)\n`;

  // PR-360-X: CANON MEMORY block — explicit field surface so the LLM
  // sees what fields are available (and doesn't have to infer them).
  const canonMemoryBlock =
    `CANON MEMORY (use this for contradiction checks, never invent names):\n` +
    `- Each accepted section lists characters as ALIVE / DEAD / INJURED (positive-inference: ALIVE is the default unless structured memory explicitly says otherwise).\n` +
    `- Continuity facts per section are listed under "Continuity facts".\n` +
    `- Character positions at end of each scene are listed under "Character positions at end".\n` +
    `- If the proposed section claims a character is dead/killed/missing AND that character is in any accepted section's ALIVE list, this is a HIGH-confidence flag (severity: "high").`;

  // Phase 7 fix (Kevin 2026-08-17 20:01 EDT): lead with character-state checks.
  // Before this fix the LLM only saw 200-500 token summaries that routinely
  // dropped alive/dead/injury facts, so "all the characters are dead" was
  // missed against scenes where the characters were explicitly alive. Now
  // the prompt carries per-character state (location, knowledge, injuries,
  // goals, possessions, emotional_stance) + continuity facts + scene-ending
  // state + explicit ALIVE/DEAD/INJURED lists, so a proposed dead-character
  // claim MUST be checked against each character's last known state.
  const systemPrompt = `You are a story-coherence assistant. Compare a proposed outline section against the project's already-accepted sections.

PRIORITY contradiction checks (always run these first):
1. Character-state contradictions: a proposed section claims a character is dead / gone / injured / has lost knowledge, but earlier scenes show that character alive, healthy, or in possession of that knowledge. Cite the section whose character state is contradicted.
2. Continuity-fact contradictions: the proposed section asserts a fact that breaks an established continuity fact from an earlier scene.
3. Scene-ending-state contradictions: the proposed section starts from a location or situation that does not match where characters were at the end of the prior accepted scene.
4. POV drift: the proposed section shifts POV without justification.
5. Plot-thread contradictions: a thread the earlier scenes marked as resolved is reopened, or vice versa, without setup.

Severity rules (PR-360-X + hotfix):
- severity: "high" — Use for EXPLICIT death/killing claims where the claimed character appears in the ALIVE list of any accepted section. This is a HIGH-confidence flag and MUST be emitted; never silently dropped.
- severity: "warn" — Use for any of:
  - Location shifts (e.g., "Ted and Fred are in Paris" when canon has them at a diner)
  - New characters with established state (e.g., "Steve is dead" when Steve is not in any prior section's ALIVE/DEAD/INJURED list) — flag as "no canon context, claim is ungrounded"
  - Weak/implicit signals (theme echoes, stylistic proximity)
  - Typos/grammar corrections (e.g., "are is paris" = "are in Paris")

Be aggressive about flagging ANY explicit claim that contradicts or shifts from canon. Missing a real contradiction is worse than a false positive.

Do NOT surface: stylistic preferences, vague thematic echoes, things that "could be inconsistent in some interpretation". Only real, specific, citation-backed contradictions.

If there are no real contradictions, return {"warnings": []}.`;

  const userPrompt = `PROPOSED SECTION:
${proposedDesc}

${canonMemoryBlock}

${explicitClaimsBlock}

ACCEPTED SECTIONS (most recent first):
${neighborText}

For each real contradiction, return one warning with:
- section_id: the UUID (in the parenthesis above) of the contradicting accepted section
- section_title: that section's title
- reason: one-sentence plain-English explanation
- severity: "high" if the proposed section explicitly claims a character is dead/killed/missing AND that character appears in the ALIVE list of an accepted section. "warn" for everything else.

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
      severity?: string;
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
      w.reason.length > 0 &&
      (w.severity === "warn" || w.severity === "high")
    )
    .map((w) => ({
      section_id: w.section_id as string,
      section_title: typeof w.section_title === "string" &&
          w.section_title.length > 0
        ? (w.section_title as string)
        : "(untitled)",
      reason: w.reason as string,
      severity: w.severity === "high" ? "high" : "warn",
    }));

  return corsResponse(JSON.stringify({ warnings }), { status: 200 });
});
