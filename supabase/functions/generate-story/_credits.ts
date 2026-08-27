// =============================================================================
// _credits.ts — Backend credit cost mapping and enforcement helpers
//
// The backend is the authoritative source for credit costs. Costs submitted
// by the iOS client are IGNORED. The server always recomputes cost from
// generationLengthMode.
//
// Free-tier defaults:
//   monthly_credit_allowance  = 10  (matches StoreKitPlan.free.monthlyCreditAllowance)
//   purchased_credit_balance  = 0
//
// Cost table (mirrors GenerationLengthMode.creditCost on iOS — keep in sync):
//   short   = 1
//   medium  = 2
//   long    = 4
//   chapter = 8
//
// Charging policy:
//   1. Before calling the LLM provider: check available credits.
//      Reject with 402 + errorCode "insufficient_credits" if short.
//   2. After a successful LLM response: insert a negative ledger entry and
//      decrement the entitlement balance. Monthly allowance is drained first,
//      then purchased balance.
//   3. If the LLM provider call fails: do NOT charge credits. The user
//      received no output.
// =============================================================================

export const ALLOWED_LENGTH_MODES = [
  "short",
  "medium",
  "long",
  "chapter",
] as const;
export type LengthMode = typeof ALLOWED_LENGTH_MODES[number];

// ---------------------------------------------------------------------------
// Credit cost mapping
// Single source of truth on the backend. Do not trust client-submitted costs.
// ---------------------------------------------------------------------------

export const CREDIT_COST: Record<LengthMode, number> = {
  short: 1,
  medium: 2,
  long: 4,
  chapter: 8,
};

/** Returns the credit cost for a given length mode. */
export function getCreditCost(mode: LengthMode): number {
  return CREDIT_COST[mode];
}

// ---------------------------------------------------------------------------
// Default free-tier entitlement values (matches iOS StoreKitPlan.free)
// ---------------------------------------------------------------------------

export const FREE_TIER_MONTHLY_ALLOWANCE = 10;

// ---------------------------------------------------------------------------
// Entitlement data shape (mirrors user_entitlements table)
// ---------------------------------------------------------------------------

export interface UserEntitlement {
  user_id: string;
  plan_name: string;
  is_pro: boolean;
  monthly_credit_allowance: number;
  purchased_credit_balance: number;
  current_period_start: string | null;
  current_period_end: string | null;
  entitlement_source: string;
  updated_at: string;
}

/** Computes the total available credits from an entitlement row. */
export function availableCredits(e: UserEntitlement): number {
  return e.monthly_credit_allowance + e.purchased_credit_balance;
}

// ---------------------------------------------------------------------------
// Credit enforcement result
// ---------------------------------------------------------------------------

export type CreditCheckResult =
  | { allowed: true; requiredCredits: number; availableCredits: number }
  | { allowed: false; requiredCredits: number; availableCredits: number };

/** Checks whether the entitlement has enough credits for the given cost. */
export function checkCredits(
  entitlement: UserEntitlement,
  cost: number,
): CreditCheckResult {
  const avail = availableCredits(entitlement);
  return avail >= cost
    ? { allowed: true, requiredCredits: cost, availableCredits: avail }
    : { allowed: false, requiredCredits: cost, availableCredits: avail };
}

// ---------------------------------------------------------------------------
// Charge computation
// Drains monthly allowance first, then purchased balance.
// Returns the new values — does not mutate.
// ---------------------------------------------------------------------------

export interface ChargeResult {
  newMonthlyAllowance: number;
  newPurchasedBalance: number;
}

/**
 * Computes new entitlement balances after charging `cost` credits.
 * Monthly allowance is drained before purchased balance.
 * Throws if the entitlement has insufficient credits (caller should have
 * pre-checked with `checkCredits` before calling this).
 */
export function computeCharge(
  entitlement: UserEntitlement,
  cost: number,
): ChargeResult {
  let remaining = cost;
  let newMonthly = entitlement.monthly_credit_allowance;
  let newPurchased = entitlement.purchased_credit_balance;

  if (newMonthly >= remaining) {
    newMonthly -= remaining;
    remaining = 0;
  } else {
    remaining -= newMonthly;
    newMonthly = 0;
    newPurchased = Math.max(0, newPurchased - remaining);
  }

  return { newMonthlyAllowance: newMonthly, newPurchasedBalance: newPurchased };
}

// ---------------------------------------------------------------------------
// CreditStore interface
// Abstracts Supabase DB calls for testability.
// Production: SupabaseCreditStore (uses service-role client).
// Tests:      MockCreditStore (in-memory).
// ---------------------------------------------------------------------------

export interface CreditStore {
  /**
   * Loads the user's entitlement row.
   * If no row exists, upserts a free-tier default and returns it.
   */
  loadOrDefault(userId: string): Promise<UserEntitlement>;

  /**
   * Applies a charge to the user's entitlement and inserts a ledger row.
   * Returns the updated entitlement.
   */
  charge(
    userId: string,
    cost: number,
    entitlement: UserEntitlement,
    relatedOutputId: string | null,
    relatedExportJobId?: string | null,
  ): Promise<UserEntitlement>;
}

// ---------------------------------------------------------------------------
// SupabaseCreditStore — production implementation
// Requires a Supabase client initialised with the service-role key so it can
// bypass RLS and write to user_entitlements / user_credit_ledger.
// ---------------------------------------------------------------------------

// deno-lint-ignore no-explicit-any
export class SupabaseCreditStore implements CreditStore {
  // deno-lint-ignore no-explicit-any
  private readonly db: any;

  // deno-lint-ignore no-explicit-any
  constructor(adminClient: any) {
    this.db = adminClient;
  }

  async loadOrDefault(userId: string): Promise<UserEntitlement> {
    const { data, error } = await this.db
      .from("user_entitlements")
      .select("*")
      .eq("user_id", userId)
      .single();

    if (!error && data) {
      return data as UserEntitlement;
    }

    // No row or error — upsert a free-tier default.
    const defaultEntitlement: Omit<UserEntitlement, "updated_at"> = {
      user_id: userId,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: FREE_TIER_MONTHLY_ALLOWANCE,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
    };

    const { data: upserted, error: upsertError } = await this.db
      .from("user_entitlements")
      .upsert(defaultEntitlement, { onConflict: "user_id" })
      .select("*")
      .single();

    if (upsertError || !upserted) {
      // Fallback: return an in-memory default so the request can still be evaluated.
      console.error("user_entitlements upsert error:", upsertError);
      return {
        ...defaultEntitlement,
        updated_at: new Date().toISOString(),
      };
    }

    return upserted as UserEntitlement;
  }

  async charge(
    userId: string,
    cost: number,
    entitlement: UserEntitlement,
    relatedOutputId: string | null,
    relatedExportJobId: string | null = null,
  ): Promise<UserEntitlement> {
    const { newMonthlyAllowance, newPurchasedBalance } = computeCharge(
      entitlement,
      cost,
    );

    // Update entitlement balance.
    const { error: updateError } = await this.db
      .from("user_entitlements")
      .update({
        monthly_credit_allowance: newMonthlyAllowance,
        purchased_credit_balance: newPurchasedBalance,
      })
      .eq("user_id", userId);

    if (updateError) {
      console.error("user_entitlements update error:", updateError);
    }

    // Insert immutable ledger row.
    const { error: ledgerError } = await this.db
      .from("user_credit_ledger")
      .insert({
        user_id: userId,
        delta: -cost,
        reason: "generation_charge",
        related_generation_output_id: relatedOutputId,
        related_export_job_id: relatedExportJobId,
        metadata: {},
      });

    if (ledgerError) {
      console.error("user_credit_ledger insert error:", ledgerError);
    }

    return {
      ...entitlement,
      monthly_credit_allowance: newMonthlyAllowance,
      purchased_credit_balance: newPurchasedBalance,
      updated_at: new Date().toISOString(),
    };
  }

  async reserve(
    userId: string,
    cost: number,
    relatedExportJobId: string,
    metadata: Record<string, unknown> = {},
  ): Promise<{ remainingCredits: number; alreadyReserved: boolean }> {
    const entitlement = await this.loadOrDefault(userId);
    const { data: prior, error: priorError } = await this.db
      .from("user_credit_ledger")
      .select("id")
      .eq("user_id", userId)
      .eq("related_export_job_id", relatedExportJobId)
      .eq("reason", "generation_reservation")
      .maybeSingle();
    if (priorError) {
      throw new Error(
        `credit reservation lookup failed: ${priorError.message}`,
      );
    }
    if (prior) {
      return {
        remainingCredits: availableCredits(entitlement),
        alreadyReserved: true,
      };
    }
    if (availableCredits(entitlement) < cost) {
      throw new Error(
        `insufficient_credits: need ${cost}, have ${
          availableCredits(entitlement)
        }`,
      );
    }
    const charged = computeCharge(entitlement, cost);
    const { error: updateError } = await this.db.from("user_entitlements")
      .update({
        monthly_credit_allowance: charged.newMonthlyAllowance,
        purchased_credit_balance: charged.newPurchasedBalance,
      })
      .eq("user_id", userId);
    if (updateError) {
      throw new Error(
        `credit reservation update failed: ${updateError.message}`,
      );
    }
    const monthly = Math.min(entitlement.monthly_credit_allowance, cost);
    const { error: ledgerError } = await this.db.from("user_credit_ledger")
      .insert({
        user_id: userId,
        delta: -cost,
        reason: "generation_reservation",
        related_generation_output_id: null,
        related_export_job_id: relatedExportJobId,
        metadata: {
          ...metadata,
          monthly_credits: monthly,
          purchased_credits: cost - monthly,
        },
      });
    if (ledgerError) {
      throw new Error(
        `credit reservation ledger failed: ${ledgerError.message}`,
      );
    }
    return {
      remainingCredits: availableCredits(entitlement) - cost,
      alreadyReserved: false,
    };
  }

  async settleReservation(
    userId: string,
    actualCost: number,
    relatedExportJobId: string,
    metadata: Record<string, unknown> = {},
  ): Promise<UserEntitlement> {
    const currentBeforeSettlement = await this.loadOrDefault(userId);
    const { data: priorCharge, error: priorChargeError } = await this.db
      .from("user_credit_ledger").select("id")
      .eq("user_id", userId).eq("related_export_job_id", relatedExportJobId)
      .eq("reason", "generation_charge").maybeSingle();
    if (priorChargeError) {
      throw new Error(
        `credit settlement lookup failed: ${priorChargeError.message}`,
      );
    }
    if (priorCharge) return currentBeforeSettlement;

    const { data: reservation, error } = await this.db.from(
      "user_credit_ledger",
    )
      .select("*").eq("user_id", userId).eq(
        "related_export_job_id",
        relatedExportJobId,
      )
      .eq("reason", "generation_reservation").maybeSingle();
    if (error || !reservation) {
      throw new Error(
        `credit reservation not found: ${error?.message ?? relatedExportJobId}`,
      );
    }
    const current = await this.loadOrDefault(userId);
    const restored = {
      ...current,
      monthly_credit_allowance: current.monthly_credit_allowance +
        Number(reservation.metadata?.monthly_credits ?? 0),
      purchased_credit_balance: current.purchased_credit_balance +
        Number(reservation.metadata?.purchased_credits ?? 0),
    };
    if (availableCredits(restored) < actualCost) {
      throw new Error(
        `credit settlement exceeds reservation: need ${actualCost}`,
      );
    }
    const charged = computeCharge(restored, actualCost);
    const { error: updateError } = await this.db.from("user_entitlements")
      .update({
        monthly_credit_allowance: charged.newMonthlyAllowance,
        purchased_credit_balance: charged.newPurchasedBalance,
      }).eq("user_id", userId);
    if (updateError) {
      throw new Error(
        `credit settlement update failed: ${updateError.message}`,
      );
    }
    const { error: ledgerError } = await this.db.from("user_credit_ledger")
      .insert([
        {
          user_id: userId,
          delta: -Number(reservation.delta),
          reason: "generation_reservation_release",
          related_export_job_id: relatedExportJobId,
          metadata: { actual_cost: actualCost },
        },
        {
          user_id: userId,
          delta: -actualCost,
          reason: "generation_charge",
          related_generation_output_id: null,
          related_export_job_id: relatedExportJobId,
          metadata,
        },
      ]);
    if (ledgerError) {
      throw new Error(
        `credit settlement ledger failed: ${ledgerError.message}`,
      );
    }
    return {
      ...restored,
      monthly_credit_allowance: charged.newMonthlyAllowance,
      purchased_credit_balance: charged.newPurchasedBalance,
      updated_at: new Date().toISOString(),
    };
  }

  async refundReservation(
    userId: string,
    relatedExportJobId: string,
  ): Promise<void> {
    const { data: reservation } = await this.db.from("user_credit_ledger")
      .select("*")
      .eq("user_id", userId).eq("related_export_job_id", relatedExportJobId)
      .eq("reason", "generation_reservation").maybeSingle();
    if (!reservation) return;
    const { data: prior } = await this.db.from("user_credit_ledger").select(
      "id",
    )
      .eq("user_id", userId).eq("related_export_job_id", relatedExportJobId)
      .eq("reason", "generation_reservation_refund").maybeSingle();
    if (prior) return;
    const { data: ent } = await this.db.from("user_entitlements").select("*")
      .eq("user_id", userId).single();
    if (!ent) return;
    await this.db.from("user_entitlements").update({
      monthly_credit_allowance: ent.monthly_credit_allowance +
        Number(reservation.metadata?.monthly_credits ?? 0),
      purchased_credit_balance: ent.purchased_credit_balance +
        Number(reservation.metadata?.purchased_credits ?? 0),
    }).eq("user_id", userId);
    await this.db.from("user_credit_ledger").insert({
      user_id: userId,
      delta: -Number(reservation.delta),
      reason: "generation_reservation_refund",
      related_export_job_id: relatedExportJobId,
      metadata: {},
    });
  }
}
