// =============================================================================
// index.ts — export-epub Supabase Edge Function
//
// Orchestrates the Kindle export pipeline (Chapter Reader PR #5).
// Per docs/pr-plans/2026-08-25-kindle-export-pr5-pr4100a-impl.md
//
// Endpoints:
//   POST /export-epub         → create job, kick off background processing
//   GET  /export-epub/status?job_id=X → poll status
//
// Flow:
//   writing → validating → (if invalid) repairing → validating →
//     (if valid) validated → uploaded
//   On VALIDATOR FAILURE (network/timeout/5xx): retryable up to 2× →
//     failed_validator (distinct from failed_validation, fail closed)
//   On invalid EPUB that can't be repaired: failed_validation
// =============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  validateEpub,
  type ValidationResult,
  ValidatorFailureError,
} from "./_validator_client.ts";
import { createJob, getJob, updateJobStatus } from "./_job_status.ts";
import { type ProjectOutline, walkSections } from "./_section_walker.ts";
import {
  assembleMetadata,
  type ExportMetadata,
  type ExportRequest,
} from "./_metadata.ts";
import {
  buildCoverPrompt,
  type CoverResult,
  generateOrFetchCover,
} from "./_cover_image.ts";
import {
  AiCoverInsufficientCreditsError,
  estimateAiCoverBilling,
  refundAiCoverCredits,
  reserveAiCoverCredits,
  settleAiCoverCredits,
} from "./_cover_billing.ts";
import { writeEpub } from "./_epub_writer.ts";
import { attemptRepair, type RepairContext } from "./_repair.ts";

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*\/export-epub/, "");

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "missing_authorization" }, 401);

    const { data: { user }, error: authError } = await supabaseAdmin.auth
      .getUser(
        authHeader.replace("Bearer ", ""),
      );
    if (authError || !user) return json({ error: "invalid_token" }, 401);

    if (req.method === "POST" && (path === "" || path === "/")) {
      return await handleExport(req, user.id);
    }
    if (req.method === "GET" && path === "/status") {
      return await handleStatus(req, user.id);
    }

    return json({ error: "not_found" }, 404);
  } catch (err) {
    console.error("Unhandled error:", err);
    return json({ error: "internal_error", message: String(err) }, 500);
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function handleExport(req: Request, userId: string): Promise<Response> {
  const body = (await req.json()) as ExportRequest;

  if (!body.project_id || !body.book_title || !body.author_name) {
    return json({
      error: "missing_required_fields",
      required: ["project_id", "book_title", "author_name"],
    }, 400);
  }

  // Two-ID boundary: localProjectId is the iOS-side UUID (project_snapshots.local_project_id);
  // snapshotProjectId is the server-generated row PK (FK target for export_jobs + export_metadata).
  const localProjectId = body.project_id;
  const { data: project, error: projectError } = await supabaseAdmin
    .from("project_snapshots")
    .select("id, user_id")
    .eq("user_id", userId)
    .eq("local_project_id", localProjectId)
    .maybeSingle();

  if (projectError || !project) {
    return json({ error: "project_not_found" }, 404);
  }
  // No separate user_id !== userId check: filtering by user_id already scoped the lookup;
  // returning 404 (not 403) avoids leaking existence of other users' projects.

  const snapshotProjectId = project.id;
  const jobId = await createJob(supabaseAdmin, {
    project_id: snapshotProjectId,
    user_id: userId,
  });

  // Background processing via Supabase's EdgeRuntime.waitUntil
  // @ts-ignore - EdgeRuntime is globally available in Supabase Edge Runtime
  EdgeRuntime.waitUntil(
    processJob(jobId, body, userId, localProjectId, snapshotProjectId),
  );

  return json({ job_id: jobId, status: "pending" }, 202);
}

async function processJob(
  jobId: string,
  req: ExportRequest,
  userId: string,
  localProjectId: string,
  snapshotProjectId: string,
): Promise<void> {
  let attemptCount = 0;
  let aiCoverReserved = false;
  let coverReady = false;
  let cachedCover: CoverResult | null = null;
  let aiCoverBilling: ReturnType<typeof estimateAiCoverBilling> | null = null;

  // Outer loop for VALIDATOR FAILURE retries (max 2 per job)
  while (true) {
    try {
      // ============ WRITING ============
      await updateJobStatus(supabaseAdmin, jobId, { status: "writing" });

      const metadata = assembleMetadata(req);
      const outline: ProjectOutline = await walkSections(
        supabaseAdmin,
        userId,
        localProjectId,
        snapshotProjectId,
      );
      if (!coverReady) {
        if (req.cover_image_ai_generate && !aiCoverReserved) {
          try {
            const estimatedBilling = estimateAiCoverBilling(
              buildCoverPrompt(outline),
            );
            await reserveAiCoverCredits(
              supabaseAdmin,
              userId,
              jobId,
              estimatedBilling,
            );
            aiCoverReserved = true;
          } catch (err) {
            const message = err instanceof AiCoverInsufficientCreditsError
              ? "Not enough credits for an AI-generated cover."
              : String(err);
            await updateJobStatus(supabaseAdmin, jobId, {
              status: "failed_validation",
              completed_at: new Date().toISOString(),
              error_message: message,
            });
            return;
          }
        }
        cachedCover = await generateOrFetchCover(supabaseAdmin, req, outline);
        aiCoverBilling = cachedCover?.billing ?? null;
        coverReady = true;
      }
      const coverBuffer = cachedCover?.bytes ?? null;

      let epub: Uint8Array = await writeEpub(metadata, outline, coverBuffer);

      // ============ VALIDATION + BOUNDED REPAIR ============
      let repairAttempts = 0;
      let result: ValidationResult | null = null;
      let tempPath = `export-tmp/${jobId}.epub`;

      while (repairAttempts <= 1) {
        await updateJobStatus(supabaseAdmin, jobId, { status: "validating" });

        // Upload to export-tmp/
        const { error: uploadError } = await supabaseAdmin.storage
          .from("export-tmp")
          .upload(tempPath, epub, {
            contentType: "application/epub+zip",
            upsert: true,
          });
        if (uploadError) {
          throw new Error(
            `upload to export-tmp failed: ${uploadError.message}`,
          );
        }

        // Generate 5-min signed URL
        const { data: signedUrlData, error: signError } = await supabaseAdmin
          .storage
          .from("export-tmp")
          .createSignedUrl(tempPath, 300);
        if (signError || !signedUrlData) {
          throw new Error(`createSignedUrl failed: ${signError?.message}`);
        }
        const signedUrl = signedUrlData.signedUrl;

        // Validate via Cloud Run (will throw ValidatorFailureError on network issues)
        result = await validateEpub(signedUrl, jobId);

        // Record validation result
        await updateJobStatus(supabaseAdmin, jobId, {
          validation_id: result.validation_id,
          epubcheck_version: result.epubcheck_version,
          error_count: result.error_count,
          warning_count: result.warning_count,
          diagnostics: result.diagnostics,
        });

        if (result.valid) break; // success — exit repair loop

        // INVALID — attempt repair on first try only
        if (repairAttempts === 0) {
          await updateJobStatus(supabaseAdmin, jobId, { status: "repairing" });
          const repairContext: RepairContext = {
            metadata,
            outline,
            coverBuffer,
          };
          const repair = await attemptRepair(
            epub,
            result.diagnostics,
            repairContext,
          );
          if (repair.repaired && repair.epub) {
            epub = repair.epub;
            repairAttempts++;
            continue; // re-validate
          }
        }

        // Could not repair or second attempt failed
        await supabaseAdmin.storage.from("export-tmp").remove([tempPath]);
        await updateJobStatus(supabaseAdmin, jobId, {
          status: "failed_validation",
          completed_at: new Date().toISOString(),
          error_message:
            `EPUB failed EPUBCheck validation (v${result.epubcheck_version}) after ${
              repairAttempts + 1
            } attempt(s); ${result.error_count} error(s), ${result.warning_count} warning(s)`,
        });
        return;
      }

      // ============ VALIDATED — promote to final bucket ============
      if (!result || !result.valid) {
        throw new Error("validation loop exited without result");
      }

      await updateJobStatus(supabaseAdmin, jobId, { status: "validated" });

      const finalPath = `exports/${localProjectId}/${jobId}.epub`;

      // Compute SHA-256 of the validated EPUB
      const sha256Hex = await sha256HexOf(epub);

      // Upload to final bucket
      const { error: finalUploadError } = await supabaseAdmin.storage
        .from("exports")
        .upload(finalPath, epub, {
          contentType: "application/epub+zip",
          upsert: true,
        });
      if (finalUploadError) {
        throw new Error(
          `upload to exports failed: ${finalUploadError.message}`,
        );
      }

      // Cleanup temp
      await supabaseAdmin.storage.from("export-tmp").remove([tempPath]);

      // Replace the current/active metadata row inside one database transaction.
      // The partial unique indexes reject a new current/active row if the old one
      // is demoted afterward; the RPC keeps history while making replacement atomic.
      const { data: metaId, error: metaError } = await supabaseAdmin.rpc(
        "replace_export_metadata",
        {
          p_project_id: snapshotProjectId,
          p_book_title: metadata.book_title,
          p_author_name: metadata.author_name,
          p_copyright_year: metadata.copyright_year ?? null,
          p_copyright_holder: metadata.copyright_holder ?? null,
          p_language: metadata.language,
          p_dedication: metadata.dedication ?? null,
          p_book_description: metadata.book_description ?? null,
          p_about_author: metadata.about_author ?? null,
          p_isbn: metadata.isbn ?? null,
          p_publisher_name: metadata.publisher_name ?? null,
          p_series_name: metadata.series_name ?? null,
          p_series_number: metadata.series_number ?? null,
          p_cover_image_url: req.cover_image_url ?? null,
          p_cover_image_ai_generated: req.cover_image_ai_generate ?? false,
          p_epub_storage_path: finalPath,
          p_epub_sha256: sha256Hex,
          p_exported_by_user_id: userId,
        },
      );

      if (metaError || !metaId) {
        throw new Error(
          `Failed to create export_metadata: ${metaError?.message}`,
        );
      }

      if (aiCoverReserved) {
        if (!aiCoverBilling) {
          throw new Error("AI cover generation returned no billing usage");
        }
        await settleAiCoverCredits(
          supabaseAdmin,
          userId,
          jobId,
          aiCoverBilling,
        );
        aiCoverReserved = false;
      }
      await updateJobStatus(supabaseAdmin, jobId, {
        status: "uploaded",
        export_metadata_id: metaId,
        completed_at: new Date().toISOString(),
      });

      return;
    } catch (err) {
      if (err instanceof ValidatorFailureError) {
        // VALIDATOR FAILURE — retryable per job (max 2)
        const job = await getJob(supabaseAdmin, jobId);
        const retryCount = job?.retry_count ?? 0;
        const maxRetries = job?.max_retries ?? 2;

        if (retryCount < maxRetries) {
          // Exponential backoff: 1s, 2s
          await sleep(Math.pow(2, retryCount) * 1000);
          await updateJobStatus(supabaseAdmin, jobId, {
            retry_count: retryCount + 1,
          });
          attemptCount++;
          continue; // retry the whole pipeline
        }

        // Exhausted retries — fail closed, do NOT mark EPUB as validated
        if (aiCoverReserved) {
          await refundAiCoverCredits(supabaseAdmin, userId, jobId);
          aiCoverReserved = false;
        }
        await updateJobStatus(supabaseAdmin, jobId, {
          status: "failed_validator",
          completed_at: new Date().toISOString(),
          error_message:
            `Validator failure (category=${err.category}) after ${retryCount} retry(s): ${err.message}`,
        });
        return;
      }

      // Other failure (writer error, storage error, etc.) — fail closed.
      // The customer did not receive a usable export, so release the cover
      // reservation. The RPC is itself idempotent.
      if (aiCoverReserved) {
        await refundAiCoverCredits(supabaseAdmin, userId, jobId);
        aiCoverReserved = false;
      }
      console.error("Job failed:", err);
      await updateJobStatus(supabaseAdmin, jobId, {
        status: "failed_validation",
        completed_at: new Date().toISOString(),
        error_message: String(err),
      });
      return;
    }
  }
}

async function handleStatus(req: Request, userId: string): Promise<Response> {
  const url = new URL(req.url);
  const jobId = url.searchParams.get("job_id");
  if (!jobId) return json({ error: "missing_job_id" }, 400);

  const job = await getJob(supabaseAdmin, jobId);
  if (!job) return json({ error: "job_not_found" }, 404);
  if (job.user_id !== userId) return json({ error: "forbidden" }, 403);

  return json({
    job_id: job.id,
    status: job.status,
    error_count: job.error_count,
    warning_count: job.warning_count,
    diagnostics: job.diagnostics,
    epubcheck_version: job.epubcheck_version,
    retry_count: job.retry_count,
    export_metadata_id: job.export_metadata_id,
    created_at: job.created_at,
    completed_at: job.completed_at,
    error_message: job.error_message,
  });
}

async function sha256HexOf(bytes: Uint8Array): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
