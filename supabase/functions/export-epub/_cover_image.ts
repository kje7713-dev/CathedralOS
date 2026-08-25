// =============================================================================
// _cover_image.ts — Cover image acquisition (user upload OR DALL-E 3 auto-gen)
//
// Returns Uint8Array of JPEG/PNG bytes if a cover is available, or null if
// no cover (Kindle shows blank cover; book still valid EPUB per spec).
//
// Aspect ratio recommended: 1600x2560 (Kindle-friendly 2:3.2).
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import type { ExportRequest } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";

export async function generateOrFetchCover(
  client: SupabaseClient,
  req: ExportRequest,
  outline: ProjectOutline,
): Promise<Uint8Array | null> {
  // Path A: user upload
  if (req.cover_image_url) {
    try {
      const { data, error } = await client.storage
        .from("covers")
        .download(req.cover_image_url);
      if (error) throw error;
      if (!data) throw new Error("empty download");
      const bytes = new Uint8Array(await data.arrayBuffer());
      if (bytes.byteLength > 5 * 1024 * 1024) {
        console.warn("cover exceeds 5MB; using anyway");
      }
      return bytes;
    } catch (err) {
      console.warn(
        `cover download failed (${req.cover_image_url}): ${(err as Error).message}; falling through`,
      );
    }
  }

  // Path B: DALL-E 3 auto-gen
  if (req.cover_image_ai_generate) {
    return await generateCoverWithDallE(outline);
  }

  // Path C: no cover
  return null;
}

async function generateCoverWithDallE(outline: ProjectOutline): Promise<Uint8Array> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY not set");

  const premiseSnippet = (outline.chapters[0]?.sections[0]?.body ?? "")
    .slice(0, 200)
    .replace(/\s+/g, " ")
    .trim();

  const prompt = [
    `Book cover for "${outline.title}".`,
    premiseSnippet ? `Inspired by: ${premiseSnippet}` : "",
    "Cinematic, evocative, no text or words, painterly composition.",
  ].filter(Boolean).join(" ");

  const response = await fetch("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "dall-e-3",
      prompt,
      n: 1,
      size: "1024x1792",
      quality: "hd",
      response_format: "url",
    }),
  });

  if (!response.ok) {
    throw new Error(`DALL-E 3 failed: ${response.status} ${await response.text()}`);
  }

  const result = await response.json() as { data: Array<{ url: string }> };
  const imageUrl = result.data[0].url;
  const imageResponse = await fetch(imageUrl);
  if (!imageResponse.ok) {
    throw new Error(`DALL-E 3 image download failed: ${imageResponse.status}`);
  }
  return new Uint8Array(await imageResponse.arrayBuffer());
}
