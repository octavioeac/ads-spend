#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# This script configures IAM roles and enables core APIs so that the
# GitHub Actions service account (DEPLOY_SA) can:
#   - Use Cloud Build (upload sources to *_cloudbuild bucket and build)
#   - Push images to Artifact Registry
#   - Deploy to Cloud Run (and impersonate the runtime SA)
#   - Read secrets from Secret Manager
#
# It is idempotent: re-running it is safe.
#
# Optional:
#   - Ensure the Cloud Build staging bucket exists and grant access
#   - Allow a human user to impersonate DEPLOY_SA for local tests
# --------------------------------------------------------------------

# --------- EDIT THESE IF NEEDED ----------
PROJECT_ID="n8n-ads-spend"
REGION="us-central1"
REPO="n8n-repo"                              # Artifact Registry repo (already created)
SERVICE="metrics-api"                        # Cloud Run service name
DEPLOY_SA="github-test@${PROJECT_ID}.iam.gserviceaccount.com"     # CI/CD SA
RUNTIME_SA="cr-metrics@${PROJECT_ID}.iam.gserviceaccount.com"     # Cloud Run runtime SA
# Set to your Gmail if you want to test impersonation from Cloud Shell:
HUMAN_USER_EMAIL="octavio.avarezdelcastillo@gmail.com"
# -----------------------------------------

CLOUDBUILD_BUCKET="${PROJECT_ID}_cloudbuild"

echo "==> Enabling required APIs on project: ${PROJECT_ID}"
gcloud services enable \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Granting base roles to CI/CD service account: ${DEPLOY_SA}"

# Allow the service account to use project services
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/serviceusage.serviceUsageConsumer"

# Cloud Build (submit builds). You may use 'roles/cloudbuild.builds.submitter' for least privilege.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/cloudbuild.builds.editor"

# Artifact Registry (push images)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/artifactregistry.writer"

# Cloud Run admin (deploy services)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/run.admin"

# Allow CI/CD SA to impersonate the Cloud Run runtime SA
gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

# Secret Manager (read secrets referenced in deploy)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor"

echo "==> Ensuring Cloud Build staging bucket exists: gs://${CLOUDBUILD_BUCKET}"
if ! gsutil ls -p "${PROJECT_ID}" "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CLOUDBUILD_BUCKET}"
fi

echo "==> Granting object admin on Cloud Build bucket to ${DEPLOY_SA}"
gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.objectAdmin" "gs://${CLOUDBUILD_BUCKET}" || true
# If needed, also grant legacy writer (some org policies still require it):
# gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.legacyBucketWriter" "gs://${CLOUDBUILD_BUCKET}" || true

# ---------------- Optional: local testing via impersonation ----------------
# This lets your human user mint tokens to act as DEPLOY_SA from Cloud Shell.
if [[ -n "${HUMAN_USER_EMAIL}" ]]; then
  echo "==> (Optional) Allowing ${HUMAN_USER_EMAIL} to impersonate ${DEPLOY_SA}"
  gcloud iam service-accounts add-iam-policy-binding "${DEPLOY_SA}" \
    --member="user:${HUMAN_USER_EMAIL}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="${PROJECT_ID}" || true
fi
# --------------------------------------------------------------------------

echo "==> Verification (quick checks)"
echo " - Project IAM bindings for ${DEPLOY_SA}:"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${DEPLOY_SA}" \
  --format="table(bindings.role)" || true

echo " - Bucket IAM (first lines):"
gsutil iam get "gs://${CLOUDBUILD_BUCKET}" | head -n 30 || true

echo "Configuration completed successfully.............."
