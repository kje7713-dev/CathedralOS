// The only automated public-sharing restriction: sexual content involving minors.
// This is deliberately separate from billable generation/embedding usage.

export const PUBLIC_SHARING_RESTRICTION_REASON =
  "sexual_content_involving_minors" as const;
export const PUBLIC_SHARING_MODERATION_MODEL = "omni-moderation-latest";

export interface PublicSharingEligibility {
  eligible: boolean;
  contentHash: string;
  checkedAt: string;
  restrictionReason: typeof PUBLIC_SHARING_RESTRICTION_REASON | null;
}

export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export async function checkPublicSharingEligibility(
  content: string,
  openaiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<PublicSharingEligibility> {
  const contentHash = await sha256Hex(content);
  const checkedAt = new Date().toISOString();
  const response = await fetchImpl("https://api.openai.com/v1/moderations", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${openaiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: PUBLIC_SHARING_MODERATION_MODEL,
      input: content,
    }),
  });
  if (!response.ok) {
    throw new Error(`moderation request failed: ${response.status}`);
  }
  const payload = await response.json() as {
    results?: Array<{ categories?: Record<string, unknown> }>;
  };
  const sexualMinors =
    payload.results?.[0]?.categories?.["sexual/minors"] === true;
  return {
    eligible: !sexualMinors,
    contentHash,
    checkedAt,
    restrictionReason: sexualMinors ? PUBLIC_SHARING_RESTRICTION_REASON : null,
  };
}

export async function persistPublicSharingEligibility(
  adminClient: any,
  outlineSectionID: string,
  content: string,
  openaiKey: string,
): Promise<PublicSharingEligibility | null> {
  try {
    const result = await checkPublicSharingEligibility(content, openaiKey);
    const { error } = await adminClient.from("section_embeddings").update({
      public_sharing_eligible: result.eligible,
      public_sharing_checked_content_hash: result.contentHash,
      public_sharing_checked_at: result.checkedAt,
      public_sharing_restriction_reason: result.restrictionReason,
    }).eq("outline_section_id", outlineSectionID);
    if (error) throw new Error(error.message);
    return result;
  } catch (error) {
    // Eligibility failure must not interrupt private writing or embedding. The
    // publication guard will fail closed until a current result exists.
    console.error("[public-sharing-eligibility] check failed:", error);
    return null;
  }
}

export async function requireCurrentSectionEligibility(
  adminClient: any,
  sectionID: string,
  reviewedContent?: string,
): Promise<{ ok: true } | { ok: false; reason: string; sectionIDs: string[] }> {
  const { data, error } = await adminClient.from("section_embeddings")
    .select(
      "outline_section_id, raw_text, public_sharing_eligible, public_sharing_checked_content_hash",
    )
    .eq("outline_section_id", sectionID)
    .maybeSingle();
  if (error) throw new Error(error.message);
  const rawText = typeof data?.raw_text === "string" ? data.raw_text : "";
  const currentHash = await sha256Hex(reviewedContent ?? rawText);
  const isCurrent = Boolean(
    data &&
      data.public_sharing_checked_content_hash === currentHash,
  );
  if (!isCurrent || data.public_sharing_eligible !== true) {
    return {
      ok: false,
      reason: data?.public_sharing_eligible === false && isCurrent
        ? PUBLIC_SHARING_RESTRICTION_REASON
        : "public_sharing_eligibility_missing",
      sectionIDs: [sectionID],
    };
  }
  return { ok: true };
}

export async function requireCurrentGenerationOutputEligibility(
  adminClient: any,
  generationOutputID: string,
  reviewedContent: string,
): Promise<{ ok: true } | { ok: false; reason: string; sectionIDs: string[] }> {
  const { data, error } = await adminClient.from("section_embeddings")
    .select(
      "outline_section_id, raw_text, public_sharing_eligible, public_sharing_checked_content_hash",
    )
    .eq("generation_output_id", generationOutputID)
    .maybeSingle();
  if (error) throw new Error(error.message);
  if (!data) {
    return {
      ok: false,
      reason: "public_sharing_eligibility_missing",
      sectionIDs: [generationOutputID],
    };
  }
  const contentHash = await sha256Hex(reviewedContent);
  if (data.public_sharing_checked_content_hash !== contentHash) {
    return {
      ok: false,
      reason: "public_sharing_eligibility_missing",
      sectionIDs: [String(data.outline_section_id ?? generationOutputID)],
    };
  }
  if (data.public_sharing_eligible !== true) {
    return {
      ok: false,
      reason: PUBLIC_SHARING_RESTRICTION_REASON,
      sectionIDs: [String(data.outline_section_id ?? generationOutputID)],
    };
  }
  return { ok: true };
}

export async function requireCurrentProjectEligibility(
  adminClient: any,
  snapshotProjectID: string,
): Promise<{ ok: true } | { ok: false; reason: string; sectionIDs: string[] }> {
  // EPUB export is built from project_snapshots.snapshot_json, which is the
  // authoritative current manuscript. Do not inspect accumulated historical
  // section_embeddings rows: deleted/stale sections must not block publication.
  const { data: snapshot, error: snapshotError } = await adminClient
    .from("project_snapshots")
    .select("snapshot_json")
    .eq("id", snapshotProjectID)
    .maybeSingle();
  if (snapshotError) throw new Error(snapshotError.message);
  const outlines = Array.isArray(snapshot?.snapshot_json?.outlines)
    ? snapshot.snapshot_json.outlines as Array<Record<string, unknown>>
    : [];
  const sectionIDs = outlines.flatMap((outline) =>
    Array.isArray(outline.sections)
      ? (outline.sections as Array<Record<string, unknown>>).map((section) =>
        String(section.id ?? "")
      )
      : []
  ).filter((id) => id.length > 0);
  if (sectionIDs.length === 0) {
    return {
      ok: false,
      reason: "public_sharing_eligibility_missing",
      sectionIDs: [],
    };
  }

  const { data, error } = await adminClient.from("section_embeddings")
    .select(
      "outline_section_id, raw_text, public_sharing_eligible, public_sharing_checked_content_hash",
    )
    .in("outline_section_id", sectionIDs);
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as Array<Record<string, unknown>>;
  const rowsBySectionID = new Map(
    rows.map((
      row,
    ) => [String(row.outline_section_id ?? "").toLowerCase(), row]),
  );
  const invalid: Array<Record<string, unknown>> = [];
  for (const sectionID of sectionIDs) {
    const row = rowsBySectionID.get(sectionID.toLowerCase());
    if (!row) {
      invalid.push({ outline_section_id: sectionID });
      continue;
    }
    const rawText = typeof row.raw_text === "string" ? row.raw_text : "";
    const currentHash = await sha256Hex(rawText);
    if (
      row.public_sharing_eligible !== true ||
      row.public_sharing_checked_content_hash !== currentHash
    ) {
      invalid.push(row);
    }
  }
  if (invalid.length > 0) {
    return {
      ok: false,
      reason: invalid.some((row) => row.public_sharing_eligible === false)
        ? PUBLIC_SHARING_RESTRICTION_REASON
        : "public_sharing_eligibility_missing",
      sectionIDs: invalid.map((row) => String(row.outline_section_id ?? "")),
    };
  }
  return { ok: true };
}
