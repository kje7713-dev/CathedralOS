// Paragraph normalization for generated prose before XHTML rendering.

export function splitParagraphs(body: string): string[] {
  return body
    .replace(/\r\n?/g, "\n")
    .split(/\n\s*\n/)
    .map((paragraph) => paragraph.trim())
    .filter((paragraph) => paragraph.length > 0);
}


/**
 * Render the tiny inline-markup subset Cathedral generation currently emits
 * into XHTML-safe paragraph content. Escape user/model text first, then add
 * only markup we own so generated HTML/XML can never pass through.
 *
 * Intentionally not a general Markdown parser: EPUB prose currently needs
 * strong emphasis from paired ** markers. Unmatched markers remain literal.
 */
export function renderInlineMarkupXhtml(input: string): string {
  const escaped = input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");

  return escaped.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
}
