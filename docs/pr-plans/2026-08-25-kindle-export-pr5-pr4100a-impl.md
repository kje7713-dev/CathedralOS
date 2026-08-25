# PR-4100-A Implementation Plan — Kindle Export Backend (Cloud Run EPUBCheck Validator)

| Field | Value |
|---|---|
| Date locked | 2026-08-25 09:06 EDT |
| Status | LOCKED. Awaiting explicit go-ahead to branch `feat/kindle-export-pr5` off `main` and start coding. |
| Parent spec | `docs/pr-plans/2026-08-24-kindle-export-pr5.md` @ `e91e391` on branch `docs/kindle-export-pr5` |
| Target code branch | `feat/kindle-export-pr5` |
| Effort estimate | 7–9 days focused (per parent spec) |

## Architectural contract

> No Cathedral EPUB is released as successfully exported unless that exact generated artifact has passed the pinned official EPUBCheck validation. Known deterministic exporter defects may be repaired once and revalidated automatically before failure is surfaced to the user.

## Pre-implementation architectural correction

**Runtime:** CathedralOS edge functions run on **Supabase Edge Runtime** (Deno-Deploy-based with Supabase bindings). Limits: 256 MB memory, 400 s wall clock (paid plan), 2 s CPU time, no subprocess support. Java cannot run inside this runtime.

**Existing export pipeline:** none. PR-4100-A creates the first Cathedral export function (`export-epub`). "Existing Cathedral export pipeline" in the spec refers to the broader Supabase backend (generate-story, embed-section, coherence-check, run-outline, etc.) — EPUB generation stays inside that family; validation moves out to a dedicated Cloud Run service.

## Locked decisions (Kevin 2026-08-25 09:01 EDT)

1. **HMAC secret:** generate one strong random secret. Store the same value in Google Secret Manager (for Cloud Run) and Supabase Edge Function secrets (for Cathedral). Never commit to repo.
2. **Cloud Run region:** `us-east1` (Cathedral Supabase is in `us-east-1`; geographic proximity reduces latency/transfer distance).
3. **EPUBCheck version:** pin `5.3.0` specifically (latest production-ready W3C release; validates EPUB 3.3). Reproducible builds.
4. **GCP project:** no hardcoded ID in code. Deployment/config input via env var. Dedicated project suggested name `cathedral-epub-validator`. Actual project ID supplied at deploy time.
5. **Repairable error classes:** the 4 listed below (manifest/spine mismatches, missing generated files/references, missing required metadata when Cathedral already has the value, malformed generated XHTML/XML caused by escaping/sanitization).
6. **CI fixtures:** checked-in real Cathedral-generated EPUBs (minimal novel + medium novel + warning-only + malformed).

---

## 1. Existing export path and runtime

- **Path:** NEW — `supabase/functions/export-epub/` (greenfield)
- **Runtime:** Supabase Edge Runtime (Deno, no subprocess)
- **Implication:** EPUB writer in Deno; validation external on Cloud Run

## 2. Files / components that will change

**New — Backend (Supabase Edge Functions, Deno):**
- `supabase/functions/export-epub/index.ts` — orchestrator
- `supabase/functions/export-epub/_epub_writer.ts` — EPUB 3 generation
- `supabase/functions/export-epub/_section_walker.ts` — chapter/section ordering
- `supabase/functions/export-epub/_metadata.ts` — metadata assembly
- `supabase/functions/export-epub/_cover_image.ts` — DALL-E 3 + user-upload paths
- `supabase/functions/export-epub/_repair.ts` — bounded repair layer
- `supabase/functions/export-epub/_validator_client.ts` — transport-agnostic EPUBCheck client (**only file that knows Cloud Run exists**)
- `supabase/functions/export-epub/_job_status.ts` — async job tracking
- `supabase/functions/export-epub/index_test.ts` — tests
- `supabase/migrations/YYYYMMDD_kindle_export_schema.sql` — `export_metadata` + `export_jobs` + storage bucket + RLS

**New — Cloud Run EPUBCheck validator:**
- `infra/epubcheck-validator/`
  - `Dockerfile` — Java 17 + pinned EPUBCheck 5.3.0 JAR
  - `src/main/java/.../Application.java` — Javalin 6.x thin HTTP server
  - `src/main/java/.../EpubcheckService.java` — runs EPUBCheck, parses output, returns structured JSON
  - `src/main/java/.../TempFileManager.java` — randomized temp dirs, guaranteed cleanup
  - `pom.xml` — Maven build
  - `application.yaml` — config (HMAC env, timeout, max size)
  - `deploy.sh` — `gcloud run deploy`
  - `Dockerfile.test` — for CI fixture validation
  - `README.md` — deploy + rotate secrets

**Modified:** none (greenfield)

**New Supabase secrets:**
- `EPUBCHECK_VALIDATOR_URL` — Cloud Run service URL
- `EPUBCHECK_VALIDATOR_HMAC_SECRET` — shared HMAC secret

**New CI workflow:**
- `.github/workflows/epubcheck-fixtures-test.yml` — runs EPUBCheck against Cathedral-generated fixtures

## 3. Cloud Run validator service structure

**Stack:** Java 17, Javalin 6.x (~5 MB), official W3C EPUBCheck 5.3.0 JAR (pinned).

**Endpoint:** `POST /v1/validate`
- Request: JSON `{ epub_storage_path: string, validation_id: string }` + HMAC header
- Response: structured JSON (see §6)
- Errors: 401 invalid HMAC / 413 size limit / 408 timeout / 500 internal / 503 unavailable

**Flow inside validator:**
1. Verify HMAC signature (constant-time compare) + timestamp window (±5 min skew)
2. Check EPUB size ≤ limit
3. Download EPUB from signed URL to randomized temp dir
4. Run fixed CLI: `java -jar epubcheck.jar <tempfile> --mode exp --profile default --json` (callers cannot inject args)
5. Parse output → structured JSON
6. Always cleanup temp dir (finally block)
7. Return response

**Scale config:**
- min-instances = 0 (scale to zero)
- max-instances = 5
- memory = 1 GiB, cpu = 1
- concurrency = 4 (4 validations per instance)
- timeout = 60 s
- request-based billing

## 4. Authentication method

**HMAC-SHA256 shared secret.** Validator publishes single `HMAC_SECRET` env var (from Google Secret Manager). Supabase side sends:

```
X-Epubcheck-Signature: t=<unix_ts>,v1=<hex(hmac_sha256(secret, ts + body))>
```

Validator verifies timestamp within ±5 min + HMAC match (constant-time). Replay protection via timestamp window.

**Why HMAC over IAM:** no service-account JSON in Supabase secrets; portable to AWS Lambda later if we change providers. Trade-off: manual secret rotation (not IAM-auto).

## 5. Direct-upload vs signed-URL transport

**Decision: signed URL.**

**Rationale:**
- Cloud Run default request body limit = 32 MB; very long novels may exceed
- Direct POST binaries through Edge Function waste both Edge Function CPU + Cloud Run ingress
- Signed URL keeps EPUB on Supabase Storage throughout — single source of truth, no copies
- Supabase signed URLs short-lived (5 min default) — secure by default
- Fall back to direct POST later is a one-file change in `_validator_client.ts`

**Flow:**
1. Export function uploads generated EPUB to `export-tmp/<job_id>.epub` in Storage
2. Export function generates 5-min signed URL
3. Export function POSTs `{ epub_storage_path: <signed_url>, validation_id: <job_id> }` + HMAC to Cloud Run
4. Cloud Run downloads, validates, returns JSON
5. Export function deletes `export-tmp/<job_id>.epub` after validation completes

## 6. Diagnostic schema

```json
{
  "validation_id": "uuid",
  "epubcheck_version": "5.3.0",
  "validation_duration_ms": 1234,
  "valid": false,
  "error_count": 2,
  "warning_count": 1,
  "diagnostics": [
    {
      "severity": "fatal" | "error" | "warning" | "info",
      "code": "OPF-001",
      "message": "Invalid OPF spine item",
      "file": "OEBPS/content.opf",
      "line": 42,
      "column": 13
    }
  ]
}
```

- `valid` = (error_count === 0 && fatal_count === 0)
- `severity` maps EPUBCheck's FATAL/ERROR/WARN/INFO
- `code` is the EPUBCheck message code (e.g., `OPF-001`, `RSC-005`)
- `file` is internal EPUB path (e.g., `OEBPS/content.opf`), not host FS path
- `line`/`column` 1-based; nullable when EPUBCheck doesn't provide them

**Persisted to `export_jobs.diagnostics` JSONB column.** No novel content stored.

## 7. Repairable error classes included in this PR

| Class | Example defect | Repair action |
|---|---|---|
| **Manifest/spine mismatch** | spine references missing section | Regenerate spine from `OutlineSection` query |
| **Missing generated file/ref** | OPF href to non-existent xhtml | Re-emit missing file from source data |
| **Missing required metadata** | `dc:title` empty when Cathedral has one | Pull from Cathedral data + rewrite OPF |
| **Malformed XHTML/XML from escaping** | unescaped `&` in generated text | Re-sanitize + rewrite affected content doc |

**NOT in scope for PR-4100-A repair:**
- EPUBCheck errors that aren't Cathedral's fault
- Spec compliance requiring writer redesign (track in `repair_backlog` for follow-up)
- Anything outside the 4 classes above

**Strategy:** deterministic pattern match against known defects. No match → skip repair → final validation → fail.

**Bounded:** initial validation → max 1 repair → final validation → surface failure. No retry loop.

## 8. Failure UX

**PASS:**
- Job: `pending → writing → validating → validated → uploaded`
- User: success state + "Preview" (Readium) + "Download"

**INVALID after repair attempt:**
- Job: `pending → writing → validating → repairing → writing → validating → failed_validation`
- User: "Export failed during validation. Reference: `<job_id>`" with diagnostic summary (codes + messages, NOT novel content)
- Logs: full structured diagnostics + offending internal EPUB paths persisted

**VALIDATOR FAILURE** (network/timeout/outage/malformed):
- Job: `pending → writing → validating → failed_validator` (distinct from `failed_validation`)
- User: "Validation service unavailable. Please try again." with retry
- System: client retries up to 2× with exponential backoff before `failed_validator`
- Fail closed: never silently bypass validation

**v1 rules:**
- EPUBCheck errors + fatals block release
- Warnings logged but don't block
- No `--failonwarnings`

## 9. Tests

**Backend (`export-epub/index_test.ts`):**
- Valid EPUB passes
- Malformed EPUB fails
- Warning-only EPUB downloads
- Structured EPUBCheck errors parsed correctly
- Known repairable defect → repair → second validation passes
- Unrepaired defect remains blocked
- Validator timeout distinguished from EPUB invalidity (mock 30 s delay → `failed_validator`)
- Validator outage distinguished (mock 500 → `failed_validator`)
- Validator cannot be bypassed on production export
- Temp files cleaned up
- Auth rejection works (invalid HMAC → 401)
- Pinned EPUBCheck version verifiable (parse + assert `5.3.0`)

**Cloud Run validator (Java):**
- HMAC verification (valid/invalid/expired)
- Size limit enforcement
- Timeout enforcement
- Temp file cleanup (success + failure paths)
- CLI args are fixed (no injection)

**CI fixtures** (`.github/workflows/epubcheck-fixtures-test.yml`):
- Run EPUBCheck 5.3.0 against representative Cathedral-generated EPUBs
- Fixtures: minimal novel (1 chapter / 3 sections), medium novel (5 chapters / 25 sections), warning-only, malformed
- Asserts expected pass/fail/warning outcome per fixture

## 10. Deployment / config / secrets

**Cloud Run deploy (`infra/epubcheck-validator/deploy.sh`):**

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${GCP_PROJECT:?Set GCP_PROJECT to your GCP project ID}"
: "${EPUBCHECK_VERSION:=5.3.0}"
: "${REGION:=us-east1}"
: "${HMAC_SECRET_SECRET_NAME:?Set to the Google Secret Manager secret name}"

gcloud run deploy epubcheck-validator \
  --project "${GCP_PROJECT}" \
  --image "gcr.io/${GCP_PROJECT}/epubcheck-validator:${EPUBCHECK_VERSION}" \
  --region "${REGION}" \
  --min-instances 0 --max-instances 5 \
  --memory 1Gi --cpu 1 --timeout 60s --concurrency 4 \
  --no-allow-unauthenticated \
  --set-secrets "HMAC_SECRET=${HMAC_SECRET_SECRET_NAME}:latest" \
  --set-env-vars "EPUBCHECK_VERSION=${EPUBCHECK_VERSION},MAX_EPUB_SIZE_MB=100"
```

**Secrets:**
- Google Secret Manager: `EPUBCHECK_HMAC_SECRET` (32+ random bytes) — name supplied at deploy time
- Supabase: `EPUBCHECK_VALIDATOR_URL`, `EPUBCHECK_VALIDATOR_HMAC_SECRET`

**IAM:** service account `epubcheck-validator-sa` with `roles/run.invoker` only; `--no-allow-unauthenticated` blocks public access.

**Supabase:** migration applied via `supabase db push`; function deployed via `supabase functions deploy export-epub`.

---

## Architectural separation

`_validator_client.ts` is the ONLY file in the export pipeline that knows Cloud Run exists.
- Interface: `validateEpub(signedUrl, validationId): Promise<ValidationResult>`
- Swap Cloud Run → AWS Lambda: rewrite one file
- Swap signed-URL → direct POST: rewrite one file
- Mock for tests: substitute one file

## Pre-flight before code branch

1. Create GCP project (if doesn't exist) + service account `epubcheck-validator-sa` with `roles/run.invoker`
2. Generate HMAC secret (32+ bytes random); create `EPUBCHECK_HMAC_SECRET` in Google Secret Manager
3. Mirror HMAC secret to Supabase Edge Function secrets (`EPUBCHECK_VALIDATOR_HMAC_SECRET`)
4. Verify `supabase/.temp/linked-project.json` is current
5. Pre-PR survey (kevbot-brain #227) for edge function location
6. Download EPUBCheck 5.3.0 JAR from W3C; vendor into `infra/epubcheck-validator/lib/`
7. Verify DALL-E 3 wiring + cost per image (~$0.04)
8. Verify Deno Deploy cold start time for a 50-section novel

## Risks

- **EPUBCheck 5.3.0 JAR size:** ~30 MB; Cloud Run container ~50 MB total. Within limits.
- **Deno-native structural validator is NOT shipped** (Option 2 chosen). All validation goes through Cloud Run; if Cloud Run is down, exports fail closed.
- **DALL-E 3 latency:** ~10-30 s per cover auto-gen; affects cover-image path only.
- **30-day GC:** requires scheduled cron (separate workflow from main deploy).
- **Async job state recovery:** if edge function restarts mid-export, job status in `export_jobs` table should support resume; v1 may simply fail those jobs.
- **EPUB 3.3 compliance:** EPUBCheck 5.3.0 validates EPUB 3.3; we write EPUB 3.0 (per spec); should be subset-valid.

## Follow-ups (out of scope for PR-4100-A)

- **PR-4100-B** — iOS pre-export screen (2-3 days)
- **PR-4100-C** — iOS Readium preview + EPUB download (2-3 days)
- **Polish** — across all 3 PRs (1.5-2 days)
- **Readium SDK version** — resolve 2.x vs 3.x during PR-4100-C impl
- **Phase 5 (Remix), Phase 6 (Continue), Chapter Reader PR #3 (Iteration)** — per novel-building arc, separate kickoffs

## kevbot-brain / memory pointers

- This doc: kevbot-brain chunk (workflow, importance 9) + MEMORY.md pointer line
- Companion: chunk #329 (Kindle export spec pointer at `e91e391`)
- Pre-PR survey: kevbot-brain #227 (CathedralOS iOS source folder structure + pre-PR survey protocol)
