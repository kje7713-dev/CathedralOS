# Chapter Reader + Multi-Section Workflow

## Current state

Each generated section creates a `generation_outputs` row. The eye button on each section row in the Outline tab shows that section's output. For multi-section generation (chapter = N sections), the user has to click N eye buttons to see all outputs. There's no unified view, no read-aloud flow, no chapter-level accept, no export.

## Goal

Provide a chapter-centric workflow for working with multi-section output:

1. **Read** a chapter as a continuous narrative (sections concatenated in order)
2. **Iterate** on individual sections with feedback
3. **Accept** all sections in a chapter at once
4. **Export** a chapter as a Kindle-compatible document (.epub)
5. **Coherence** warnings (Phase 7 soft warn) before generating

## Phasing

### PR #1 — Chapter reader view (this PR, foundational)

- New view: `ChapterReaderView`
- Shows all sections of a chapter stitched together in outline order
- Each section row: title, container, POV, current output (if generated), or "Generate" button (if not)
- Section-level "Regenerate" and "Accept" actions (delegate to existing flows)
- Navigation: from Outline tab, tap on a chapter → reader navigates in
- Read-only flow (no regeneration needed to read)

**Files:**
- New: `CathedralOSApp/Features/Reader/ChapterReaderView.swift`
- Modify: `CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift` (add NavigationLink on chapter rows)

**Acceptance criteria:**
- User can navigate from Outline tab to chapter reader by tapping on a chapter row
- Chapter reader shows all sub-sections of the chapter in `position` order
- Each section displays its current output (if any) or a "Generate" button
- Each section shows container, POV, beat tag
- Sections without output show "Generate" button (delegates to existing flow)
- Sections with output show "Regenerate" + "Accept" buttons
- User can navigate back to Outline tab
- Read-only flow works (no regeneration needed)

### PR #2 — Phase 7 coherence soft warn

- Backend: pre-gen check that returns "this new section might contradict section X"
- iOS: surface warning before generating
- Locked design rules (PR #310/#311) already specify the data; this is the UI/integration

### PR #3 — Iteration with feedback

- Regenerate with feedback prompt
- Use the feedback to inform next generation
- Backend: append feedback to the kickoff request

### PR #4 — Accept all in chapter

- Bulk accept button for all sections in a chapter
- Existing single-section accept flow stays

### PR #5 — Export to Kindle (.epub)

- iOS: generate EPUB from a chapter's stitched sections
- File format: `.epub` (Kindle-compatible, modern industry standard)
- EPUB structure: META-INF/container.xml, OEBPS/content.opf, OEBPS/content.toc.xhtml, one XHTML per section
- Front matter: title page, chapter title, story arc beat tag as chapter heading
- iOS: export button in chapter reader, save to Files app

## Carry-over notes

- PR #347 left a known flat-outline edge case: chapter rows with no children default to "chapter" which returns nothing. Quick fix when relevant.
- The multi-section walker (PR #347) is now in production. The chapter reader relies on multi-section output being correctly UPSERTed by run-outline.
- Storage: section_embeddings is fully populated (verified 2026-08-16 17:44 EDT). The chapter reader doesn't need to touch embeddings — it only reads generation_outputs.
