import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  SupabaseGenerationModelStore,
  type GenerationModelStore,
} from "../generate-story/_generation_models.ts";

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

interface HandlerDependencies {
  modelStore?: GenerationModelStore;
  authenticatedUserId?: string;
}

export async function handler(req: Request, deps: HandlerDependencies = {}): Promise<Response> {
  const { modelStore, authenticatedUserId } = deps;
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method !== "GET") {
    return corsResponse(JSON.stringify({ status: "failed", error: "Method not allowed" }), {
      status: 405,
    });
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseURL || !serviceRoleKey) {
    return corsResponse(
      JSON.stringify({
        status: "failed",
        errorCode: "backend_config_missing",
        error: "Server configuration error",
      }),
      { status: 500 },
    );
  }

  if (!authenticatedUserId) {
    const authHeader = req.headers.get("Authorization");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!authHeader || !supabaseAnonKey) {
      return corsResponse(
        JSON.stringify({ status: "failed", errorCode: "unauthenticated", error: "Unauthorized" }),
        { status: 401 },
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
        JSON.stringify({ status: "failed", errorCode: "unauthenticated", error: "Unauthorized" }),
        { status: 401 },
      );
    }
  }

  const effectiveModelStore = modelStore ??
    new SupabaseGenerationModelStore(createClient(supabaseURL, serviceRoleKey));
  const models = await effectiveModelStore.listEnabledModels();
  return corsResponse(JSON.stringify({ status: "complete", models }), { status: 200 });
}

Deno.serve((req) => handler(req));
