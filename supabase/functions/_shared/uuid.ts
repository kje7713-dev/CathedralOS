/** Canonical representation for UUID identity comparisons and persistence. */
export function canonicalUUID(value: string): string {
  return value.toLowerCase();
}

export function canonicalUUIDSet(values: Iterable<string>): Set<string> {
  return new Set(Array.from(values, canonicalUUID));
}

export function uuidSetsEqual(left: Iterable<string>, right: Iterable<string>): boolean {
  const leftSet = canonicalUUIDSet(left);
  const rightSet = canonicalUUIDSet(right);
  return leftSet.size === rightSet.size &&
    Array.from(leftSet).every((value) => rightSet.has(value));
}
