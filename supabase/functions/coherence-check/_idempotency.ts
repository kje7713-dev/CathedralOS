// =============================================================================
// coherence-check/_idempotency.ts
//
// Idempotency-key derivation for the coherence-check edge function.
// Pulled out of index.ts so tests can import the real implementation
// (kevbot-brain: mirror tests hide regressions).
//
// Two requests with the same verified user_id, same body fingerprint, and
// the same minute bucket collapse to the same key. After the minute bucket
// rolls, a new request creates a fresh key — legitimate re-checks are not
// blocked.
// =============================================================================

import type { CoherenceCheckRequest } from "./_validation.ts";

export async function sha256Hex(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function computeIdempotencyKey(
  userId: string,
  body: CoherenceCheckRequest,
  now: number = Date.now(),
): Promise<string> {
  const fingerprint = await sha256Hex(JSON.stringify({
    output_text: body.output_text,
    current_section_id: body.current_section?.id ?? null,
    prior_canon_count: body.prior_canon.sections.length,
  }));
  const minuteBucket = Math.floor(now / 60_000);
  return await sha256Hex(`${userId}|${fingerprint}|${minuteBucket}`);
}
