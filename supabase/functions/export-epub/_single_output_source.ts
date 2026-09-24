import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import type { ProjectOutline, Section } from "./_section_walker.ts";

export class StandaloneOutputSourceError extends Error {
  constructor(public readonly code: string, message: string = code) {
    super(message);
    this.name = "StandaloneOutputSourceError";
  }
}

interface GenerationOutputRow {
  id: string;
  user_id: string;
  project_local_id: string | null;
  title: string | null;
  output_text: string | null;
  status: string | null;
  source_payload_json: unknown;
}

/**
 * Resolve the explicitly selected standalone story into the same in-memory
 * ProjectOutline shape consumed by the existing EPUB writer.
 *
 * This adapter is deliberately separate from walkSections(): an absent source
 * ID always means the existing outline export path, while an explicit source
 * ID is validated and fails closed rather than falling back to an outline.
 */
export async function buildStandaloneOutputOutline(
  client: SupabaseClient,
  userId: string,
  localProjectId: string,
  snapshotProjectId: string,
  generationOutputID: string,
  bookTitle: string,
): Promise<ProjectOutline> {
  if (!isUUID(generationOutputID)) {
    throw new StandaloneOutputSourceError("invalid_generation_output_id");
  }

  const { data: row, error } = await client
    .from("generation_outputs")
    .select(
      "id, user_id, project_local_id, title, output_text, status, source_payload_json",
    )
    .eq("id", generationOutputID)
    .eq("user_id", userId)
    .maybeSingle();
  if (error || !row) {
    throw new StandaloneOutputSourceError("generation_output_not_found");
  }

  const output = row as GenerationOutputRow;
  if (!output.project_local_id) {
    throw new StandaloneOutputSourceError("generation_output_project_mismatch");
  }
  if (
    output.project_local_id.trim().toUpperCase() !==
      localProjectId.trim().toUpperCase()
  ) {
    throw new StandaloneOutputSourceError("generation_output_project_mismatch");
  }

  const status = String(output.status ?? "").toLowerCase();
  if (status === "failed" || status === "generating") {
    throw new StandaloneOutputSourceError("generation_output_not_exportable");
  }
  const body = String(output.output_text ?? "");
  if (!body.trim()) {
    throw new StandaloneOutputSourceError("generation_output_empty");
  }

  const { data: snapshot, error: snapshotError } = await client
    .from("project_snapshots")
    .select("snapshot_json")
    .eq("id", snapshotProjectId)
    .eq("user_id", userId)
    .maybeSingle();
  if (snapshotError || !snapshot) {
    throw new StandaloneOutputSourceError("project_not_found");
  }

  const snapshotJson = (snapshot.snapshot_json ?? {}) as Record<
    string,
    unknown
  >;
  return makeStandaloneOutputOutline(output, snapshotJson, bookTitle);
}

export function makeStandaloneOutputOutline(
  output: Pick<GenerationOutputRow, "id" | "title" | "output_text">,
  snapshotJson: Record<string, unknown>,
  bookTitle: string,
): ProjectOutline {
  const selectedTitle = bookTitle.trim() ||
    String(output.title ?? "Untitled Story");
  const body = String(output.output_text ?? "");
  const section: Section = {
    id: output.id,
    title: selectedTitle,
    container: "chapter",
    pov: null,
    body,
    position: 0,
    parent_id: null,
    story_arc_beat_id: null,
    story_arc_role: null,
  };
  const project = (snapshotJson.project ?? {}) as Record<string, unknown>;
  const summary = typeof project.summary === "string"
    ? project.summary.trim().slice(0, 1000)
    : "";
  return {
    id: output.id,
    title: selectedTitle,
    chapters: [{
      id: output.id,
      title: selectedTitle,
      position: 0,
      sections: [section],
    }],
    parts: [],
    storyBrief: summary ? { projectSummary: summary } : undefined,
  };
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
