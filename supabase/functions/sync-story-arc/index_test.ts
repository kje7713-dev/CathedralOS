import { assertEquals } from "jsr:@std/assert@1";
import { canonicalUUID, canonicalUUIDSet, uuidSetsEqual } from "../_shared/uuid.ts";

const BEAT_A = "cca975fc-e13a-4ade-8344-2470a8c2b3a0";
const BEAT_B = "11111111-1111-4111-8111-111111111111";

Deno.test("UUID identity canonicalization handles uppercase and mixed casing", () => {
  assertEquals(canonicalUUID(BEAT_A.toUpperCase()), BEAT_A);
  assertEquals(
    canonicalUUIDSet([BEAT_A.toUpperCase(), BEAT_B]),
    new Set([BEAT_A, BEAT_B]),
  );
  assertEquals(uuidSetsEqual([BEAT_A.toUpperCase()], [BEAT_A]), true);
});

Deno.test("repeat sync has no deletion when only UUID casing differs", () => {
  const existing = [BEAT_A, BEAT_B];
  const incoming = [BEAT_A.toUpperCase(), BEAT_B.toUpperCase()];
  const existingIDs = canonicalUUIDSet(existing);
  const incomingIDs = canonicalUUIDSet(incoming);
  const toDelete = [...existingIDs].filter((id) => !incomingIDs.has(id));
  assertEquals(toDelete, []);
});

Deno.test("replace sync still deletes genuinely removed beats", () => {
  const existingIDs = canonicalUUIDSet([BEAT_A, BEAT_B]);
  const incomingIDs = canonicalUUIDSet([BEAT_A.toUpperCase()]);
  assertEquals([...existingIDs].filter((id) => !incomingIDs.has(id)), [BEAT_B]);
});

Deno.test("sync postcondition rejects a persisted set mismatch", () => {
  assertEquals(uuidSetsEqual([BEAT_A], [BEAT_A.toUpperCase()]), true);
  assertEquals(uuidSetsEqual([BEAT_A], [BEAT_B]), false);
  assertEquals(uuidSetsEqual([], [BEAT_A]), false);
});
