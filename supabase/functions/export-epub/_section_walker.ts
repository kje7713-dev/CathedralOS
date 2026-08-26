// =============================================================================
// _section_walker.ts — Walk OutlineSection tree for export ordering
//
// Returns chapters (parent_id IS NULL, container="chapter") + their nested
// child sections, sorted by position. Each section carries the latest
// GenerationOutput text (regardless of accepted status per spec).
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export type Container = "chapter" | "scene" | "beat" | "set-piece" | "summary";

export interface Section {
  id: string;
  title: string;
  container: Container;
  pov: string | null;
  body: string;             // latest GenerationOutput text
  position: number;
  parent_id: string | null;
}

export interface Chapter {
  id: string;
  title: string;
  position: number;
  sections: Section[];      // [chapter root] + [child sections, position-ordered]
}

export interface ProjectOutline {
  id: string;
  title: string;
  chapters: Chapter[];      // position-ordered
}

export async function walkSections(
  client: SupabaseClient,
  userId: string,
  localProjectId: string,
  _snapshotProjectId: string,
): Promise<ProjectOutline> {
  // Normalize at the read boundary so the lookup matches the canonical UPPERCASE
  // form stored in outlines.local_project_id (per PR-4100-D migration
  // 20260826000000_normalize_outlines_local_project_id.sql — CHECK constraint
  // outlines_local_project_id_uppercase). The CHECK constraint does NOT make
  // .eq() case-insensitive, so we normalize before the .eq() call. This also
  // means both uppercase and lowercase callers resolve the same canonical row.
  const normalizedProjectId = localProjectId.toUpperCase();

  // 1. Resolve outline via (user_id, local_project_id). The stale schema
  //    referenced a non-existent `projects` table + `outline_sections.project_id`;
  //    current Cathedral schema has `outlines` keyed on (user_id, local_project_id)
  //    and `outline_sections` keyed on `outline_id`.
  const { data: outline, error: outlineError } = await client
    .from("outlines")
    .select("id, name")
    .eq("user_id", userId)
    .eq("local_project_id", normalizedProjectId)
    .maybeSingle();
  if (outlineError || !outline) {
    throw new Error(`outline not found for project ${localProjectId} (normalized: ${normalizedProjectId})`);
  }

  // 2. Fetch all sections for this outline, ordered by position
  const { data: sections, error: sectionsError } = await client
    .from("outline_sections")
    .select("id, outline_id, container, title, pov, position, parent_id")
    .eq("outline_id", outline.id)
    .order("position", { ascending: true });
  if (sectionsError) {
    throw new Error(`fetching sections failed: ${sectionsError.message}`);
  }
  if (!sections || sections.length === 0) {
    return { id: outline.id, title: outline.name ?? "", chapters: [] };
  }

  // 3. Fetch latest generation_output per section
  const sectionIds = sections.map((s) => s.id);
  const { data: outputs, error: outputsError } = await client
    .from("generation_outputs")
    .select("outline_section_id, body, created_at")
    .in("outline_section_id", sectionIds)
    .order("created_at", { ascending: false });
  if (outputsError) {
    throw new Error(`fetching generation outputs failed: ${outputsError.message}`);
  }

  // 4. Build map: latest body per section
  const latestBody = new Map<string, string>();
  for (const out of outputs ?? []) {
    if (!latestBody.has(out.outline_section_id)) {
      latestBody.set(out.outline_section_id, out.body ?? "");
    }
  }

  // 5. Group: chapters vs children
  const chapters: Chapter[] = [];
  const childrenByParent = new Map<string, Section[]>();

  for (const s of sections) {
    const section: Section = {
      id: s.id,
      title: s.title ?? "",
      container: s.container as Container,
      pov: s.pov ?? null,
      body: latestBody.get(s.id) ?? "",
      position: s.position,
      parent_id: s.parent_id ?? null,
    };

    // Every top-level outline section = 1 Kindle chapter, regardless of container value.
    // Per Kevin 2026-08-25 19:58 EDT: "Each generate section from section outlined
    // accepted is a chapter in the kindle book."
    if (s.parent_id === null) {
      chapters.push({
        id: s.id,
        title: s.title || `Chapter ${chapters.length + 1}`,
        position: s.position,
        sections: [section],   // chapter root goes first
      });
    } else if (s.parent_id !== null) {
      if (!childrenByParent.has(s.parent_id)) {
        childrenByParent.set(s.parent_id, []);
      }
      childrenByParent.get(s.parent_id)!.push(section);
    }
    // Top-level non-chapter sections (e.g., standalone scenes) — skip in v1
  }

  // 6. Sort chapters by position; attach children to their parent chapter
  chapters.sort((a, b) => a.position - b.position);
  for (const ch of chapters) {
    const children = (childrenByParent.get(ch.id) ?? [])
      .sort((a, b) => a.position - b.position);
    ch.sections.push(...children);
  }

  return { id: outline.id, title: outline.name ?? "", chapters };
}
