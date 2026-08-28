# Persona-First MVP UX Orchestration

**Status:** Draft PR plan — planning only; no implementation approval
**Date:** 2026-08-27
**Scope:** Three tactical UX PRs; no app redesign

## Goal and outcome

Make the two core workflows obvious without changing CathedralOS's underlying
infrastructure:

- **Write a Quick Story** — get useful prose quickly from one idea.
- **Build a Novel** — develop a story deliberately over time.

Both paths continue to use the existing project, generation, billing, sync, reader,
publishing, and EPUB/export systems. A Quick Story can become a Novel Workspace using
the same project and carrying forward its idea/output.

## Current behavior

- `ProjectsListView` is the primary entry. Its `+` button opens the existing project
  name sheet; imported projects use a separate menu item.
- After creation, the user lands in `ProjectDetailView`.
- `ProjectDetailView` exposes a seven-way `StoryEditorMode` picker: Story, Cast,
  Themes, Recipe, Outline, Compile, and Output. An Advanced toggle exposes the full
  editor list at once.
- Generation is currently concentrated in the Compile surface and output actions live
  in `GenerationOutputDetailView`.
- Novel-building tools already exist in `OutlineTabView`, including
  `StoryArcRegionView` and `OutlineSectionsRegionView`.
- Reading is provided by `ChapterReaderView`; publishing/output actions are in
  `GenerationOutputDetailView`; Kindle/EPUB work is in `KindleExportView`.
- The infrastructure works, but the first destination and next useful action are not
  obvious for either persona.

## Proposed behavior

### Quick Story

`Write a Quick Story` opens a focused flow with only:

1. Idea input
2. A small set of optional controls
3. Generate
4. Read the output

Before generation, do not show recipe, story arc, outline, prompt pack, or section
management concepts. After generation, use explicit actions:

- **Regenerate**
- **Continue the story**
- **Build this into a novel**
- **Save / Share / Export** where supported by the existing output flow

`Build this into a novel` opens the normal Novel Workspace for the same project and
preserves the idea and generated output. It does not create a second generation path.

### Novel Workspace

Keep the existing tools and add a lightweight guidance surface around them:

**Define → Shape → Outline → Write → Review → Read → Export**

This is orientation, not a checklist. It must never gate tools or require strict phase
completion. The project should surface the most useful next action from current state,
while all existing tabs and actions remain accessible.

## Shared behavior to reuse

- Existing `StoryProject` and `GenerationOutput` SwiftData models and sync.
- Existing `SupabaseGenerationService`, model selection, estimates, and credit flows.
- Existing generate/regenerate/continue/remix output actions.
- Existing `ProjectDetailView` editor tabs and Advanced toggle.
- Existing outline suggestion/acceptance, coherence, Chapter Reader, publishing, and
  Kindle/EPUB export flows.
- Existing output lineage and project relationships for the Quick Story → Novel bridge.

No new generation, billing, orchestration, or project-mode backend is planned.

# PR plan

## PR 1 — Entry-point split only

### Current behavior

The Projects screen offers a generic `+` project creation action. The user must decide
what kind of experience they want only after entering the dense project editor.

### Proposed behavior

Add two outcome-oriented creation choices at the Projects entry point:

- **Write a Quick Story** — “Get useful prose quickly from one idea.”
- **Build a Novel** — “Develop your story deliberately over time.”

The Build a Novel choice continues into the existing project creation flow. The Quick
Story choice establishes the focused entry destination to be completed in PR 2. Neither
choice changes generation or project persistence in this PR.

### Likely screens/components

- `ProjectsListView`
- A small creation-choice view/component if needed for clear presentation
- Existing `addProjectSheet` routing only as required

### Reuse

Existing project list, navigation stack, project creation sheet, and
`ProjectDetailView` destination.

### Non-goals

- No Quick Story generation implementation
- No Novel roadmap/progress surface
- No model or database changes
- No changes to generation, billing, sync, export, or editor behavior

### Acceptance criteria

- A new user can immediately distinguish Quick Story from Build a Novel.
- The labels communicate outcome, not beginner/advanced status.
- Build a Novel still creates/opens a normal existing project.
- Existing import, project list, output list, and project navigation continue to work.
- No existing project behavior changes.

## PR 2 — Focused Quick Story flow

### Current behavior

Generation is reached through the full project editor and Compile surface, which exposes
novel-building concepts before a casual user has generated anything.

### Proposed behavior

Implement the focused Quick Story destination from PR 1:

- Idea field first
- Only a small set of optional controls
- Existing generation service and estimate/credit confirmation behavior
- Direct transition to the existing readable output detail surface
- Explicit post-generation actions: Regenerate, Continue the story, Build this into a
  novel, and existing save/share/export actions

The bridge creates or opens the same normal project representation and carries forward
the idea and output. It must not fork generation logic.

### Likely screens/components

- Quick Story entry component introduced by PR 1, likely a new focused SwiftUI view
- `KindleExportView` only if existing export/share actions need a direct handoff
- `GenerationOutputDetailView` for the result and explicit actions
- Existing generation service/client protocols and output persistence path
- Existing project creation/persistence path for the bridge

### Reuse

Existing generation request construction, model/length controls where appropriate,
server estimates, credit confirmation, output persistence, output detail, continuation,
regeneration, sharing, and export.

### Non-goals

- No recipe, arc, outline, prompt-pack, or section UI before generation
- No new generation endpoint or billing architecture
- No redesign of `GenerationOutputDetailView`
- No Novel Workspace roadmap yet
- No mandatory save or project-mode database field unless the implementation proves it
  is required to preserve the bridge

### Acceptance criteria

- A user can go from Quick Story entry to generated readable prose without seeing
  novel-specific concepts.
- The required input is only an idea.
- Optional controls remain limited and understandable.
- The generated result supports explicit Regenerate and Continue the story actions.
- Build this into a novel preserves the original idea and generated output in the normal
  project flow.
- Existing estimate, billing, sync, output lineage, share, and export behavior remains
  intact.

## PR 3 — Novel workflow/progress and next-action surface

### Current behavior

`ProjectDetailView` exposes powerful tabs and an Advanced toggle, but a returning user
must infer what to do next from the current tab layout. The existing novel tools are
available but not presented as a coherent progression.

### Proposed behavior

Add a compact, non-blocking workflow/progress surface to the normal novel project
experience:

**Define → Shape → Outline → Write → Review → Read → Export**

It should:

- Show lightweight state based on existing project/output data.
- Highlight one useful next action, such as define the premise, shape the arc, add an
  outline section, generate a section, review an output, open the reader, or export.
- Link directly to the existing destination for that action.
- Remain visible/useful when reopening an existing project.
- Leave every existing editor tab, Advanced mode, output action, reader, publishing,
  and export route accessible.

### Likely screens/components

- `ProjectDetailView` as the host
- A small workflow/progress view or component
- `StoryEditorMode` routing/selection for Define, Shape, Outline, and Write targets
- `OutlineTabView`, `StoryArcRegionView`, and `OutlineSectionsRegionView`
- Existing output/read/export destinations, including `GenerationOutputDetailView`,
  `ChapterReaderView`, and `KindleExportView`

### Reuse

Existing project relationships, outline/section/output state, navigation destinations,
editor tabs, chapter reader, publishing, and export. State should be derived from
existing data rather than introducing a new workflow engine.

### Non-goals

- No wizard or AI orchestration infrastructure
- No mandatory phases, locks, or completion gates
- No major navigation rewrite
- No beginner/advanced modes
- No broad redesign of artifact editors
- No new billing, sync, reader, publishing, or export behavior
- No new project-mode database field unless implementation proves it necessary
- No unrelated cleanup

### Acceptance criteria

- A returning novel user can identify the next useful action within a few seconds of
  opening a project.
- The progression is understandable but explicitly optional/non-blocking.
- Each suggested action opens the existing relevant screen.
- Existing tools remain accessible regardless of inferred state.
- State updates naturally after existing edits, outline changes, generation, review,
  reading, or export.
- Existing projects open safely with useful guidance and no migration requirement.

## Tactical delivery order

1. **PR 1:** make the two outcomes visible at the front door.
2. **PR 2:** make Quick Story genuinely useful end to end.
3. **PR 3:** make the existing Novel Workspace self-explanatory for returning users.

Each PR should be independently reviewable and useful. The success measure is not a new
visual system; it is that users stop asking “where do I start?” and “what do I do next?”
