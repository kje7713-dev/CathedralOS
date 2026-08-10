# CathedralOS Novel-Building Direction

**Status:** Established 2026-08-04 07:13 EDT (Kevin via Telegram)
**Phase:** Pre-implementation — durable spec, awaiting implementation start
**Memory:** kevbot-brain (project_convention, importance 9), MEMORY.md "CathedralOS novel-building direction"

---

## Goal

Shift CathedralOS from short-story generation to novel-building capability. Category change, not feature add. Coherence across sections is the new core problem.

The chain:

```
Recipe → Outline (new) → Outline sections (each = one Container run)
      → Accepted outputs → Vectorized DB (new) → Remix / continue
```

Novel-building requires:
- **Planning** — outline first, not freeform generation
- **Linking** — vectorized DB ties sections together semantically
- **Coherence** — containerized runs within a project stay consistent across sections

---

## IA decision: Story Arc lives in the Outline tab

Story Arc is a planning artifact, not a recipe ingredient. It belongs with sections, not with premise.

**Outline tab = two regions, top to bottom:**

1. **Story Arc** (top) — template picker (Three-act / Hero's Journey / Mystery / Romance / Thriller / etc.) + beat editor. User picks a template, beats auto-populate, user customizes.
2. **Outline Sections** (bottom) — manual CRUD. Each section is one Container run, OR a group of Containers (e.g. "Chapter 1" = 3 scenes). Sections can tag which arc beat they cover.

**Recipe (Story bucket) stays as "what the story is about":**
- Summary, Audience, Setting, Motifs, Cast, Themes. No arc.

**iOS tabs:** 6 total — Story / Cast / Themes / Outline / Compile / Output. Outline is the new one.

---

## Design decisions (locked)

1. **Outline source** — AI suggests (via `outline-from-recipe` LLM), user accepts/edits.
2. **Section granularity** — Flexible. Each section is one Container run OR a group of Containers. Schema: `OutlineSection` with `parent_id` self-ref OR `containers` array.
3. **Acceptance model** — Explicit Accept button per output. On accept: extract + embed + link to outline section.
4. **Vector extraction** — Concise structured summary on accept, ~200-500 tokens. Fields: characters + their current state, key events, open threads, established facts, tone, foreshadowing. Embed the summary (NOT raw text). Keep raw text alongside for later deep context. Summary is what gets injected for retrieval. "As much as needed to work well."
5. **Coherence** — Soft warn first. Pre-gen check returns "this might contradict section X in this way". User proceeds anyway or revises. Hard constraint later if needed.
6. **Pricing** — Stays tokenized, no changes. Per-generation credit model works at novel scale.
7. **iOS IA** — New Outline tab. 6 tabs total.

---

## Recipe expansion

For novel-building, the recipe needs more arc primitives than the short-story version has.

**Templates (cleanest abstraction):** pick "Three-Act" and the recipe auto-populates Setup / Confrontation / Resolution beats. User customizes. Adding a new template later = one DB row.

**Starter templates to seed:** Three-act, Hero's Journey, Mystery. Romance, Thriller, and others added over time.

**Additional arc primitives needed:**
- Inciting incident / midpoint / climax / resolution (explicit story beats)
- Conflict type (person vs. self / society / nature / technology / god)
- Pacing notes — where slow vs. fast moments should land
- Character arc — how the protagonist changes

These can be encoded as `StoryArcBeat` rows with `role` + `label` + `description`. JSON shape: `{ "role": "inciting_incident", "label": "Inciting Incident", "description": "..." }` — extensible later.

---

## Reusable components (already exist, no work needed)

- **`Container.swift`** (13 cases) — already the unit of generation
- **`generate-story` edge function** — already takes container + POV + terminal beat
- **`GenerationOutput` rows** — already store outputs with metadata
- **Supabase Postgres** — pgvector is a one-line extension enable

## New surface area

- **Models:** `StoryArc`, `StoryArcBeat`, `Outline`, `OutlineSection` (SwiftData + Postgres)
- **Edge functions:** `outline-from-recipe`, retrieval-augmented `generate-story`, `remix-section`, `continue-from-section`
- **Database:** pgvector + `section_embeddings` table + entity-extraction-on-accept
- **iOS:** Outline tab, section cards, accept / remix / continue controls

---

## Phasing

Each phase ships usable. Total ~3-4 weeks focused, 6-12 weeks with iteration.

### Phase 0/1 — Outline tab + Story Arc + manual sections (5 days)

**Goal:** Pure data model + UI. No LLM cost. Validates IA + schema before burning cycles.

**Postgres:**

- `story_arc_templates` (id, name, description, beats JSONB, created_at)
- `story_arcs` (project_id, template_id, customizations JSONB, created_at, updated_at)
- `story_arc_beats` (story_arc_id, position, role, label, description)
- `outlines` (project_id, story_arc_id NULLABLE, name, created_at)
- `outline_sections` (outline_id, parent_id NULLABLE for grouping, position, title, summary, container JSONB or container_id NULLABLE, pov NULLABLE, terminal_beat NULLABLE, status DEFAULT 'draft')

Seed 3 templates: Three-act, Hero's Journey, Mystery.

**SwiftData:**

- `StoryArc`, `StoryArcBeat`, `Outline`, `OutlineSection` linked to `StoryProject`
- Migration to add the new tables and seed data

**UI:**

- New Outline tab on `ProjectDetailView`
- Two regions: Story Arc (top), Outline Sections (bottom)
- Per-section "Generate" button (stub initially, real in Phase 3)
- Swipe actions on sections (delete, duplicate, reorder)

**Acceptance criteria:**

- User can pick a template and see beats auto-populate
- User can edit, add, remove, reorder beats
- User can manually create sections (single-container or grouped)
- User can tag a section with which arc beat it covers
- Sections persist across app launches
- Per-section Generate button shows a stub "coming soon" state

### Phase 2 — AI-generated outline suggestions (2 days)

- `outline-from-recipe` edge function takes recipe + arc template, returns 5-15 suggested sections
- User accepts/edits the suggestions before locking in
- Same data model as Phase 0/1, just the input source changes

### Phase 3 — pgvector + acceptance indexing (3 days)

- Enable pgvector extension on Supabase
- `section_embeddings` table (id, project_id, outline_section_id, embedding vector(1536), extracted_summary text, raw_text text, container, pov, created_at)
- On Accept: run extraction pass via LLM (~200-500 token summary), embed via `text-embedding-3-small`, store both summary and raw text
- Index on embedding column (HNSW for write-heavy workloads)

### Phase 4 — RAG retrieval via the 5 structured memory layers (revised 2026-08-10 18:01 EDT, Kevin's hard rule: schema tight, pull deep)

**Supersedes** the original top-K similarity design (PR #262) and the "N most recent" heuristic that PR #305 / PR #309's DAY3_NARROW_LIMIT tried. The wrong abstraction was: embed the current scene's plan → cosine similarity vs `section_embeddings.vector(1536)` → take top-K → dump their summaries. The right abstraction: **narrow, scoped queries against the 5 structured columns** that PR #304 added to `section_embeddings` (`character_deltas`, `plot_thread_deltas`, `continuity_facts`, `open_loops`, `scene_ending_state`).

**Locked design rules** (from `docs/multi-section-generation.md`):

1. **Keep the 5 structured memory layers.** Don't drop or rename.
2. **`character_deltas`: merge fields, don't let the latest entry overwrite earlier fields.** Scene 1: `{character_name: "Jon", knowledge: "X"}`. Scene 2: `{character_name: "Jon", goal: "Y"}`. Aggregate: `{character_name: "Jon", knowledge: "X", goal: "Y"}` — both fields merged.
3. **`plot_thread_deltas` + `open_loops`: stable IDs + explicit lifecycle/status.** Each thread/loop has a stable UUID that persists across scenes. Status: `introduced` / `advanced` / `resolved`. When resolved, mark with `resolved_at` timestamp.
4. **`continuity_facts`: provenance + active/superseded.** Each fact: `{id, fact, source_section_id, active, superseded_by?, created_at}`. When a fact is no longer true, mark `active=false` or `superseded_by=<other_fact_id>`.
5. **ALWAYS inject the immediately previous canonical section's summary + ending state**, regardless of intent filtering. The model needs what just happened.
6. **Retrieve by outline order / current accepted revision**, NOT `created_at`. Use `outline_sections.position`.
7. **`location` must actually filter** (not just tie-break). Other-location scenes are excluded from the prior context.
8. **Pipeline order: generate → persist output → extract/store scene memory → next.** The output is persisted BEFORE the next section can read it.
9. **`raw_text` is stored for re-extraction/debugging** but **NOT injected by default**. Only the compressed summary + structured state are sent to the model.

- `generate-story` (and the new `run-outline` orchestrator in Phase 8) accepts optional `outline_section_id`
- When provided:
  - Query narrow: "which prior scenes mention this character?", "what's the status of this plot thread?", "what open loops are unresolved?", "what's the most recent ending state for this location?"
  - Postgres-level filters, compact rows
- No token budget cap (Kevin: "I don't want a token budget on inputs" 14:33 EDT). Narrow queries against the structured columns produce naturally compact results — compact by design, not by an explicit cap.
- The aggregate-form helper (`fetchProjectStateContext`, from PR #305) lives in `generate-story` for the FIRST section of a chapter (full state); a scoped variant `fetchScopedProjectState` is added for subsequent sections
- Multi-section generation (Phase 8) consumes this same lookup shape repeatedly — once per section in a chapter

**PR #305 (`feat(generate-story): RAG retrieval against section_embeddings`) is now dead-code plumbing awaiting Phase 8.** PR #305's `fetchProjectStateContext` stays in place; once Phase 8's `run-outline` exists, it becomes the consumer. The retrieval plumbing in `generate-story` now follows the narrow-query shape above, not PR #305's N-most-recent aggregation.

### Phase 5 — Remix (2 days)

- UI button on each accepted section: "Remix"
- User picks variation: same container, different POV; same POV, different container; different terminal beat; or any combo
- Generate new version, side-by-side compare with original, pick favorite
- New `remix-section` edge function

### Phase 6 — Continue (2 days)

- UI button on each accepted section: "Continue from here"
- Generates the next outline section with continued context
- Auto-links in outline (sets `parent_id` or appends as next-sibling)
- New `continue-from-section` edge function

### Phase 7 — Coherence check (later)

- Pre-generation check: compare proposed section's premise against accepted sections
- If high-similarity contradiction detected, surface as soft warning
- "This section might contradict 'Section X' which says Y. Proceed anyway?"
- User accepts and proceeds, or revises

---

## Concrete first deliverable (Phase 0/1)

- 4 new SwiftData models: `StoryArc`, `StoryArcBeat`, `Outline`, `OutlineSection`
- 5 new Postgres tables: `story_arc_templates`, `story_arcs`, `story_arc_beats`, `outlines`, `outline_sections`
- Migration to seed 3 templates (Three-act, Hero's Journey, Mystery)
- New Outline tab on `ProjectDetailView` with two regions (arc + sections)
- Per-section Generate stub button
- No LLM cost — purely data model + UI

## Housekeeping folded into PRs as we go

Smaller items that get addressed during the build:
- AccountView.swift:38 Swift 6 actor-isolation warning (1-line `@MainActor` fix)
- Phase 3 legacy column drop (pure SQL)
- Stale local branches cleanup
- Phase 3 commit retroactive PR for review trail (optional)
- CathedralView.swift dead code (delete / repurpose / leave — decide during Phase 0/1)
- Truncation loop verification on real device (confirm Container + terminal-beat paradigm holds)

## Deferred (not in this arc)

- IAP / monetization (StoreKit 2 + receipt validation) — discussed, deferred to a later session.

---

## Open questions for later phases

- Should outline sections be exposed in the Compile tab (alongside the current single-recipe generation) or only in the Outline tab?
- Should the AI suggest a coherent sequence of arcs (e.g. "Three-act structure works well for your premise") or just let the user pick?
- For multi-author / collaborative projects, how does coherence work across authors?
- Pricing: does the per-generation model hold at 50+ generations per project, or do we need bundles? (Kevin 07:09: "stays tokenized so i don't think we need to touch that now" — revisit if usage data disagrees.)

---

**Last updated:** 2026-08-04 07:13 EDT (initial spec, awaiting implementation start)
