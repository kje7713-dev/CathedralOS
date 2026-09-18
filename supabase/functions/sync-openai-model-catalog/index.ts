import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handler } from "./_handler.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";

Deno.serve((req: Request) => {
  const auth = req.headers.get("Authorization");
  const authorized = Boolean(
    serviceRoleKey && auth === `Bearer ${serviceRoleKey}`,
  );
  const db = createClient(supabaseUrl, serviceRoleKey);
  return handler(req, { db, authorized, apiKey: openaiKey });
});
