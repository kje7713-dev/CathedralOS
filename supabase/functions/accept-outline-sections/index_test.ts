import { assertEquals } from "jsr:@std/assert@1";
import { acceptRunTerminalOutcome } from "./_outcome.ts";

Deno.test("Accept All completes only after all sections and snapshot merge succeed", () => {
  assertEquals(acceptRunTerminalOutcome(0, null, null), {
    status: "completed",
    error: null,
  });
});

Deno.test("Accept All fails when snapshot merge fails after 6/6 sections", () => {
  assertEquals(
    acceptRunTerminalOutcome(
      0,
      "Could not update project snapshot: permission denied",
      null,
    ),
    {
      status: "failed",
      error: "Could not update project snapshot: permission denied",
    },
  );
});

Deno.test("Accept All preserves partial section failure details", () => {
  assertEquals(acceptRunTerminalOutcome(1, null, "Section title failed"), {
    status: "failed",
    error: "Section title failed",
  });
});
