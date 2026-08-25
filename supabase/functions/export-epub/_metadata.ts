// =============================================================================
// _metadata.ts — Assemble EPUB metadata from ExportRequest + project data
//
// Pure function (no I/O). Applies defaults, validates required fields,
// maps to OPF metadata block.
// =============================================================================

export interface ExportMetadata {
  book_title: string;
  author_name: string;
  copyright_year?: number;
  copyright_holder?: string;
  language: string;             // BCP-47 (e.g., "en")
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
  // TODO: PR-4100-A follow-up
  // 1. Validate required fields (project_id, book_title, author_name) — caller
  //    already enforces these; defensive check here.
  // 2. Default language to "en" if not provided.
  // 3. Compute copyright_year if not provided (current year).
  // 4. Trim/sanitize all string fields for OPF safety (no XML-unsafe content).
  // 5. Return assembled metadata.
  throw new Error("_metadata.assembleMetadata: not yet implemented");
}
