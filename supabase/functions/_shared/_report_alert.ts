export interface ReportAlertContext {
  reportID: string;
  sharedOutputID: string;
  reason: string;
  createdAt: string;
}

/** Best-effort operator alert. Report persistence is never coupled to email. */
export async function notifySharedOutputReport(
  context: ReportAlertContext,
  deps: {
    fetchImpl?: typeof fetch;
    getEnv?: (key: string) => string | undefined;
  } = {},
): Promise<void> {
  const getEnv = deps.getEnv ?? ((key: string) => Deno.env.get(key));
  const apiKey = getEnv("RESEND_API_KEY");
  const to = getEnv("OPERATOR_ALERT_EMAIL");
  const from = getEnv("OPERATOR_ALERT_FROM_EMAIL");
  if (!apiKey || !to || !from) {
    console.warn(
      "[report-alert] email configuration missing; report remains persisted",
    );
    return;
  }
  const fetchImpl = deps.fetchImpl ?? fetch;
  try {
    const response = await fetchImpl("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        subject: "StoryDonkey public-content report",
        text: [
          `Report ID: ${context.reportID}`,
          `Shared output ID: ${context.sharedOutputID}`,
          `Reason: ${context.reason}`,
          `Timestamp: ${context.createdAt}`,
        ].join("\\n"),
      }),
    });
    if (!response.ok) {
      console.error(`[report-alert] Resend returned ${response.status}`);
    }
  } catch (error) {
    console.error("[report-alert] send failed:", error);
  }
}
