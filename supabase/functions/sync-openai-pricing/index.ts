import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handler } from "./_handler.ts";

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

Deno.serve((req: Request) => {
  const authorized = Boolean(
    serviceRoleKey &&
      req.headers.get("Authorization") === `Bearer ${serviceRoleKey}`,
  );
  const db = createClient(supabaseUrl, serviceRoleKey);
  return handler(req, { db, authorized });
});
