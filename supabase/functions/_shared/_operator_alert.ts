// =============================================================================
// _shared/_operator_alert.ts
//
// Server-side operator email alert for provider_billing_unavailable (non-
// retryable provider billing failure, e.g. OpenAI HTTP 429 with upstream
// code credit_balance_exhausted). Resend-backed, Postgres-dedupe'd.
//
// Design rules (per Kevin 2026-09-21 spec):
//   - Secrets come from Supabase env vars (RESEND_API_KEY,
//     OPERATOR_ALERT_EMAIL, OPERATOR_ALERT_FROM_EMAIL). Never hardcoded,
//     never logged, never persisted.
//   - Dedupe via should_send_provider_billing_alert(stable_code) RPC; one
//     email per provider_billing_unavailable incident per ~45 minutes.
//   - Email failure MUST NOT prevent the user-facing error response.
//     Callers wrap with EdgeRuntime.waitUntil(...) for fire-and-forget.
//   - The public message ("Temporarily unavailable — try again later.")
//     stays on the user-facing surface; this alert is operator-only.
//   - Telemetry (last_alert_attempted_at, last_alert_succeeded_at,
//     last_alert_status, last_alert_error) is recorded via
//     record_provider_billing_alert_outcome RPC. No secrets, prompts,
//     generated prose, or user-sensitive story content is ever sent.
//   - fetch + env getters are injectable so unit tests do not hit Resend.
// =============================================================================

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

export interface ProviderBillingUnavailableContext {
  /** Stable internal error code. Always "provider_billing_unavailable"
   * today; the RPC key is stable_code so future codes dedupe independently. */
  stableCode: "provider_billing_unavailable";
  /** Upstream OpenAI error.code (e.g. "credit_balance_exhausted"). */
  upstreamProviderCode?: string | null;
  /** Sanitized upstream OpenAI error.message. */
  upstreamMessage?: string | null;
  /** Upstream HTTP status (e.g. 429). */
  upstreamStatus?: number | null;
  /** Provider model identifier as sent to OpenAI (e.g. "gpt-5.6-luna"). */
  providerModel?: string | null;
  /** Selected model from the customer's generation request, when known. */
  selectedModel?: string | null;
  /** Supabase request id from the edge function logger. */
  requestID?: string | null;
  /** Outline-suggestion / Run All chapter_run id, when applicable. */
  chapterRunID?: string | null;
  /** Outline id the run is acting on, when applicable. */
  outlineID?: string | null;
  /** Project id, when applicable. */
  projectID?: string | null;
  /** Deployment environment; defaults to "production". */
  environment?: "production" | "staging" | "development" | "test" | null;
  /** Override the suppression window (minutes). Defaults to 45. */
  alertSuppressionWindowMinutes?: number | null;
  /** Override the "occurred at" timestamp. Test-only. */
  occurredAt?: Date | null;
}

export interface OperatorAlertDeps {
  /** Injectable fetch. Defaults to global fetch. */
  fetchImpl?: typeof fetch;
  /** Injectable env reader. Defaults to Deno.env.get. */
  getEnv?: (key: string) => string | undefined;
  /** Injectable Supabase admin client (or any object with .rpc). Used for
   *  the dedupe RPC + outcome record RPC. */
  rpcClient?: unknown;
  /** Injectable clock. Test-only. */
  now?: () => Date;
}

export type AlertStatus = "sent" | "failed" | "skipped";

export interface AlertOutcome {
  attempted: boolean;
  deduped: boolean;
  sent: boolean;
  status?: AlertStatus;
  error?: string;
}

const DEFAULT_WINDOW_MINUTES = 45;
const MAX_SUBJECT_LEN = 200;
const MAX_BODY_LEN = 8000;
const MAX_ERROR_LEN = 500;

// ---------------------------------------------------------------------------
// notifyProviderBillingUnavailable
// ---------------------------------------------------------------------------

/**
 * Fire-and-forget operator email alert for provider_billing_unavailable.
 * Returns synchronously with the outcome; callers should launch via
 * `EdgeRuntime.waitUntil(...)` to keep the parent edge function alive
 * until the alert finishes (so Resend delivery does not abort when the
 * user-facing response is committed).
 *
 * The function NEVER throws. All errors are logged and reflected in the
 * returned AlertOutcome. The user-facing error response is the caller's
 * responsibility — this function must never block it.
 */
export async function notifyProviderBillingUnavailable(
  ctx: ProviderBillingUnavailableContext,
  deps: OperatorAlertDeps = {},
): Promise<AlertOutcome> {
  const fetchImpl = deps.fetchImpl ?? ((url, init) => fetch(url, init));
  const getEnv = deps.getEnv ?? ((k: string) => Deno.env.get(k));
  const now = deps.now ?? (() => new Date());
  const occurredAt = ctx.occurredAt ?? now();

  const apiKey = getEnv("RESEND_API_KEY");
  const to = getEnv("OPERATOR_ALERT_EMAIL");
  const from = getEnv("OPERATOR_ALERT_FROM_EMAIL");

  if (!apiKey || !to || !from) {
    console.warn(
      "[operator-alert] RESEND_API_KEY, OPERATOR_ALERT_EMAIL, or " +
        "OPERATOR_ALERT_FROM_EMAIL missing; skipping alert send",
      {
        hasApiKey: Boolean(apiKey),
        hasTo: Boolean(to),
        hasFrom: Boolean(from),
      },
    );
    await recordOutcomeSafe(
      deps.rpcClient,
      ctx.stableCode,
      "skipped",
      "missing_env_vars",
    );
    return { attempted: false, deduped: false, sent: false, status: "skipped" };
  }

  // 1. Dedupe check. RPC failure does NOT block the send — surface the
  //    error in logs and proceed; the alternative would be dropping the
  //    alert on transient DB hiccups.
  let dedupeAllowed = true;
  if (deps.rpcClient) {
    try {
      const result = await (deps.rpcClient as {
        rpc: (
          name: string,
          params: Record<string, unknown>,
        ) => Promise<{ data: unknown; error?: { message?: string } | null }>;
      }).rpc("should_send_provider_billing_alert", {
        p_stable_code: ctx.stableCode,
        p_window_minutes: ctx.alertSuppressionWindowMinutes ??
          DEFAULT_WINDOW_MINUTES,
      });
      if (result?.error) {
        console.error(
          "[operator-alert] dedupe RPC failed:",
          sanitizeError(JSON.stringify(result.error)),
        );
      } else {
        dedupeAllowed = Boolean(result?.data);
      }
    } catch (err) {
      console.error(
        "[operator-alert] dedupe RPC threw:",
        sanitizeError(err instanceof Error ? err.message : String(err)),
      );
    }
  }

  if (!dedupeAllowed) {
    console.log(
      `[operator-alert] dedupe suppressed alert for ${ctx.stableCode}`,
    );
    return {
      attempted: false,
      deduped: true,
      sent: false,
      status: "skipped",
    };
  }

  // 2. Build sanitized subject + body.
  const subject = sanitizeSubject(
    `[CathedralOS] OpenAI provider billing unavailable (${ctx.stableCode})`,
  );
  const body = formatAlertBody(ctx, occurredAt);

  // 3. Send via Resend.
  try {
    const response = await fetchImpl("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({ from, to: [to], subject, text: body }),
    });
    if (!response.ok) {
      const errorText = await response.text().catch(() => "");
      const safe = sanitizeError(errorText);
      console.error(
        `[operator-alert] Resend returned ${response.status}: ${safe}`,
      );
      const outcome: AlertOutcome = {
        attempted: true,
        deduped: false,
        sent: false,
        status: "failed",
        error: `HTTP ${response.status}`,
      };
      await recordOutcomeSafe(
        deps.rpcClient,
        ctx.stableCode,
        "failed",
        outcome.error,
      );
      return outcome;
    }
    console.log(`[operator-alert] alert sent for ${ctx.stableCode}`);
    const outcome: AlertOutcome = {
      attempted: true,
      deduped: false,
      sent: true,
      status: "sent",
    };
    await recordOutcomeSafe(deps.rpcClient, ctx.stableCode, "sent", undefined);
    return outcome;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const safe = sanitizeError(msg);
    console.error(`[operator-alert] Resend fetch threw: ${safe}`);
    const outcome: AlertOutcome = {
      attempted: true,
      deduped: false,
      sent: false,
      status: "failed",
      error: msg,
    };
    await recordOutcomeSafe(deps.rpcClient, ctx.stableCode, "failed", msg);
    return outcome;
  }
}

// ---------------------------------------------------------------------------
// Failure-isolated outcome recorder. Never throws — telemetry must not
// crash the alert path or the user-facing response.
// ---------------------------------------------------------------------------

async function recordOutcomeSafe(
  rpcClient: unknown,
  stableCode: string,
  status: AlertStatus,
  error: string | undefined,
): Promise<void> {
  if (!rpcClient) return;
  try {
    await (rpcClient as {
      rpc: (
        name: string,
        params: Record<string, unknown>,
      ) => Promise<{ error?: { message?: string } | null }>;
    }).rpc("record_provider_billing_alert_outcome", {
      p_stable_code: stableCode,
      p_status: status,
      p_error: error ?? null,
    });
  } catch (err) {
    console.error(
      "[operator-alert] recordOutcome RPC threw:",
      sanitizeError(err instanceof Error ? err.message : String(err)),
    );
  }
}

// ---------------------------------------------------------------------------
// Body / subject formatters
// ---------------------------------------------------------------------------

function formatAlertBody(
  ctx: ProviderBillingUnavailableContext,
  occurredAt: Date,
): string {
  const env = ctx.environment ?? "production";
  const lines: string[] = [];
  lines.push("CathedralOS operator alert");
  lines.push("============================");
  lines.push(`Stable internal code: ${ctx.stableCode}`);
  lines.push(`Environment:         ${env}`);
  lines.push(`Occurred at:         ${occurredAt.toISOString()}`);
  lines.push("");
  lines.push(`Upstream provider code: ${
    sanitizeField(ctx.upstreamProviderCode) ?? "(unknown)"
  }`);
  lines.push(`Upstream status:       ${ctx.upstreamStatus ?? "(unknown)"}`);
  lines.push(`Upstream message:      ${
    sanitizeField(ctx.upstreamMessage) ?? "(unknown)"
  }`);
  lines.push(`Provider model:        ${
    sanitizeField(ctx.providerModel) ?? "(unknown)"
  }`);
  lines.push(`Selected model:        ${
    sanitizeField(ctx.selectedModel) ?? "(unknown)"
  }`);
  lines.push("");
  lines.push(`Request ID:            ${sanitizeField(ctx.requestID) ?? "(unknown)"}`);
  lines.push(`Chapter run ID:        ${sanitizeField(ctx.chapterRunID) ?? "(n/a)"}`);
  lines.push(`Outline ID:            ${sanitizeField(ctx.outlineID) ?? "(n/a)"}`);
  lines.push(`Project ID:            ${sanitizeField(ctx.projectID) ?? "(n/a)"}`);
  lines.push("");
  lines.push(
    "Automatic retry was suppressed: this is a non-retryable condition.",
  );
  lines.push("");
  lines.push(
    "This alert is dedupe'd; subsequent occurrences within the suppression",
  );
  lines.push(
    "window are recorded in provider_billing_alerts.alert_count without",
  );
  lines.push("firing another email.");
  return lines.join("\n").slice(0, MAX_BODY_LEN);
}

function sanitizeSubject(s: string): string {
  return s.replace(/[\r\n]+/g, " ").slice(0, MAX_SUBJECT_LEN);
}

function sanitizeError(s: string): string {
  return s.replace(/[\r\n]+/g, " ").slice(0, MAX_ERROR_LEN);
}

/** Drop CR/LF and cap length. Null/undefined pass through. */
function sanitizeField(s: string | null | undefined): string | null {
  if (s == null) return null;
  return String(s).replace(/[\r\n]+/g, " ").slice(0, MAX_ERROR_LEN);
}
