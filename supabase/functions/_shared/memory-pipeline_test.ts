import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CURRENT_MEMORY_PIPELINE_VERSION,
  LEGACY_MEMORY_PIPELINE_VERSION,
  isCurrentMemoryPipelineVersion,
  memoryPipelineVersion,
} from "./memory-pipeline.ts";

Deno.test("memory pipeline treats missing versions as legacy and current as compatible", () => {
  assertEquals(memoryPipelineVersion(undefined), LEGACY_MEMORY_PIPELINE_VERSION);
  assertEquals(memoryPipelineVersion(null), LEGACY_MEMORY_PIPELINE_VERSION);
  assertEquals(isCurrentMemoryPipelineVersion(LEGACY_MEMORY_PIPELINE_VERSION), false);
  assertEquals(isCurrentMemoryPipelineVersion(CURRENT_MEMORY_PIPELINE_VERSION), true);
});
