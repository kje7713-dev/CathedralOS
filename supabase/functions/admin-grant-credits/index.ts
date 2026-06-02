import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  FREE_TIER_MONTHLY_ALLOWANCE,
  type UserEntitlement,
} from "../generate-story/_credits.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface GrantRequest {
  targetUserID: string;
  amount: number;
  reason?: string;
}

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

function parseAdminUserIDs(raw: string | undefined): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value.length > 0),
  );
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

async function loadOrCreateEntitlement(
  adminClient: ReturnType<typeof createClient>,
  userId: string,
): Promise<UserEntitlement> {
  const { data: existing, error: loadError } = await adminClient
    .from("user_entitlements")
    .select("*")
    .eq("user_id", userId)
    .single();

  if (!loadError && existing) {
    return existing as UserEntitlement;
  }

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
    throw new Error(
      upsertError?.message ??
        "Could not create default entitlement for target user.",
    );
  }

  return upserted as UserEntitlement;
}

async function buildCreditStateResponse(
  adminClient: ReturnType<typeof createClient>,
  entitlement: UserEntitlement,
  isAdmin: boolean,
): Promise<Response> {
  const { data: ledger } = await adminClient
    .from("user_credit_ledger")
    .select("id, delta, reason, created_at")
    .eq("user_id", entitlement.user_id)
    .order("created_at", { ascending: false })
    .limit(10);

  return corsResponse(
    JSON.stringify({
      planName: entitlement.plan_name,
      isPro: entitlement.is_pro,
      monthlyCreditAllowance: entitlement.monthly_credit_allowance,
      purchasedCreditBalance: entitlement.purchased_credit_balance,
      availableCredits: entitlement.monthly_credit_allowance +
        entitlement.purchased_credit_balance,
      isAdmin,
      currentPeriodEnd: entitlement.current_period_end,
      recentLedger: ledger ?? [],
    }),
    { status: 200 },
  );
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "POST") {
    return corsResponse(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405 },
    );
  }

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
  const adminUserIDs = parseAdminUserIDs(Deno.env.get("ADMIN_USER_IDS"));

  if (!supabaseURL || !supabaseAnonKey || !serviceRoleKey) {
    return corsResponse(
      JSON.stringify({ error: "Server configuration error" }),
      { status: 500 },
    );
  }

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

  if (!adminUserIDs.has(user.id)) {
    return corsResponse(
      JSON.stringify({ error: "Forbidden" }),
      { status: 403 },
    );
  }

  let payload: GrantRequest;
  try {
    payload = await req.json() as GrantRequest;
  } catch {
    return corsResponse(
      JSON.stringify({ error: "Invalid JSON body" }),
      { status: 400 },
    );
  }

  const targetUserID = payload.targetUserID?.trim();
  const amount = payload.amount;
  const reason = payload.reason?.trim() || "developer_test_grant";

  if (!targetUserID || !isUUID(targetUserID)) {
    return corsResponse(
      JSON.stringify({ error: "targetUserID must be a valid UUID" }),
      { status: 400 },
    );
  }

  if (!Number.isInteger(amount) || amount <= 0) {
    return corsResponse(
      JSON.stringify({ error: "amount must be a positive integer" }),
      { status: 400 },
    );
  }

  const adminClient = createClient(supabaseURL, serviceRoleKey);

  let entitlement: UserEntitlement;
  try {
    entitlement = await loadOrCreateEntitlement(adminClient, targetUserID);
  } catch (error) {
    return corsResponse(
      JSON.stringify({
        error: error instanceof Error ? error.message : String(error),
      }),
      { status: 400 },
    );
  }

  const { error: grantInsertError } = await adminClient
    .from("credit_grants")
    .insert({
      user_id: targetUserID,
      granted_by: user.id,
      amount,
      reason,
    });

  if (grantInsertError) {
    console.error("credit_grants insert error:", grantInsertError);
    return corsResponse(
      JSON.stringify({ error: "Failed to record credit grant" }),
      { status: 500 },
    );
  }

  const updatedPurchasedBalance = entitlement.purchased_credit_balance + amount;
  const { data: updatedEntitlement, error: updateError } = await adminClient
    .from("user_entitlements")
    .update({
      purchased_credit_balance: updatedPurchasedBalance,
      entitlement_source: "admin_adjustment",
    })
    .eq("user_id", targetUserID)
    .select("*")
    .single();

  if (updateError || !updatedEntitlement) {
    console.error("user_entitlements update error:", updateError);
    return corsResponse(
      JSON.stringify({ error: "Failed to update entitlement balance" }),
      { status: 500 },
    );
  }

  const { error: ledgerError } = await adminClient
    .from("user_credit_ledger")
    .insert({
      user_id: targetUserID,
      delta: amount,
      reason,
      metadata: {
        granted_by: user.id,
        source: "admin-grant-credits",
      },
    });

  if (ledgerError) {
    console.error("user_credit_ledger insert error:", ledgerError);
    return corsResponse(
      JSON.stringify({ error: "Failed to record credit ledger entry" }),
      { status: 500 },
    );
  }

  return await buildCreditStateResponse(
    adminClient,
    updatedEntitlement as UserEntitlement,
    true,
  );
}

Deno.serve((req: Request) => handler(req));
