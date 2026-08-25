# epubcheck-validator

Google Cloud Run service that validates EPUB files using the **official W3C EPUBCheck 5.3.0 JAR**.

Per `docs/pr-plans/2026-08-25-kindle-export-pr5-pr4100a-impl.md`.

## Architecture

- **Stack:** Java 17 + Javalin 6.x thin HTTP server (~5 MB app JAR)
- **EPUBCheck:** official W3C JAR (pinned to 5.3.0, vendored into the container)
- **Auth:** HMAC-SHA256 shared secret from Google Secret Manager
- **Transport:** receives signed URL pointing at Supabase Storage; downloads EPUB, validates, returns structured JSON
- **Security:** fixed CLI args, size limits, timeouts, randomized temp dirs, guaranteed cleanup, bounded concurrency, no persistent storage, public Cloud Run ingress with HMAC-protected validation endpoint

## Endpoints

### `POST /v1/validate`

Validate an EPUB.

**Headers:**
- `X-Epubcheck-Signature: t=<unix_ts>,v1=<hex(hmac_sha256(secret, ts + "." + body))>`

**Body:**
```json
{
  "epub_storage_path": "<signed_url_to_supabase_storage>",
  "validation_id": "<uuid>"
}
```

**Response (200 OK):**
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
      "severity": "fatal",
      "code": "OPF-001",
      "message": "Invalid OPF spine item",
      "file": "OEBPS/content.opf",
      "line": 42,
      "column": 13
    }
  ]
}
```

**Errors:**
- `401` — missing/malformed/invalid signature, expired timestamp
- `400` — invalid JSON or missing required fields
- `413` — EPUB exceeds `MAX_EPUB_SIZE_MB`
- `502` — download from signed URL failed
- `408` — EPUBCheck timed out
- `500` — internal validation error

### `GET /health`

Health check. Returns `{"status": "ok", "epubcheck_version": "5.3.0"}`.

## Environment variables

| Var | Required | Default | Notes |
|---|---|---|---|
| `HMAC_SECRET` | yes | — | 32+ byte secret from Google Secret Manager |
| `EPUBCHECK_JAR` | no | `/app/epubcheck.jar` | Path to vendored EPUBCheck JAR |
| `EPUBCHECK_TIMEOUT_SECONDS` | no | `60` | Per-validation timeout |
| `MAX_EPUB_SIZE_MB` | no | `100` | Rejects EPUBs over this size |
| `PORT` | no | `8080` | HTTP listen port |

## Deploy

### Prerequisites

1. GCP project (suggested name: `cathedral-epub-validator`)
2. `gcloud` CLI authenticated
3. Supabase Edge Function secrets access

### One-time setup

```bash
# 1. Create GCP project (if doesn't exist)
gcloud projects create cathedral-epub-validator --name="Cathedral EPUB Validator"
gcloud config set project cathedral-epub-validator

# 2. Enable required APIs
gcloud services enable run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com

# 3. Create service account for Cloud Run runtime identity
gcloud iam service-accounts create epubcheck-validator-sa \
  --display-name="EPUB Check Validator Service Account"

# 4. Generate HMAC secret (32+ random bytes)
HMAC=$(openssl rand -hex 32)

# 5. Store in Google Secret Manager
echo -n "$HMAC" | gcloud secrets create EPUBCHECK_HMAC_SECRET \
  --replication-policy=automatic --data-file=-

# 6. Allow the Cloud Run runtime identity to read only this secret
gcloud secrets add-iam-policy-binding EPUBCHECK_HMAC_SECRET \
  --member="serviceAccount:epubcheck-validator-sa@cathedral-epub-validator.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 7. Mirror the HMAC secret to Supabase
supabase secrets set EPUBCHECK_VALIDATOR_HMAC_SECRET="$HMAC"
```

### Deploy

```bash
export GCP_PROJECT=cathedral-epub-validator
./deploy.sh

SERVICE_URL=$(gcloud run services describe epubcheck-validator \
  --project "$GCP_PROJECT" \
  --region us-east1 \
  --format='value(status.url)')

supabase secrets set EPUBCHECK_VALIDATOR_URL="$SERVICE_URL"
```

The deploy script:
1. Builds the container image (Cloud Build)
2. Pushes to `gcr.io/${GCP_PROJECT}/epubcheck-validator:5.3.0`
3. Deploys to Cloud Run in `us-east1` with scale-to-zero (min=0, max=5)
4. Wires `HMAC_SECRET` from Secret Manager
5. Prints the service URL

### Smoke test

```bash
SERVICE_URL=$(gcloud run services describe epubcheck-validator \
  --region=us-east1 --format='value(status.url)')

# /health
curl "$SERVICE_URL/health"

# /v1/validate with HMAC
HMAC_SECRET=$(gcloud secrets versions access latest --secret=EPUBCHECK_HMAC_SECRET)
TS=$(date +%s)
BODY='{"epub_storage_path":"https://your-supabase-storage/signed-url","validation_id":"test-uuid"}'
SIG=$(printf "%s.%s" "$TS" "$BODY" | openssl dgst -sha256 -hmac "$HMAC_SECRET" -hex | awk '{print $2}')
curl -X POST "$SERVICE_URL/v1/validate" \
  -H "Content-Type: application/json" \
  -H "X-Epubcheck-Signature: t=${TS},v1=${SIG}" \
  -d "$BODY"
```

## Resource consumption

- **Memory:** 1 GiB (Cloud Run container limit; EPUBCheck itself needs ~200 MB)
- **CPU:** 1 vCPU (EPUBCheck is single-threaded)
- **Concurrency:** 4 validations per instance (bounded)
- **Timeout:** 60 s per request
- **Cold start:** ~3-5 s (Java + JRE)

## Architecture contract

Per PR-4100-A impl plan: this validator is the **only** mechanism by which Cathedral EPUBs are released. EPUBs that fail validation OR fail to validate (network/timeout) are NOT released. Failures are categorized:
- `failed_validation` — EPUB invalid (errors/fatals detected), after bounded repair attempt
- `failed_validator` — validator unreachable/timed out, retryable up to 2×, then fail closed

## References

- EPUBCheck: https://github.com/w3c/epubcheck (v5.3.0 release)
- Javalin: https://javalin.io
- Cloud Run: https://cloud.google.com/run/docs
