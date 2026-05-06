// =============================================================================
// index.ts — get-credit-state Supabase Edge Function
//
// Returns the authoritative credit state for the authenticated user.
// Use this for Account/Settings display in the iOS app.
//
// Response shape:
//   {
//     planName:                string,
//     isPro:                   boolean,
//     monthlyCreditAllowance:  number,
//     purchasedCreditBalance:  number,
//     availableCredits:        number,
//     currentPeriodEnd:        string | null,   // ISO-8601 or null
//     recentLedger:            LedgerEntry[]    // most recent 10 entries
//   }
//
// LedgerEntry:
//   { id, delta, reason, created_at }
//
// Secrets required (auto-injected by Supabase):
//   SUPABASE_URL
//   SUPABASE_ANON_KEY
//   SUPABASE_SERVICE_ROLE_KEY
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  FREE_TIER_MONTHLY_ALLOWANCE,
  type UserEntitlement,
} from "../generate-story/_credits.ts";

// ---------------------------------------------------------------------------
// CORS headers
// ---------------------------------------------------------------------------

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

function corsResponse(body: string, init: ResponseInit = {}): Response {
  return new Response(body, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...(init.headers ?? {}),
    },
  });
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "GET" && req.method !== "POST") {
    return corsResponse(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405 },
    );
  }

  // -------------------------------------------------------------------------
  // Auth
  // -------------------------------------------------------------------------

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return corsResponse(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401 },
    );
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseURL || !supabaseAnonKey || !serviceRoleKey) {
    return corsResponse(
      JSON.stringify({ error: "Server configuration error" }),
      { status: 500 },
    );
  }

  // Verify JWT via user-scoped client.
  const userClient = createClient(supabaseURL, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const {
    data: { user },
    error: authError,
  } = await userClient.auth.getUser();

  if (authError || !user) {
    return corsResponse(
      JSON.stringify({ error: "Unauthorized" }),
      { status: 401 },
    );
  }

  const userId = user.id;

  // -------------------------------------------------------------------------
  // Load entitlement via service-role client
  // (bypasses RLS so we can upsert a default row for new users)
  // -------------------------------------------------------------------------

  const adminClient = createClient(supabaseURL, serviceRoleKey);

  // Try to load existing entitlement.
  const { data: existing, error: loadError } = await adminClient
    .from("user_entitlements")
    .select("*")
    .eq("user_id", userId)
    .single();

  let entitlement: UserEntitlement;

  if (!loadError && existing) {
    entitlement = existing as UserEntitlement;
  } else {
    // New user — upsert a free-tier default.
    const defaultRow = {
      user_id: userId,
      plan_name: "free",
      is_pro: false,
      monthly_credit_allowance: FREE_TIER_MONTHLY_ALLOWANCE,
      purchased_credit_balance: 0,
      current_period_start: null,
      current_period_end: null,
      entitlement_source: "monthly_grant",
    };

    const { data: upserted, error: upsertError } = await adminClient
      .from("user_entitlements")
      .upsert(defaultRow, { onConflict: "user_id" })
      .select("*")
      .single();

    if (upsertError || !upserted) {
      console.error("user_entitlements upsert error:", upsertError);
      // Return in-memory defaults so the app still gets a useful response.
      entitlement = {
        ...defaultRow,
        updated_at: new Date().toISOString(),
      };
    } else {
      entitlement = upserted as UserEntitlement;
    }
  }

  // -------------------------------------------------------------------------
  // Load recent ledger entries (most recent 10, newest first)
  // -------------------------------------------------------------------------

  const { data: ledger } = await adminClient
    .from("user_credit_ledger")
    .select("id, delta, reason, created_at")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(10);

  // -------------------------------------------------------------------------
  // Build response
  // -------------------------------------------------------------------------

  const availableCredits =
    entitlement.monthly_credit_allowance + entitlement.purchased_credit_balance;

  return corsResponse(
    JSON.stringify({
      planName: entitlement.plan_name,
      isPro: entitlement.is_pro,
      monthlyCreditAllowance: entitlement.monthly_credit_allowance,
      purchasedCreditBalance: entitlement.purchased_credit_balance,
      availableCredits,
      currentPeriodEnd: entitlement.current_period_end,
      recentLedger: ledger ?? [],
    }),
    { status: 200 },
  );
});
