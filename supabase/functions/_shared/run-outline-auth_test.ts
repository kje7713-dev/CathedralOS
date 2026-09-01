import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  createRunOutlineToken,
  verifyRunOutlineToken,
} from "./run-outline-auth.ts";

Deno.test("Run All token binds the user, run, and section", async () => {
  const token = await createRunOutlineToken(
    "test-secret",
    "user-1",
    "run-1",
    "section-1",
  );
  assertEquals(
    await verifyRunOutlineToken(
      "test-secret",
      token,
      "user-1",
      "run-1",
      "section-1",
    ),
    true,
  );
  assertEquals(
    await verifyRunOutlineToken(
      "test-secret",
      token,
      "user-1",
      "run-1",
      "section-2",
    ),
    false,
  );
});
