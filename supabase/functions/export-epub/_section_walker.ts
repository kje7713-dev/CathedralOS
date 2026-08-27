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

export interface StoryBrief {
  projectSummary?: string;
  setting?: string;
  recipe?: string;
  characters?: string;
  conflict?: string;
  themes?: string;
  endingTexture?: string;
}

export interface ProjectOutline {
  id: string;
  title: string;
  chapters: Chapter[];
  storyBrief?: StoryBrief;
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

  // UUID text may arrive with different casing between JSON snapshots and
  // PostgREST rows. Normalize IDs before joining; UUID equality is
  // case-insensitive in Postgres, but Map lookups are not.
  const latestBody = new Map<string, string>();
  for (const out of (outputs ?? []) as Array<Record<string, unknown>>) {
    const sid = String(out.outline_section_id).toLowerCase();
    if (!latestBody.has(sid)) {
      latestBody.set(sid, String(out.output_text ?? ""));
    }
  }

  // Do not create a technically valid but useless EPUB containing only outline
  // headings. Legacy generation_outputs rows may have project_local_id but no
  // outline_section_id; there is no safe way to infer which section they belong
  // to, so they must not be silently substituted for current section prose.
  const generatedSectionCount = snapshotSections.filter((section) =>
    String(latestBody.get(String(section.id).toLowerCase()) ?? "").trim().length > 0
  ).length;
  if (snapshotSections.length > 0 && generatedSectionCount === 0) {
    throw new Error(
      `no generated content found for outline ${String(currentOutline.id ?? "unknown")}; export requires section-linked generation outputs`,
    );
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
      body: latestBody.get(sid.toLowerCase()) ?? "",
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
    storyBrief: buildStoryBrief(snapshot.snapshot_json, currentOutline, snapshotSections),
  };
}


function buildStoryBrief(
  snapshot: Record<string, unknown>,
  outline: Record<string, unknown>,
  sections: Array<Record<string, unknown>>,
): StoryBrief {
  const text = (value: unknown, limit = 700): string => {
    if (Array.isArray(value)) {
      return value.map((item) => text(item, 300)).filter(Boolean).join(", ").slice(0, limit);
    }
    if (typeof value !== "string") return "";
    return value.replace(/\s+/g, " ").trim().slice(0, limit);
  };
  const join = (values: unknown[], limit = 1200): string =>
    values.map((v) => text(v, 400)).filter(Boolean).join("; ").slice(0, limit);
  const project = (snapshot.project ?? {}) as Record<string, unknown>;
  const setting = (snapshot.setting ?? {}) as Record<string, unknown>;
  const packs = Array.isArray(snapshot.promptPacks) ? snapshot.promptPacks as Array<Record<string, unknown>> : [];
  const pack = packs.find((p) => String(p.localProjectID ?? "") === String(outline.localProjectID ?? "")) ?? packs[0];
  const selectedIds = new Set(Array.isArray(pack?.selectedCharacterIDs) ? pack.selectedCharacterIDs.map(String) : []);
  const characters = Array.isArray(snapshot.characters) ? snapshot.characters as Array<Record<string, unknown>> : [];
  const selectedCharacters = characters.filter((c) => selectedIds.size === 0 || selectedIds.has(String(c.id)));
  const sparks = Array.isArray(snapshot.storySparks) ? snapshot.storySparks as Array<Record<string, unknown>> : [];
  const sparkID = pack?.selectedStorySparkID ? String(pack.selectedStorySparkID) : "";
  const spark = sparks.find((s) => String(s.id) === sparkID) ?? sparks[0];
  const aftertastes = Array.isArray(snapshot.aftertastes) ? snapshot.aftertastes as Array<Record<string, unknown>> : [];
  const aftertasteID = pack?.selectedAftertasteID ? String(pack.selectedAftertasteID) : "";
  const aftertaste = aftertastes.find((a) => String(a.id) === aftertasteID) ?? aftertastes[0];
  const themes = Array.isArray(snapshot.themeQuestions) ? snapshot.themeQuestions as Array<Record<string, unknown>> : [];
  const motifs = Array.isArray(snapshot.motifs) ? snapshot.motifs as Array<Record<string, unknown>> : [];
  const selectedThemeIDs = new Set(Array.isArray(pack?.selectedThemeQuestionIDs) ? pack.selectedThemeQuestionIDs.map(String) : []);
  const selectedMotifIDs = new Set(Array.isArray(pack?.selectedMotifIDs) ? pack.selectedMotifIDs.map(String) : []);
  const outlineSignals = sections.map((s) => `${text(s.title, 100)}: ${text(s.summary, 180)}`).filter(Boolean).join(" | ").slice(0, 1800);
  return {
    projectSummary: text(project.summary, 1000),
    setting: join([setting.summary, setting.domains, setting.themes, setting.environmentalPressure, setting.mythicFrame], 1200),
    characters: selectedCharacters.map((c) => `${text(c.name, 100)} (${join([c.roles, c.goals, c.fears, c.secrets], 240)})`).join("; ").slice(0, 1400),
    conflict: join([spark?.title, spark?.situation, spark?.stakes, spark?.twist, spark?.threat, spark?.complication, spark?.clock], 1400),
    themes: themes.filter((t) => selectedThemeIDs.size === 0 || selectedThemeIDs.has(String(t.id))).map((t) => join([t.question, t.coreTension, t.valueConflict, t.moralFaultLine], 350)).filter(Boolean).concat(
      motifs.filter((m) => selectedMotifIDs.size === 0 || selectedMotifIDs.has(String(m.id))).map((m) => join([m.label, m.meaning, m.examples], 250)).filter(Boolean)
    ).join("; ").slice(0, 1400),
    endingTexture: join([aftertaste?.label, aftertaste?.emotionalResidue, aftertaste?.endingTexture, aftertaste?.lastImageFeeling], 800),
    // Keep the outline itself in the brief so sparse recipes still reflect the whole book.
    recipe: [join([pack?.name, pack?.notes, pack?.instructionBias], 900), `Outline signals: ${outlineSignals}`].filter(Boolean).join(" ").slice(0, 1800),
  };
}
