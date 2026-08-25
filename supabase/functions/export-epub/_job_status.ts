// =============================================================================
// _job_status.ts — export_jobs table state management
//
// Centralizes all reads/writes to the export_jobs table.
// =============================================================================

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

export type ExportJobStatus =
  | "pending"
  | "writing"
  | "validating"
  | "repairing"
  | "validated"
  | "failed_validation"
  | "failed_validator"
  | "uploaded";

export interface ExportJob {
  id: string;
  project_id: string;
  user_id: string;
  export_metadata_id: string | null;
  status: ExportJobStatus;
  epub_temp_path: string | null;
  validation_id: string | null;
  epubcheck_version: string | null;
  error_count: number | null;
  warning_count: number | null;
  diagnostics: unknown | null;
  retry_count: number;
  max_retries: number;
  created_at: string;
  updated_at: string;
  completed_at: string | null;
  error_message: string | null;
}

export interface CreateJobInput {
  project_id: string;
  user_id: string;
}

export async function createJob(
  client: SupabaseClient,
  input: CreateJobInput,
): Promise<string> {
  const { data, error } = await client
    .from("export_jobs")
    .insert({
      project_id: input.project_id,
      user_id: input.user_id,
      status: "pending",
      retry_count: 0,
      max_retries: 2,
    })
    .select("id")
    .single();

  if (error || !data) {
    throw new Error(`Failed to create export job: ${error?.message}`);
  }
  return data.id;
}

export interface UpdateJobInput {
  status?: ExportJobStatus;
  epub_temp_path?: string;
  validation_id?: string;
  epubcheck_version?: string;
  error_count?: number;
  warning_count?: number;
  diagnostics?: unknown;
  retry_count?: number;
  completed_at?: string;
  error_message?: string;
  export_metadata_id?: string;
}

export async function updateJobStatus(
  client: SupabaseClient,
  jobId: string,
  update: UpdateJobInput,
): Promise<void> {
  const { error } = await client
    .from("export_jobs")
    .update(update)
    .eq("id", jobId);

  if (error) {
    throw new Error(`Failed to update export job: ${error.message}`);
  }
}

export async function getJob(
  client: SupabaseClient,
  jobId: string,
): Promise<ExportJob | null> {
  const { data, error } = await client
    .from("export_jobs")
    .select("*")
    .eq("id", jobId)
    .single();

  if (error || !data) return null;
  return data as ExportJob;
}

export async function getJobRetryCount(
  client: SupabaseClient,
  jobId: string,
): Promise<number> {
  const job = await getJob(client, jobId);
  return job?.retry_count ?? 0;
}
