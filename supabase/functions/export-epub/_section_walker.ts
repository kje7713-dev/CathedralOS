// =============================================================================
// _section_walker.ts — Walk current project structure from snapshot_json
//
// PR-4100-A-hotfix: Use project_snapshots.snapshot_json as the authoritative
// current structure. The relational outline_sections table is an accumulated
// historical mirror (the extract trigger UPSERTs but never DELETEs), so a
// 4-section snapshot can correspond to 100+ stale relational rows.
//
// PR-4100-D: Normalize localProjectId to UPPERCASE at the read boundary.
//
// PR-fixup: generation_outputs uses `output_text` (not the stale `body`).
//
// Chapter grouping (per Kevin 2026-08-25 19:58 EDT / PR-4100-B correction):
// every top-level section (parentID == null) is a Kindle chapter, regardless
// of container value.
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export type Container = "chapter" | "scene" | "beat" | "set-piece" | "summary";

export interface Section {
  id: string;
  title: string;
  container: Container;
  pov: string | null;
  body: string;
  position: number;
  parent_id: string | null;
}

export interface Chapter {
  id: string;
  title: string;
  position: number;
  sections: Section[];
}

export interface ProjectOutline {
  id: string;
  title: string;
  chapters: Chapter[];
}

export async function walkSections(
  client: SupabaseClient,
  _userId: string,
  localProjectId: string,
  snapshotProjectId: string,
): Promise<ProjectOutline> {
  const normalizedProjectId = localProjectId.toUpperCase();

  const { data: snapshot, error: snapshotError } = await client
    .from("project_snapshots")
    .select("snapshot_json")
    .eq("id", snapshotProjectId)
    .maybeSingle();
  if (snapshotError || !snapshot) {
    throw new Error(`project snapshot not found: ${snapshotProjectId}`);
  }

  const rawOutlines = (snapshot.snapshot_json?.outlines ?? []) as unknown[];
  const currentOutline = (rawOutlines as Array<Record<string, unknown>>).find(
    (o) => String(o.localProjectID ?? "").toUpperCase() === normalizedProjectId,
  );
  if (!currentOutline) {
    throw new Error(`outline not found in snapshot for project ${normalizedProjectId}`);
  }

  const rawSections = (currentOutline.sections ?? []) as unknown[];
  const snapshotSections = rawSections as Array<Record<string, unknown>>;

  const sectionIds = snapshotSections.map((s) => String(s.id));
  const { data: outputs, error: outputsError } = await client
    .from("generation_outputs")
    .select("outline_section_id, output_text, created_at")
    .in("outline_section_id", sectionIds)
    .order("created_at", { ascending: false });
  if (outputsError) {
    throw new Error(`fetching generation outputs failed: ${outputsError.message}`);
  }

  const latestBody = new Map<string, string>();
  for (const out of (outputs ?? []) as Array<Record<string, unknown>>) {
    const sid = String(out.outline_section_id);
    if (!latestBody.has(sid)) {
      latestBody.set(sid, String(out.output_text ?? ""));
    }
  }

  const chapters: Chapter[] = [];
  const childrenByParent = new Map<string, Section[]>();

  for (const s of snapshotSections) {
    const sid = String(s.id);
    const section: Section = {
      id: sid,
      title: String(s.title ?? ""),
      container: (String(s.container ?? "scene")) as Container,
      pov: s.pov ? String(s.pov) : null,
      body: latestBody.get(sid) ?? "",
      position: Number(s.position ?? 0),
      parent_id: s.parentID ? String(s.parentID) : null,
    };

    if (section.parent_id === null) {
      chapters.push({
        id: sid,
        title: section.title || `Chapter ${chapters.length + 1}`,
        position: section.position,
        sections: [section],
      });
    } else {
      const pid = section.parent_id;
      if (!childrenByParent.has(pid)) childrenByParent.set(pid, []);
      childrenByParent.get(pid)!.push(section);
    }
  }

  chapters.sort((a, b) => a.position - b.position);
  for (const ch of chapters) {
    const children = (childrenByParent.get(ch.id) ?? []).sort((a, b) => a.position - b.position);
    ch.sections.push(...children);
  }

  return {
    id: String(currentOutline.id ?? snapshotProjectId),
    title: String(currentOutline.name ?? ""),
    chapters,
  };
}
