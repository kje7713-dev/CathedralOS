# PR6 — Fix the Shit (cycle 6) — Recover the 41 Persisted Suggestions Without Re-Billing

**Status:** Implementation plan
**Branch:** `fix/recover-41-suggestions` (off `origin/main` at `5e9db26`)
**Date:** 2026-09-12

## Diagnosis

Device smoke test of build `34661243262` (PR #537) surfaced a hard error on the Suggest Sections retry path:

> Suggest Sections Failed
> story material enrichment is insufficient: no canonical recipe material was preserved

Looking at `supabase/functions/outline-from-recipe/index.ts`:

- Line 2279: when iOS retries a Suggest Sections call and the persisted run already has `story_material`, the worker reuses it via `body = { ...body, storyMaterialEnrichment: claimedRun.story_material }`.
- Line 2285: the persisted material is validated through `validateStoryMaterialEnrichment(claimedRun.story_material, { recipe: body.recipe })`.
- Line 2286–2287: `isCompatibleStoryMaterialEnrichment(...)` and `storyMaterialSufficiency(...)` enforce that the material was generated against the **same canonical recipe** AND contains enough `source: "recipe"` items.

The 41 legacy runs were planned before `STORY_MATERIAL_ENRICHMENT` was introduced in PR #527, so their persisted `story_material` either:
- has zero `source: "recipe"` items (the planner filled every category as `source: "planner"`), OR
- carries a stale `sourceRecipeHash` that no longer matches the live project.

Either case throws at line 2288 (`"persisted expansion checkpoint has incompatible story material"`), and the worker re-bills on every retry. A retry today would also re-bill for the enrichment LLM call, which is wasteful given we already have the canonical recipe in the request body.

## Fix

### 1. New function `repairStoryMaterialFromRecipe(recipe: unknown): StoryMaterialEnrichment`

Pure JS (no LLM, no DB). Walks the canonical envelope fields (`selectedCharacters`, `selectedStorySpark`, `selectedAftertaste`, `selectedRelationships`, `selectedThemeQuestions`, `selectedMotifs`) and constructs a valid `cathedralos.story_material_enrichment` payload where every item carries `source: "recipe"` and a meaningful `sourceReference` (e.g., `selectedCharacters[<id>]`).

The output satisfies `validateStoryMaterialEnrichment` (schema/version/format/rationale + per-category items) and `storyMaterialSufficiency` (enough recipe-derived items for the requested format). Rationale: `"recovered from canonical recipe; legacy run pre-dates story-material provenance"`.

### 2. Resume-path repair (`outline-from-recipe/index.ts` ~line 2287)

When `claimedRun.story_material` is present but `isCompatibleStoryMaterialEnrichment` returns false OR `storyMaterialSufficiency` is insufficient:

- Call `repairStoryMaterialFromRecipe(body.recipe)` instead of throwing.
- Persist the repaired material to `claimedRun.story_material` via `updateRun({ story_material: repaired })`.
- Set `diagnostics.stage = "story_material_repaired"`, `repairedAt`, and `repairedFromRecipeHash`.
- Continue into the normal `expansionResumeState` / expansion flow with the repaired material.
- No billable LLM call. No credit charge. Audit row already exists on the persisted run.

### 3. Migration `20260912120000_outline_suggestion_run_repair_audit.sql`

Add `outline_suggestion_runs.repaired_at timestamptz` and `repaired_from_recipe_hash text`. Add an index `(user_id, repaired_at)` for the device recovery list. No destructive changes to existing rows.

### 4. Tests (`outline-from-recipe/index_test.ts`)

- `repairStoryMaterialFromRecipe` produces a valid enrichment that passes `validateStoryMaterialEnrichment`.
- A run with empty persisted story_material, when resumed, is repaired and continues through `expansionResumeState` (mocked) without calling `billableCall`.
- A run with mismatched recipe hash is repaired using the live request recipe, not the persisted one.
- A run with valid story_material is left alone (no repair, no extra diagnostics).

## Validation

1. `deno check supabase/functions/outline-from-recipe/index.ts supabase/functions/outline-from-recipe/index_test.ts` — pass.
2. `deno test -A supabase/functions/outline-from-recipe/index_test.ts` — pass (existing + new repair cases).
3. `git diff --check` — clean.
4. Supabase Deploy applies migration + edge function. Live verification: pick one of the 41 persisted runs (or a freshly-broken run) and re-issue Suggest Sections; expect 200 + recovered material instead of 400.
5. CI gates: Supabase Deploy + TestFlight Deploy (no iOS changes).

## Non-Goals

- No new acceptance/recovery surface for Accept All (PR #518 already shipped the story_packet envelope).
- No prompt re-tuning for `buildEnrichmentPrompt` — the repair is fully offline.
- No retry budget changes for the worker — the repaired run goes through the same `updateRun` completion path.
