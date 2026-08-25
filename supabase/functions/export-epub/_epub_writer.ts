// =============================================================================
// _epub_writer.ts — Custom EPUB 3 generation (no library)
//
// Produces a byte array conforming to EPUB 3.3 spec:
//   mimetype (uncompressed)
//   META-INF/container.xml
//   OEBPS/content.opf (package document with spine + manifest)
//   OEBPS/nav.xhtml (navigation document)
//   OEBPS/toc.ncx (legacy NCX for backwards compat)
//   OEBPS/styles.css (typography: serif, ~1.3em line-height, justified)
//   OEBPS/text/*.xhtml (per-section content docs)
//   OEBPS/cover-image.{jpg|png} (if cover provided)
//
// Typography (per spec):
//   - Kindle-book look: serif font, ~1.3em line-height, justified text
//   - Section separator: blank line + title + blank line
//   - Container + POV: NOT visible in body
//
// Chapter grouping:
//   - Chapter roots (parent_id IS NULL, container="chapter") → <h1>
//   - Child sections flow as continuous prose (no separate <h1>)
//
// =============================================================================

import type { ExportMetadata } from "./_metadata.ts";
import type { ProjectOutline, Section, Chapter } from "./_section_walker.ts";

export async function writeEpub(
  _metadata: ExportMetadata,
  _outline: ProjectOutline,
  _coverBuffer: Uint8Array | null,
): Promise<Uint8Array> {
  // TODO: PR-4100-A follow-up
  // This is the biggest piece. Implementation outline:
  //   1. Build EPUB zip structure (use Deno's native Zip + tarball helpers,
  //      or a minimal ZIP encoder since we can't add deps easily)
  //   2. mimetype file (uncompressed, first entry, "application/epub+zip")
  //   3. META-INF/container.xml pointing to OEBPS/content.opf
  //   4. OEBPS/content.opf:
  //      - metadata block (title, creator, language, identifier, etc.)
  //      - manifest (every file referenced in spine + cover + nav)
  //      - spine (ordered list of content docs)
  //      - For chapter roots: <itemref idref=...> as <h1>
  //      - For child sections: continuous <itemref idref=...> flow
  //   5. OEBPS/nav.xhtml (EPUB 3 navigation, required)
  //   6. OEBPS/toc.ncx (legacy NCX for older readers, optional but recommended)
  //   7. OEBPS/styles.css (typography)
  //   8. OEBPS/text/section-N.xhtml per section
  //   9. OEBPS/cover-image.{jpg|png} if cover provided
  //
  // Title fallback (per spec Q7): if a section has no title, use "Untitled Section N"
  // Section separator (per spec): blank line + title + blank line
  // Chapter title (per spec Q3): pull from chapter root OutlineSection.title,
  //   fall back to "Chapter N"
  throw new Error("_epub_writer.writeEpub: not yet implemented");
}
