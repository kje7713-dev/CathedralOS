// =============================================================================
// _section_walker.ts — Walk OutlineSection tree for export ordering
//
// Returns chapters (parent_id IS NULL) + their nested child sections,
// sorted by position. Each section carries the latest GenerationOutput text.
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
  sections: Section[];      // [chapter itself] + [child sections, position-ordered]
}

export interface ProjectOutline {
  id: string;
  title: string;
  chapters: Chapter[];      // position-ordered
}

export async function walkSections(
  _client: SupabaseClient,
  _projectId: string,
): Promise<ProjectOutline> {
  // TODO: PR-4100-A follow-up
  // 1. Query outline_sections WHERE project_id = X ORDER BY position
  // 2. Group: parent_id IS NULL → chapter roots; parent_id IS NOT NULL → children
  // 3. For each section, query latest generation_outputs WHERE outline_section_id = X
  //    AND status = 'accepted' ORDER BY created_at DESC LIMIT 1; fall back to latest
  //    if no accepted output exists.
  // 4. Assemble Chapter[] with child sections nested under their parent chapter
  throw new Error("_section_walker.walkSections: not yet implemented");
}
