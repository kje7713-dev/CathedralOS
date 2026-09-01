import {
  checkCredits,
  type CreditCheckResult,
  type UserEntitlement,
} from "../generate-story/_credits.ts";

/**
 * chapter_runs.credits_reserved is an integer for compatibility with the iOS
 * RunOutlineStatus model. Keep the exact estimate for pricing decisions, but
 * reserve conservatively so persistence can never truncate the estimate.
 */
export function prepareCreditReservation(
  estimatedCost: number,
  entitlement: UserEntitlement,
): { reservedCredits: number; check: CreditCheckResult } {
  const reservedCredits = Math.ceil(estimatedCost);
  return {
    reservedCredits,
    check: checkCredits(entitlement, reservedCredits),
  };
}
