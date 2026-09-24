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
import type { ProjectOutline, Section } from "./_section_walker.ts";
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
    chapterId: string;
    chapterRootId: string;
    sections: Section[];
  }> = [];

  for (let ci = 0; ci < outline.chapters.length; ci++) {
    const chapter = outline.chapters[ci];
    const chapterTitle = chapter.title || `Chapter ${ci + 1}`;
    const chapterRoot = chapter.sections.find((section) =>
      section.parent_id === null
    );
    const generatedSections = chapter.sections.filter((section) =>
      section.body.trim().length > 0
    );

    // Do not publish empty outline placeholders as EPUB chapters. An outline
    // can contain many accepted sections before prose has been generated; only
    // sections with actual generated text belong in the book.
    if (generatedSections.length === 0) continue;

    // Body: generated chapter root + child sections concatenated as <p> blocks
    const bodyParts: string[] = [
      `<h1 class="section-title">${escapeXml(chapterTitle)}</h1>`,
    ];
    for (const section of generatedSections) {
      if (section.id !== chapterRoot?.id && section.title) {
        bodyParts.push(
          `<h2 id="${sectionAnchorId(ci, section.id)}">${
            escapeXml(section.title)
          }</h2>`,
        );
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
      chapterId: chapter.id,
      chapterRootId: chapterRoot?.id ?? chapter.id,
      sections: generatedSections,
    });
  }

  // Readium requires at least one readable spine item. Fail closed here rather
  // than emitting an EPUB that crashes the reader during pagination setup.
  if (sectionFiles.length === 0) {
    throw new Error("EPUB has no generated readable content");
  }

  // Derive rendered Parts only after generated-content filtering. Source Part
  // identity remains available for semantic subtitles and saved custom names.
  const sourceParts = outline.parts
    .map((part) => ({
      source: part,
      chapters: sectionFiles.filter((sf) =>
        part.chapter_ids.includes(sf.chapterId)
      ),
    }))
    .filter((part) => part.chapters.length > 0);
  const activeParts = sourceParts.map(({ source, chapters }, position) => ({
    ...source,
    sourcePartID: source.id,
    sourcePosition: source.position,
    id: `part-${position + 1}`,
    position,
    label: `Part ${roman(position + 1)}`,
    chapters,
  }));
  const activePartByChapterID = new Map<string, typeof activeParts[number]>();
  for (const part of activeParts) {
    for (const chapter of part.chapters) {
      activePartByChapterID.set(chapter.chapterId, part);
    }
  }
  const orderedSectionFilesForPart = (partID: string) =>
    sectionFiles.filter((sf) =>
      activePartByChapterID.get(sf.chapterId)?.id === partID
    );
  let previousPartPosition = -1;
  for (const sf of sectionFiles) {
    const part = activePartByChapterID.get(sf.chapterId);
    if (activeParts.length > 0 && !part) {
      throw new Error(
        `generated chapter ${sf.chapterId} has no Part assignment`,
      );
    }
    if (part && part.sourcePosition < previousPartPosition) {
      throw new Error(
        "non-contiguous Part assignment would reorder manuscript content",
      );
    }
    if (part) previousPartPosition = part.sourcePosition;
  }
  const resolvedPartSubtitle = (
    part: typeof activeParts[number],
  ): string | null => {
    const custom = metadata.part_names?.[part.sourcePartID]?.trim();
    return custom || part.default_subtitle || null;
  };
  const partTOCTitle = (part: typeof activeParts[number]): string => {
    const subtitle = resolvedPartSubtitle(part);
    return subtitle ? `${part.label} — ${subtitle}` : part.label;
  };

  // 4. OEBPS/content.opf
  const manifestItems = [
    `<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>`,
    `<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>`,
    `<item id="css" href="styles.css" media-type="text/css"/>`,
  ];
  if (coverBuffer) {
    // Keep the image resource marked as the EPUB cover and add a readable
    // cover document so navigators such as Readium present it before prose.
    manifestItems.push(
      `<item id="cover-image" href="cover-image.jpg" media-type="image/jpeg" properties="cover-image"/>`,
    );
    manifestItems.push(
      `<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>`,
    );
  }
  for (const part of activeParts) {
    manifestItems.push(
      `<item id="${part.id}" href="text/${part.id}.xhtml" media-type="application/xhtml+xml"/>`,
    );
  }
  for (const sf of sectionFiles) {
    manifestItems.push(
      `<item id="${sf.id}" href="${sf.href}" media-type="application/xhtml+xml"/>`,
    );
  }
  // PR #619 (EPUB Acknowledgements): include the back-matter manifest entry
  // only when acknowledgements text is present so the writer omits the page
  // entirely when the user did not provide it.
  if (metadata.acknowledgements) {
    manifestItems.push(
      `<item id="acknowledgements" href="text/acknowledgements.xhtml" media-type="application/xhtml+xml"/>`,
    );
  }

  const spineEntries: string[] = [];
  if (coverBuffer) spineEntries.push(`<itemref idref="cover"/>`);
  let previousPartID: string | null = null;
  for (const sf of sectionFiles) {
    const part = activePartByChapterID.get(sf.chapterId);
    if (part && part.id !== previousPartID) {
      spineEntries.push(`<itemref idref="${part.id}"/>`);
      previousPartID = part.id;
    }
    spineEntries.push(`<itemref idref="${sf.id}"/>`);
  }
  // PR #619: acknowledgements appears as the last spine entry when present.
  if (metadata.acknowledgements) {
    spineEntries.push(`<itemref idref="acknowledgements"/>`);
  }
  const spineItems = spineEntries.join("\n    ");

  const copyrightLine = metadata.copyright_holder
    ? `Copyright © ${metadata.copyright_year ?? new Date().getFullYear()} ${
      escapeXml(metadata.copyright_holder)
    }`
    : "";

  const metadataBlock =
    `<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="BookId">urn:uuid:${uuid}</dc:identifier>
    <dc:title>${escapeXml(metadata.book_title)}</dc:title>
    <dc:creator id="creator">${escapeXml(metadata.author_name)}</dc:creator>
    <dc:language>${metadata.language}</dc:language>
    ${
      metadata.copyright_year
        ? `<dc:date>${metadata.copyright_year}</dc:date>`
        : ""
    }
    ${copyrightLine ? `<dc:rights>${escapeXml(copyrightLine)}</dc:rights>` : ""}
    ${
      metadata.isbn
        ? `<dc:identifier id="ISBN">${escapeXml(metadata.isbn)}</dc:identifier>`
        : ""
    }
    ${
      metadata.publisher_name
        ? `<dc:publisher>${escapeXml(metadata.publisher_name)}</dc:publisher>`
        : ""
    }
    ${
      metadata.book_description
        ? `<dc:description>${
          escapeXml(metadata.book_description)
        }</dc:description>`
        : ""
    }
    ${
      metadata.about_author
        ? `<meta property="x-about-author">${
          escapeXml(metadata.about_author)
        }</meta>`
        : ""
    }
    ${
      metadata.series_name
        ? `<meta property="belongs-to-collection" id="collection">${
          escapeXml(metadata.series_name)
        }</meta>`
        : ""
    }
    ${
      metadata.series_number
        ? `<meta refines="#collection" property="group-position">${metadata.series_number}</meta>`
        : ""
    }
    <meta property="dcterms:modified">${now}</meta>
    ${coverBuffer ? `<meta name="cover" content="cover-image"/>` : ""}
    ${
      metadata.dedication
        ? `<dc:subject>${escapeXml(metadata.dedication)}</dc:subject>`
        : ""
    }
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

  // 5. OEBPS/nav.xhtml — Parts contain chapter documents, and chapter
  // documents contain fragment links for child OutlineSections.
  const sectionNav = (sf: typeof sectionFiles[number]): string => {
    const childLinks = sf.sections
      .filter((section) =>
        section.id !== sf.chapterRootId && section.body.trim().length > 0 &&
        section.title
      )
      .map((section) =>
        `<li><a href="${sf.href}#${
          sectionAnchorId(sf.chapterIdx, section.id)
        }">${escapeXml(section.title)}</a></li>`
      )
      .join("\n            ");
    return `<li><a href="${sf.href}">${escapeXml(sf.title)}</a>${
      childLinks
        ? `\n          <ol>\n            ${childLinks}\n          </ol>`
        : ""
    }</li>`;
  };
  const navList = activeParts.length > 0
    ? activeParts.map((part) =>
      `<li><a href="text/${part.id}.xhtml">${
        escapeXml(partTOCTitle(part))
      }</a>\n        <ol>\n          ${
        orderedSectionFilesForPart(part.id).map(sectionNav).join("\n          ")
      }\n        </ol>\n      </li>`
    ).join("\n      ")
    : sectionFiles.map(sectionNav).join("\n      ");
  const landmarkItems = [
    ...(coverBuffer
      ? ['<li><a epub:type="cover" href="cover.xhtml">Cover</a></li>']
      : []),
    ...(sectionFiles[0]
      ? [
        `<li><a epub:type="bodymatter" href="${
          sectionFiles[0].href
        }">Start of Book</a></li>`,
      ]
      : []),
    '<li><a epub:type="toc" href="nav.xhtml">Table of Contents</a></li>',
  ].join("\n      ");
  const navTail = metadata.acknowledgements
    ? '\n      <li><a href="text/acknowledgements.xhtml">Acknowledgements</a></li>'
    : "";
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
      ${navList}${navTail}
  </ol>
</nav>
<nav epub:type="landmarks" hidden="">
  <h2>Landmarks</h2>
  <ol>
      ${landmarkItems}
  </ol>
</nav>
</body>
</html>`,
  );

  // 6. OEBPS/toc.ncx — retain the legacy navigation with the same hierarchy.
  let playOrder = 1;
  const ncxSection = (sf: typeof sectionFiles[number]): string => {
    const parentOrder = playOrder++;
    const childPoints = sf.sections
      .filter((section) =>
        section.id !== sf.chapterRootId && section.body.trim().length > 0 &&
        section.title
      )
      .map((section) => {
        const childOrder = playOrder++;
        return `<navPoint id="navPoint-${
          safeNavID(section.id)
        }" playOrder="${childOrder}"><navLabel><text>${
          escapeXml(section.title)
        }</text></navLabel><content src="${sf.href}#${
          sectionAnchorId(sf.chapterIdx, section.id)
        }"/></navPoint>`;
      })
      .join("\n        ");
    return `<navPoint id="navPoint-${
      safeNavID(sf.id)
    }" playOrder="${parentOrder}"><navLabel><text>${
      escapeXml(sf.title)
    }</text></navLabel><content src="${sf.href}"/>${
      childPoints ? `\n        ${childPoints}` : ""
    }</navPoint>`;
  };
  const navPoints = activeParts.length > 0
    ? activeParts.map((part) => {
      const partOrder = playOrder++;
      return `<navPoint id="navPoint-${part.id}" playOrder="${partOrder}"><navLabel><text>${
        escapeXml(partTOCTitle(part))
      }</text></navLabel><content src="text/${part.id}.xhtml"/>\n        ${
        orderedSectionFilesForPart(part.id).map(ncxSection).join("\n        ")
      }\n      </navPoint>`;
    }).join("\n    ")
    : sectionFiles.map(ncxSection).join("\n    ");
  const acknowledgementsNavPoint = metadata.acknowledgements
    ? `\n    <navPoint id="navPoint-acknowledgements" playOrder="${playOrder++}"><navLabel><text>Acknowledgements</text></navLabel><content src="text/acknowledgements.xhtml"/></navPoint>`
    : "";
  const hasChildNavigation = sectionFiles.some((sf) =>
    sf.sections.some((section) =>
      section.id !== sf.chapterRootId && section.body.trim().length > 0 &&
      section.title
    )
  );
  const ncxDepth = activeParts.length > 0
    ? (hasChildNavigation ? 3 : 2)
    : (hasChildNavigation ? 2 : 1);
  zip.file(
    "OEBPS/toc.ncx",
    `<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:${uuid}"/>
    <meta name="dtb:depth" content="${ncxDepth}"/>
  </head>
  <docTitle><text>${escapeXml(metadata.book_title)}</text></docTitle>
  <navMap>
    ${navPoints}${acknowledgementsNavPoint}
  </navMap>
</ncx>`,
  );

  // 7. OEBPS/styles.css — Kindle-book typography per spec
  zip.file(
    "OEBPS/styles.css",
    `@charset "UTF-8";
body {
  margin: 0;
  padding: 0;
  font-size: 1em;
  line-height: 1.3;
  text-align: start;
}
h1 {
  font-size: 1.8em;
  font-weight: bold;
  margin-top: 2em;
  margin-bottom: 1em;
  page-break-before: always;
  text-align: center;
}
h1.section-title {
  page-break-before: always;
}
h2 {
  font-size: 1.3em;
  font-weight: bold;
  margin-top: 1.5em;
  margin-bottom: 0.5em;
}
p {
  margin-top: 0;
  margin-bottom: 0;
  text-indent: 1.2em;
}
h1 + p,
h2 + p {
  text-indent: 0;
}
.part-page {
  text-align: center;
}
.part-page .part-name {
  text-indent: 0;
  margin-top: 0.5em;
}
.cover {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  min-height: 100vh;
  margin: 0;
  padding: 2rem 1.25rem;
  gap: 1rem;
  text-align: center;
}
.cover img {
  max-width: 100%;
  max-height: 62vh;
  object-fit: contain;
}
.cover-metadata {
  margin: 0;
  max-width: 100%;
}
.cover-metadata h1,
.cover-metadata p {
  margin: 0;
}
.cover-metadata h1 {
  font-size: 1.35rem;
  line-height: 1.2;
  font-weight: 600;
}
.cover-metadata p {
  margin-top: 0.35rem;
  color: #555;
  font-size: 1rem;
  line-height: 1.3;
}
`,
  );

  // 8. Cover image (if provided)
  if (coverBuffer) {
    zip.file("OEBPS/cover-image.jpg", coverBuffer);
  }

  // 9. Cover document — a manifest-only image is not shown by every EPUB
  // navigator. Put the cover in the spine so Readium opens it first.
  if (coverBuffer) {
    zip.file(
      "OEBPS/cover.xhtml",
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<link rel="stylesheet" type="text/css" href="styles.css"/>
<title>${escapeXml(metadata.book_title)}</title>
</head>
<body class="cover">
<img src="cover-image.jpg" alt="${escapeXml(metadata.book_title)}"/>
<div class="cover-metadata">
<h1>${escapeXml(metadata.book_title)}</h1>
<p>By ${escapeXml(metadata.author_name)}</p>
</div>
</body>
</html>`,
    );
  }

  // 9b. Part divider pages. They are intentionally minimal and contain no
  // manuscript prose; the existing chapter documents remain unchanged.
  for (const part of activeParts) {
    zip.file(
      `OEBPS/text/${part.id}.xhtml`,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<link rel="stylesheet" type="text/css" href="../styles.css"/>
<title>${escapeXml(partTOCTitle(part))}</title>
</head>
<body class="part-page">
<h1>${escapeXml(part.label)}</h1>
${
        resolvedPartSubtitle(part)
          ? `<p class="part-name">${escapeXml(resolvedPartSubtitle(part)!)}</p>`
          : ""
      }
</body>
</html>`,
    );
  }

  // 10. Section files (one per chapter)
  for (const sf of sectionFiles) {
    zip.file(
      `OEBPS/${sf.href}`,
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<link rel="stylesheet" type="text/css" href="../styles.css"/>
<title>${escapeXml(sf.title)}</title>
</head>
<body>
${sf.body}
</body>
</html>`,
    );
  }

  // PR #619 (EPUB Acknowledgements): back-matter page after the final story
  // section. Rendered only when acknowledgements text is non-empty.
  if (metadata.acknowledgements) {
    const ackBody: string[] = [`<h1>Acknowledgements</h1>`];
    for (const paragraph of splitParagraphs(metadata.acknowledgements)) {
      ackBody.push(`<p>${escapeXml(paragraph)}</p>`);
    }
    zip.file(
      "OEBPS/text/acknowledgements.xhtml",
      `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<link rel="stylesheet" type="text/css" href="../styles.css"/>
<title>Acknowledgements</title>
</head>
<body>
${ackBody.join("\n")}
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

function roman(value: number): string {
  return [
    "I",
    "II",
    "III",
    "IV",
    "V",
    "VI",
    "VII",
    "VIII",
    "IX",
    "X",
  ][value - 1] ?? String(value);
}

function sectionAnchorId(chapterIndex: number, sectionId: string): string {
  const safeSectionId = sectionId.replace(/[^A-Za-z0-9_-]+/g, "-");
  return `section-${chapterIndex + 1}-${safeSectionId}`;
}

function safeNavID(value: string): string {
  return value.replace(/[^A-Za-z0-9_-]+/g, "-");
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
