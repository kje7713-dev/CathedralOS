// =============================================================================
// _rate_limiter.ts — Per-user rate limiting for generate-story
//
// Rate limit policy (MVP):
//   PER_MINUTE   — max requests per user per rolling 60-second window
//   PER_HOUR     — max requests per user per rolling 60-minute window
//   FAILED_HOUR  — max failed requests per user per rolling 60-minute window
//
// The limiter reads the generation_request_logs table (service-role client).
// Rate limit checks happen BEFORE the LLM provider call and credit deduction.
//
// Logging:
//   recordRequest() inserts a structured row into generation_request_logs after
//   each request completes (success or failure). Raw prompt text is never stored.
// =============================================================================

// ---------------------------------------------------------------------------
// Rate limit constants
// ---------------------------------------------------------------------------

export const RATE_LIMITS = {
  /** Maximum generation requests per rolling minute per user. */
  perMinute: 5,
  /** Maximum generation requests per rolling hour per user. */
  perHour: 30,
  /** Maximum failed generation requests per rolling hour per user.
   *  Prevents abuse via intentional repeated failures (e.g. to probe limits). */
  failedPerHour: 20,
} as const;

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

export interface RateLimitResult {
  allowed: boolean;
  /** Seconds until the user may retry. Only present when allowed is false. */
  retryAfterSeconds?: number;
}

export interface RequestLogParams {
  requestId: string;
  action: string;
  generationLengthMode: string;
  outputBudget: number;
  status: string;
  errorCode?: string;
  errorMessage?: string;
  modelName?: string;
  inputTokens?: number;
  outputTokens?: number;
  durationMs?: number;
}

// ---------------------------------------------------------------------------
// RateLimitStore interface
// ---------------------------------------------------------------------------

export interface RateLimitStore {
  /**
   * Checks whether the user has exceeded any rate limit.
   * Returns { allowed: true } if the request may proceed, or
   * { allowed: false, retryAfterSeconds } when a limit is hit.
   */
  checkLimits(userId: string): Promise<RateLimitResult>;

  /**
   * Inserts a structured metadata row into generation_request_logs.
   * Call once per request after the outcome is known.
   * Never includes raw prompt text.
   */
  recordRequest(userId: string, params: RequestLogParams): Promise<void>;
}

// ---------------------------------------------------------------------------
// SupabaseRateLimitStore — production implementation
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
export class SupabaseRateLimitStore implements RateLimitStore {
  // deno-lint-ignore no-explicit-any
  private readonly db: any;

  // deno-lint-ignore no-explicit-any
  constructor(adminClient: any) {
    this.db = adminClient;
  }

  async checkLimits(userId: string): Promise<RateLimitResult> {
    const now = Date.now();
    const oneMinuteAgo = new Date(now - 60_000).toISOString();
    const oneHourAgo = new Date(now - 3_600_000).toISOString();

    // Per-minute check
    const { count: minuteCount, error: minuteError } = await this.db
      .from("generation_request_logs")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .gte("created_at", oneMinuteAgo);

    if (minuteError) {
      // If we cannot read the rate limit table, fail open (allow) to avoid
      // blocking legitimate users due to a transient DB error.
      console.error("rate_limiter: minute count error:", minuteError);
      return { allowed: true };
    }

    if ((minuteCount ?? 0) >= RATE_LIMITS.perMinute) {
      return { allowed: false, retryAfterSeconds: 60 };
    }

    // Per-hour check
    const { count: hourCount, error: hourError } = await this.db
      .from("generation_request_logs")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .gte("created_at", oneHourAgo);

    if (hourError) {
      console.error("rate_limiter: hour count error:", hourError);
      return { allowed: true };
    }

    if ((hourCount ?? 0) >= RATE_LIMITS.perHour) {
      return { allowed: false, retryAfterSeconds: 3600 };
    }

    // Failed-per-hour check (anti-abuse)
    const { count: failedCount, error: failedError } = await this.db
      .from("generation_request_logs")
      .select("id", { count: "exact", head: true })
      .eq("user_id", userId)
      .neq("status", "success")
      .gte("created_at", oneHourAgo);

    if (failedError) {
      console.error("rate_limiter: failed count error:", failedError);
      return { allowed: true };
    }

    if ((failedCount ?? 0) >= RATE_LIMITS.failedPerHour) {
      return { allowed: false, retryAfterSeconds: 3600 };
    }

    return { allowed: true };
  }

  async recordRequest(userId: string, params: RequestLogParams): Promise<void> {
    const { error } = await this.db
      .from("generation_request_logs")
      .insert({
        user_id: userId,
        request_id: params.requestId,
        action: params.action,
        generation_length_mode: params.generationLengthMode,
        output_budget: params.outputBudget,
        status: params.status,
        error_code: params.errorCode ?? null,
        error_message: params.errorMessage ?? null,
        model_name: params.modelName ?? null,
        input_tokens: params.inputTokens ?? null,
        output_tokens: params.outputTokens ?? null,
        duration_ms: params.durationMs ?? null,
      });

    if (error) {
      // Log the error but do not fail the request — observability is best-effort.
      console.error("rate_limiter: recordRequest insert error:", error);
    }
  }
}
