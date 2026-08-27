// =============================================================================
// _cover_image.ts — Cover image acquisition (user upload OR OpenAI image-gen)
//
// Returns Uint8Array of JPEG/PNG bytes if a cover is available, or null if
// no cover (Kindle shows blank cover; book still valid EPUB per spec).
//
// Aspect ratio recommended: 1600x2560 (Kindle-friendly 2:3.2).
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import type { ExportRequest } from "./_metadata.ts";
import type { ProjectOutline } from "./_section_walker.ts";
import {
  actualAiCoverBilling,
  AI_COVER_IMAGE_OUTPUT_TOKENS,
  type AiCoverBilling,
} from "./_cover_billing.ts";

export interface CoverResult {
  bytes: Uint8Array;
  billing?: AiCoverBilling;
}

export async function generateOrFetchCover(
  client: SupabaseClient,
  req: ExportRequest,
  outline: ProjectOutline,
): Promise<CoverResult | null> {
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
      return { bytes };
    } catch (err) {
      console.warn(
        `cover download failed (${req.cover_image_url}): ${
          (err as Error).message
        }; falling through`,
      );
    }
  }

  // Path B: OpenAI image generation
  if (req.cover_image_ai_generate) {
    return await generateCoverWithDallE(outline);
  }

  // Path C: no cover
  return null;
}

async function generateCoverWithDallE(
  outline: ProjectOutline,
): Promise<CoverResult> {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY not set");

  const prompt = buildCoverPrompt(outline);

  const model = Deno.env.get("OPENAI_IMAGE_MODEL") ?? "gpt-image-1";

  const response = await fetch("https://api.openai.com/v1/images/generations", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      prompt,
      n: 1,
      size: "1024x1536",
      quality: "high",
      output_format: "jpeg",
    }),
  });

  if (!response.ok) {
    throw new Error(
      `OpenAI image generation failed (${model}): ${response.status} ${await response
        .text()}`,
    );
  }

  const result = await response.json() as {
    data?: Array<{ url?: string; b64_json?: string }>;
    usage?: { input_tokens?: number; output_tokens?: number };
  };
  const image = result.data?.[0];
  if (!image) {
    throw new Error(`OpenAI image generation returned no image (${model})`);
  }

  // GPT Image models return base64 by default; retain URL support for
  // compatible image providers/configurations.
  if (image.b64_json) {
    const binary = atob(image.b64_json);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return {
      bytes,
      billing: actualAiCoverBilling(
        result.usage?.input_tokens,
        result.usage?.output_tokens ?? AI_COVER_IMAGE_OUTPUT_TOKENS,
        prompt,
      ),
    };
  }

  if (!image.url) {
    throw new Error(
      `OpenAI image generation returned no image data (${model})`,
    );
  }
  const imageResponse = await fetch(image.url);
  if (!imageResponse.ok) {
    throw new Error(`OpenAI image download failed: ${imageResponse.status}`);
  }
  const bytes = new Uint8Array(await imageResponse.arrayBuffer());
  return {
    bytes,
    billing: actualAiCoverBilling(
      result.usage?.input_tokens,
      result.usage?.output_tokens ?? AI_COVER_IMAGE_OUTPUT_TOKENS,
      prompt,
    ),
  };
}

export function buildCoverPrompt(outline: ProjectOutline): string {
  const brief = outline.storyBrief ?? {};
  return [
    `Create a cohesive literary book cover for "${outline.title}" representing the whole story, not one isolated scene.`,
    brief.projectSummary ? `Premise: ${brief.projectSummary}` : "",
    brief.recipe ? `Recipe and story arc: ${brief.recipe}` : "",
    brief.setting ? `Setting and atmosphere: ${brief.setting}` : "",
    brief.characters ? `Key characters: ${brief.characters}` : "",
    brief.conflict ? `Central conflict and stakes: ${brief.conflict}` : "",
    brief.themes ? `Themes and motifs: ${brief.themes}` : "",
    brief.endingTexture ? `Emotional aftertaste: ${brief.endingTexture}` : "",
    "Use the recurring visual idea that best unifies these signals. No readable text, letters, logos, or words; no spoilers.",
  ].filter(Boolean).join(" ");
}
