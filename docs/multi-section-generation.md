# Multi-Section Generation RFC

**Status:** Draft, awaiting Kevin's review
**Date:** 2026-08-10
**Memory:** kevbot-brain (forthcoming)
**Supersedes:** Implicit Phase 4 retrieval approach in `docs/novel-building.md` (PR #262) — that spec's top-K similarity abstraction is the wrong one.

---

## Problem

Today, `generate-story` takes **one section at a time per iOS button tap**. There's no way to kick off "generate this whole chapter" or "generate this whole outline." Novel-building direction requires coherence across sections, but the system has no multi-section flow at all.

The plumbing is in place (PR #304 storage, PR #301 Outline tab, Story Arc + sections on iOS, pgvector), but **nothing walks the outline in order and threads prior state into each subsequent generation**.

---

## Scope (what this RFC covers)

1. Outline-walker: kicks off multi-section generation, walks in canonical order.
2. Per-section flow: aggregate narrow, relevant prior state → call `generate-story` → capture output.
3. Async vs sync: multi-section takes minutes per section. iOS can't block. Background job with progress polling.
4. Rate-limit + token controls: existing `SupabaseRateLimitStore` + per-run credit ceiling.
5. Failure semantics: what happens when section N fails. Recommend: stop the chain (v1).
6. iOS UI shape: "Generate chapter" button + progress view + cost preview + outcome.
7. Cost display **before** kickoff: estimated credits + estimated wall time.

## Out of scope

- Redesigning Phase 4 retrieval (top-K similarity). The wrong abstraction lives in the canonical spec too — separate cleanup.
- Remix / continue / coherence phases. Those come after.
- Anything that touches model selection, prompt engineering, or terminal-beat design.
- The server-side `sync-story-arc` and other deploy plumbing.

---

## Data flow (v1)

```
iOS tap "Generate chapter"
  → POST /functions/v1/run-outline { outline_id, start_section_id, end_section_id }
     (auth, rate-limit, credit reservation at entry)
  → for each section in canonical order (parent_section_id → position):
       1. Aggregate narrow prior state via structured queries
          (NOT top-K similarity — see "Prior context query shape" below)
       2. Call generate-story with the section + prior context
       3. Stream progress to a Postgres run_log row (iOS polls)
  → on chain complete: commit credits, write summary
  → on chain failure: roll back uncommitted credits, write error
iOS polls GET /functions/v1/run-outline/{run_id}
  → returns { status, sections_done, sections_total, current_section, errors }
```

Two new artifacts needed:
- `chapter_runs` Postgres table — one row per kickoff, tracks state, per-section status, per-section credit usage.
- `run-outline` Edge Function — the orchestrator.

Existing artifacts reused:
- `outline_sections` (iOS already has these, PR #301)
- `section_embeddings` (PR #304 — stores the 5 structured fields)
- `generate-story` (PR #305 added the aggregate-context helper but no consumer yet — this RFC is the consumer)
- `SupabaseRateLimitStore` + credit pipeline (existing)

---

## Prior context query shape (the core design decision)

This is what was wrong with PR #305 (and the canonical spec's Phase 4):

> **WRONG:** "Top-K most similar sections" — embeds the current scene's plan, does cosine similarity vs `section_embeddings.vector(1536)`, takes top-K, dumps their summaries.

> **RIGHT (proposed):** Narrow, scoped queries against the structured columns (`character_deltas`, `plot_thread_deltas`, `continuity_facts`, `open_loops`, `scene_ending_state`):
> - "Which prior scenes mention character X?" → query `character_deltas` for entries with that name.
> - "What's the current status of plot thread Y?" → query `plot_thread_deltas` for entries with that thread.
> - "What open loops are unresolved?" → query `open_loops`.
> - "What's the most recent ending state for this scene's location?" → query the latest `scene_ending_state`.

These are narrow Postgres queries with explicit filters, returning compact rows. **No token budget cap** (Kevin: "I don't want a token budget on inputs" 14:33 EDT) — narrow queries against the structured columns produce naturally compact results by design, not by an explicit number.

PR #305's `fetchProjectStateContext` helper does the cumulative-aggregate form. For multi-section, we may want a parallel `fetchScopedProjectState(projectId, scopes: ScopeSet)` that takes a narrow filter. **Same Postgres column reads, narrower result.** Decide in implementation.

---

## Async + iOS experience

**v1 shape:**
1. iOS user taps "Generate this chapter" (a range of sections on the Outline tab).
2. Bottom sheet shows estimated cost + ETA. User taps Confirm.
3. iOS calls `run-outline` edge function via SupabaseBackendClient (existing pattern in `GenerationBackendService`).
4. The kickoff returns a `run_id` immediately (don't wait for the whole chapter).
5. iOS surfaces a progress view (sheet or modal): "Section 3 of 12 — generating... ~3 min left."
6. iOS polls every ~10s via GET `/chapter-runs/{run_id}`. Background-job UI pattern.
7. On completion: progress view shows "Done. 12/12. Cost: X credits." Auto-dismiss after 5s. Each new section lands in the standard Accepted Outputs flow.

**No real-time streaming UI** (text streaming over SSE for prose). v1 keeps it async-poll. Streaming is a future enhancement.

---

## Failure semantics

**Recommend v1: stop the chain on failure.**
- Section N fails → halt. Don't attempt N+1, N+2...
- Roll back any credits reserved for unprocessed sections.
- Mark N-1 as accepted (they completed), N as failed (not accepted), N+1 as pending (not attempted).
- iOS surface: "Section 5 failed: <error>. Retry just section 5, or skip and continue with section 6, or stop?"

**Future: resume from where stopped, or retry just the failed section.** Not v1.

---

## Cost + rate-limit

- **Per-run credit ceiling:** user-set on the bottom sheet. Default = sum of estimated credits across all sections in batch. Hard cap = user's available credits (whichever is lower).
- **Per-run rate limit:** reuse `SupabaseRateLimitStore` (already used in generate-story). The multi-section endpoint hits the same key (userId) at each step.
- **Token usage reporting:** stored per-section in `chapter_runs.sections[].credit_used`. After completion, the table row holds the full audit trail.
- **No reservation until kickoff.** Reserve credits at kickoff time (`credit_pipeline.reserve(estimated_total)`), commit at end. If a single section fails, release its reserved portion.

---

## Failure boundary conditions

- User navigates away during run: run continues server-side; iOS resumes polling on next foreground.
- Run errors mid-section (LLM timeout, credit exhaustion): roll back reserved credits for that section onward, surface the error to iOS.
- Same outline kicked off twice (idempotency): second kickoff returns 409 — user must explicitly retry or wait for first to finish. Don't double-charge.

---

## iOS UI affordances (new)

On `OutlineSectionsRegionView` (PR #301):
- **Per-section:** Generate button (existing stub), and a new "Generate from here to end" menu item. Long-press reveals it.
- **Multi-select:** swipe to multi-select → action sheet "Generate N sections starting from #X".

On kickoff:
- Bottom sheet: "Generate sections #5–#10. Estimated: 42 credits / ~8 min. Start?"
- Buttons: Start, Cancel, View current rate (if curious).

During run:
- Persistent banner at top of Outline tab: "Generating #5 of 12 (last updated: 30s ago)." Tap to expand into a progress sheet.
- The progress sheet shows per-section status (pending / running / done / failed) with elapsed ETA per running section.

On completion:
- Banner auto-dismisses after 5s.
- Toast: "Chapter done. 12 sections generated. 42 credits used."

---

## Phasing (proposed)

**Phase 8 — Multi-section pipeline (this RFC, 5 days):**
1. Day 1: `chapter_runs` table, `run-outline` edge function skeleton (auth, rate-limit, credit reserve).
2. Day 2: outline-walker + per-section loop. Calls generate-story.
3. Day 3: prior-context query shape (the right one, not top-K).
4. Day 4: iOS UI — bottom sheet, progress banner, completion toast.
5. Day 5: testing, failed-section handling, polling edge cases.

**Phase 9 (later, this arc or next):** redesign Phase 4 retrieval in `novel-building.md` to use the narrow-query shape, not top-K.

---

## Open decisions (need Kevin's input before code)

1. **Failure semantics: stop the chain (v1) or skip-and-continue?** Recommend stop.
2. **Per-section progress: 10s polling or 5s?** Lean 10s to save credits on polling.
3. **Cost preview: how to estimate before kickoff?** Walk all sections, sum estimates. Same heuristic as current per-section estimate, just summed.
4. **What counts as a "chapter" boundary?** Use `outline_sections.parent_id` self-ref (chapters are parents of section children)? Or arbitrary start/end range? v1 = arbitrary range.
5. **Sequential only, or do we ever parallelize?** v1 = sequential (each section sees prior only). Parallel is a future optimization.
6. **What if the user changes the outline mid-run?** Reserve the run, let it finish, then re-run. Don't try to be clever about it.
7. **Idempotency on the kickoff.** Standard "use a clientRequestId dedupe" pattern, or simpler "second kickoff gets 409"?
8. **Should `fetchProjectStateContext` (PR #305's aggregate helper) stay as-is, or get scoped?** Keep the aggregate form available (orchestrator may want full state for the FIRST section of a chapter). Add `fetchScopedProjectState` for subsequent sections. Two helpers, distinct uses.

---

## Pre-mortem

What could go wrong:

- **Section generation hits its own token cap mid-chapter.** Result: chapter partially generated, credits partially committed. Recovery: roll back per-section.
- **LLM provider rate-limit (not Supabase rate-limit).** The current per-section generate-story doesn't dedupe across rapid retries. Add jitter or backoff if we see throttling.
- **Out-of-order section acceptance.** If the user accepts a section, then asks to "generate from section 5," what does that mean? v1: assume the user wants fresh state, ignore past accepts. v2: use accept-marker timestamps.
- **iOS app dies mid-chapter.** Run continues server-side. iOS resumes polling on reopen. (Handled.)

---

## Open questions for Kevin

- Should this RFC drop the canonical spec's Phase 4 retrieval approach (top-K) wholesale, or wait for a separate cleanup PR?
- Right scope for v1: per-chapter (range of sections) only, or also support "this whole outline"?
- Naming: `run-outline` edge function, or something else? (`run-outline-batch`, `section-batch`, ...?)
