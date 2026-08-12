import type { LengthMode } from "../generate-story/_credits.ts";

export const OUTPUT_BUDGETS: Record<LengthMode, number> = {
  short: 800,
  medium: 1600,
  long: 3000,
  chapter: 6000,
};

type JSONObject = Record<string, unknown>;

/** Match both local and canonical identities for restored/imported projects. */
export function projectSnapshotLookupFilter(projectId: string, lineageId: unknown): string {
  const lineage = String(lineageId ?? "").trim();
  return lineage
    ? `local_project_id.eq.${projectId},lineage_id.eq.${lineage}`
    : `local_project_id.eq.${projectId}`;
}

function objects(value: unknown): JSONObject[] {
  return Array.isArray(value)
    ? value.filter((item): item is JSONObject => !!item && typeof item === "object")
    : [];
}

function selectedByIds(items: unknown, ids: unknown): JSONObject[] {
  const wanted = new Set(Array.isArray(ids) ? ids.map(String) : []);
  return objects(items).filter((item) => wanted.has(String(item.id ?? "")));
}

/** Convert the synced ProjectImportExportPayload into the canonical prompt-pack payload. */
export function buildSourcePayloadJSON(
  snapshot: JSONObject,
  section: { title: string; summary: string },
): JSONObject {
  const packs = objects(snapshot.promptPacks);
  if (packs.length === 0) throw new Error("project snapshot has no prompt pack");
  const pack = packs[0];
  const setting = snapshot.setting && typeof snapshot.setting === "object"
    ? snapshot.setting as JSONObject
    : {};
  const sectionInstruction = `Outline section: ${section.title}\n${section.summary}`.trim();
  const packNotes = String(pack.notes ?? "").trim();

  return {
    schema: "cathedralos.prompt_pack_export",
    version: 1,
    project: snapshot.project,
    setting: { ...setting, included: pack.includeProjectSetting === true },
    selectedCharacters: selectedByIds(snapshot.characters, pack.selectedCharacterIDs),
    selectedStorySpark: selectedByIds(snapshot.storySparks, [pack.selectedStorySparkID])[0] ?? null,
    selectedAftertaste: selectedByIds(snapshot.aftertastes, [pack.selectedAftertasteID])[0] ?? null,
    selectedRelationships: selectedByIds(snapshot.relationships, pack.selectedRelationshipIDs),
    selectedThemeQuestions: selectedByIds(snapshot.themeQuestions, pack.selectedThemeQuestionIDs),
    selectedMotifs: selectedByIds(snapshot.motifs, pack.selectedMotifIDs),
    promptPack: {
      id: pack.id,
      name: pack.name,
      includeProjectSetting: pack.includeProjectSetting === true,
      notes: [packNotes, sectionInstruction].filter(Boolean).join("\n\n"),
      instructionBias: pack.instructionBias ?? "",
    },
  };
}

export function buildGenerateStoryRequest(args: {
  snapshot: JSONObject;
  // `id` is the outline_sections.id (mirrors the chapter_run.start_parent_section_id
  // the run loop passes in). Added in the PR-#327 backend fix-forward so generate-story
  // can persist `outline_section_id` on the generation_outputs row it inserts, which is
  // what the iOS-side `GenerationOutput.outlineSectionID` field expects on sync.
  section: { id: string; title: string; summary: string; container: string | null; pov: string | null; terminal_beat: string | null };
  projectId: string;
  selectedModelId?: string;
  lengthMode: LengthMode;
}): JSONObject {
  const project = args.snapshot.project as JSONObject | undefined;
  const payload = buildSourcePayloadJSON(args.snapshot, args.section);
  const promptPack = payload.promptPack as JSONObject;
  return {
    generationAction: "generate",
    generationLengthMode: args.lengthMode,
    sourcePayloadJSON: payload,
    outputBudget: OUTPUT_BUDGETS[args.lengthMode],
    selectedModelId: args.selectedModelId,
    container: args.section.container ?? "scene",
    pov: args.section.pov ?? "thirdPersonLimited",
    terminalBeat: args.section.terminal_beat ?? undefined,
    projectID: args.projectId,
    project_id: args.projectId,
    projectName: project?.name ?? "",
    promptPackID: promptPack.id ?? "",
    promptPackName: promptPack.name ?? "",
    outline_section_id: args.section.id,
  };
}

export function generationOutputId(response: unknown): string {
  if (!response || typeof response !== "object") return "";
  return String((response as JSONObject).cloudGenerationOutputID ?? "");
}

/** generate-story owns the debit; the orchestrator only reports its charges. */
export function shouldChargeAtRunCompletion(): boolean {
  return false;
}
