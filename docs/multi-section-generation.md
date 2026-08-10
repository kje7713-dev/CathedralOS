# Multi-Section Generation RFC

**Status:** Locked design rules updated (2026-08-10 16:28 EDT, Kevin)
**Date:** 2026-08-10
**Memory:** kevbot-brain (forthcoming)
**Supersedes:** Earlier design choices around Phase 4 retrieval (top-K similarity) and
prior-context query shape (N most recent). This RFC defines the locked rules.
PR #309 amends its prior commit (DAY3_NARROW_LIMIT = 5) — that heuristic is
replaced by the proper design here.

---

## Problem

Today, `generate-story` takes **one section at a time per iOS button tap**. There's no
multi-section flow at all. We need an orchestrator that walks the outline in
canonical order, threads prior state into each section, and tracks cost + status.

---

## Locked design rules (Kevin 2026-08-10 16:28 EDT — HARD CONSTRAINTS)

These rules supersede any earlier design choices. **Implementation MUST follow them.**

1. **Keep the 5 structured memory layers** (`character_deltas`, `plot_thread_deltas`,
   `continuity_facts`, `open_loops`, `scene_ending_state`). Don't drop or rename.

2. **`character_deltas`: merge fields, don't let the latest entry overwrite earlier fields.**
   Scene 1: `{character_name: "Jon", knowledge: "X"}`. Scene 2: `{character_name: "Jon", goal: "Y"}`.
   Aggregate: `{character_name: "Jon", knowledge: "X", goal: "Y"}` — **both fields merged**, not just the latest.

3. **`plot_thread_deltas` + `open_loops`: stable IDs + explicit lifecycle/status.**
   - Each thread/loop has a stable ID (UUID) that persists across scenes.
   - Status: `introduced` / `advanced` / `resolved` (threads); `open` / `investigated` / `resolved` (loops).
   - When resolved, mark with `resolved_at` timestamp.

4. **`continuity_facts`: provenance + active/superseded flag.**
   - Each fact: `{id, fact, source_section_id, active, superseded_by?, created_at}`.
   - When a fact is no longer true, mark `active=false` or `superseded_by=<other_fact_id>`.

5. **ALWAYS inject the immediately previous canonical section's summary + ending state**,
   regardless of intent filtering. The model needs what just happened.

6. **Retrieve history by outline order / current accepted revision**, NOT `created_at`.
   Use `outline_sections.position` (the canonical order in the outline).

7. **`location` must actually filter** (not just tie-break). Other-location scenes are
   excluded from the prior context.

8. **Automated pipeline order: generate prose → persist output → extract/store scene
   memory → generate next section.** The output is persisted BEFORE the next
   section can read it.

9. **`raw_text` is stored for re-extraction/debugging** but **NOT injected by default**.
   Only the compressed summary + structured state are sent to the model.

---

## Scope (what this RFC covers)

1. Outline-walker: kicks off multi-section generation, walks in canonical order.
2. Per-section flow: aggregate narrow, relevant prior state → call `generate-story`
   → persist output → call embed-section to extract memory.
3. Async poll-based progress (not sync, not streaming in v1).
4. Rate-limit + token controls: existing `SupabaseRateLimitStore` + per-run credit ceiling.
5. Failure semantics: stop the chain (v1).
6. iOS UI shape: "Generate chapter" button + progress view + cost preview + outcome.
7. Cost display before kickoff: estimated credits + estimated wall time.

## Out of scope
- Streaming responses (poll only in v1)
- Parallel section generation
- Remix / continue / coherence phases
- Anything that touches model selection, prompt engineering, or terminal-beat design

---

## Data flow (v1) — per Locked Rule 8

```
iOS tap "Generate chapter"
  → POST /functions/v1/run-outline {
      outline_id,
      start_parent_section_id,    # anchor: leaf section OR chapter parent
      idempotency_key (optional, UUID),
    }
     (auth, rate-limit, credit reservation at entry)
  → for each section in canonical order (children of start_parent_section_id, by `outline_sections.position`):
       1. Fetch narrow prior context (per Rules 2-7):
          - Query section_embeddings filtered by intent (current_characters, current_threads)
          - Apply location filter (per Rule 7)
          - ALWAYS include the immediately previous section's summary + ending state (per Rule 5)
          - Use outline order (per Rule 6), not created_at
       2. Call generate-story with the section + prior context → gets the prose
       3. PERSIST the prose output to generation_outputs (per Rule 8) — output must
          be committed BEFORE the next section can read it
       4. Call embed-section to extract the 5 structured layers from raw_text
          (per Rule 8) — this stores the new state for the NEXT section
       5. Update section status in chapter_runs.sections[]
  → on chain complete: commit credits, mark run completed
  → on chain failure: no charge (per _credits.ts policy), mark run failed with section error

iOS polls GET /functions/v1/run-outline/{run_id}/status
  → returns { status, sections_done, sections_total, current_section, errors, immediate_previous_section_id }
```

Two new artifacts needed:
- `chapter_runs` Postgres table — tracks run state.
- `run-outline` Edge Function — the orchestrator.

Existing artifacts reused:
- `outline_sections` (iOS already has these; PR #301) + 3 new intent fields
- `section_embeddings` (PR #304) — stores the 5 structured layers + raw_text
- `generate-story` (PR #305 added the aggregate-context helper)
- `SupabaseRateLimitStore` + credit pipeline (existing)
- `embed-section` (PR #304) — extracts the 5 structured layers + raw_text per section

---

## Prior context query shape — per Locked Rules 2-7

The prior context has two parts:

### Part 1: ALWAYS-injected (per Rule 5)
The immediately previous canonical section's:
- `extracted_summary` (compressed summary, ~200-500 tokens)
- `scene_ending_state` (where everyone is, what immediate pressure exists)

This is **always included**, regardless of intent. The model needs to know what just happened.

### Part 2: Intent-filtered (per Rules 2-7)
The current section's intent (3 fields, populated by iOS at outline-edit time):
- `current_characters: text[]` — which characters are in scope
- `current_threads: text[]` — which plot threads are in scope
- `current_location: text` — which scene/location

The query filters `section_embeddings`:
- Scenes whose `character_deltas` mentions any of `current_characters`, OR
- Scenes whose `plot_thread_deltas` mentions any of `current_threads`
- AND whose `scene_ending_state.character_positions[*].location` matches `current_location` (per Rule 7)
- Use `outline_sections.position` (Rule 6), not `created_at`

### Aggregate merge semantics (per Rules 2-4)
- `character_deltas`: **merge fields per `character_name`** across all matching scenes (Rule 2).
- `plot_thread_deltas`: **latest status per `thread_id`** (stable IDs, lifecycle) (Rule 3).
- `open_loops`: **active loops per `loop_id`** (lifecycle) (Rule 3).
- `continuity_facts`: **union of active facts** (only `active=true`, excluding `superseded_by`) (Rule 4).
- `scene_ending_state`: **latest** (from the most recent prior section, per Rule 5).

### Output format (injected into `generate-story` as `project_state_context`)

```markdown
## Project state (cumulative across all accepted scenes)

**Immediately previous section (always included per Rule 5):**
- Summary: {summary}
- Ending state: {scene_ending_state}

**Earlier relevant sections (filtered by intent per Rules 6-7):**

### Characters (latest merged state)
- **{character_name}**: {merged_fields}

### Plot threads (latest status per thread)
- **{thread_name}** [{status}]: {description}

### Open loops (unresolved)
- [{type}] {description}

### Continuity facts (active only)
- {fact}
```

`raw_text` is **never** in this output (per Rule 9). The model gets structured state only, not full prose.

---

## Phasing

**Day 0/1** (PR #307) — `chapter_runs` table + run-outline skeleton ✓
**Day 2** (PR #308) — outline-walker + per-section loop + status polling ✓
**Day 3** (PR #309) — cost reserve + commit/rollback + intent-based narrow queries
                              (in progress; being amended per Rules 1-9)
**Day 4** — iOS UI: bottom sheet + progress banner (per current section's status)
**Day 5** — edge cases: idempotency, background polling, stop-the-chain

## Open follow-ups (lower priority)
- DB-side narrow query via Postgres RPC (same design, pushed to DB layer for performance)
- `EdgeRuntime.waitUntil` for true async (Day 3 follow-up — sync works for v1)
