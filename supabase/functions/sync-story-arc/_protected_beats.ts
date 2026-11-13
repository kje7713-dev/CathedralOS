/**
 * Accepted outlines own their beat identity. A later edit to the project's
 * live arc must not delete a beat that an accepted section still references.
 */
export function beatsToDelete(
  existingIds: Set<string>,
  incomingIds: Set<string>,
  protectedIds: Set<string>,
): string[] {
  return [...existingIds].filter((id) =>
    !incomingIds.has(id) && !protectedIds.has(id)
  );
}
