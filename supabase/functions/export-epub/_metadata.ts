// =============================================================================
// _metadata.ts — Assemble EPUB metadata from ExportRequest
//
// Pure function (no I/O). Applies defaults, validates required fields,
// maps to OPF metadata block. Caller already enforces required fields.
// =============================================================================

export interface ExportMetadata {
  book_title: string;
  author_name: string;
  copyright_year?: number;
  copyright_holder?: string;
  language: string;
  dedication?: string;
  book_description?: string;
  about_author?: string;
  isbn?: string;
  publisher_name?: string;
  series_name?: string;
  series_number?: number;
}

export interface ExportRequest {
  project_id: string;
  book_title: string;
  author_name: string;
  copyright_year?: number;
  copyright_holder?: string;
  language?: string;
  dedication?: string;
  book_description?: string;
  about_author?: string;
  isbn?: string;
  publisher_name?: string;
  series_name?: string;
  series_number?: number;
  cover_image_url?: string;
  cover_image_ai_generate?: boolean;
}

export function assembleMetadata(req: ExportRequest): ExportMetadata {
  const currentYear = new Date().getFullYear();
  return {
    book_title: trim(req.book_title),
    author_name: trim(req.author_name),
    copyright_year: req.copyright_year ?? currentYear,
    copyright_holder: req.copyright_holder ? trim(req.copyright_holder) : undefined,
    language: req.language ?? "en",
    dedication: req.dedication ? trim(req.dedication) : undefined,
    book_description: req.book_description ? trim(req.book_description) : undefined,
    about_author: req.about_author ? trim(req.about_author) : undefined,
    isbn: req.isbn ? trim(req.isbn) : undefined,
    publisher_name: req.publisher_name ? trim(req.publisher_name) : undefined,
    series_name: req.series_name ? trim(req.series_name) : undefined,
    series_number: req.series_number,
  };
}

function trim(s: string): string {
  return s.trim();
}
