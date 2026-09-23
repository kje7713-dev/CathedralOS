import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export function isTrustedInternalRequest(
  req: Request,
  serviceRoleKey: string,
): boolean {
  if (!serviceRoleKey) return false;
  const header = req.headers.get("Authorization") ?? "";
  const expected = `Bearer ${serviceRoleKey}`;
  if (header.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < header.length; i++) {
    diff |= header.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return diff === 0;
}

export function internalAuthHeader(serviceRoleKey: string): string {
  return `Bearer ${serviceRoleKey}`;
}

export async function loadDurableRunOwner(
  adminClient: any,
  runId: string,
): Promise<
  {
    id: string;
    user_id: string;
    outline_id: string;
    status: string;
    sections: unknown[];
  } | null
> {
  const { data, error } = await adminClient
    .from("chapter_runs")
    .select("id, user_id, outline_id, status, sections")
    .eq("id", runId)
    .maybeSingle();
  if (error) throw new Error(`durable run lookup failed: ${error.message}`);
  if (!data) return null;
  const row = data as any;
  return {
    id: String(row.id),
    user_id: String(row.user_id),
    outline_id: String(row.outline_id),
    status: String(row.status),
    sections: Array.isArray(row.sections) ? row.sections : [],
  };
}

export function durableRunContainsSection(
  run: { sections: unknown[] },
  sectionId: string,
): boolean {
  return run.sections.some((section) =>
    typeof section === "object" && section !== null &&
    String((section as Record<string, unknown>).id ?? "") === sectionId
  );
}
