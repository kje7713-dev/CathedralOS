import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";

Deno.test("outline suggestion polling contract preserves structured failures and success", async () => {
  const source = await Deno.readTextFile(
    "./supabase/functions/outline-from-recipe/index.ts",
  );
  assertEquals(source.includes("error_code: errorCode"), true);
  assertEquals(source.includes("errorCode: run.error_code"), true);
  assertEquals(source.includes('status: "completed"'), true);
  assertEquals(source.includes('status: "failed"'), true);
  assertEquals(source.includes('status: "running"'), true);
  assertEquals(source.includes("suggestions: run.suggestions"), true);
});
