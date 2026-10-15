export type CanonicalContentRating = "all_ages" | "13_plus" | "16_plus" | "18_plus";
export type CanonicalIntimacyRating = "unspecified" | "romantic" | "fade_to_black" | "open_door" | "explicit";

export function normalizeContentRating(value: unknown): CanonicalContentRating {
  const raw = String(value ?? "").trim().toLowerCase().replace(/[- ]/g, "_");
  if (["13_plus", "16_plus", "18_plus"].includes(raw)) return raw as CanonicalContentRating;
  return raw === "all_ages" ? "all_ages" : "all_ages";
}

export function normalizeIntimacyRating(value: unknown): CanonicalIntimacyRating {
  const raw = String(value ?? "").trim().toLowerCase().replace(/[- ]/g, "_");
  return ["romantic", "fade_to_black", "open_door", "explicit"].includes(raw)
    ? raw as CanonicalIntimacyRating
    : "unspecified";
}

export function isIntimacyCompatible(contentRating: unknown, intimacyRating: unknown): boolean {
  const age = normalizeContentRating(contentRating);
  const intimacy = normalizeIntimacyRating(intimacyRating);
  if (age === "all_ages" || age === "13_plus") return intimacy === "unspecified" || intimacy === "romantic";
  if (age === "16_plus") return intimacy === "unspecified" || intimacy === "romantic" || intimacy === "fade_to_black";
  return true;
}

export function resolveAudienceFields(request: { sourcePayloadJSON?: unknown; readingLevel?: unknown; contentRating?: unknown; intimacyRating?: unknown; audienceNotes?: unknown }) {
  let project: Record<string, unknown> = {};
  try {
    const payload = typeof request.sourcePayloadJSON === "string" ? JSON.parse(request.sourcePayloadJSON) : request.sourcePayloadJSON;
    if (payload && typeof payload === "object" && (payload as any).project && typeof (payload as any).project === "object") project = (payload as any).project;
  } catch { /* legacy malformed payloads retain empty/default behavior */ }
  return {
    readingLevel: String(request.readingLevel || project.readingLevel || ""),
    contentRating: String(request.contentRating || project.contentRating || ""),
    intimacyRating: normalizeIntimacyRating(request.intimacyRating || project.intimacyRating),
    audienceNotes: String(request.audienceNotes || project.audienceNotes || ""),
  };
}

export function validateAudienceCompatibility(contentRating: unknown, intimacyRating: unknown): string | null {
  const normalizedAge = normalizeContentRating(contentRating);
  const normalizedIntimacy = normalizeIntimacyRating(intimacyRating);
  return isIntimacyCompatible(normalizedAge, normalizedIntimacy)
    ? null
    : `intimacy rating ${normalizedIntimacy} is incompatible with content rating ${normalizedAge}`;
}
