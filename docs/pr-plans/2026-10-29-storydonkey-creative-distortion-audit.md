# StoryDonkey Creative-Distortion Audit

**Date:** 2026-10-29
**Scope:** Read-only investigation of the canonical recipe → enrichment → outline pipeline
**Repository:** `kje7713-dev/CathedralOS`
**Baseline:** persisted run `e6a7a4ca-afec-484a-a983-d85ac0dd4f0f`

## Executive finding

The pipeline contains no deterministic rewrite that explicitly turns imaginative recipes into procedural plots. The distortion emerges from the interaction of:

1. Story Arc contracts and conventional narrative priors.
2. Allocation pressure toward countable, section-sized developments.
3. A highly prescriptive generation-ready outline schema.
4. Novel-length budgeting and progressive expansion.
5. LLM selection among developments that are all structurally valid.

Enrichment is currently the strongest creative-preservation layer. The main distortion occurs after enrichment, when rich character and world material is translated into allocation units and then into canonical, continuity-constrained section contracts.

## Evidence examined

- `supabase/functions/outline-from-recipe/index.ts`
- `supabase/functions/outline-from-recipe/_prompt_context.ts`
- Enrichment, allocation, outline, semantic-repair, and expansion prompts
- Existing validation, checkpoint, and recovery behavior
- Persisted baseline run `e6a7a4ca-afec-484a-a983-d85ac0dd4f0f`
- Creative-authority and character-driven directives introduced by recent work

The baseline contained 27 sections, 6 planner characters, 4 planner relationships, 3 planner institutions, and 18 procedurally leaning summaries. No new paid generation was performed for this audit.

## Pipeline transformation map

### Recipe → enrichment

`buildEnrichmentPrompt()` explicitly carries authored identity, genre, tone, intensity, absurdity, uncertainty, relationships, character contradictions, and non-negotiables. It instructs the provider to invent concrete situations rather than defaulting to documents, investigations, reports, or administrative discovery. Planner-created material is marked provisional.

**Finding:** Enrichment is not the primary demonstrated source of distortion. It produces usable imaginative material, including character conflicts, viral mythology, unreliable visions, hybrid persecution, and unstable relationships.

### Enrichment → allocation

`buildAllocationPrompt()` converts the material into one allocation for every Story Arc beat, section counts, container counts, midpoint token estimates, and a complete first-pass novel projection near 115,000 words under a 125,000-word cap.

This transforms a network of possible character interactions into a budgeted inventory of measurable narrative units. Developments that are easy to count and assign to beats are favored in practice: pursuits, confrontations, discoveries, escapes, rescues, institutional escalations, and tactical reversals.

**Finding:** Allocation is the first major narrowing point. It does not require procedural plotting, but it makes procedural causal spines unusually convenient.

### Allocation → outline prompt

`buildPrompt()` contains strong recipe-authority and Character-Driven Dramatic Selection instructions. It also imposes simultaneous requirements for:

- complete section-by-section output;
- one canonical event per section;
- exact entry and terminal states;
- continuity across all beats;
- one validated dramatic function;
- non-redundancy;
- recipe-obligation coverage;
- container semantics;
- novel-length scale;
- concrete people, places, actions, consequences, and transitions;
- premise payoff and climax causality.

**Finding:** The prompt says to choose the most original option, but the larger contract rewards events that are causally explicit, operationally complete, and easy to validate. Conventional plot machinery satisfies those constraints reliably.

### Outline → validators and repairs

Structural validation checks schema correctness, beat assignment, section counts, container validity, distinct titles, recipe-obligation IDs, continuity fields, and Story Arc requirements. Literary diagnostics include dramatic distinctness, semantic arc issues, causal scale, and unused material, but these remain advisory rather than general completion gates.

**Finding:** The system is much better at rejecting malformed or incomplete outlines than at rejecting creatively generic ones. A procedural outline can complete if it is coherent, distinct enough structurally, recipe-tagged, continuous, and within budget.

### Novel expansion

Expansion prioritizes authored premise and characters, then consequences and reversals, planner material, and fresh material. It explicitly warns against generic institutional or procedural steps.

**Finding:** Expansion is not the original cause, but it can preserve the initial plot grammar. Once the first pass establishes a pursuit, campaign, rescue, or operation as the causal spine, expansion extends that spine rather than reconsidering whether it was creatively appropriate.

## Primary distortion mechanisms

### 1. Structural authority exceeds creative authority

The recipe is described as authoritative, but the executable requirements are more numerous and concrete than the creative principles. The model must prove location, action, state change, continuation, beat assignment, obligation coverage, budget fit, and non-repetition. Procedural causality is safer than strange, socially emergent, psychologically nonlinear, or structurally unconventional causality.

**Confidence:** High.

### 2. Character material is present but does not necessarily cause the plot

Characters can receive scenes, relationships can receive turns, and traits can appear in summaries while institutions, missions, pursuits, or investigations determine the sequence. This is causal substitution: characters remain present, but systems determine what happens next.

**Confidence:** High.

### 3. Story Arc roles carry conventional genre gravity

Terms such as incitement, escalation, reversal, crisis, climax, transformation, and resolution are structurally useful but semantically broad. Unless the recipe strongly prevents it, the model fills them using familiar genre patterns.

The baseline contains unusual material but repeatedly organizes it through roadblocks, pursuits, contractor operations, transfer depots, diversions, extraction, and rescue logic.

**Confidence:** High.

### 4. Canonical-event requirements suppress productive ambiguity

Requiring one specific person, place, object, and action improves generation readiness. It can also suppress authored uncertainty, dream logic, social misinterpretation, contradiction, or unresolved causality when those are themselves part of the intended experience. The prompt permits ambiguity, but its dominant instruction is to resolve alternatives into one concrete event.

**Confidence:** Medium-high.

### 5. Novel-scale budgeting rewards event inventory

The 115,000-word target and 125,000-word cap are necessary for novel support, but they encourage a large collection of countable dramatic units. To fill the book while avoiding repetition, the model tends to chain new threats, locations, confrontations, revelations, and tactical complications.

**Confidence:** High.

### 6. Creative diagnostics are non-blocking

The code records creative-quality diagnostics, but structural validity and required-obligation coverage determine completion. Creative conventionality is observable but does not generally prevent a run from succeeding.

**Confidence:** High.

## What the baseline demonstrates

The baseline is not generically dull. It preserves Fred’s violence and unreliable visions, Ted’s accidental public mythology, Millie’s divided loyalties, unstable sexual and chemical dependence, hybrid persecution, contradictory public interpretations, morally compromised outcomes, collateral harm, and the absence of clean justice or reconciliation.

However, those elements are repeatedly organized through conventional causal machinery:

- a filmed assault creates a manhunt;
- a roadblock creates an escape;
- a crowd creates a public movement;
- a casino creates a contained disaster;
- contractors create a pursuit;
- a transfer depot creates a rescue operation;
- a diversion enables extraction;
- a final operation produces the climax.

This confirms that the issue is not simple loss of source material. It is causal substitution: distinctive characters and situations remain present, but conventional operational structures frequently determine what they do next.

## What the evidence does not establish

This audit does not establish that:

- enrichment systematically deletes creative material;
- validators directly rewrite imaginative sections into procedural ones;
- the pipeline always produces conventional fiction;
- recent creative-authority changes improve production output;
- PR #793 or later changes produce literary improvement.

Those claims require controlled paid comparisons using the same persisted enrichment package.

## Root-cause conclusion

StoryDonkey’s creative distortion is primarily a selection-pressure problem, not a missing-creativity problem.

The pipeline carries imaginative source material forward, but later stages favor developments that are easy to allocate, express as one canonical event, connect through continuity, map to Story Arc functions, validate, and expand to novel length. Procedural plots satisfy those constraints unusually well.

> Enrichment preserves possibilities; allocation and outline planning select a causal spine; validation confirms structural compliance but does not strongly enforce creative distinctiveness.

That is where the architecture most consistently turns imaginative source material into conventional fiction.
