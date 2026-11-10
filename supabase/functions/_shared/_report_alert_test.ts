import { assert, assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { notifySharedOutputReport } from "./_report_alert.ts";

Deno.test("notifySharedOutputReport sends a readable operator alert", async () => {
  let requestBody: Record<string, unknown> | null = null;

  await notifySharedOutputReport(
    {
      reportID: "report-1",
      sharedOutputID: "output-1",
      sharedOutputURL: "https://storydonkey.example/shared/output-1",
      shareTitle: "A public story",
      creatorDisplayName: "StoryDonkey Review Publisher",
      reason: "inappropriate_content",
      details: "The report details.",
      createdAt: "2026-11-10T19:03:01Z",
    },
    {
      getEnv: (key) => ({
        RESEND_API_KEY: "re_test",
        OPERATOR_ALERT_EMAIL: "operator@example.test",
        OPERATOR_ALERT_FROM_EMAIL: "alerts@example.test",
      }[key]),
      fetchImpl: async (_input, init) => {
        requestBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response(null, { status: 200 });
      },
    },
  );

  assert(requestBody !== null);
  const capturedBody = requestBody as Record<string, unknown>;
  assertEquals(capturedBody.subject, "StoryDonkey public-content report: inappropriate_content");
  const text = String(capturedBody.text);
  assertStringIncludes(text, "Title: A public story\nCreator: StoryDonkey Review Publisher");
  assertStringIncludes(text, "Reason: inappropriate_content\nDetails: The report details.");
  assertEquals(text.includes("\\n"), false);
});
