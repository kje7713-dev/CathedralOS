/** Deterministic, lossless planning evidence compilation and packetization. */

export type EvidenceSource = "recipe" | "planner" | "obligation";

export interface PlanningEvidenceAtom {
  id: string;
  sourcePath: string;
  kind: string;
  source: EvidenceSource;
  required: boolean;
  entityID?: string;
  parentID?: string;
  text: string;
  chunkOrdinal?: number;
}

export interface BeatRoutingEntry {
  obligationIDs: string[];
  evidenceIDs: string[];
  materialIDs: string[];
}

export type BeatRouting = Record<string, BeatRoutingEntry>;

export interface RoutingAssignment {
  evidenceID: string;
  beatIndexes: number[];
}

export interface PlanningEvidencePacket {
  packetOrdinal: number;
  packetCount: number;
  atoms: PlanningEvidenceAtom[];
  estimatedInputTokens: number;
  promptBytes: number;
}

export interface PlanningContextV2 {
  schema: "cathedralos.outline_planning_context";
  version: 2;
  provenance: Record<string, unknown>;
  globalSpine: Record<string, unknown>;
  arc: Record<string, unknown>;
  obligations: PlanningEvidenceAtom[];
  evidenceByID: Record<string, PlanningEvidenceAtom>;
  materialByID: Record<string, PlanningEvidenceAtom>;
  existingOutline: unknown[];
}

const encoder = new TextEncoder();

export function estimateInputTokens(value: unknown): number {
  return Math.ceil(JSON.stringify(value).length / 4);
}

export function splitLosslessText(text: string, maxChars = 3200): string[] {
  const normalized = String(text ?? "");
  if (normalized.length <= maxChars) return normalized ? [normalized] : [];
  const chunks: string[] = [];
  let remaining = normalized;
  while (remaining.length > maxChars) {
    const window = remaining.slice(0, maxChars + 1);
    const boundary = Math.max(
      window.lastIndexOf("\n\n"),
      window.lastIndexOf(". "),
      window.lastIndexOf(" "),
    );
    const cut = boundary > Math.floor(maxChars * 0.55)
      ? boundary + (window[boundary] === "." ? 1 : 0)
      : maxChars;
    chunks.push(remaining.slice(0, cut));
    remaining = remaining.slice(cut);
  }
  if (remaining) chunks.push(remaining);
  return chunks;
}

export function atomizeText(
  atom: Omit<PlanningEvidenceAtom, "text" | "chunkOrdinal">,
  text: string,
  maxChars = 3200,
): PlanningEvidenceAtom[] {
  const chunks = splitLosslessText(text, maxChars);
  return chunks.map((chunk, index) => ({
    ...atom,
    id: chunks.length === 1 ? atom.id : `${atom.id}:chunk:${index + 1}`,
    text: chunk,
    ...(chunks.length > 1 ? { chunkOrdinal: index + 1 } : {}),
  }));
}

function scalarText(value: unknown): string {
  if (value == null) return "";
  if (typeof value === "string") return value.trim();
  return JSON.stringify(value);
}

function addObjectAtoms(
  out: PlanningEvidenceAtom[],
  source: EvidenceSource,
  prefix: string,
  value: unknown,
  required = false,
  parentID?: string,
): void {
  if (!value || typeof value !== "object") return;
  for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
    if (raw == null || (Array.isArray(raw) && raw.length === 0)) continue;
    const text = scalarText(raw);
    if (!text) continue;
    out.push(
      ...atomizeText({
        id: `${prefix}.${key}`,
        sourcePath: `${prefix}.${key}`,
        kind: Array.isArray(raw) ? "list" : "field",
        source,
        required,
        ...(parentID ? { parentID } : {}),
      }, text),
    );
  }
}

export function compilePlanningContextV2(input: {
  recipe: Record<string, unknown>;
  arcTemplate: {
    id?: string;
    name?: string;
    description?: string;
    beats?: unknown[];
  };
  obligations?: Array<Record<string, unknown>>;
  material?: Record<string, unknown>;
  existingSections?: unknown[];
  provenance?: Record<string, unknown>;
}): PlanningContextV2 {
  const evidence: PlanningEvidenceAtom[] = [];
  const recipe = input.recipe ?? {};
  addObjectAtoms(evidence, "recipe", "recipe.project", recipe.project, true);
  addObjectAtoms(evidence, "recipe", "recipe.setting", recipe.setting, false);
  for (
    const key of [
      "selectedStorySpark",
      "selectedAftertaste",
      "promptPack",
      "instructionBias",
    ]
  ) {
    if (
      recipe[key] && typeof recipe[key] === "object" &&
      !Array.isArray(recipe[key])
    ) {
      addObjectAtoms(
        evidence,
        "recipe",
        `recipe.${key}`,
        recipe[key],
        true,
        key,
      );
    }
  }
  for (const [category, values] of Object.entries(recipe)) {
    if (!Array.isArray(values)) continue;
    values.forEach((value, index) =>
      addObjectAtoms(
        evidence,
        "recipe",
        `recipe.${category}[${index}]`,
        value,
        true,
      )
    );
  }
  const obligations: PlanningEvidenceAtom[] = [];
  for (const [index, obligation] of (input.obligations ?? []).entries()) {
    const id = String(obligation.id ?? `obligation-${index + 1}`);
    const statement = scalarText(
      obligation.statement ?? obligation.directive ?? obligation.label ??
        obligation,
    );
    obligations.push(
      ...atomizeText({
        id,
        sourcePath: `obligations.${id}`,
        kind: "recipe-obligation",
        source: "obligation",
        required: Boolean(obligation.required),
        parentID: id,
      }, statement),
    );
  }
  const materialAtoms: PlanningEvidenceAtom[] = [];
  for (const [category, values] of Object.entries(input.material ?? {})) {
    if (!Array.isArray(values)) continue;
    for (const [index, item] of values.entries()) {
      if (!item || typeof item !== "object") continue;
      const row = item as Record<string, unknown>;
      const id = String(row.id ?? `material-${category}-${index + 1}`);
      const source = row.source === "recipe" ? "recipe" : "planner";
      const text = `${String(row.label ?? "")}\n${
        String(row.description ?? "")
      }`.trim();
      materialAtoms.push(
        ...atomizeText({
          id,
          sourcePath: `storyMaterial.${category}[${index}]`,
          kind: category,
          source,
          required: source === "recipe",
          entityID: id,
          parentID: id,
        }, text),
      );
    }
  }
  const evidenceByID = Object.fromEntries(
    [...evidence, ...obligations].map((atom) => [atom.id, atom]),
  );
  const materialByID = Object.fromEntries(
    materialAtoms.map((atom) => [atom.id, atom]),
  );
  const beats = (input.arcTemplate.beats ?? []).map((beat, beatIndex) => ({
    beatIndex,
    ...(beat as Record<string, unknown>),
  }));
  return {
    schema: "cathedralos.outline_planning_context",
    version: 2,
    provenance: input.provenance ?? {},
    globalSpine: {
      projectID: (recipe.project as Record<string, unknown> | undefined)?.id ??
        null,
      projectName:
        (recipe.project as Record<string, unknown> | undefined)?.name ?? null,
      format: (recipe as Record<string, unknown>).format ?? null,
      promptPackID:
        (recipe.promptPack as Record<string, unknown> | undefined)?.id ?? null,
      promptPackName:
        (recipe.promptPack as Record<string, unknown> | undefined)?.name ??
          null,
    },
    arc: {
      id: input.arcTemplate.id ?? null,
      name: input.arcTemplate.name ?? null,
      description: input.arcTemplate.description ?? null,
      beats,
    },
    obligations,
    evidenceByID,
    materialByID,
    existingOutline: input.existingSections ?? [],
  };
}

export function emptyBeatRouting(beatIDs: string[]): BeatRouting {
  return Object.fromEntries(
    beatIDs.map((
      beatID,
    ) => [beatID, { obligationIDs: [], evidenceIDs: [], materialIDs: [] }]),
  );
}

export function mergeRoutingAssignments(input: {
  beatIDs: string[];
  assignments: RoutingAssignment[];
  existing?: BeatRouting;
  evidenceByID: Record<string, PlanningEvidenceAtom>;
  materialByID: Record<string, PlanningEvidenceAtom>;
  obligationIDs: Set<string>;
}): BeatRouting {
  const routing = Object.fromEntries(input.beatIDs.map((beatID) => {
    const prior = input.existing?.[beatID];
    return [beatID, {
      obligationIDs: [...(prior?.obligationIDs ?? [])],
      evidenceIDs: [...(prior?.evidenceIDs ?? [])],
      materialIDs: [...(prior?.materialIDs ?? [])],
    }];
  }));
  for (const assignment of input.assignments) {
    const atom = input.evidenceByID[assignment.evidenceID] ??
      input.materialByID[assignment.evidenceID] ??
      Object.values(input.evidenceByID).find((candidate) =>
        candidate.parentID === assignment.evidenceID
      ) ??
      Object.values(input.materialByID).find((candidate) =>
        candidate.parentID === assignment.evidenceID
      );
    if (!atom) {
      throw new Error(
        `routing references unknown evidenceID ${assignment.evidenceID}`,
      );
    }
    for (const beatIndex of assignment.beatIndexes) {
      if (
        !Number.isInteger(beatIndex) || beatIndex < 0 ||
        beatIndex >= input.beatIDs.length
      ) {
        throw new Error(
          `routing references unknown beatIndex ${String(beatIndex)}`,
        );
      }
      const beat = routing[input.beatIDs[beatIndex]];
      const target = atom.source === "obligation" ||
          input.obligationIDs.has(atom.parentID ?? atom.id)
        ? beat.obligationIDs
        : atom.sourcePath.startsWith("storyMaterial.")
        ? beat.materialIDs
        : beat.evidenceIDs;
      const id = atom.parentID ?? atom.id;
      if (!target.includes(id)) target.push(id);
    }
  }
  for (const beat of Object.values(routing)) {
    beat.obligationIDs.sort();
    beat.evidenceIDs.sort();
    beat.materialIDs.sort();
  }
  return routing;
}

export function requiredRoutingGaps(
  routing: BeatRouting,
  requiredIDs: string[],
): string[] {
  const routed = new Set(
    Object.values(routing).flatMap((entry) => entry.obligationIDs),
  );
  return requiredIDs.filter((id) => !routed.has(id));
}

export function packetizeAtoms(
  atoms: PlanningEvidenceAtom[],
  targetTokens = 10000,
): PlanningEvidencePacket[] {
  const packets: PlanningEvidenceAtom[][] = [];
  let current: PlanningEvidenceAtom[] = [];
  let currentTokens = 0;
  for (const atom of atoms) {
    const atomTokens = estimateInputTokens(atom);
    if (current.length > 0 && currentTokens + atomTokens > targetTokens) {
      packets.push(current);
      current = [];
      currentTokens = 0;
    }
    current.push(atom);
    currentTokens += atomTokens;
  }
  if (current.length) packets.push(current);
  const packetCount = packets.length;
  return packets.map((packet, index) => {
    const payload = { packetOrdinal: index + 1, packetCount, atoms: packet };
    const promptBytes = encoder.encode(JSON.stringify(payload)).byteLength;
    return {
      ...payload,
      estimatedInputTokens: estimateInputTokens(payload),
      promptBytes,
    };
  });
}

export function dedupeMaterialBySourceReference<
  T extends { id: string; source?: string; sourceReference?: string | null },
>(items: T[]): T[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    const key = item.source === "recipe" && item.sourceReference
      ? `recipe:${item.sourceReference}`
      : `planner:${item.id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function allocationBeatSummary(input: {
  beatIndex: number;
  beat: Record<string, unknown>;
  existingSectionCount: number;
  existingRecipeRequirementIDs?: string[];
  requiredObligationIDs: string[];
  requiredObligationClasses?: Record<string, number>;
  routedEvidenceCount: number;
  routedMaterialCounts: Record<string, number>;
}): Record<string, unknown> {
  return {
    beatIndex: input.beatIndex,
    role: input.beat.role ?? null,
    label: input.beat.label ?? null,
    description: input.beat.description ?? null,
    existingSectionCount: input.existingSectionCount,
    existingRecipeRequirementIDs: input.existingRecipeRequirementIDs ?? [],
    requiredObligationIDs: input.requiredObligationIDs,
    requiredObligationClasses: input.requiredObligationClasses ?? {},
    routedEvidenceCount: input.routedEvidenceCount,
    routedMaterialCounts: input.routedMaterialCounts,
  };
}

export function mergeMaterialBatches<
  T extends { id: string; source?: string; sourceReference?: string | null },
>(batches: T[][]): T[] {
  const seen = new Set<string>();
  const merged: T[] = [];
  for (const [batchIndex, batch] of batches.entries()) {
    for (const [itemIndex, item] of batch.entries()) {
      let id = item.id || `planner-item-${batchIndex + 1}-${itemIndex + 1}`;
      let suffix = 2;
      while (seen.has(id)) id = `${item.id}-${batchIndex + 1}-${suffix++}`;
      seen.add(id);
      merged.push({ ...item, id });
    }
  }
  return merged;
}

export const ROUTING_RESPONSE_SCHEMA = {
  type: "object",
  properties: {
    assignments: {
      type: "array",
      items: {
        type: "object",
        properties: {
          evidenceID: { type: "string", minLength: 1 },
          beatIndexes: {
            type: "array",
            items: { type: "integer", minimum: 0 },
            minItems: 1,
          },
        },
        required: ["evidenceID", "beatIndexes"],
        additionalProperties: false,
      },
    },
  },
  required: ["assignments"],
  additionalProperties: false,
} as const;

export function buildRoutingPrompt(input: {
  beats: Array<Record<string, unknown>>;
  packet: PlanningEvidencePacket;
}): { system: string; user: string } {
  return {
    system:
      "Route each supplied evidence atom to every canonical Story Arc beat where it materially belongs. Use beatIndexes only; an atom may route to multiple beats. Do not invent evidence, obligations, or beat indexes. Return JSON only.",
    user: JSON.stringify(
      {
        beats: input.beats.map((beat, beatIndex) => ({
          beatIndex,
          id: beat.id ?? null,
          role: beat.role ?? null,
          label: beat.label ?? null,
          description: beat.description ?? null,
        })),
        packet: input.packet,
      },
      null,
      2,
    ),
  };
}

export function parseRoutingResponse(
  raw: string,
  beatCount: number,
  knownIDs: Set<string>,
): RoutingAssignment[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("routing provider returned invalid JSON");
  }
  const assignments =
    parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as { assignments?: unknown }).assignments
      : undefined;
  if (!Array.isArray(assignments)) {
    throw new Error("routing response missing assignments array");
  }
  const seen = new Set<string>();
  return assignments.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("routing assignment malformed");
    }
    const evidenceID = String((item as any).evidenceID ?? "");
    const beatIndexes = (item as any).beatIndexes;
    if (!knownIDs.has(evidenceID)) {
      throw new Error(`routing references unknown evidenceID ${evidenceID}`);
    }
    if (
      !Array.isArray(beatIndexes) || beatIndexes.length === 0 ||
      beatIndexes.some((index: unknown) =>
        !Number.isInteger(index) || Number(index) < 0 ||
        Number(index) >= beatCount
      )
    ) {
      throw new Error(`routing has invalid beatIndexes for ${evidenceID}`);
    }
    const normalized = [...new Set(beatIndexes.map(Number))].sort((a, b) =>
      a - b
    );
    const key = `${evidenceID}:${normalized.join(",")}`;
    if (seen.has(key)) {
      throw new Error(`routing contains duplicate assignment ${key}`);
    }
    seen.add(key);
    return { evidenceID, beatIndexes: normalized };
  });
}
