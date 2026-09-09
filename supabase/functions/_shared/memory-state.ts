// Canonical semantic fold used by both generate-story and run-outline.
// It deliberately treats IDs as authoritative and falls back to semantic keys
// only for legacy rows that predate server-owned lifecycle IDs.
export function formatCanonicalProjectState(
  scenes: Array<Record<string, unknown>>,
  previousScene?: Record<string, unknown>,
  maxChars = 24_000,
): string {
  const characters = new Map<string, Record<string, unknown>>();
  const threads = new Map<string, Record<string, unknown>>();
  const facts = new Map<string, Record<string, unknown>>();
  const loops = new Map<string, Record<string, unknown>>();
  const key = (value: unknown) =>
    String(value ?? "").toLocaleLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const lines = ["## Project State", ""];
  if (previousScene) {
    lines.push("## Previous Canonical Section", "");
    if (
      typeof previousScene.extracted_summary === "string" &&
      previousScene.extracted_summary
    ) lines.push(`Summary: ${previousScene.extracted_summary}`, "");
    if (
      previousScene.scene_ending_state &&
      typeof previousScene.scene_ending_state === "object"
    ) {
      lines.push(
        "Ending state:",
        "```json",
        JSON.stringify(previousScene.scene_ending_state, null, 2),
        "```",
        "",
      );
    }
  }
  for (const scene of scenes) {
    for (
      const item of Array.isArray(scene.character_deltas)
        ? scene.character_deltas
        : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const name = key(record.character_name);
      if (!name) continue;
      const prior = characters.get(name) ?? {};
      for (const [field, value] of Object.entries(record)) {
        if (value !== null && value !== undefined && value !== "") {
          prior[field] = value;
        }
      }
      characters.set(name, prior);
    }
    for (
      const item of Array.isArray(scene.plot_thread_deltas)
        ? scene.plot_thread_deltas
        : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = key(record.reference) || key(record.thread_name);
      if (!id) continue;
      threads.set(id, record);
    }
    for (
      const item of Array.isArray(scene.continuity_facts)
        ? scene.continuity_facts
        : []
    ) {
      const record = typeof item === "string"
        ? { fact: item }
        : item && typeof item === "object"
        ? item as Record<string, unknown>
        : null;
      if (!record) continue;
      const id = key(record.reference) || key(record.fact);
      if (!id) continue;
      if (record.active === false || record.superseded_by) facts.delete(id);
      else facts.set(id, record);
    }
    for (
      const item of Array.isArray(scene.open_loops) ? scene.open_loops : []
    ) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const id = key(record.reference) || key(record.description);
      if (!id) continue;
      if (record.status === "resolved" || record.status === "closed") {
        loops.delete(id);
      } else loops.set(id, record);
    }
  }
  lines.push("## Cumulative Story State", "");
  if (characters.size) {
    lines.push(
      "Characters:",
      ...Array.from(characters.values()).map((item) =>
        `- **${item.character_name}**: ${JSON.stringify(item)}`
      ),
      "",
    );
  }
  const activeThreads = Array.from(threads.values()).filter((item) =>
    item.status !== "resolved"
  );
  if (activeThreads.length) {
    lines.push(
      "Plot threads:",
      ...activeThreads.map((item) =>
        `- **${item.thread_name}** (${item.reference ?? "no-reference"}) [${
          item.status ?? "unknown"
        }]: ${item.description ?? ""}`
      ),
      "",
    );
  }
  if (facts.size) {
    lines.push(
      "Continuity Facts:",
      ...Array.from(facts.values()).map((item) =>
        `- ${String(item.reference ?? "no-reference")}: ${
          String(item.fact ?? "")
        }`
      ),
      "",
    );
  }
  if (loops.size) {
    lines.push(
      "Open loops:",
      ...Array.from(loops.values()).map((item) =>
        `- [${item.type ?? "unknown"}] (${item.reference ?? "no-reference"}) ${
          item.description ?? ""
        }`
      ),
      "",
    );
  }
  return lines.join("\n").slice(0, Math.max(1_000, maxChars));
}
