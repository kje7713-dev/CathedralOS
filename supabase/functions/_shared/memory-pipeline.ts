export const CURRENT_MEMORY_PIPELINE_VERSION = "scene-memory-v3";
export const LEGACY_MEMORY_PIPELINE_VERSION = "legacy-v1";
export const MEMORY_STAGE_EXTRACTION = "scene-memory-extraction";
export const MEMORY_STAGE_EMBEDDING = "scene-memory-embedding";

export function isCurrentMemoryPipelineVersion(value: unknown): boolean {
  return value === CURRENT_MEMORY_PIPELINE_VERSION;
}

export function memoryPipelineVersion(value: unknown): string {
  return typeof value === "string" && value.trim()
    ? value.trim()
    : LEGACY_MEMORY_PIPELINE_VERSION;
}
