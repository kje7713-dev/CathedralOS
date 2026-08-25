# CathedralOS Kindle Export (Chapter Reader PR #5)

**Status:** Planned 2026-08-24 21:17 EDT (Kevin via Telegram)
**Phase:** Pre-implementation — durable spec, awaiting implementation start
**Branch:** `docs/kindle-export-pr5` (this file's home)
**Memory:** kevbot-brain (workflow + project_convention), MEMORY.md "CathedralOS Kindle export (Chapter Reader PR #5)" section
**Parent:** `docs/novel-building/chapter-reader.md` (PR #5 in that sub-arc)
**Adjacent:** `docs/novel-building.md` (Phase 5 Remix + Phase 6 Continue are still queued separately)

---

## Goal

Add a Kindle-ready EPUB export for novel-building projects. Section-based generations package into a professional EPUB with proper front matter, chapter structure, and Kindle-quality typography. Section titles drive the structure (chapters + sections), industry-standard front pages, in-app preview, and server-side validation.

## Locked decisions (all 7 user questions resolved 2026-08-24 21:17 EDT)

### Q1 — In-app reader
**Locked: C — Readium SDK**
- Heavy Swift package (~MB of SDK code in iOS bundle) but gives Kindle-quality in-app rendering
- In-app reader is **preview-before-save only** — not the primary reading surface (users open the EPUB in Apple Books or Kindle for actual reading)
- Alternative considered: QLPreviewController (zero deps, generic Apple document viewer). Rejected because Kevin wants "Kindle-quality" preview.
- Imported via SwiftPM. SPM dependency on Readium 2.x or 3.x (TBD during implementation).

### Q2 — Cover image
**Locked: (d) Both — user can upload OR auto-generate, with "Skip cover" as third path**
- User upload: stored in Supabase Storage, URL persisted in `export_metadata.cover_image_url`
- Auto-generate: AI image gen from Recipe premise (likely DALL-E 3 via OpenAI API; provider TBD). New LLM cost per cover.
- "Skip cover": book is valid EPUB without cover; Kindle shows a blank cover placeholder
- Default behavior on the screen: "Generate cover" button + "Upload image" button + "Skip cover" link
- Cover image: 1600×2560 px recommended (Kindle KFX aspect ratio 1:1.6), JPEG or PNG, max ~5MB

### Q3 — Chapter title source
**Locked: (a) Pull from chapter-root `OutlineSection.title` with auto-fall-back**
- If `OutlineSection.title` exists for a chapter-root section, use it as the chapter heading
- If missing or empty, fall back to auto-numbered "Chapter N" (1-indexed by chapter position)

### Q4 — Cloud versioning
**Locked: (c) Keep latest + active, with 30-day GC for old versions**
- Each export has a `version_id` (uuid)
- The **latest** export is implicitly "current" (what iOS reader pulls by default)
- The user can **flag a specific version as "active"** (overrides "current" if set)
- Old versions remain queryable in cloud for **30 days**, then GC'd by a cron job
- `export_metadata` table keyed by `(project_id, version_id)`

### Q5 — Export execution model
**Locked: (b) Async with progress**
- User taps "Export" → request kicks off server-side job
- Server returns `job_id` immediately
- iOS polls a status endpoint (`GET /export-job-status?job_id=xxx`) every ~3s
- Status: `queued | rendering | validating | uploading | complete | failed`
- Optional push notification when complete (iOS local notification, not APNs — keeps it simple)
- Preview screen opens on `complete` status

### Q6 — Error UX
**Locked: (a) Hard fail**
- On any failure (LLM call, EPUB validation, cloud upload), show error toast
- No partial output saved to cloud or local
- User can retry from the same pre-export screen
- Failed export job is logged in `export_jobs` table for diagnostics; retention 7 days

### Q7 — Background chapter title fallback
**Locked: (a) "Untitled Section N" placeholder**
- If a section in the chapter has no title (legacy data, edge case), use "Untitled Section 1", "Untitled Section 2", etc.
- Section is **NOT dropped** from the export — it's included with the placeholder title
- This avoids the silent-data-loss risk of option (b)

---

## Architecture overview

```
┌──────────────┐         ┌────────────────────────┐         ┌─────────────────┐
│   iOS App    │  POST   │   export-epub           │  EPUB   │ Supabase        │
│              │ ──────► │   edge function         │ ──────► │ Storage         │
│  Pre-export  │         │   (Deno)                │  bytes  │ (per-user       │
│  screen +    │ ◄────── │                        │ ◄────── │  folder)        │
│  Readium     │  JSON   │   ┌──────────────────┐ │         │                 │
│  preview     │         │   │ EPUB writer       │ │         └─────────────────┘
└──────────────┘         │   │ (Deno, no lib)   │ │
       ▲                │   └──────────────────┘ │
       │                │            │              │
       │   GET          │            ▼              │
       │   poll         │   ┌──────────────────┐    │
       │   status       │   │ epubcheck (Java) │    │
       │                │   │ validation        │    │
       └────────────────│   └──────────────────┘    │
                        │                          │
                        │   optional: generate-     │
                        │   cover-image edge fn     │
                        └──────────────────────────┘
```

---

## Database schema

### New: `export_metadata`

```sql
create table public.export_metadata (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  version_id uuid not null default gen_random_uuid(),

  -- User-supplied fields (locked from pre-export screen)
  book_title text not null,
  author_name text not null,
  copyright_year int not null,
  copyright_holder text not null,
  language text not null default 'en',
  isbn text, -- placeholder, optional
  publisher_name text,
  series_name text,
  series_number int,

  -- AI-drafted fields (with user edit on the pre-export screen)
  dedication text,
  book_description text,
  about_author text,

  -- Cover image (one of: user-uploaded, AI-generated, or null = no cover)
  cover_image_url text, -- supabase storage path
  cover_image_source text check (cover_image_source in ('user_upload', 'ai_generated', null)),

  -- Status flags
  is_active boolean not null default false, -- user-flagged "active" version
  is_current boolean not null default false, -- implicit "latest" flag (set by trigger or app code)

  -- Export metadata (provenance)
  exported_at timestamptz not null default now(),
  exported_by_user_id uuid not null references auth.users(id),
  epub_storage_path text, -- supabase storage path to the EPUB file
  epub_size_bytes bigint,
  epub_sha256 text, -- content hash for integrity
  export_metadata_json jsonb, -- additional fields (e.g., AI prompt versions, validation status)

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Latest export per project is "current"
create unique index idx_export_metadata_current_per_project
  on public.export_metadata (project_id)
  where is_current = true;

-- Active export per project (user-flagged)
create unique index idx_export_metadata_active_per_project
  on public.export_metadata (project_id)
  where is_active = true;

-- Project lookup index
create index idx_export_metadata_project_id_created
  on public.export_metadata (project_id, created_at desc);
```

### New: `export_jobs` (async job tracking)

```sql
create table public.export_jobs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  export_metadata_id uuid references public.export_metadata(id), -- set on complete

  status text not null check (status in ('queued', 'rendering', 'validating', 'uploading', 'complete', 'failed')),
  progress_pct int default 0,
  error_message text,
  error_code text,

  started_at timestamptz not null default now(),
  completed_at timestamptz,

  created_at timestamptz not null default now()
);

create index idx_export_jobs_project_status on public.export_jobs (project_id, status);
create index idx_export_jobs_created on public.export_jobs (created_at desc);
```

### Storage

New Supabase Storage bucket: `epub-exports`
- Per-user folder structure: `users/{user_id}/epubs/{version_id}.epub`
- RLS: user can read/write only their own folder

---

## Pre-export UI screen (NEW dedicated iOS screen)

Not a modal. Accessed from chapter reader (PR #1, shipped as #348) via "Export" button.

### Fields

**User-supplied (required unless marked optional):**
- Book title (required)
- Author name (required)
- Copyright year (required, default current year)
- Copyright holder (required, default = author name)
- Language (required, dropdown of common languages, default "en")
- ISBN placeholder (optional)
- Publisher name (optional)
- Series name (optional)
- Series number (optional, only if series name provided)

**AI-drafted (with "Draft from Recipe" button next to each):**
- Dedication (1-3 sentences, intimate tone)
- Book description / back-cover blurb (50-200 words)
- About the author (1-2 paragraphs)

**Cover image:** Three buttons in a row:
- "Generate cover" (calls AI cover generation, shows progress)
- "Upload image" (file picker, max 5MB, JPEG/PNG)
- "Skip cover" (subtle text link)

**Once cover is set:** thumbnail preview + "Replace" / "Remove" buttons.

**Bottom:** "Generate Export" button (primary action). Disabled until required fields filled.

---

## Server-side export flow (export-epub edge function)

### Request shape

```typescript
POST /export-epub
{
  project_id: string;
  book_title: string;
  author_name: string;
  copyright_year: number;
  copyright_holder: string;
  language: string;
  isbn?: string;
  publisher_name?: string;
  series_name?: string;
  series_number?: number;
  dedication?: string;
  book_description?: string;
  about_author?: string;
  cover_image_url?: string; // supabase storage path
}
```

### Response (immediate)

```typescript
{
  job_id: string;
  status: 'queued';
}
```

### Processing pipeline (background)

1. **Render EPUB** (`rendering` status, 10-50s for typical novel)
   - Fetch all `OutlineSection`s for project, ordered by `position`
   - Group by `parent_id` (chapter roots = sections with no parent)
   - For each section, fetch the LATEST `GenerationOutput` (regardless of accepted status)
   - Build EPUB structure (see "EPUB writer details" below)
2. **Validate with epubcheck** (`validating` status, 1-5s)
   - Run `epubcheck` Java tool as Deno subprocess
   - Validate: well-formed XML, valid OPF spine, all referenced files exist, no broken internal links, metadata is complete
3. **Upload to Supabase Storage** (`uploading` status, 1-5s)
   - Path: `users/{user_id}/epubs/{version_id}.epub`
   - Compute SHA-256, store in `export_metadata.epub_sha256`
4. **Write export_metadata + update status** (`complete` status)
5. **Send local notification** to user (iOS side handles this via polling detection)

### Failure handling

On any failure: `failed` status with `error_code` + `error_message`. NO partial output saved to cloud. User can retry from same pre-export screen.

---

## EPUB writer details (Deno implementation, no library)

### EPUB structure (per spec)

```
epub-exports/{version_id}.epub
├── mimetype                          # "application/epub+zip" (no compression, must be first)
├── META-INF/
│   ├── container.xml                 # standard EPUB container
│   └── metadata.xml                  # Dublin Core metadata
├── OEBPS/
│   ├── content.opf                   # OPF package document (manifest + spine)
│   ├── content.toc.xhtml             # NCX/TOC navigation
│   ├── content.toc.ncx               # legacy NCX (some readers need it)
│   ├── nav.xhtml                      # EPUB3 navigation document
│   ├── stylesheet.css                  # typography CSS
│   ├── cover.jpg (optional)          # cover image
│   ├── title-page.xhtml               # industry-standard title page
│   ├── copyright.xhtml                # copyright page
│   ├── dedication.xhtml (optional)    # dedication page
│   ├── toc.xhtml                       # table of contents
│   ├── chapter-N.xhtml                 # one per chapter
│   └── colophon.xhtml                 # about-the-author page
```

### Typography (Kindle-book look)

CSS defaults:
- `font-family: Georgia, "Times New Roman", serif;`
- `font-size: 1em;` (the reader scales)
- `line-height: 1.3;`
- `text-align: justify;`
- `text-indent: 1.5em;` for paragraph first lines (except first paragraph of a chapter/section)
- Chapter heading: `<h1>` with 2em top margin, page-break-before
- Section heading: `<h2>` within chapter, no page break
- Section separator (within a chapter): `blank line + title + blank line` (Kevin-locked style)
- Margins: 1em (readers handle real margins)

### Chapter grouping

- A section with `parent_id = NULL` is a **chapter root**
- A section with `parent_id != NULL` is a **child section within a chapter**
- Chapter title: from `OutlineSection.title` of the chapter root, fall back to "Chapter N"
- Child sections: appended to their parent chapter's XHTML, separated by blank line + section title + blank line
- Sections without a parent (legacy data, no `parent_id`): treat as their own chapter

### Section flow within chapter

```html
<!-- chapter-1.xhtml -->
<h1>Chapter 1: The Lighthouse</h1>

<p>First paragraph of the first section...</p>

<p>...</p>

<!-- Section break: blank line, title, blank line -->
<h2>The Letter</h2>

<p>First paragraph of the second section...</p>

<p>...</p>
```

### Section title rendering

- Pull from `OutlineSection.title`
- If missing: "Untitled Section N" (1-indexed per chapter, not global)
- Container + POV: NOT visible (per Kevin's locked decision)

### Section selection

- Per `OutlineSection`, fetch the LATEST `GenerationOutput` (by `created_at DESC`)
- No filtering by `accepted` status — user is responsible for cleaning up bad sections before export
- If a section has no `GenerationOutput`, export with placeholder text: "[This section has not been generated yet.]"

### Whitespace / typography heuristics (writer-side, "do whatever is more likely to produce desired results")

- Strip leading/trailing whitespace from each output
- Collapse runs of 3+ blank lines into 1
- Strip any leading `#`, `**`, `_`, or other Markdown-style markers that might leak from generation
- Normalize curly quotes vs straight quotes (preserve curly — they're more Kindle-like)
- Strip leading whitespace from each line (LLMs sometimes emit it)
- Normalize line endings to `\n`
- Escape `&`, `<`, `>`, `"`, `'` for XHTML

---

## In-app preview (Readium)

After export completes, iOS opens `EPUBPreviewView`:
- Loads EPUB via Readium SDK (`EPUBPublication` → `Navigator`)
- Standard Readium reader chrome: page navigation, font size, theme toggle (light/sepia/dark), table of contents
- "Done" button to dismiss back to the pre-export screen or chapter reader

Readium SDK integration:
- SwiftPM dependency: `Readium` package, latest 2.x stable (or 3.x if available — verify during implementation)
- Module imports: `ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`
- ~50-100 lines of integration code on the iOS side

---

## File changes (provisional)

### iOS (`CathedralOS` repo)

**New:**
- `CathedralOSApp/Features/Export/PreExportView.swift` — pre-export screen
- `CathedralOSApp/Features/Export/ExportService.swift` — calls export-epub, polls status
- `CathedralOSApp/Features/Export/EPUBPreviewView.swift` — Readium-backed reader
- `CathedralOSApp/Features/Export/PreExportViewModel.swift` — view model (if needed; otherwise inline)
- `CathedralOSApp/Models/ExportMetadata.swift` — SwiftData model (optional; backend is source of truth)
- `CathedralOSApp/Package.swift` (or `.xcodeproj/project.pbxproj`) — add Readium SwiftPM dep

**Modified:**
- `CathedralOSApp/Features/Reader/ChapterReaderView.swift` (PR #1 / shipped as #348) — add "Export" toolbar button → opens PreExportView
- `CathedralOSApp/Features/Projects/OutlineSectionsRegionView.swift` — same Export button on the chapter level

### Supabase (`CathedralOS` repo, `supabase/` directory)

**New:**
- `supabase/migrations/YYYYMMDDHHMMSS_kindle_export.sql` — `export_metadata` + `export_jobs` tables, RLS, indexes
- `supabase/functions/export-epub/index.ts` — the entrypoint edge function (~200 lines)
- `supabase/functions/export-epub/_writer.ts` — EPUB builder (~500 lines)
- `supabase/functions/export-epub/_templates.ts` — XHTML template strings (~200 lines)
- `supabase/functions/export-epub/_epubcheck.ts` — validation helper (~50 lines)
- `supabase/functions/export-job-status/index.ts` — status polling endpoint (~50 lines)
- `supabase/functions/generate-cover-image/index.ts` — DALL-E cover generation (~100 lines)
- `supabase/functions/_shared/storage.ts` — Supabase Storage helpers (if not already existing)

**Modified:**
- `supabase/config.toml` — add new function entries
- `supabase/migrations/*` — Storage bucket setup via SQL or `supabase_storage` config

### Tests

- `supabase/functions/export-epub/_writer_test.ts` — EPUB structure tests (well-formed XML, valid OPF, etc.)
- `supabase/functions/export-epub/_templates_test.ts` — template rendering tests
- `CathedralOSApp/Features/Export/ExportServiceTests.swift` — iOS service tests
- `CathedralOSApp/Features/Export/PreExportViewTests.swift` — pre-export screen tests

---

## Effort estimate (provisional)

| Phase | Effort | Notes |
|---|---|---|
| Backend: schema + storage bucket | 0.5 days | Migration + RLS |
| Backend: export-epub edge function + EPUB writer | 4-5 days | Deno implementation, the bulk of backend work |
| Backend: epubcheck integration | 0.5-1 day | Subprocess helper, error handling |
| Backend: generate-cover-image edge function | 1 day | DALL-E integration, image upload |
| Backend: async job tracking + status endpoint | 1 day | export_jobs table, polling endpoint |
| iOS: PreExportView (new screen) | 1.5-2 days | Metadata fields, AI draft buttons, cover handling |
| iOS: ExportService (API + polling) | 1 day | REST calls, polling logic, error states |
| iOS: Readium integration + EPUBPreviewView | 1.5-2 days | SwiftPM dep, viewer, dismiss flow |
| iOS: Export button on ChapterReaderView | 0.25 day | Toolbar button + navigation |
| Polish + cross-platform testing | 1.5-2 days | End-to-end testing, edge cases |
| **Total** | **12-15 days** | Roughly 3 weeks focused work |

---

## Open decisions to resolve during implementation

These don't block spec but need answers before code:

1. **Readium SDK version** — 2.x stable vs 3.x (if released). Verify on SwiftPM during implementation kickoff.
2. **Cover image AI provider** — OpenAI DALL-E 3 (cleaner, consistent style), Stability AI (cheaper), or Azure OpenAI (if Azure is preferred). Recommendation: DALL-E 3 for v1.
3. **epubcheck binary hosting** — Java tool. Options: (a) vendor the JAR in the repo (~3MB), (b) download from official source on first run, (c) use a smaller EPUB conformance library. Recommendation: vendor it.
4. **Cover image aspect ratio** — 1600×2560 (KFX-friendly) vs 1400×1872 (older Kindle) vs 1:1.5 (standard). Default: 1600×2560.
5. **Series info display in EPUB** — when series_name + series_number provided, where does it appear? Title page? Chapter header? Both?
6. **Existing assets / data migration** — do any existing projects need their export_metadata backfilled? (Probably not — export_metadata is per-export, not per-project.)
7. **Theft / watermarking** — do we add an invisible watermark to the EPUB with the user's user_id for traceability? (Light deterrent against unauthorized sharing.) Recommendation: optional, off by default.
8. **Multi-language** — Kevin locked language as a user-supplied field, but what about per-language EPUB generation rules (e.g., RTL languages, CJK font handling)? Defer to later; out of scope for v1.
9. **Export from Outline tab vs chapter reader** — locked to chapter reader for v1, but should we also add Export from the Outline tab (whole project, not just one chapter)? Recommendation: yes, in v2.
10. **"Active" flag UX** — how does the user mark a specific version as active in the iOS UI? Recommendation: tap-and-hold on an export in the export history list → "Mark as active" action.

---

## Risks (informational, factored into the plan)

- **Readium SDK size impact on iOS bundle** — ~MB of compiled Swift code. Acceptable for an app that already ships substantial code. Mitigation: confirm with Kevin before locking the version.
- **epubcheck Java dependency** — adds a JAR (or vendor copy) to the edge function bundle. Mitigation: vendor the JAR; it's stable.
- **DALL-E 3 cost** — ~$0.04 per cover image at 1024×1024. Acceptable cost per export (user-triggered).
- **Cloud storage costs** — per-user EPUBs at ~50KB-2MB per novel. Supabase Storage is $0.021/GB/month. Negligible cost at expected user scale.
- **Async job state** — if the user kills the iOS app mid-export, the server-side job still runs. Mitigation: jobs table lets us track + retry; user can re-poll from history view.
- **Section cleanup responsibility** — Kevin explicitly said "user cleans up sections before export." This means we ship a "manage sections" UX if one doesn't already exist (it does — the Outline tab). The export is "dumb" — it just packages whatever the Outline tab currently contains.

---

## Verification plan

End-to-end smoke test:
1. Pick a project with ≥10 outline sections (mix of chapter-root + child sections)
2. Open Chapter Reader → tap Export
3. Pre-export screen: fill metadata, generate cover (AI), draft dedication/book description (AI)
4. Tap Generate Export → expect async job kickoff
5. Wait for completion notification → tap to open EPUBPreviewView
6. Verify in Readium: title page, copyright, dedication, TOC, body chapters, colophon all render correctly
7. Save to Files app
8. Run `epubcheck` against the downloaded file (manual verify)
9. Verify cloud storage: query `export_metadata` table, confirm row exists with `epub_storage_path`, `epub_sha256`, `is_current=true`

---

## Memory hygiene (per AGENTS.md)

This plan doc + its branch tip MUST be:
1. Referenced from a kevbot-brain chunk (workflow class, importance 8-9)
2. Referenced from MEMORY.md "CathedralOS Kindle export (Chapter Reader PR #5)" section with: file path, branch, latest commit hash, content summary, locked decisions, open decisions
3. Updated on every checkpoint commit (advance the tip pointer)

When the implementation begins, this plan doc should be the single source of truth for what to build. If implementation surfaces a decision not captured here, update this doc first, then code.

---

## Housekeeping folded into implementation

Smaller items to address during the build:
- Async job GC (cron job to delete completed/failed `export_jobs` older than 7 days)
- 30-day GC of old EPUBs in cloud storage (cron job)
- Export history view in iOS (list of past exports with "Download", "Mark as active", "Delete" actions)
- Audit log: who exported what when (GDPR-relevant)

---

**Last updated:** 2026-08-24 21:17 EDT — all 7 user questions resolved, spec locked.
