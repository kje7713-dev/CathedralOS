# CathedralOS — EPUB / Kindle Publishing Refinement PR Bundle

> **Status**: PR 1 implemented — 1/4 PRs complete; CI/review pending
> **Source plan**: provided by Kevin via Telegram on 2026-09-23 09:55 EDT
> **Base branch**: `main` @ `a39417a` (latest after PR #618 merge)
> **Purpose**: turn CathedralOS's existing validated EPUB exporter into a polished, persistent, Kindle-oriented publishing and sharing workflow without touching the successful novel-generation pipeline.

## Progress Bookmark

| PR | Title | Status | Branch | PR # | Head SHA | Notes |
|----|-------|--------|--------|------|----------|-------|
| 1 | Acknowledgements + Metadata Completion | ✅ Implemented — awaiting CI/review | `feat/epub-acknowledgements` | — | `7e5cda3` | Backend 36/36 export-epub tests pass; local Deno typecheck has the pre-existing JSZip default-export mismatch |
| 2 | True EPUB History + Correct Filename + Delete | ⬜ Not started | — | — | — | `feat(epub): preserve export history and improve sharing` |
| 3 | Kindle-Ready EPUB Rendering + Landmarks | ⬜ Not started | — | — | — | `refactor(epub): make reflowable output Kindle-ready` |
| 4 | Story Arc → Parts + Nested Navigation | ⬜ Not started | — | — | — | `feat(epub): organize books into Story Arc parts` |

## Cross-PR Invariants (Non-Negotiable)

- **Do not touch generation pipeline**: outline-from-recipe, generate-story, run-outline, scene-memory extraction, repetition restraint, model selection, generation prompts, length targets, billing — unless a direct compile dependency is discovered (then stop and report before widening scope).
- **Zero new LLM calls**: Parts deterministic, Acknowledgements user-entered, formatting deterministic, sharing/history deterministic. Zero new generation credit cost.
- **Preserve source manuscript**: EPUB work must not mutate GenerationOutput, OutlineSection, scene memory, story arc, or project content. Export is a rendering/publishing layer only.
- **Historical EPUBs are immutable**: once Export #1 is produced, later export operations must not overwrite its bytes. Distinct storage paths/metadata IDs; regeneration creates a new export.
- **Security**: all history/download/delete operations remain user-owned. Never expose service role to iOS. Require `exported_by_user_id == auth.uid()` before download, deletion, or mutation of history metadata.
- **EPUBCheck**: successful production export means EPUBCheck succeeded under existing policy. Do not weaken validation to make new navigation pass — fix invalid XHTML/OPF/nav output instead.

## Validation Required for Every PR

1. Run relevant Swift unit tests.
2. Run backend Deno tests.
3. Run production source type checks.
4. Run EPUB export tests.
5. Run EPUBCheck fixture validation where applicable.
6. Run iOS Build CI.
7. Inspect PR diff for unrelated files.
8. Confirm branch is based on latest main.
9. **Do not deploy.**
10. **Do not merge** without explicit go-ahead.

## Final Bundle Acceptance Test (Summary)

Use a realistic generated novel (50+ sections, selected Story Arc, generated cover, custom book title, author, dedication, acknowledgements, About Author, description, ≥1 child OutlineSection). Export twice. Both exports must: open, share, remain downloadable; share filename must be `Book Title.epub`; EPUB must render Cover → front matter → Part I (with optional custom name) → titled sections → Part II/III → Acknowledgements → back matter; every nav link works; reader font controls not defeated by hard-coded body fonts; normal fiction paragraphs not blank-line-separated; book passes EPUBCheck. Deleting Export #1 must delete its artifact, retain Export #2 as current, leave project untouched. Deleting current Export #2 while Export #1 exists must promote Export #1 to current.

## Final Architecture Summary (per the bundle)

```
StoryProject
  ↓
Project snapshot
  ↓
Story Arc + OutlineSections + GenerationOutputs
  ↓
EPUB section walker
  ↓
deterministic Parts
  ↓
custom EPUB writer
  ↓
EPUBCheck
  ↓
immutable export artifact
  ↓
Export History
  ↓
Open / native iOS Share Sheet / Delete
```

## Progress Log

- 2026-09-23 09:55 EDT — Plan received from Kevin via Telegram; saved to `docs/pr-plans/2026-09-23-epub-kindle-publishing-refinement-pr-bundle.md` on a detached worktree at `main` HEAD `a39417a` (post-PR #618 merge). No branches created yet, no commits made.

---

## Authoritative Bundle Specification (Kevin, 2026-09-23)

The following is the full authoritative specification provided by Kevin. It is preserved verbatim and is the single source of truth for scope, tests, and acceptance criteria across all four PRs.

---

**CathedralOS — EPUB / Kindle Publishing Refinement PR Bundle**  
  
**Objective**  
  
**Move CathedralOS from a functionally valid EPUB exporter to a polished, digital-first, Kindle-oriented publishing workflow.**  
  
**The generation pipeline is not part of this work.**  
  
**The current application already has most of the required publishing infrastructure:**  
  
**	●	Kindle/EPUB export screen**  
**	●	persistent per-project export metadata draft**  
**	●	title / author / copyright / language metadata**  
**	●	dedication**  
**	●	description**  
**	●	About Author**  
**	●	ISBN**  
**	●	publisher**  
**	●	series name / number**  
**	●	uploaded covers**  
**	●	AI-generated covers**  
**	●	asynchronous EPUB generation**  
**	●	EPUBCheck validation**  
**	●	bounded EPUB repair**  
**	●	private Supabase export storage**  
**	●	authenticated EPUB downloads**  
**	●	internal Readium reader**  
**	●	native iOS share sheet**  
**	●	previous-export UI**  
**	●	regeneration of historical exports**  
**	●	Story Arc models and beat-to-section relationships**  
**	●	project snapshots containing Story Arc + Outline information**  
  
**Do not rebuild these systems.**  
  
**The work is a focused refinement of the existing EPUB/export infrastructure.**  
  
  
  
**Product Requirements Locked by Product Owner**  
  
**Book metadata**  
  
**Existing metadata UX remains.**  
  
**Only two changes are required:**  
  
**	1.	Exported/user-visible EPUB filename must use the entered book title.**  
**	2.	Add Acknowledgements as another optional book field.**  
  
**Do not redesign the Book/Optional panes.**  
  
  
  
**Cover**  
  
**No work required.**  
  
**The current:**  
  
**	●	Upload**  
**	●	AI Generate**  
**	●	Skip**  
  
**cover functionality is already satisfactory.**  
  
**Do not redesign cover generation, storage, billing, selection, or cover UI.**  
  
  
  
**Reading structure**  
  
**The output should be optimized for digital / Kindle reading.**  
  
**The existing short Cathedral sections are intentional.**  
  
**Do NOT merge generated sections into artificial 3,000–8,000 word conventional chapters merely for print conventions.**  
  
**Desired hierarchy:**  
  
Book  
  
 **├──** Part I  
  
 │    **├──** Existing Section Title  
  
 │    **├──** Existing Section Title  
  
 │    **├──** Existing Section Title  
  
 │    **└──** ...  
  
 **├──** Part II  
  
 │    **├──** Existing Section Title  
  
 │    **└──** ...  
  
 **└──** Part III  
  
      **├──** Existing Section Title  
  
      **└──** ...  
  
**Every existing generated section title remains reader-facing and navigable.**  
  
**Story Arc structure should determine the Part boundaries.**  
  
**Users may rename Parts.**  
  
**Keep visual design simple and minimal.**  
  
  
  
**Navigation**  
  
**Required:**  
  
**	●	every generated section title appears in navigation**  
**	●	navigation is nested underneath Parts**  
**	●	Parts may be renamed**  
**	●	EPUB contains conventional Kindle/EPUB landmarks**  
**	●	preserve legacy NCX compatibility where already supported**  
**	●	maintain EPUBCheck validity**  
  
**No section should disappear merely because it belongs inside a Part.**  
  
  
  
**Sharing**  
  
**Current share/export infrastructure already exists.**  
  
**Current implementation uses:**  
  
UIActivityViewController  
  
**Keep this.**  
  
**Improve the shared file so iOS can expose appropriate destinations such as:**  
  
**	●	Files**  
**	●	AirDrop**  
**	●	Apple Books**  
**	●	Mail**  
**	●	Messages**  
**	●	Kindle / Send to Kindle where registered by the installed app**  
**	●	other EPUB-capable apps**  
  
**Do not implement fake or hard-coded third-party integrations when the native Share Sheet can expose registered activities.**  
  
  
  
**EPUB history**  
  
**Every successful EPUB export must remain available until the user explicitly deletes it.**  
  
**Generating a new EPUB must NOT make the previous EPUB inaccessible.**  
  
**History is immutable-artifact-oriented:**  
  
Export #1  
  
Export #2  
  
Export #3 ← current  
  
**All three remain downloadable/openable/shareable.**  
  
**Only is_current should move to the newest export.**  
  
**Deletion is explicit user action.**  
  
  
  
**Existing Code Architecture**  
  
**iOS export UI**  
  
**Primary file:**  
  
CathedralOSApp/Features/Projects/KindleExportView.swift  
  
**Current metadata draft:**  
  
private struct KindleExportMetadataDraft: Codable {  
  
    var bookTitle: String  
  
    var authorName: String  
  
    var copyrightYear: String  
  
    var copyrightHolder: String  
  
    var language: String  
  
    var dedication: String  
  
    var bookDescription: String  
  
    var aboutAuthor: String  
  
    var isbn: String  
  
    var publisherName: String  
  
    var seriesName: String  
  
    var seriesNumber: String  
  
    var coverChoice: CoverChoice  
  
    var coverUploadPath: String?  
  
}  
  
**Existing optional UI currently includes:**  
  
Dedication  
  
Book description  
  
About author  
  
ISBN  
  
Publisher name  
  
Series name  
  
Series number  
  
**Add only:**  
  
Acknowledgements  
  
**The screen already has:**  
  
previousExports: [KindleExportHistoryItem]  
  
**and UI titled:**  
  
Previous EPUBs  
  
**It already supports:**  
  
**	●	opening historical EPUB**  
**	●	sharing historical EPUB**  
**	●	regenerating from a historical export**  
  
**Do not create a second export-history UI.**  
  
  
  
**iOS export service**  
  
**Primary file:**  
  
CathedralOSApp/Services/KindleExportService.swift  
  
**Existing request:**  
  
struct KindleExportRequest: Codable {  
  
    let project_id: String  
  
    let book_title: String  
  
    let author_name: String  
  
    let copyright_year: Int?  
  
    let copyright_holder: String?  
  
    let language: String?  
  
    let dedication: String?  
  
    let book_description: String?  
  
    let about_author: String?  
  
    let isbn: String?  
  
    let publisher_name: String?  
  
    let series_name: String?  
  
    let series_number: Int?  
  
    let cover_image_url: String?  
  
    let cover_image_ai_generate: Bool?  
  
}  
  
**Extend this rather than replacing it.**  
  
**Current history item:**  
  
struct KindleExportHistoryItem: Codable, Identifiable {  
  
    let id: String  
  
    let book_title: String  
  
    let author_name: String  
  
    let is_current: Bool  
  
    let is_active: Bool  
  
    let created_at: String  
  
}  
  
**Reuse this model where practical.**  
  
  
  
**Downloader**  
  
**Primary file:**  
  
CathedralOSApp/Services/KindleExportDownloader.swift  
  
**Current cache path is:**  
  
private func cacheURL(for exportMetadataId: String) -> URL {  
  
    cacheDirectory.appendingPathComponent("\(exportMetadataId).epub")  
  
}  
  
**This is fine as the internal immutable cache key.**  
  
**Do NOT replace immutable cache identity with title-based identity.**  
  
**Instead distinguish:**  
  
internal cache filename  
  
    export_metadata UUID.epub  
  
user-facing/share filename  
  
    Book Title.epub  
  
**This prevents collisions while providing correct publishing UX.**  
  
  
  
**Share sheet**  
  
**Primary file:**  
  
CathedralOSApp/Features/Projects/KindleExportShareSheet.swift  
  
**Current implementation:**  
  
UIActivityViewController(  
  
    activityItems: items,  
  
    applicationActivities: nil  
  
)  
  
**Keep native sharing.**  
  
**Improve the activity item / temporary share URL so the file:**  
  
**	●	has a .epub extension**  
**	●	has an EPUB-compatible content type / UTI where supported**  
**	●	carries the correct human-facing filename**  
**	●	uses the book title**  
  
**Do not replace UIActivityViewController with custom destination buttons unless strictly necessary.**  
  
  
  
**EPUB backend**  
  
**Primary function:**  
  
supabase/functions/export-epub/  
  
**Important files:**  
  
index.ts  
  
_metadata.ts  
  
_epub_writer.ts  
  
_section_walker.ts  
  
_paragraphs.ts  
  
_repair.ts  
  
_validator_client.ts  
  
**Current writer is custom EPUB 3 and already produces:**  
  
mimetype  
  
META-INF/container.xml  
  
OEBPS/content.opf  
  
OEBPS/nav.xhtml  
  
OEBPS/toc.ncx  
  
OEBPS/styles.css  
  
OEBPS/cover-image.jpg  
  
OEBPS/cover.xhtml  
  
OEBPS/text/section-N.xhtml  
  
**Preserve this architecture.**  
  
**Do not introduce another EPUB library unless a proven blocker exists.**  
  
  
  
**EPUB validation**  
  
**Current export flow already performs:**  
  
write EPUB  
  
→ upload temp  
  
→ EPUBCheck  
  
→ bounded repair  
  
→ EPUBCheck again  
  
→ final private storage  
  
**Preserve this.**  
  
**No successful export should bypass EPUBCheck.**  
  
  
  
**PR 1 — Acknowledgements + Metadata Completion**  
  
**Goal**  
  
**Add Acknowledgements to the existing Optional metadata flow and render it as proper EPUB back matter.**  
  
**No other metadata redesign.**  
  
  
  
**iOS**  
  
**Update:**  
  
CathedralOSApp/Features/Projects/KindleExportView.swift  
  
**Add:**  
  
@State private var acknowledgements: String = ""  
  
**Add to:**  
  
KindleExportMetadataDraft  
  
**Example:**  
  
var acknowledgements: String  
  
**Update:**  
  
saveMetadata()  
  
loadSavedMetadata()  
  
performKickoffExport()  
  
**Add Optional pane field similar to About Author / Book Description.**  
  
**Use multiline entry.**  
  
**Do not create another screen.**  
  
**Maintain backward compatibility for old saved UserDefaults metadata drafts.**  
  
**Because adding a non-optional Codable property may break decoding previously saved drafts, use either:**  
  
var acknowledgements: String?  
  
**in the Codable draft**  
  
**or provide backward-compatible decoding/default behavior.**  
  
**Existing users’ saved export settings must continue loading.**  
  
  
  
**Request DTO**  
  
**Update:**  
  
CathedralOSApp/Services/KindleExportService.swift  
  
**Add:**  
  
let acknowledgements: String?  
  
**to:**  
  
KindleExportRequest  
  
  
  
**Backend metadata**  
  
**Update:**  
  
supabase/functions/export-epub/_metadata.ts  
  
**Add:**  
  
acknowledgements?: string;  
  
**to:**  
  
ExportMetadata  
  
ExportRequest  
  
**and normalize it in:**  
  
assembleMetadata()  
  
  
  
**Database**  
  
**Current table:**  
  
public.export_metadata  
  
**needs:**  
  
acknowledgements text  
  
**Create a forward migration.**  
  
**Do not modify old committed migrations.**  
  
**Update:**  
  
replace_export_metadata(...)  
  
**through a forward migration.**  
  
**Do not drop/recreate production history.**  
  
**Existing rows receive NULL.**  
  
  
  
**EPUB output**  
  
**Acknowledgements is actual back matter, not OPF subject metadata.**  
  
**If non-empty, create something such as:**  
  
OEBPS/text/acknowledgements.xhtml  
  
**Render after the final story section.**  
  
**Minimal markup:**  
  
<h1>Acknowledgements</h1>  
  
<p>...</p>  
  
**Split multiline content appropriately using existing paragraph logic where suitable.**  
  
**Add to:**  
  
**	●	manifest**  
**	●	spine**  
**	●	navigation if conventional**  
**	●	NCX if included in TOC**  
  
**Do not put acknowledgements before the novel.**  
  
  
  
**Tests**  
  
**Add/update tests proving:**  
  
**	●	old metadata drafts decode**  
**	●	acknowledgements survives save/load**  
**	●	request serializes acknowledgements**  
**	●	backend trims it**  
**	●	DB RPC accepts it**  
**	●	EPUB includes acknowledgements only when non-empty**  
**	●	acknowledgements appears after story content**  
**	●	EPUBCheck remains green**  
  
  
  
**PR 2 — True EPUB History + Correct Filename + Delete**  
  
**Goal**  
  
**Make the existing Previous EPUBs feature actually preserve all exports.**  
  
**This fixes a current architectural mismatch.**  
  
  
  
**Existing bug**  
  
**Current migration/function:**  
  
supabase/migrations/20260826180000_fix_export_metadata_replacement.sql  
  
**contains logic equivalent to:**  
  
update public.export_metadata  
  
set is_current = false,  
  
    is_active = false  
  
where project_id = p_project_id  
  
  and (is_current = true or is_active = true);  
  
**Then inserts the new row with:**  
  
is_current = true,  
  
is_active = true  
  
**This means creating Export B deactivates Export A.**  
  
**But:**  
  
export-epub-list  
  
**currently filters:**  
  
.eq("is_active", true)  
  
**and:**  
  
export-epub-download  
  
**rejects:**  
  
is_active === false  
  
**Therefore the current UI titled Previous EPUBs cannot function as real persistent history.**  
  
**Fix the lifecycle model.**  
  
  
  
**New semantics**  
  
**Use:**  
  
is_current = newest/preferred export  
  
is_active = artifact exists and has not been user-deleted  
  
**Creating a new export:**  
  
old export:  
  
    is_current = false  
  
    is_active = true  
  
new export:  
  
    is_current = true  
  
    is_active = true  
  
**Do NOT mark historical exports inactive merely because they are old.**  
  
  
  
**Database migration**  
  
**Create a forward migration.**  
  
**Do not edit old committed migrations.**  
  
**Modify/replace:**  
  
replace_export_metadata(...)  
  
**so it only demotes:**  
  
is_current = false  
  
**on prior current row.**  
  
**Do not set prior is_active=false.**  
  
  
  
**Unique indexes**  
  
**Current schema contains both:**  
  
unique current export per project  
  
unique active export per project  
  
**The is_current partial unique index is still correct.**  
  
**The unique is_active index conflicts with persistent history.**  
  
**Remove only the uniqueness requirement that allows only one active export.**  
  
**An ordinary lookup index may remain/add if useful.**  
  
  
  
**Existing historical rows**  
  
**Audit whether prior exports that still have valid:**  
  
epub_storage_path  
  
**were previously demoted to inactive.**  
  
**Provide a safe forward migration/repair path to reactivate historical exports where:**  
  
**	●	artifact still exists or can safely be considered extant**  
**	●	owner/project associations remain valid**  
  
**Do not blindly activate broken rows with no storage artifact.**  
  
**If storage existence cannot be proven safely inside migration, leave data repair as a separately reported operational step rather than inventing truth.**  
  
  
  
**List endpoint**  
  
**Current:**  
  
supabase/functions/export-epub-list/index.ts  
  
**queries:**  
  
.eq("is_active", true)  
  
**That becomes correct once all undeleted history stays active.**  
  
**Return newest first as current implementation already does.**  
  
**Consider adding fields useful for history UX if already easily available:**  
  
version_id  
  
created_at  
  
is_current  
  
**No requirement for complex version names.**  
  
  
  
**Explicit delete**  
  
**There is currently no explicit EPUB-history delete UX.**  
  
**Add it.**  
  
**Prefer a dedicated authenticated backend endpoint, e.g.:**  
  
export-epub-delete  
  
**or a clear action inside an existing export-management function.**  
  
**Required request:**  
  
{  
  
  "export_metadata_id": "..."  
  
}  
  
**Security:**  
  
**	1.	authenticate user JWT**  
**	2.	load export row**  
**	3.	require:**  
  
exported_by_user_id == authenticated user  
  
**	4.	delete the Storage object**  
**	5.	remove or deactivate metadata row**  
  
**Preferred behavior:**  
  
**	●	delete storage artifact**  
**	●	delete metadata row**  
  
**because user explicitly requested deletion.**  
  
**If maintaining tombstone semantics is important elsewhere, use an inactive tombstone only if proven necessary.**  
  
**Do not silently delete historical artifacts on regeneration.**  
  
  
  
**Deleting current export**  
  
**If current export is deleted:**  
  
**Promote the newest remaining active export for that project:**  
  
is_current = true  
  
**Do this atomically if possible.**  
  
**If no exports remain:**  
  
no current export  
  
**is valid.**  
  
  
  
**No automatic deletion**  
  
**Audit any GC/cron behavior.**  
  
**The original schema contains comments describing:**  
  
30-day GC for old non-current, non-active exports  
  
**Under the new semantics, user-preserved historical exports remain:**  
  
is_active = true  
  
**so they must not be garbage-collected.**  
  
**Confirm no currently deployed code/cron deletes active historical artifacts.**  
  
**Report exact findings.**  
  
  
  
**User-facing filename**  
  
**Current backend storage path is:**  
  
exports/${localProjectId}/${jobId}.epub  
  
**Keep immutable backend filenames.**  
  
**Current local cache filename is:**  
  
<exportMetadataId>.epub  
  
**Keep immutable cache filenames.**  
  
**The user-facing/share artifact must instead be:**  
  
<Book Title>.epub  
  
**Example:**  
  
Brody in Hawkins.epub  
  
**NOT:**  
  
metadata-uuid.epub  
  
job-uuid.epub  
  
Brody in Hawkins v3.epub  
  
**unless v3 is literally part of entered book title.**  
  
  
  
**Filename sanitization**  
  
**Implement a deterministic sanitizer.**  
  
**Preserve normal Unicode book titles where filesystem supports them.**  
  
**Remove/replace characters invalid or unsafe in filenames.**  
  
**Examples to handle:**  
  
/  
  
:  
  
NUL/control characters  
  
leading/trailing whitespace  
  
**Fallback:**  
  
Untitled.epub  
  
**only if sanitized title becomes empty.**  
  
**Do not mutate the EPUB’s internal dc:title merely for filesystem safety.**  
  
  
  
**Sharing implementation**  
  
**KindleExportDownloader should continue caching immutable copies by metadata ID.**  
  
**For Share:**  
  
**create or copy to a temporary/share URL:**  
  
<sanitized book title>.epub  
  
**Then feed that URL to:**  
  
KindleExportShareSheet  
  
**Prefer proper EPUB content-type metadata / item provider representation where feasible.**  
  
**Use standard EPUB identifier:**  
  
org.idpf.epub-container  
  
**or the modern UniformTypeIdentifiers equivalent if available on the project’s deployment target.**  
  
**Do not hard-code Apple Books or Kindle activities.**  
  
**Let iOS expose registered destinations.**  
  
  
  
**History UI**  
  
**Reuse:**  
  
Previous EPUBs  
  
**in:**  
  
KindleExportView  
  
**Keep:**  
  
**	●	Open**  
**	●	Share**  
**	●	Regenerate**  
  
**Add:**  
  
**	●	Delete**  
  
**Deletion must require confirmation:**  
  
Delete EPUB?  
  
This permanently removes this exported file. Your story project and generated sections are not affected.  
  
**Do not use swipe-delete without confirmation for irreversible server deletion.**  
  
**After delete:**  
  
refresh Previous EPUBs  
  
  
  
**Tests**  
  
**Cover:**  
  
**	●	creating export B leaves A active**  
**	●	B becomes current**  
**	●	A becomes non-current**  
**	●	both list**  
**	●	both download**  
**	●	old export share works**  
**	●	unauthorized deletion fails**  
**	●	owner deletion succeeds**  
**	●	storage artifact removed**  
**	●	deleting current promotes newest remaining export**  
**	●	deleting last export leaves none current**  
**	●	filename sanitizer tests**  
**	●	share URL uses title filename**  
**	●	immutable cache still uses metadata ID**  
**	●	history survives regeneration**  
**	●	no automatic history deletion**  
  
  
  
**PR 3 — Kindle-Ready EPUB Rendering + Landmarks**  
  
**Goal**  
  
**Improve the existing custom EPUB writer for normal reflowable Kindle-style fiction.**  
  
**Do not change story content.**  
  
**Do not merge sections.**  
  
**Do not introduce fixed layout.**  
  
  
  
**Current writer**  
  
**File:**  
  
supabase/functions/export-epub/_epub_writer.ts  
  
**Current CSS includes:**  
  
body {  
  
  font-family: Georgia, "Times New Roman", serif;  
  
  font-size: 1em;  
  
  line-height: 1.3em;  
  
  text-align: justify;  
  
  margin: 1em 0.5em;  
  
}  
  
**and:**  
  
p {  
  
  margin: 0;  
  
  text-indent: 1.5em;  
  
}  
  
p + p {  
  
  margin-top: 1em;  
  
  text-indent: 0;  
  
}  
  
**This produces a hybrid style where the first paragraph is indented but later paragraphs get vertical spacing and no indent.**  
  
**Change to a more conventional reflowable fiction presentation.**  
  
  
  
**Desired body typography**  
  
**Avoid forcing a specific reading font.**  
  
**Prefer:**  
  
body {  
  
  margin: 0;  
  
  padding: 0;  
  
}  
  
**or similarly minimal device-friendly body styling.**  
  
**Normal prose:**  
  
p {  
  
  margin-top: 0;  
  
  margin-bottom: 0;  
  
  text-indent: 1.2em;  
  
}  
  
**First paragraph after a major/minor section heading:**  
  
h1 + p,  
  
h2 + p {  
  
  text-indent: 0;  
  
}  
  
**Do not add a full blank line between every normal paragraph.**  
  
**Do not require:**  
  
Georgia  
  
Times New Roman  
  
**Reader devices should remain free to apply user font preferences.**  
  
**Keep typography relative:**  
  
em / rem / %  
  
**Avoid fixed pixel sizing for body text.**  
  
  
  
**Alignment**  
  
**Do not aggressively force justification if Kindle/device preferences can control presentation.**  
  
**Prefer natural/start alignment for prose unless current KDP compatibility testing demonstrates a strong reason otherwise.**  
  
  
  
**Headings**  
  
**Minimal.**  
  
**Part:**  
  
<h1 class="part-title">Part I</h1>  
  
**or equivalent divider semantics.**  
  
**Section:**  
  
<h1 class="section-title">Bike Tires on the Blacktop</h1>  
  
**For child outline sections within one XHTML document:**  
  
<h2 id="...">...</h2>  
  
**Do not decorate heavily.**  
  
  
  
**Front/back matter**  
  
**Preserve all existing implemented front/back matter behavior.**  
  
**This PR must not re-create fields already handled elsewhere.**  
  
**Acknowledgements comes from PR 1.**  
  
  
  
**Landmarks**  
  
**Current nav.xhtml only has:**  
  
<nav epub:type="toc">  
  
**Add a conventional EPUB landmarks nav.**  
  
**Conceptually:**  
  
<nav epub:type="landmarks" hidden="">  
  
  <h2>Landmarks</h2>  
  
  <ol>  
  
    <li>  
  
      <a epub:type="cover" href="cover.xhtml">Cover</a>  
  
    </li>  
  
    <li>  
  
      <a epub:type="toc" href="nav.xhtml">Table of Contents</a>  
  
    </li>  
  
    <li>  
  
      <a epub:type="bodymatter" href="text/...">Start of Book</a>  
  
    </li>  
  
  </ol>  
  
</nav>  
  
**Only include Cover if one exists.**  
  
**If title/front matter pages currently exist in actual code at implementation time, use correct semantics for them.**  
  
**Do not create fake landmarks pointing to nonexistent documents.**  
  
**The first story section should be the logical body-matter entry.**  
  
  
  
**Legacy compatibility**  
  
**Current EPUB already emits:**  
  
toc.ncx  
  
**Preserve it.**  
  
**Update depth/nesting appropriately after Part hierarchy ships in PR 4.**  
  
  
  
**HTML TOC**  
  
**If current book has only nav.xhtml but no reader-facing TOC document, evaluate adding a conventional navigable TOC page.**  
  
**Avoid unnecessary duplication if Kindle navigation is already clean.**  
  
**If added:**  
  
toc.xhtml  
  
**should be:**  
  
**	●	in manifest**  
**	●	optionally in spine in conventional location**  
**	●	included as TOC landmark**  
**	●	nested consistently with nav.xhtml**  
  
**Do not create inconsistent navigation structures.**  
  
  
  
**EPUBCheck**  
  
**Every produced variant must still pass the existing EPUBCheck pipeline.**  
  
**Add tests inspecting generated ZIP contents directly.**  
  
  
  
**Tests**  
  
**Validate:**  
  
**	●	no forced Georgia/Times body family**  
**	●	paragraph first-line indentation**  
**	●	no default blank line between every prose paragraph**  
**	●	first paragraph after headings not indented**  
**	●	cover landmark conditional**  
**	●	toc landmark**  
**	●	bodymatter landmark**  
**	●	all landmark hrefs exist**  
**	●	nav remains valid XHTML**  
**	●	NCX remains valid**  
**	●	EPUBCheck green with:**  
**	●	cover**  
**	●	no cover**  
**	●	acknowledgements**  
**	●	no acknowledgements**  
  
  
  
**PR 4 — Story Arc → Parts + Nested Navigation**  
  
**Goal**  
  
**Use CathedralOS’s existing Story Arc structure as the macro-level book hierarchy.**  
  
**No LLM call.**  
  
**No story rewrite.**  
  
**No section deletion.**  
  
  
  
**Existing source data**  
  
**Story Arc already exists in:**  
  
StoryArc  
  
StoryArcBeat  
  
StoryArcTemplate  
  
**Models:**  
  
CathedralOSApp/Models/StoryArc.swift  
  
CathedralOSApp/Models/StoryArcBeat.swift  
  
CathedralOSApp/Models/StoryArcTemplate.swift  
  
**Outline sections already contain:**  
  
storyArcBeatID: UUID?  
  
**Project snapshots already serialize:**  
  
storyArcs  
  
    beats  
  
        id  
  
        position  
  
        role  
  
        label  
  
        details  
  
outlines  
  
    storyArcID  
  
    sections  
  
        storyArcBeatID  
  
**Therefore export can derive Parts from the existing snapshot.**  
  
**Do NOT query another LLM.**  
  
**Do NOT create another story-planning system.**  
  
  
  
**Current walker limitation**  
  
**Current:**  
  
supabase/functions/export-epub/_section_walker.ts  
  
**exports a Section approximately like:**  
  
export interface Section {  
  
  id: string;  
  
  title: string;  
  
  container: Container;  
  
  pov: string | null;  
  
  body: string;  
  
  position: number;  
  
  parent_id: string | null;  
  
}  
  
**Add:**  
  
story_arc_beat_id: string | null;  
  
**derived from snapshot:**  
  
storyArcBeatID  
  
**The current walker already loads snapshot_json, so derive Story Arc relationships there rather than introducing redundant DB lookups unless necessary.**  
  
  
  
**Proposed export model**  
  
**Extend:**  
  
ProjectOutline  
  
**with something like:**  
  
export interface BookPart {  
  
  id: string;  
  
  position: number;  
  
  defaultTitle: string;  
  
  chapterIds: string[];  
  
}  
  
export interface ProjectOutline {  
  
  id: string;  
  
  title: string;  
  
  chapters: Chapter[];  
  
  parts: BookPart[];  
  
  storyBrief?: StoryBrief;  
  
}  
  
**Exact type names may vary.**  
  
**The important invariant:**  
  
Parts group existing reading units.  
  
Parts do not replace or merge them.  
  
  
  
**Part derivation**  
  
**Parts are deterministic.**  
  
**Use the selected Story Arc template/beat roles where available.**  
  
**Do not make each arc beat a Part.**  
  
  
  
**Three-Act**  
  
**3 Parts.**  
  
**Suggested semantic boundary:**  
  
Part I  
  
setup  
  
inciting_incident  
  
first_plot_point  
  
Part II  
  
rising_action  
  
midpoint  
  
crisis  
  
Part III  
  
climax  
  
resolution  
  
**Boundary handling should preserve section order.**  
  
  
  
**Hero’s Journey**  
  
**3 Parts.**  
  
**Suggested grouping:**  
  
Part I  
  
ordinary_world  
  
call_to_adventure  
  
refusal_of_call  
  
meeting_mentor  
  
crossing_threshold  
  
Part II  
  
tests_allies_enemies  
  
approach_inmost_cave  
  
ordeal  
  
reward  
  
Part III  
  
road_back  
  
resurrection  
  
return_with_elixir  
  
  
  
**Mystery**  
  
**3 Parts.**  
  
**Suggested grouping:**  
  
Part I  
  
the_crime  
  
investigation_begins  
  
first_suspect  
  
Part II  
  
rising_tension  
  
key_revelation  
  
false_solution  
  
real_clue  
  
Part III  
  
confrontation  
  
resolution  
  
  
  
**Save the Cat**  
  
**3 Parts.**  
  
Part I  
  
opening_image  
  
theme_stated  
  
setup  
  
catalyst  
  
debate  
  
Part II  
  
break_into_two  
  
b_story  
  
fun_and_games  
  
midpoint  
  
bad_guys_close_in  
  
all_is_lost  
  
dark_night_of_the_soul  
  
Part III  
  
break_into_three  
  
finale  
  
final_image  
  
  
  
**Story Circle**  
  
**3 Parts.**  
  
Part I  
  
you  
  
need  
  
go  
  
Part II  
  
search  
  
find  
  
take  
  
Part III  
  
return  
  
change  
  
  
  
**Freytag’s Pyramid**  
  
**Preserve its explicit five-part structure:**  
  
Part I   Exposition  
  
Part II  Rising Action  
  
Part III Climax  
  
Part IV  Falling Action  
  
Part V   Denouement  
  
  
  
**Kishōtenketsu**  
  
**Preserve its natural four-part structure:**  
  
Part I   Ki  
  
Part II  Shō  
  
Part III Ten  
  
Part IV  Ketsu  
  
  
  
**Unknown/custom arc**  
  
**Do not fail export.**  
  
**Derive contiguous groupings from ordered StoryArc beats.**  
  
**Prefer approximately 3 Parts for a normal multi-beat arc.**  
  
**Requirements:**  
  
**	●	deterministic**  
**	●	contiguous**  
**	●	preserve order**  
**	●	no empty Parts**  
**	●	every generated section assigned exactly once**  
  
**If the arc is too small to reasonably produce 3 groups, use fewer.**  
  
  
  
**Sections without Story Arc Beat**  
  
**Do not drop them.**  
  
**Assign by sequence to the nearest sensible Part.**  
  
**Safe deterministic strategy:**  
  
**	●	before first tagged section → first Part**  
**	●	after last tagged section → last Part**  
**	●	between tagged sections → inherit previous/containing contiguous Part**  
  
**Never create a missing-section export because a beat link is null.**  
  
  
  
**User-editable Part names**  
  
**Product owner requires:**  
  
> Allow naming of parts.  
  
**Keep this inside the existing export screen.**  
  
**Do not create an entire new project editor.**  
  
**Add a small:**  
  
Book Parts  
  
**section to:**  
  
KindleExportView  
  
**Only display when Parts can be derived.**  
  
**Example:**  
  
Book Parts  
  
Part I     [________________]  
  
Part II    [________________]  
  
Part III   [________________]  
  
**Empty custom name means use default:**  
  
Part I  
  
Part II  
  
Part III  
  
**or template-aware defaults if desired.**  
  
**User-entered value can be:**  
  
Part I — The Signal  
  
**or:**  
  
The Signal  
  
**Choose one clear UX and normalize consistently.**  
  
**Preferred:**  
  
Label: Part I  
  
TextField: Optional title  
  
**Rendered:**  
  
Part I  
  
The Signal  
  
**This avoids forcing users to type numbering.**  
  
  
  
**Persist Part names**  
  
**Use the existing per-project:**  
  
KindleExportMetadataDraft  
  
**for export presentation choices unless a better existing export-settings persistence mechanism is present.**  
  
**Example:**  
  
var partNames: [String]  
  
**or a stable beat/group keyed dictionary.**  
  
**Do not use array indexes if Part structure can change without invalidation.**  
  
**Prefer stable key such as:**  
  
part-1  
  
part-2  
  
part-3  
  
**for current deterministic export structure, or a stable grouping fingerprint if necessary.**  
  
**Backward-compatible decoding required.**  
  
  
  
**EPUB Part divider pages**  
  
**Create lightweight Part divider XHTML files.**  
  
**Example:**  
  
OEBPS/text/part-1.xhtml  
  
**Contents:**  
  
<body class="part-page">  
  
  <h1>Part I</h1>  
  
  <p class="part-name">The Signal</p>  
  
</body>  
  
**Minimal.**  
  
**No unnecessary illustration or decoration.**  
  
**Add Part pages to spine before the first section in that Part.**  
  
  
  
**Keep all existing section documents/titles**  
  
**Do NOT reduce navigation to Parts only.**  
  
**Desired TOC:**  
  
<ol>  
  
  <li>  
  
    <a href="text/part-1.xhtml">Part I — The Signal</a>  
  
    <ol>  
  
      <li>  
  
        <a href="text/section-1.xhtml">Bike Tires on the Blacktop</a>  
  
      </li>  
  
      <li>  
  
        <a href="text/section-2.xhtml">The Mercer House Argument</a>  
  
      </li>  
  
    </ol>  
  
  </li>  
  
  <li>  
  
    <a href="text/part-2.xhtml">Part II</a>  
  
    <ol>  
  
      ...  
  
    </ol>  
  
  </li>  
  
</ol>  
  
  
  
**Child OutlineSections**  
  
**Current walker supports:**  
  
top-level section  
  
    child section  
  
**and current writer renders child title as:**  
  
<h2>  
  
**but the existing nav only points to top-level chapter files.**  
  
**Product requirement is:**  
  
> every title  
  
**Therefore every generated child section title must also receive navigation.**  
  
**Do NOT necessarily split every child into its own XHTML document.**  
  
**It is acceptable to keep current document grouping and use fragment anchors.**  
  
**Example:**  
  
<h2 id="section-uuid">  
  
  Child Section Title  
  
</h2>  
  
**TOC:**  
  
<a href="text/section-3.xhtml#section-uuid">  
  
  Child Section Title  
  
</a>  
  
**This preserves existing reading flow while making every title navigable.**  
  
  
  
**NCX nested navigation**  
  
**Update:**  
  
toc.ncx  
  
**to reflect hierarchy.**  
  
**Example:**  
  
<navPoint>  
  
  <navLabel>  
  
    <text>Part I</text>  
  
  </navLabel>  
  
  <content src="text/part-1.xhtml"/>  
  
  <navPoint>  
  
    <navLabel>  
  
      <text>Bike Tires on the Blacktop</text>  
  
    </navLabel>  
  
    <content src="text/section-1.xhtml"/>  
  
  </navPoint>  
  
</navPoint>  
  
**Correct:**  
  
<meta name="dtb:depth" ...>  
  
**for nested navigation.**  
  
  
  
**EPUB nav**  
  
**nav.xhtml must contain nested:**  
  
Part  
  
    section  
  
    section  
  
Part  
  
    section  
  
**Every title appears once in the logical TOC.**  
  
**No duplicate flat section list underneath the nested list.**  
  
  
  
**Content preview in iOS**  
  
**Current UI reports:**  
  
Chapters  
  
Sections  
  
Preview  
  
**Update terminology only if required to avoid confusion.**  
  
**Potential desired view:**  
  
Parts: 3  
  
Sections: 58  
  
**or:**  
  
Parts: 3  
  
Reading sections: 58  
  
**Do not call 58 things “chapters” if the EPUB is now intentionally presenting:**  
  
Part → titled sections  
  
**Keep UI concise.**  
  
  
  
**PR 4 Tests**  
  
**Create deterministic fixtures for each built-in Story Arc.**  
  
**Test:**  
  
**	●	Three Act → 3 Parts**  
**	●	Hero’s Journey → 3**  
**	●	Mystery → 3**  
**	●	Save the Cat → 3**  
**	●	Story Circle → 3**  
**	●	Freytag → 5**  
**	●	Kishōtenketsu → 4**  
**	●	custom arc fallback deterministic**  
**	●	untagged beginning section retained**  
**	●	untagged middle section retained**  
**	●	untagged ending section retained**  
**	●	every generated section belongs to exactly one Part**  
**	●	ordering unchanged**  
**	●	Part custom names survive save/load**  
**	●	nested nav contains all Parts**  
**	●	nested nav contains all top-level titles**  
**	●	child section title links use valid fragment anchors**  
**	●	NCX hierarchy matches**  
**	●	all fragment targets exist**  
**	●	Part divider pages are in spine**  
**	●	no empty Parts**  
**	●	no prose omitted**  
**	●	EPUBCheck passes**  
  
  
  
**Shared Invariants Across All Four PRs**  
  
**These are non-negotiable.**  
  
**Do not touch generation**  
  
**Do not modify:**  
  
outline-from-recipe  
  
generate-story  
  
run-outline  
  
scene-memory extraction  
  
repetition restraint  
  
model selection  
  
generation prompts  
  
length targets  
  
billing  
  
**unless a direct compile dependency is discovered.**  
  
**If such dependency appears, stop and report before widening scope.**  
  
  
  
**No new LLM calls**  
  
**Parts are deterministic.**  
  
**Acknowledgements are user-entered.**  
  
**EPUB formatting is deterministic.**  
  
**Sharing/history are deterministic.**  
  
**Zero new generation credit cost.**  
  
  
  
**Preserve source manuscript**  
  
**EPUB work must not mutate:**  
  
GenerationOutput  
  
OutlineSection  
  
scene memory  
  
story arc  
  
project content  
  
**Export is a rendering/publishing layer.**  
  
  
  
**Historical EPUBs are immutable**  
  
**Once Export #1 is produced, later export operations must not overwrite its bytes.**  
  
**Use distinct storage paths/metadata IDs.**  
  
**Regeneration creates a new export.**  
  
  
  
**Security**  
  
**All history/download/delete operations remain user-owned.**  
  
**Never expose service role to iOS.**  
  
**Require current authenticated user and verify:**  
  
exported_by_user_id == auth.uid()  
  
**before:**  
  
**	●	download**  
**	●	deletion**  
**	●	mutation of history metadata**  
  
  
  
**EPUBCheck**  
  
**Successful production export means EPUBCheck succeeded under existing policy.**  
  
**Do not weaken validation to make new navigation pass.**  
  
**Fix invalid XHTML/OPF/nav output instead.**  
  
  
  
**Suggested PR Sequence**  
  
**Implement as four PRs, not one monster PR.**  
  
**PR 1**  
  
**Suggested title:**  
  
feat(epub): add acknowledgements back matter  
  
**Expected small scope:**  
  
**	●	iOS field/persistence**  
**	●	request metadata**  
**	●	DB forward migration**  
**	●	writer back matter**  
**	●	tests**  
  
  
  
**PR 2**  
  
**Suggested title:**  
  
feat(epub): preserve export history and improve sharing  
  
**Scope:**  
  
**	●	active/current lifecycle**  
**	●	DB forward migration**  
**	●	list/download behavior**  
**	●	delete endpoint**  
**	●	history delete UI**  
**	●	title filenames**  
**	●	EPUB share content type**  
**	●	tests**  
  
**This PR fixes an existing behavior mismatch and should be treated carefully.**  
  
  
  
**PR 3**  
  
**Suggested title:**  
  
refactor(epub): make reflowable output Kindle-ready  
  
**Scope:**  
  
**	●	fiction CSS**  
**	●	landmarks**  
**	●	TOC/navigation baseline**  
**	●	OPF/spine cleanup if required**  
**	●	EPUBCheck tests**  
  
**Do not add Parts yet.**  
  
  
  
**PR 4**  
  
**Suggested title:**  
  
feat(epub): organize books into Story Arc parts  
  
**Scope:**  
  
**	●	Story Arc grouping**  
**	●	custom Part naming**  
**	●	Part divider pages**  
**	●	nested navigation**  
**	●	every section title navigable**  
**	●	child anchors**  
**	●	nested NCX**  
**	●	tests**  
  
  
  
**Validation Required for Every PR**  
  
**Before declaring a PR complete:**  
  
**	1.	Run relevant Swift unit tests.**  
**	2.	Run backend Deno tests.**  
**	3.	Run production source type checks.**  
**	4.	Run EPUB export tests.**  
**	5.	Run EPUBCheck fixture validation where applicable.**  
**	6.	Run iOS Build CI.**  
**	7.	Inspect PR diff for unrelated files.**  
**	8.	Confirm branch is based on latest main.**  
**	9.	Do not deploy.**  
**	10.	Do not merge.**  
  
  
  
**Final Bundle Acceptance Test**  
  
**After all four PRs are merged, use a realistic generated novel with:**  
  
**	●	50+ sections**  
**	●	selected Story Arc**  
**	●	generated cover**  
**	●	custom book title**  
**	●	author**  
**	●	dedication**  
**	●	acknowledgements**  
**	●	About Author**  
**	●	description**  
**	●	at least one child OutlineSection if available**  
  
**Export twice.**  
  
**Expected result:**  
  
Previous EPUBs  
  
Book Title  
  
Export 2       Current  
  
[Open] [Share] [Regenerate] [Delete]  
  
Book Title  
  
Export 1  
  
[Open] [Share] [Regenerate] [Delete]  
  
**Both must open.**  
  
**Both must share.**  
  
**Both must remain downloadable.**  
  
**The shared filename must be:**  
  
Book Title.epub  
  
**The EPUB must display approximately:**  
  
Cover  
  
[existing front matter]  
  
Part I  
  
[optional custom Part name]  
  
Section Title  
  
prose...  
  
Section Title  
  
prose...  
  
Part II  
  
...  
  
Acknowledgements  
  
...  
  
[existing back matter]  
  
**Navigation should display:**  
  
Part I  
  
    Section Title  
  
    Section Title  
  
    Section Title  
  
Part II  
  
    Section Title  
  
    Section Title  
  
Part III  
  
    Section Title  
  
    Section Title  
  
Acknowledgements  
  
**Every listed link must work.**  
  
**Reader font controls must not be defeated by hard-coded body fonts.**  
  
**Normal fiction paragraphs should not have blank-line web styling between every paragraph.**  
  
**The book must pass EPUBCheck.**  
  
**Deleting Export #1 must:**  
  
delete Export #1 artifact  
  
retain Export #2  
  
leave Export #2 current  
  
leave project/manuscript untouched  
  
**Deleting current Export #2 while Export #1 still exists must promote the newest remaining export to current.**  
  
  
  
**Final Agent Report**  
  
**For every PR return:**  
  
**	●	PR number**  
**	●	head SHA**  
**	●	exact files changed**  
**	●	migrations added**  
**	●	existing architecture reused**  
**	●	behavior changed**  
**	●	behavior deliberately unchanged**  
**	●	tests added/updated**  
**	●	exact test results**  
**	●	Deno CI result**  
**	●	iOS Build result**  
**	●	EPUBCheck result**  
**	●	known limitations**  
**	●	any production migration/deployment steps still required**  
**	●	confirmation no deployment occurred**  
**	●	confirmation no merge occurred**  
  
**At the end of the four-PR bundle, provide a short architecture summary showing:**  
  
StoryProject  
  
   ↓  
  
Project snapshot  
  
   ↓  
  
Story Arc + OutlineSections + GenerationOutputs  
  
   ↓  
  
EPUB section walker  
  
   ↓  
  
deterministic Parts  
  
   ↓  
  
custom EPUB writer  
  
   ↓  
  
EPUBCheck  
  
   ↓  
  
immutable export artifact  
  
   ↓  
  
Export History  
  
   ↓  
  
Open / native iOS Share Sheet / Delete  
  
**Do not introduce additional systems when the current CathedralOS implementation already provides the required capability.**  
  
**The purpose of this bundle is refinement:**  
  
## turn CathedralOS’s existing validated EPUB exporter into a polished, persistent, Kindle-oriented publishing and sharing workflow without touching the successful novel-generation pipeline.  
