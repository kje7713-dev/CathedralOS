import type { LengthMode } from "../generate-story/_credits.ts";

// PR-360-Z: OUTPUT_BUDGETS removed. The container (section.container) now
// owns the output limit — see generate-story's CONTAINER_HARD_CAPS lookup
// and the new max_tokens formula
//   min(containerHardCap, modelMaxOutputTokens ?? containerHardCap ?? 4096).
// The length-mode budget was a legacy signal that pre-dated the container
// taxonomy. OutputBudget is no longer in buildGenerateStoryRequest's
// returned payload.

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
): JSONObject {
  const packs = objects(snapshot.promptPacks);
  if (packs.length === 0) throw new Error("project snapshot has no prompt pack");
  const pack = packs[0];
  const setting = snapshot.setting && typeof snapshot.setting === "object"
    ? snapshot.setting as JSONObject
    : {};
  // PR-360-Z: sectionInstruction (the "Outline section: ...\n... " smuggling
  // into promptPack.notes) is GONE. Section context now travels as explicit
  // top-level `sectionTitle` + `sectionSummary` fields on the generate-story
  // request payload (see buildGenerateStoryRequest below). Prompt assembly
  // reads sectionTitle + sectionSummary directly from the body — never from
  // promptPack.notes. This also stops the editor-side annotations
  // (copy / test / draft) from leaking into the LLM prompt via notes.
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
      notes: packNotes,
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
  // PR-360-Z cleanup pass (Kevin 2026-08-21 17:47 EDT): the 5 Story Arc
  // Context fields were REMOVED from buildGenerateStoryRequest. generate-story
  // now resolves story arc context server-side from body.outline_section_id
  // via fetchOutlineSectionContext. run-outline no longer needs to fetch
  // the arc context separately — single source of truth (server-side).
  // The section type also no longer carries story_arc_beat_id (backend
  // fetches it from outline_sections).
}): JSONObject {
  const project = args.snapshot.project as JSONObject | undefined;
  // PR-360-Z: buildSourcePayloadJSON no longer takes the section (section
  // context is now explicit top-level fields on the generate-story request,
  // not embedded in promptPack.notes).
  const payload = buildSourcePayloadJSON(args.snapshot);
  const promptPack = payload.promptPack as JSONObject;
  return {
    generationAction: "generate",
    generationLengthMode: args.lengthMode,
    sourcePayloadJSON: payload,
    // PR-360-Z: outputBudget removed. The container (section.container) now
    // owns the output cap via CONTAINER_HARD_CAPS in generate-story. The
    // length-mode budget is no longer sent.
    selectedModelId: args.selectedModelId,
    container: args.section.container ?? "scene",
    pov: args.section.pov ?? "thirdPersonLimited",
    terminalBeat: args.section.terminal_beat ?? undefined,
    projectID: args.projectId,
    // PR-360-Z Bug A: send BOTH `projectID` (camelCase, what iOS reads)
    // AND `project_id` (snake_case, what run-outline used to send and what
    // generate-story reads via the normalized projectID variable in Commit 1).
    // The backend accepts either; this is belt-and-suspenders while iOS
    // direct generation migrates to canonical sectionTitle + sectionSummary.
    project_id: args.projectId,
    projectName: project?.name ?? "",
    promptPackID: promptPack.id ?? "",
    promptPackName: promptPack.name ?? "",
    outline_section_id: args.section.id,
    // PR-360-Z: canonical explicit section context fields. Replaces the
    // "smuggle section into promptPack.notes" pattern. The prompt assembly
    // reads from these fields directly (with sanitizeTitleForLLM applied
    // to sectionTitle). Both iOS direct generation AND run-outline
    // generation must populate the same canonical fields — iOS is wired
    // up in Commit 4.
    sectionTitle: args.section.title,
    sectionSummary: args.section.summary,
    // PR-360-Z cleanup pass (Kevin 2026-08-21 17:47 EDT): the 5 Story Arc
    // Context fields were REMOVED from the payload. generate-story resolves
    // them server-side from outline_section_id. The buildSourcePayloadJSON
    // source-payload snapshot is unchanged (still includes the project's
    // prompt pack data — Characters, Themes, etc.).
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
