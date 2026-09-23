import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { epubPublicationOwnerMatches } from "./index.ts";

const OWNER = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";

Deno.test("EPUB download provenance accepts matching shared and export owners", () => {
  assertEquals(epubPublicationOwnerMatches(OWNER, OWNER), true);
});

Deno.test("EPUB download provenance rejects cross-owner linkage", () => {
  assertEquals(epubPublicationOwnerMatches(OWNER, OTHER), false);
  assertEquals(epubPublicationOwnerMatches(OWNER, null), false);
  assertEquals(epubPublicationOwnerMatches("", OWNER), false);
});
