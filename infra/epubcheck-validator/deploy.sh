#!/usr/bin/env bash
# =============================================================================
# Deploy epubcheck-validator to Google Cloud Run
#
# Required env vars (or pass as args):
#   GCP_PROJECT                  — GCP project ID (suggested: cathedral-epub-validator)
#   HMAC_SECRET_SECRET_NAME      — Google Secret Manager secret name (e.g., EPUBCHECK_HMAC_SECRET)
#
# Optional:
#   EPUBCHECK_VERSION            — default 5.3.0
#   REGION                       — default us-east1
#   IMAGE_TAG                    — default =EPUBCHECK_VERSION
# =============================================================================

set -euo pipefail

: "${GCP_PROJECT:?Set GCP_PROJECT to your GCP project ID}"
: "${HMAC_SECRET_SECRET_NAME:=EPUBCHECK_HMAC_SECRET}"

EPUBCHECK_VERSION="${EPUBCHECK_VERSION:-5.3.0}"
REGION="${REGION:-us-east1}"
IMAGE_TAG="${IMAGE_TAG:-${EPUBCHECK_VERSION}}"
IMAGE="gcr.io/${GCP_PROJECT}/epubcheck-validator:${IMAGE_TAG}"

echo "==> Building image: ${IMAGE}"
gcloud builds submit \
  --project "${GCP_PROJECT}" \
  --tag "${IMAGE}" \
  --timeout 10m \
  infra/epubcheck-validator

echo "==> Deploying to Cloud Run (region: ${REGION})"
gcloud run deploy epubcheck-validator \
  --project "${GCP_PROJECT}" \
  --image "${IMAGE}" \
  --region "${REGION}" \
  --platform managed \
  --service-account "epubcheck-validator-sa@${GCP_PROJECT}.iam.gserviceaccount.com" \
  --min-instances 0 \
  --max-instances 5 \
  --memory 1Gi \
  --cpu 1 \
  --timeout 60s \
  --concurrency 4 \
  --allow-unauthenticated \
  --set-secrets "HMAC_SECRET=${HMAC_SECRET_SECRET_NAME}:latest" \
  --set-env-vars "EPUBCHECK_VERSION=${EPUBCHECK_VERSION},MAX_EPUB_SIZE_MB=100"

echo "==> Deploy complete. Capture the service URL:"
gcloud run services describe epubcheck-validator \
  --project "${GCP_PROJECT}" \
  --region "${REGION}" \
  --format='value(status.url)'
