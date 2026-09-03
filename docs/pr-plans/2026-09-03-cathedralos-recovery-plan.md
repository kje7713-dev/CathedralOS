<!--
Status: planning-only; no implementation authorized by this document.
Source: Kevin's attached CathedralOS_Recovery_Plan document (2026-09-03).
-->

# CathedralOS Recipe → Outline → Generation Recovery Plan

## Purpose

Repair the planning pipeline so CathedralOS reliably turns the canonical recipe into a full-length novel without dropping major story obligations between recipe creation, outlining, Run All, and prose generation.

This plan is based on the Test3 failure where:

- the canonical recipe reached `outline-from-recipe` correctly;
- the recipe included the project premise, Fred/Ted/Betty/Steve, relationships, theme, spark, motif, and aftertaste;
- the outline collapsed much of that material into a narrower Ted-control/Fred-Steve domestic story;
- the outline projected only ~29,462 words;
- expansion failed with `expansion placement crosses arc beats`;
- the outline was still marked completed and later generated as a ~28k-word book;
- `generate-story` still received the full recipe, but the Section Contract correctly outranked the broader recipe, making it too late for generation to repair a bad outline.

The primary repair area is therefore:

`recipe → outline planning → validation → frozen outline contract → Run All`

Do not begin by broadly rewriting `generate-story` prompting.

---

# Desired Architecture

```text
Canonical Recipe
      ↓
Recipe Obligations
      ↓
Story Arc + Length Allocation
      ↓
Section Contracts
      ↓
Coverage + Scale Validation
      ↓
Frozen Generation Contract
      ↓
Run All
      ↓
Prose Generation
```

Authority should ultimately resolve as:

```text
1. HARD CANON
   Frozen recipe facts / premise invariants

2. BOOK CONTRACT
   Required recipe obligations and global length target

3. SECTION CONTRACT
   What must happen now

4. SUPPORTING CONTEXT
   Themes, motifs, aftertaste, optional guidance

5. PROJECT STATE
   Prior accepted-story continuity
```

The Section Contract remains authoritative for the immediate section, but it must be derived from and traceable back to the Book Contract rather than replacing it.

---

# PR 1 — Fail Closed on Undersized Novel Outlines

## Goal

Never allow a clearly undersized novel outline to become a successful planning result.

## Primary area

`supabase/functions/outline-from-recipe/`

## Required changes

1. Treat novel scale as a hard planning invariant rather than a warning.
2. Preserve the existing 70k–90k broad novel target unless product settings already provide a different explicit target.
3. Continue using projected section/container size for planning diagnostics.
4. After first-pass generation:
   - if projected length is below the accepted minimum, expansion is required;
   - if expansion succeeds, validate again;
   - if expansion fails and the outline is still materially under target, fail the request.
5. Do not return `completed` merely because Story Arc coverage is valid.
6. Replace the current warning-only outcome with explicit failure states such as:
   - `failed_under_target`
   - `failed_expansion`
7. Preserve diagnostics:
   - projected words before/after;
   - projected tokens before/after;
   - remaining estimated deficit;
   - expansion round count;
   - expansion validation error;
   - final section count.
8. Do not persist or expose an undersized outline as generation-ready.

## Exact regression to cover

Reproduce the Test3 shape:

```text
22 sections
~29,462 projected words
expansion error: expansion placement crosses arc beats
remaining deficit: large
```

Expected result:

```text
planning fails
outline is NOT generation-ready
Run All cannot start
```

Also test a successful expansion similar to the earlier same-recipe run:

```text
~23 first-pass sections
→ ~42 expanded sections
→ ~71,500 projected words
```

Expected result: success.

## Acceptance criteria

- A novel projected at ~29k can never return `completed`.
- An invalid expansion response cannot silently preserve an undersized outline as usable.
- Existing valid full-scale outlines remain unaffected.

---

# PR 2 — Persist a Real Book-Level and Section-Level Length Contract

## Goal

Move from vague container-based estimation to an explicit length budget that survives all the way into Run All.

## Schema

Add outline-level planning fields, either directly to `outlines` or through a dedicated planning metadata table:

```text
planning_format
target_word_count
target_word_count_min
target_word_count_max
projected_word_count
```

Add section-level fields to `outline_sections`:

```text
target_words
target_words_min
target_words_max
```

Names may vary, but the concepts must persist.

## Planner behavior

For a novel target such as 80,000 words:

1. Allocate approximate word budget across Story Arc movements.
2. Let each movement determine how many dramatically distinct sections it needs.
3. Allocate section word targets within each movement.
4. Reconcile section targets to the global target.
5. Do not satisfy length merely by changing everything into `chapter`, `setPiece`, or other giant containers.

Example only:

```text
Novel target: 80,000

You       7,000
Need      8,000
Go       12,000
Search   16,000
Find      10,000
Take      11,000
Return     8,000
Change     8,000
```

The actual allocation should be story-dependent.

## Generation interaction

- Container still determines literary shape and safe output cap.
- Section target words become planning intent, not a reason to pad.
- The generation request should carry the section's persisted target range so telemetry can compare planned vs. actual length.

## Telemetry

Persist or log:

```text
planned_target_words
actual_output_words
length_variance_pct
```

This should make it obvious whether future failures occur in planning or generation.

## Acceptance criteria

- Sum of section targets approximately reconciles to the outline target.
- A novel cannot be declared generation-ready when its section budgets only add up to novella scale.
- Test3 would have been rejected before generation.

---

# PR 3 — Derive and Validate Recipe Obligations

## Goal

Prevent the outline from structurally satisfying the Story Arc while silently abandoning the actual promised story.

## Problem being fixed

The full Test3 recipe included material such as:

- drugs / lines;
- killing / violent consequences;
- saving the world;
- Ted's triggered black rage;
- Fred/Steve power conflict;
- Ted/Betty control dynamic;
- theme: whether bad people can do good things.

The produced outline retained some of those while reducing the story mainly to learning how to control Ted.

Current outline validation does not prove that the outline still realizes the important recipe content.

## Add a Recipe Obligation layer

Before section generation, derive a compact set of narrative obligations from the canonical recipe.

Example for Test3:

```text
R1 Ted's random triggers produce black violent rage.
R2 Drugs/lines materially affect the story rather than appearing as decoration.
R3 Killing/violence is a substantive story engine.
R4 Fred/Ted's actions escalate beyond the immediate household.
R5 The central plot materially involves saving the world.
R6 Fred/Steve's father-son conflict over use of power affects the plot.
R7 Ted/Betty's sexual control dynamic materially affects Ted's violence.
R8 The story tests whether bad people can accomplish something good.
```

These are examples, not hardcoded Test3 rules.

## Obligation classification

Each derived obligation should be classified, for example:

```text
hard_premise
major_plot
character_arc
relationship
world_constraint
supporting_theme
supporting_motif
ending_intent
```

Only genuinely important recipe content should become mandatory obligations.

Motifs and aftertaste should usually remain supporting rather than hard plot obligations.

## Section mapping

Each proposed outline section may carry:

```json
{
  "recipeRequirementIDs": ["R3", "R5"]
}
```

or an equivalent persisted representation.

## Validation

Before accepting an outline, verify:

1. Every required obligation is covered.
2. Major premise obligations receive sufficient development, not one token mention.
3. Required obligations are distributed plausibly through the Story Arc.
4. No required obligation is contradicted by the outline.
5. Supporting motifs/themes are not incorrectly promoted into mandatory plot events.
6. The central premise remains recognizable in the completed outline.

A simple first implementation can be LLM-assisted validation, but the result must be stored and auditable.

## Failure behavior

If a required obligation is missing:

- attempt bounded repair/expansion;
- if still missing, fail planning;
- do not return a generation-ready outline.

## Acceptance criteria

- An outline for Test3 cannot pass without materially covering the "save the world" portion of the premise.
- Sparse recipes still allow invention.
- Rich recipes preserve supplied material instead of replacing it with a simpler alternate story.

---

# PR 4 — Freeze Recipe Provenance Onto the Outline

## Goal

Ensure Run All uses the exact canonical recipe that produced the outline.

## Current architectural risk

`run-outline` currently reconstructs generation context from the latest project snapshot and selects the first prompt pack.

That means outline creation and prose generation can theoretically use different source recipes after edits or in multi-pack projects.

## Required data

Persist immutable provenance when an outline is successfully planned.

Possible direct fields on `outlines`:

```text
source_recipe_json
source_recipe_hash
source_recipe_version
source_prompt_pack_id
source_prompt_pack_name
source_snapshot_id
```

A dedicated immutable `outline_source_recipes` table is also acceptable if cleaner.

## Creation behavior

When outline planning begins/succeeds:

1. Canonicalize the recipe.
2. Freeze the exact recipe payload used.
3. Generate a deterministic hash.
4. Persist prompt-pack identity.
5. Associate all of it with the outline.

## Immutability

Editing the project later must not silently alter the recipe attached to an existing outline.

If the user wants the outline to use the edited recipe, require an explicit re-plan / refresh operation.

## Acceptance criteria

- Given an outline ID, the backend can retrieve the exact recipe that produced it.
- Run All no longer depends on `packs[0]`.
- Run All no longer depends on "latest snapshot" semantics for source canon.
- Recipe hash is available in diagnostics/logging.

---

# PR 5 — Make Run All Consume the Frozen Generation Contract

## Goal

Create one canonical generation request path based on the frozen outline contract.

## Primary area

`supabase/functions/run-outline/`

## Per-section generation input

Construct each generation request from:

```text
Frozen canonical recipe
+
Book-level recipe obligations
+
Section-specific assigned obligations
+
Story Arc position / movement purpose
+
Section Contract
+
Prior canonical Project State
```

Do not rebuild recipe canon from the newest project snapshot.

## Prompt authority

Preserve the current Section Contract authority for immediate prose.

Add a separate book-level block such as:

```text
## Book Contract

The following requirements come from the frozen recipe that this outline was built to fulfill.
They define global story obligations. The current Section Contract controls what happens now,
but it must remain consistent with these obligations and materially advance any obligation
assigned to this section.
```

Then per section:

```text
## Required Recipe Progress

This section is responsible for materially advancing:
- R4: violence expands beyond the household
- R5: establish or advance the larger save-the-world objective
```

Do not make every recipe field mandatory in every scene.

## Keep supporting context separate

Themes, motifs, aftertaste, and similar elements should remain supporting unless explicitly classified otherwise by the recipe-obligation layer.

This prevents a skull motif from having the same authority level as the central save-the-world premise.

## Remove unsafe reconstruction

Eliminate or bypass the generation path that does:

```ts
const pack = packs[0]
```

for Run All canon selection.

## Acceptance criteria

- Every generated section can be traced to:
  - outline ID;
  - frozen recipe hash;
  - assigned recipe obligations;
  - section contract;
  - Story Arc beat.
- Project edits after outline creation do not silently change an active Run All job.

---

# PR 6 — Add a Generation-Readiness Gate

## Goal

Make it impossible for Run All to begin from an invalid or incomplete planning product.

## Planning status

Add an explicit state such as:

```text
draft
planning
validating
generation_ready
invalid
```

Run All must accept only `generation_ready` outlines.

## Required readiness checks

Before an outline becomes generation-ready:

```text
[ ] canonical frozen recipe exists
[ ] recipe hash exists
[ ] source prompt pack identity exists
[ ] Story Arc coverage passes
[ ] required recipe-obligation coverage passes
[ ] projected total length passes
[ ] section length allocations reconcile with project target
[ ] every section has valid container
[ ] every section has valid POV
[ ] every section has a usable Section Contract
[ ] Story Arc placement is valid
[ ] expansion/repair did not end in unresolved failure
[ ] no duplicate or effectively duplicate section contracts
```

## API behavior

Run All request against a non-ready outline should return a clear 4xx response with structured diagnostics, not attempt best-effort generation.

Example:

```json
{
  "errorCode": "outline_not_generation_ready",
  "failures": [
    "projected_length_below_minimum",
    "missing_recipe_obligation:R5"
  ]
}
```

## Acceptance criteria

- Test3's 22-section/~29k outline cannot reach Run All.
- A valid ~70k+ Test3 plan can.

---

# End-to-End Regression Fixtures

Add permanent integration fixtures rather than relying only on implementation-string tests.

## Fixture A — Sparse Recipe

Recipe concept:

```text
Monsters kill humans.
Only named character: Douche.
```

Expected behavior:

- planner may invent supporting plot material and additional context where allowed;
- Story Arc remains coherent;
- novel-scale target is reached through distinct dramatic material;
- the central monsters-kill-humans premise remains dominant;
- generated sections do not repeatedly restart the outline.

## Fixture B — Rich Recipe / Test3-shaped

Use a sanitized fixture structurally equivalent to Test3 with:

- 4 named characters;
- 2 important relationships;
- trigger/rage spark;
- drugs/violence/global objective in premise;
- theme;
- motif;
- ending residue;
- Story Circle arc.

Expected behavior:

- all hard/major obligations receive outline coverage;
- global objective cannot disappear;
- projected novel scale passes;
- Run All uses frozen recipe hash;
- generated sections preserve continuity without repeatedly recreating the same dramatic state.

---

# Out of Scope Until These PRs Land

Avoid broad prompt churn in `generate-story` unless a PR specifically needs a small compatibility change.

Do not attempt to solve this by:

- weakening Section Contract authority globally;
- making the prose model "remember the recipe harder";
- dumping the entire recipe into every volatile section instruction;
- inflating all sections into giant containers;
- adding arbitrary filler sections merely to hit word count;
- relying on latest project snapshots during Run All;
- accepting an undersized outline with a warning.

The planner should guarantee that the generated section contracts collectively describe the right book before prose generation starts.

---

# Recommended Merge Order

```text
PR 1  Hard novel-scale invariant
  ↓
PR 2  Persisted book/section length budgets
  ↓
PR 3  Recipe obligations + coverage validation
  ↓
PR 4  Frozen recipe provenance
  ↓
PR 5  Run All consumes frozen generation contract
  ↓
PR 6  Generation-readiness gate + E2E regression coverage
```

Do not combine all six into one PR.

PRs 1–3 repair the direct Test3 failure.
PRs 4–6 make the architecture durable and prevent adjacent versions of the same failure.

---

# Definition of Done

This recovery work is complete when all of the following are true:

1. A requested novel cannot silently become a ~30k work because planning expansion failed.
2. The system can explain the planned word budget before generation begins.
3. Every important canonical recipe obligation can be traced into the outline.
4. The outline validator rejects a structurally valid Story Arc that abandoned the core recipe.
5. An outline permanently references the exact recipe revision that produced it.
6. Run All uses that frozen recipe rather than reconstructing canon from current project state.
7. Every generated section can be traced to both its Section Contract and its assigned Book Contract obligations.
8. Run All refuses any outline that is not explicitly `generation_ready`.
9. Sparse recipes still permit useful invention.
10. Rich recipes preserve user-specified story material rather than being simplified into a different story.
