import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handler } from "./_handler.ts";
import { isAuthorized, readSupabaseSecretKey } from "./_auth.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const supabaseSecretKey = readSupabaseSecretKey(
  Deno.env.get("SUPABASE_SECRET_KEYS"),
);
const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";

Deno.serve((req: Request) => {
  const db = createClient(supabaseUrl, supabaseSecretKey);
  return handler(req, {
    db,
    authorized: isAuthorized(req, supabaseSecretKey),
    apiKey: openaiKey,
  });
});
