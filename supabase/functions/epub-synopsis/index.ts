import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { OpenAIProvider } from "../generate-story/_provider.ts";
import { SupabaseCreditStore } from "../generate-story/_credits.ts";
import { handleSynopsis, validateSynopsisRequest } from "./_handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const adminClient = createClient(url, serviceKey, {
  auth: { persistSession: false },
});
const provider = new OpenAIProvider(
  Deno.env.get("OPENAI_API_KEY")!,
  Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5-mini",
);
const deps = {
  adminClient,
  provider,
  creditStore: new SupabaseCreditStore(adminClient),
  defaultModel: Deno.env.get("OPENAI_MODEL_DEFAULT") ?? "gpt-5-mini",
};

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ errorCode: "method_not_allowed" }), {
      status: 405,
      headers,
    });
  }
  const authorization = request.headers.get("Authorization");
  if (!authorization) {
    return new Response(JSON.stringify({ errorCode: "unauthorized" }), {
      status: 401,
      headers,
    });
  }
  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) {
    return new Response(JSON.stringify({ errorCode: "unauthorized" }), {
      status: 401,
      headers,
    });
  }
  try {
    const body = validateSynopsisRequest(await request.json());
    const response = await handleSynopsis(data.user.id, body, deps);
    return new Response(response.body, { status: response.status, headers });
  } catch (error) {
    return new Response(
      JSON.stringify({
        errorCode: "invalid_request",
        message: error instanceof Error ? error.message : String(error),
      }),
      { status: 400, headers },
    );
  }
});
