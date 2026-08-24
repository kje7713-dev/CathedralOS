// =============================================================================
// coherence-check Edge Function (Coherence v2.1 — general-purpose, 2026-08-20,
// Phase A refactor onto _shared/billable-llm.ts 2026-08-24, revision
// 2026-08-24 extracts handler into _handler.ts)
//
// Thin Deno.serve entry point. The handler logic lives in _handler.ts
// (import-safe; no Deno.serve at module top level) so unit tests can
// exercise the full auth-resolved -> validate -> billable-LLM -> audit
// -> response flow without importing index.ts.
//
// Auth: requires a valid Supabase user JWT in the Authorization header.
// user_id is derived EXCLUSIVELY from the verified JWT — never from the body.
// Cost: server-side charged via the shared billable-LLM runner
//       (purpose="coherence-check", action="check"). Uses the SAME pricing
//       model as generate-story (computeActualChargeCredits + snapshotPricing).
//       Idempotency: server-derived from request fingerprint + 60s minute
//       bucket. Partial unique index on (user_id, idempotency_key) prevents
//       duplicate usage rows from double-taps / network retries.
//
// Request:  POST {
//             output_text:     string,
//             current_section: CurrentSection | null,
//             prior_canon:     { sections: CanonSection[] },
//             project_id?:     string   // for llm_prompts logging only
//           }
// Response: 200 {
//             warnings: [{ reason: string, severity: "warn" | "high" }],
//             diagnostics: {
//               raw_content: string,
//               finish_reason: string,
//               model: string,
//               pre_filter_count: number,
//               post_filter_count: number,
//               prompt_tokens: number | null,
//               completion_tokens: number | null,
//             }
//           }
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type CoherenceConfig,
  type CoherenceRuntimeDeps,
  handleCoherenceCheck,
} from "./_handler.ts";
import { validateRequest } from "./_validation.ts";
import { GenerationModel } from "../generate-story/_generation_models.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { LLMProvider, OpenAIProvider } from "../generate-story/_provider.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  "";
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const OPENAI_MODEL_DEFAULT = Deno.env.get("OPENAI_MODEL_DEFAULT") ??
  "gpt-5-mini";
const COHERENCE_TEMPERATURE = 0.2;
const COHERENCE_MAX_COMPLETION_TOKENS = 1500;

// Service-role admin client — passed to the shared runner for billing writes
// AND used by the handler for model lookup + llm_prompts audit insert.
const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const creditStore = new SupabaseCreditStore(adminClient);

// LLM provider for the coherence feature. Uses chat/completions + Structured
// Outputs via the 4th options argument (LLMProviderOptions.responseFormat).
const provider: LLMProvider = new OpenAIProvider(
  OPENAI_API_KEY,
  OPENAI_MODEL_DEFAULT,
);

// Fallback model row when the env-var-provided model isn\'t in
// generation_models. Used for snapshotPricing() only — the actual LLM call
// still uses OPENAI_MODEL_DEFAULT.
const FALLBACK_MODEL: GenerationModel = {
  id: "__fallback__",
  provider: "openai",
  provider_model: OPENAI_MODEL_DEFAULT,
  display_name: OPENAI_MODEL_DEFAULT,
  description:
    "Fallback pricing for coherence-check when model not in generation_models",
  input_credit_rate: 0,
  output_credit_rate: 0,
  minimum_charge_credits: 1,
  max_output_tokens: null,
  enabled: true,
  // PR-372: cache-write rate (1.25× input standard; coherence-check
  // doesn't actually hit cache in production, but the snapshot is
  // populated for billing-correctness when cacheWrite tokens appear).
  provider_cache_write_usd_per_1m: 0,
  // PR-372: coherence-check uses chat/completions which doesn't support
  // explicit cache mode. Default to "implicit" so prompt_cache_key is
  // sent (cache writes / reads never materialize here, so this is safe).
  cacheMode: "implicit",
  sort_order: 0,
  billing_multiplier: 2.0,
  provider_input_usd_per_1m: 0.40,
  provider_cached_input_usd_per_1m: 0.10,
  provider_output_usd_per_1m: 1.60,
  pricing_effective_at: new Date().toISOString(),
};

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const corsResponse = (body: string, init: ResponseInit = {}): Response =>
  new Response(body, {
    ...init,
    headers: { ...CORS_HEADERS, ...(init.headers ?? {}) },
  });

const errorResponse = (
  code: string,
  message: string,
  status: number,
): Response =>
  corsResponse(JSON.stringify({ errorCode: code, message }), { status });

const RUNTIME_DEPS: CoherenceRuntimeDeps = {
  adminClient,
  provider,
  creditStore,
};

const RUNTIME_CONFIG: CoherenceConfig = {
  openaiModelDefault: OPENAI_MODEL_DEFAULT,
  fallbackModel: FALLBACK_MODEL,
  maxCompletionTokens: COHERENCE_MAX_COMPLETION_TOKENS,
  temperature: COHERENCE_TEMPERATURE,
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return corsResponse("", { status: 204 });
  if (req.method !== "POST") {
    return errorResponse("method_not_allowed", "POST required", 405);
  }

  // 1. Auth via user JWT.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return errorResponse("unauthorized", "missing Authorization header", 401);
  }
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) {
    return errorResponse("unauthorized", "invalid JWT", 401);
  }
  const userId = userData.user.id;

  // 2. Parse + validate the request body.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return errorResponse("invalid_body", "JSON body required", 400);
  }
  const validation = validateRequest(body);
  if (!validation.ok) {
    return errorResponse("invalid_body", validation.error, 400);
  }

  // 3. Delegate to the import-safe handler (testable without Deno.serve).
  return await handleCoherenceCheck(
    userId,
    validation.request,
    RUNTIME_DEPS,
    RUNTIME_CONFIG,
  );
});
