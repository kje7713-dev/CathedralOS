import { buildMessages, validateSynopsisRequest } from "./_handler.ts";

Deno.test("synopsis request validation rejects missing story source", () => {
  let failed = false;
  try {
    validateSynopsisRequest({
      project_id: "p",
      title: "Book",
      source_text: " ",
    });
  } catch (error) {
    failed = error instanceof Error && error.message === "source_text required";
  }
  if (!failed) throw new Error("expected source_text validation failure");
});

Deno.test("synopsis prompt requests bounded, spoiler-free back-cover copy", () => {
  const messages = buildMessages({
    action: "generate",
    project_id: "p",
    title: "The Glass Orchard",
    source_text: "A story about an orchard keeper and a dangerous inheritance.",
  });
  const system = messages[0].content;
  if (!system.includes("80 to 180 words")) {
    throw new Error("word range missing");
  }
  if (!system.includes("without summarizing the ending")) {
    throw new Error("spoiler rule missing");
  }
  if (!system.includes("Return only one polished synopsis")) {
    throw new Error("plain-text rule missing");
  }
});
