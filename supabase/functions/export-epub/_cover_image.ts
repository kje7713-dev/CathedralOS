// =============================================================================
// _cover_image.ts — Cover image acquisition (user upload OR DALL-E 3 auto-gen)
//
// Returns:
//   - Uint8Array of JPEG/PNG bytes if a cover is available
//   - null if no cover (Kindle shows blank cover; book still valid EPUB)
//
// Cover aspect ratio enforced: 1600x2560 (2:3.2 — Kindle recommended).
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import type { ExportRequest } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";

const COVER_ASPECT_W = 1600;
const COVER_ASPECT_H = 2560;

export async function generateOrFetchCover(
  _client: SupabaseClient,
  _req: ExportRequest,
  _outline: ProjectOutline,
): Promise<Uint8Array | null> {
  // TODO: PR-4100-A follow-up
  // Path A (user upload):
  //   1. If req.cover_image_url is set, download from Supabase Storage
  //   2. Validate format (JPEG/PNG) + size (≤ 5MB per spec)
  //   3. If aspect ratio != 2:3.2, log warning (don't reject — Kindle accepts)
  //   4. Return bytes
  //
  // Path B (DALL-E 3 auto-gen):
  //   1. If req.cover_image_ai_generate is true (and no upload URL):
  //      a. Build prompt from outline.title + first chapter premise
  //      b. Call OpenAI Images API (gpt-image-1 or dall-e-3, 1024x1792 or
  //         upscale to 1600x2560)
  //      c. Upload result to Supabase Storage (covers/{user_id}/{job_id}.jpg)
  //      d. Return bytes
  //
  // Path C (skip):
  //   - If neither A nor B applies, return null. Kindle shows blank cover.
  throw new Error("_cover_image.generateOrFetchCover: not yet implemented");
}
