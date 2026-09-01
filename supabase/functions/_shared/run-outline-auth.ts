// Authentication for server-to-server Run All section requests.
// The caller still presents the user's JWT; this token only authorizes the
// durable-job rate-limit class and binds the request to one owned run/section.

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/g,
    "",
  );
}

async function sign(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message),
  );
  return base64Url(new Uint8Array(signature));
}

function messageFor(userId: string, runId: string, sectionId: string): string {
  return `${userId}:${runId}:${sectionId}`;
}

export function createRunOutlineToken(
  secret: string,
  userId: string,
  runId: string,
  sectionId: string,
): Promise<string> {
  return sign(secret, messageFor(userId, runId, sectionId));
}

export async function verifyRunOutlineToken(
  secret: string,
  token: string,
  userId: string,
  runId: string,
  sectionId: string,
): Promise<boolean> {
  if (!secret || !token) return false;
  const expected = await createRunOutlineToken(
    secret,
    userId,
    runId,
    sectionId,
  );
  return token === expected;
}
