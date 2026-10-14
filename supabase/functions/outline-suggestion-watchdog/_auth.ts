export function readSecretKey(raw: string | undefined): string {
  if (!raw) return "";
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return "";
    const value = (parsed as Record<string, unknown>).default;
    return typeof value === "string" ? value.trim() : "";
  } catch {
    return "";
  }
}

export function isAuthorized(supplied: string | null, expected: string): boolean {
  return Boolean(expected && supplied && supplied === expected);
}
