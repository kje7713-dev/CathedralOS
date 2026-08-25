// =============================================================================
// _validator_client.ts — Cloud Run EPUBCheck validator client
//
// Only file in the export pipeline that knows Cloud Run exists.
// Interface: validateEpub(signedUrl, validationId): Promise<ValidationResult>
//
// Transport: signed URL (EPUB lives on Supabase Storage throughout)
// Auth: HMAC-SHA256 with timestamp + body
//
// Retry policy for VALIDATOR FAILURE:
//   - 4xx (auth): do NOT retry — fail closed
//   - 5xx / timeout / network: retry up to 2x with exponential backoff
//   - 200 with invalid EPUB: do NOT retry — repair layer handles this
// =============================================================================

const VALIDATOR_URL = Deno.env.get("EPUBCHECK_VALIDATOR_URL");
const HMAC_SECRET = Deno.env.get("EPUBCHECK_VALIDATOR_HMAC_SECRET");

if (!VALIDATOR_URL) console.error("EPUBCHECK_VALIDATOR_URL not set");
if (!HMAC_SECRET) console.error("EPUBCHECK_VALIDATOR_HMAC_SECRET not set");

export interface ValidationDiagnostic {
  severity: "fatal" | "error" | "warning" | "info";
  code: string;
  message: string;
  file?: string;
  line?: number;
  column?: number;
}

export interface ValidationResult {
  validation_id: string;
  epubcheck_version: string;
  validation_duration_ms: number;
  valid: boolean;
  error_count: number;
  warning_count: number;
  diagnostics: ValidationDiagnostic[];
}

export type ValidatorFailureCategory =
  | "auth"
  | "network"
  | "timeout"
  | "server_error"
  | "malformed_response";

export class ValidatorFailureError extends Error {
  readonly category: ValidatorFailureCategory;
  constructor(message: string, category: ValidatorFailureCategory) {
    super(message);
    this.name = "ValidatorFailureError";
    this.category = category;
  }
}

export interface ValidateOptions {
  maxRetries?: number;
  timeoutMs?: number;
}

export async function validateEpub(
  signedUrl: string,
  validationId: string,
  options: ValidateOptions = {},
): Promise<ValidationResult> {
  const { maxRetries = 2, timeoutMs = 65_000 } = options;

  if (!VALIDATOR_URL || !HMAC_SECRET) {
    throw new ValidatorFailureError(
      "Validator not configured (missing URL or HMAC secret)",
      "auth",
    );
  }

  const body = JSON.stringify({
    epub_storage_path: signedUrl,
    validation_id: validationId,
  });

  let lastError: ValidatorFailureError | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    if (attempt > 0) {
      await sleep(Math.pow(2, attempt - 1) * 1000);
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

    try {
      const timestamp = Math.floor(Date.now() / 1000).toString();
      const signature = await hmacSign(`${timestamp}.${body}`, HMAC_SECRET);

      const response = await fetch(`${VALIDATOR_URL}/v1/validate`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Epubcheck-Signature": `t=${timestamp},v1=${signature}`,
        },
        body,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      if (response.status === 401) {
        throw new ValidatorFailureError("Validator auth rejected (401)", "auth");
      }
      if (response.status === 408 || response.status === 504) {
        throw new ValidatorFailureError(
          `Validator timeout (${response.status})`,
          "timeout",
        );
      }
      if (response.status >= 500) {
        throw new ValidatorFailureError(
          `Validator server error (${response.status})`,
          "server_error",
        );
      }
      if (!response.ok) {
        throw new ValidatorFailureError(
          `Validator returned ${response.status}`,
          "server_error",
        );
      }

      const result = (await response.json()) as ValidationResult;

      if (
        typeof result?.valid !== "boolean" ||
        !Array.isArray(result?.diagnostics)
      ) {
        throw new ValidatorFailureError(
          "Malformed validator response",
          "malformed_response",
        );
      }

      return result;
    } catch (err) {
      clearTimeout(timeoutId);

      if (err instanceof ValidatorFailureError) {
        if (err.category === "auth") throw err; // fail closed
        lastError = err;
      } else if (err instanceof DOMException && err.name === "AbortError") {
        lastError = new ValidatorFailureError(
          `Validator request timed out after ${timeoutMs}ms`,
          "timeout",
        );
      } else {
        lastError = new ValidatorFailureError(
          `Validator network error: ${String(err)}`,
          "network",
        );
      }
    }
  }

  throw lastError!;
}

async function hmacSign(payload: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(payload),
  );
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
