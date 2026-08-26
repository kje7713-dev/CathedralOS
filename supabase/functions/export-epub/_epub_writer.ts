// =============================================================================
// _epub_writer.ts — Custom EPUB 3.3 generation (no external EPUB library)
//
// Produces a ZIP archive conforming to EPUB 3.3 spec:
//   mimetype (uncompressed, MUST be first entry)
//   META-INF/container.xml
//   OEBPS/content.opf (package document: metadata + manifest + spine)
//   OEBPS/nav.xhtml (navigation, EPUB 3 required)
//   OEBPS/toc.ncx (legacy NCX for backwards compat)
//   OEBPS/styles.css (typography: serif, ~1.3em line-height, justified)
//   OEBPS/cover-image.jpg (if cover provided)
//   OEBPS/text/section-N.xhtml (per chapter)
//
// Spec compliance (per Kindle export spec @ e91e391):
//   - Container + POV: NOT visible in body
//   - Section separator: blank line + title + blank line (handled by <p> + <h1>)
//   - Chapter title: from chapter-root OutlineSection.title w/ "Chapter N" fallback
//   - "Untitled Section N" placeholder for sections without titles (handled by walker)
//   - Typography: serif, ~1.3em line-height, justified
// =============================================================================

// jszip's esm.sh .d.ts DOES declare a default export in Deno 1.x (CI runtime).
// If a local deno version ever loses the default export, add a
// `// @ts-expect-error` directive above this line.
import JSZip from "https://esm.sh/jszip@3.10.1";
import type { ExportMetadata } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";
import { splitParagraphs } from "./_paragraphs.ts";

export async function writeEpub(
  metadata: ExportMetadata,
  outline: ProjectOutline,
  coverBuffer: Uint8Array | null,
): Promise<Uint8Array> {
  const zip = new JSZip();
  const uuid = crypto.randomUUID();
  const now = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");

  // 1. mimetype — must be first entry, uncompressed
  zip.file("mimetype", "application/epub+zip", { compression: "STORE" });

  // 2. META-INF/container.xml
  zip.file(
    "META-INF/container.xml",
    `<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>`,
  );

  // 3. Build section content + spine/manifest entries
  // One content doc per chapter (chapter + all child sections flow continuously)
  const sectionFiles: Array<{
    id: string;
    href: string;
    title: string;
    body: string;
    chapterIdx: number;
  }> = [];

  for (let ci = 0; ci < outline.chapters.length; ci++) {
    const chapter = outline.chapters[ci];
    const chapterTitle = chapter.title || `Chapter ${ci + 1}`;
    const chapterRoot = chapter.sections[0];
    const generatedSections = chapter.sections.filter((section) =>
      section.body.trim().length > 0
    );

    // Do not publish empty outline placeholders as EPUB chapters. An outline
    // can contain many accepted sections before prose has been generated; only
    // sections with actual generated text belong in the book.
    if (generatedSections.length === 0) continue;

    // Body: generated chapter root + child sections concatenated as <p> blocks
    const bodyParts: string[] = [`<h1>${escapeXml(chapterTitle)}</h1>`];
    for (const section of generatedSections) {
      if (section !== chapterRoot && section.title) {
        bodyParts.push(`<h2>${escapeXml(section.title)}</h2>`);
      }
      for (const paragraph of splitParagraphs(section.body)) {
        bodyParts.push(`<p>${escapeXml(paragraph)}</p>`);
      }
    }

    sectionFiles.push({
      id: `section-${ci + 1}`,
      href: `text/section-${ci + 1}.xhtml`,
      title: chapterTitle,
      body: bodyParts.join("\n"),
      chapterIdx: ci,
    });
  }

  // 4. OEBPS/content.opf
  const manifestItems = [
    `<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>`,
    `<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>`,
    `<item id="css" href="styles.css" media-type="text/css"/>`,
  ];
  if (coverBuffer) {
    manifestItems.push(
      `<item id="cover-image" href="cover-image.jpg" media-type="image/jpeg" properties="cover-image"/>`,
    );
  }
  for (const sf of sectionFiles) {
    manifestItems.push(
      `<item id="${sf.id}" href="${sf.href}" media-type="application/xhtml+xml"/>`,
    );
  }

  const spineItems = sectionFiles
    .map((sf) => `<itemref idref="${sf.id}"/>`)
    .join("\n    ");

  const copyrightLine = metadata.copyright_holder
    ? `Copyright © ${metadata.copyright_year ?? new Date().getFullYear()} ${escapeXml(metadata.copyright_holder)}`
    : "";

  const metadataBlock = `<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="BookId">urn:uuid:${uuid}</dc:identifier>
    <dc:title>${escapeXml(metadata.book_title)}</dc:title>
    <dc:creator id="creator">${escapeXml(metadata.author_name)}</dc:creator>
    <dc:language>${metadata.language}</dc:language>
    ${metadata.copyright_year ? `<dc:date>${metadata.copyright_year}</dc:date>` : ""}
    ${copyrightLine ? `<dc:rights>${escapeXml(copyrightLine)}</dc:rights>` : ""}
    ${metadata.isbn ? `<dc:identifier id="ISBN">${escapeXml(metadata.isbn)}</dc:identifier>` : ""}
    ${metadata.publisher_name ? `<dc:publisher>${escapeXml(metadata.publisher_name)}</dc:publisher>` : ""}
    ${metadata.book_description ? `<dc:description>${escapeXml(metadata.book_description)}</dc:description>` : ""}
    ${metadata.series_name ? `<meta property="belongs-to-collection" id="collection">${escapeXml(metadata.series_name)}</meta>` : ""}
    ${metadata.series_number ? `<meta refines="#collection" property="group-position">${metadata.series_number}</meta>` : ""}
    <meta property="dcterms:modified">${now}</meta>
    ${metadata.dedication ? `<dc:subject>${escapeXml(metadata.dedication)}</dc:subject>` : ""}
  </metadata>`;

  zip.file(
    "OEBPS/content.opf",
    `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="BookId">
  ${metadataBlock}
  <manifest>
    ${manifestItems.join("\n    ")}
  </manifest>
  <spine toc="ncx">
    ${spineItems}
  </spine>
</package>`,
  );

  // 5. OEBPS/nav.xhtml
  const navList = sectionFiles
    .map((sf) => `<li><a href="${sf.href}">${escapeXml(sf.title)}</a></li>`)
    .join("\n      ");
  zip.file(
    "OEBPS/nav.xhtml",
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Table of Contents</title></head>
<body>
<nav epub:type="toc">
  <h1>Table of Contents</h1>
  <ol>
      ${navList}
  </ol>
</nav>
</body>
</html>`,
  );

  // 6. OEBPS/toc.ncx
  const navPoints = sectionFiles
    .map((sf, i) =>
      `<navPoint id="navPoint-${i + 1}" playOrder="${i + 1}"><navLabel><text>${escapeXml(sf.title)}</text></navLabel><content src="${sf.href}"/></navPoint>`
    )
    .join("\n    ");
  zip.file(
    "OEBPS/toc.ncx",
    `<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:${uuid}"/>
    <meta name="dtb:depth" content="1"/>
  </head>
  <docTitle><text>${escapeXml(metadata.book_title)}</text></docTitle>
  <navMap>
    ${navPoints}
  </navMap>
</ncx>`,
  );

  // 7. OEBPS/styles.css — Kindle-book typography per spec
  zip.file(
    "OEBPS/styles.css",
    `@charset "UTF-8";
body {
  font-family: Georgia, "Times New Roman", serif;
  font-size: 1em;
  line-height: 1.3em;
  text-align: justify;
  margin: 1em 0.5em;
}
h1 {
  font-size: 1.8em;
  font-weight: bold;
  margin-top: 2em;
  margin-bottom: 1em;
  page-break-before: always;
  text-align: center;
}
h2 {
  font-size: 1.3em;
  font-weight: bold;
  margin-top: 1.5em;
  margin-bottom: 0.5em;
}
p {
  margin: 0;
  text-indent: 1.5em;
}
p + p {
  margin-top: 1em;
  text-indent: 0;
}
p:first-of-type {
  text-indent: 0;
}
`,
  );

  // 8. Cover image (if provided)
  if (coverBuffer) {
    zip.file("OEBPS/cover-image.jpg", coverBuffer);
  }

  // 9. Section files (one per chapter)
  for (const sf of sectionFiles) {
    zip.file(
      `OEBPS/${sf.href}`,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${escapeXml(sf.title)}</title></head>
<body>
${sf.body}
</body>
</html>`,
    );
  }

  // Generate ZIP (DEFLATE compression except mimetype)
  return new Uint8Array(
    await zip.generateAsync({
      type: "uint8array",
      compression: "DEFLATE",
      compressionOptions: { level: 6 },
    }),
  );
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
