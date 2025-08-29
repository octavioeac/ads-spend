#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# CI/CD Setup Wizard for Google Cloud (GitHub Actions)
#
# This script:
#   • Interactively collects core config (Project ID, region, repo, service)
#   • Grants IAM roles to the CI/CD Service Account (DEPLOY_SA)
#   • Ensures the Cloud Build staging bucket exists and is accessible
#   • Ensures the Cloud Build Service Agent identity exists and has its role
#   • (Optional) Creates/updates the API_KEY secret in Secret Manager
#   • Prints a summary of the configuration
#
# Safe to re-run (idempotent where possible).
# --------------------------------------------------------------------

echo "=== CI/CD Setup Wizard ==="

# 1) PROJECT_ID → detect from gcloud config or ask
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT_ID}" ]]; then
  read -rp "Enter your GCP Project ID: " PROJECT_ID
fi
echo "Using PROJECT_ID=${PROJECT_ID}"

# 2) REGION → default
DEFAULT_REGION="us-central1"
read -rp "Enter region for Cloud Run / Artifact Registry [default: ${DEFAULT_REGION}]: " REGION
REGION="${REGION:-${DEFAULT_REGION}}"
echo "Using REGION=${REGION}"

# 3) REPO → Artifact Registry repo name
DEFAULT_REPO="n8n-repo"
read -rp "Enter Artifact Registry repo name [default: ${DEFAULT_REPO}]: " REPO
REPO="${REPO:-${DEFAULT_REPO}}"
echo "Using REPO=${REPO}"

# 4) SERVICE → Cloud Run service name
DEFAULT_SERVICE="metrics-api"
read -rp "Enter Cloud Run service name [default: ${DEFAULT_SERVICE}]: " SERVICE
SERVICE="${SERVICE:-${DEFAULT_SERVICE}}"
echo "Using SERVICE=${SERVICE}"

# 5) RUNTIME_SA → runtime Service Account (email is <name>@<project>.iam.gserviceaccount.com)
DEFAULT_RUNTIME_SA_NAME="cr-metrics"
read -rp "Enter runtime Service Account NAME [default: ${DEFAULT_RUNTIME_SA_NAME}]: " RUNTIME_SA_NAME
RUNTIME_SA_NAME="${RUNTIME_SA_NAME:-${DEFAULT_RUNTIME_SA_NAME}}"
RUNTIME_SA="${RUNTIME_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "Using RUNTIME_SA=${RUNTIME_SA}"

# 6) BigQuery dataset/table (static defaults, change if needed)
DATASET="ads_warehouse"
TABLE="ads_spend_raw"
echo "Using BigQuery DATASET=${DATASET} TABLE=${TABLE}"

# 7) Secret (for API_KEY)
DEFAULT_SECRET="metrics-api-key"
read -rp "Enter Secret Manager name for API_KEY [default: ${DEFAULT_SECRET}]: " SECRET_NAME
SECRET_NAME="${SECRET_NAME:-${DEFAULT_SECRET}}"

DEFAULT_API_KEY_VALUE="super-secret"
read -rp "Enter initial API_KEY value (press Enter to skip/keep existing) [default: ${DEFAULT_API_KEY_VALUE}]: " API_KEY_VALUE
API_KEY_VALUE="${API_KEY_VALUE:-${DEFAULT_API_KEY_VALUE}}"

# 8) DEPLOY_SA (the CI/CD service account used by GitHub Actions)
DEFAULT_DEPLOY_SA="github-test@${PROJECT_ID}.iam.gserviceaccount.com"
read -rp "Enter Deploy Service Account EMAIL [default: ${DEFAULT_DEPLOY_SA}]: " DEPLOY_SA
DEPLOY_SA="${DEPLOY_SA:-${DEFAULT_DEPLOY_SA}}"
echo "Using DEPLOY_SA=${DEPLOY_SA}"

# 9) PROJECT_NUMBER (fetch dynamically)
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
echo "Detected PROJECT_NUMBER=${PROJECT_NUMBER}"

# Derived
CLOUDBUILD_BUCKET="${PROJECT_ID}_cloudbuild"
CB_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo
echo "==> Enabling required APIs on project ${PROJECT_ID}..."
gcloud services enable \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  serviceusage.googleapis.com \
  --project="${PROJECT_ID}"

echo "==> Granting roles to CI/CD Service Account: ${DEPLOY_SA}"

# Use project services
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/serviceusage.serviceUsageConsumer"

# Cloud Build (submit builds). For least privilege, you can swap to roles/cloudbuild.builds.submitter
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/cloudbuild.builds.editor"

# Artifact Registry (push images)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/artifactregistry.writer"

# Cloud Run (deploy services)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/run.admin"

# Secret Manager (read secrets)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor"

echo "==> Ensuring Cloud Build Service Agent exists and has its role..."
# Create/ensure the service identity for Cloud Build (no-op if already present)
gcloud beta services identity create \
  --service=cloudbuild.googleapis.com \
  --project="${PROJECT_ID}" || true

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${CB_SERVICE_AGENT}" \
  --role="roles/cloudbuild.serviceAgent"

echo "==> (Optional) Grant 'Cloud Build Service Account' to Default Compute Engine SA..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${DEFAULT_COMPUTE_SA}" \
  --role="roles/cloudbuild.builds.builder"

echo "==> Allow DEPLOY_SA to impersonate the Cloud Run runtime SA..."
gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

echo "==> Ensuring Cloud Build staging bucket exists: gs://${CLOUDBUILD_BUCKET}"
if ! gsutil ls -p "${PROJECT_ID}" "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CLOUDBUILD_BUCKET}"
fi

echo "==> Granting bucket-level and object permissions on the staging bucket..."
# Objects permissions
gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.objectAdmin" "gs://${CLOUDBUILD_BUCKET}"
# Bucket-level (some org policies/flows require legacy roles)
gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.legacyBucketReader" "gs://${CLOUDBUILD_BUCKET}"
gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.legacyBucketWriter" "gs://${CLOUDBUILD_BUCKET}"
# Alternative (broader) for simplicity at bucket scope:
# gsutil iam ch "serviceAccount:${DEPLOY_SA}:roles/storage.admin" "gs://${CLOUDBUILD_BUCKET}"

echo "==> (Optional) Create/update Secret Manager secret for API_KEY..."
# Create the secret if it doesn't exist
if ! gcloud secrets describe "${SECRET_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud secrets create "${SECRET_NAME}" \
    --replication-policy="automatic" \
    --project "${PROJECT_ID}"
fi
# Add a new version (skip if you don't want to overwrite)
if [[ -n "${API_KEY_VALUE}" ]]; then
  printf "%s" "${API_KEY_VALUE}" | gcloud secrets versions add "${SECRET_NAME}" \
    --data-file=- \
    --project "${PROJECT_ID}" || true
fi
# Ensure DEPLOY_SA can access the secret (already covered by project-wide role, but this is explicit if needed)
gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --project "${PROJECT_ID}" || true

echo
echo "=== Quick debug ==="
gcloud auth list
gcloud config list
gsutil iam get "gs://${CLOUDBUILD_BUCKET}" | head -n 40 || true

# ----------------------------
#  Cloud Build: staging bucket + permissions
# ----------------------------
log "Ensuring Cloud Build staging bucket and permissions"

# Detect project number and derive identities
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
CB_RUNTIME_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"                        # Cloud Build runtime SA
CB_SERVICE_AGENT="service-${PROJECT_NUMBER}@gcp-sa-cloudbuild.iam.gserviceaccount.com"  # Cloud Build service agent
CLOUDBUILD_BUCKET="${PROJECT_ID}_cloudbuild"

# (A) Enable Service Usage for the CI/CD caller (if using a pipeline SA)
# If you run GitHub Actions with a dedicated SA, define DEPLOY_SA before this block, e.g.:
#   DEPLOY_SA="github-test@${PROJECT_ID}.iam.gserviceaccount.com"
if [[ -n "${DEPLOY_SA:-}" ]]; then
  log "Granting Service Usage role to DEPLOY_SA: ${DEPLOY_SA}"
  grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/serviceusage.serviceUsageConsumer"
  # Optional (for strict org policies): roles/serviceusage.serviceUsageAdmin
fi

# (B) Ensure the Cloud Build service identity exists and has its role
log "Ensuring Cloud Build service identity and role"
gcloud beta services identity create \
  --service=cloudbuild.googleapis.com \
  --project="$PROJECT_ID" >/dev/null 2>&1 || true
grant_project_role "serviceAccount:${CB_SERVICE_AGENT}" "roles/cloudbuild.serviceAgent"

# (C) Create staging bucket if it does not exist
log "Creating Cloud Build staging bucket if missing: gs://${CLOUDBUILD_BUCKET}"
gsutil ls -p "$PROJECT_ID" "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1 || \
  gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${CLOUDBUILD_BUCKET}"

# (D) Grant bucket/object permissions to:
#   - Cloud Build runtime SA (PROJECT_NUMBER@cloudbuild.gserviceaccount.com)
#   - CI/CD SA performing the submit (DEPLOY_SA), if defined
for SA in "$CB_RUNTIME_SA" "${DEPLOY_SA:-}"; do
  [[ -z "$SA" ]] && continue
  log "Granting bucket/object permissions on ${CLOUDBUILD_BUCKET} to ${SA}"
  gsutil iam ch "serviceAccount:${SA}:roles/storage.objectAdmin"        "gs://${CLOUDBUILD_BUCKET}"
  gsutil iam ch "serviceAccount:${SA}:roles/storage.legacyBucketReader" "gs://${CLOUDBUILD_BUCKET}"
  gsutil iam ch "serviceAccount:${SA}:roles/storage.legacyBucketWriter" "gs://${CLOUDBUILD_BUCKET}"
  # Simplified alternative (broader, at bucket scope):
  # gsutil iam ch "serviceAccount:${SA}:roles/storage.admin" "gs://${CLOUDBUILD_BUCKET}"
done

# (E) (Optional) Cloud Build submit role for the CI/CD caller
if [[ -n "${DEPLOY_SA:-}" ]]; then
  log "Granting Cloud Build submit role to DEPLOY_SA"
  grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/cloudbuild.builds.editor"
  # For least privilege, replace with: roles/cloudbuild.builds.submitter
fi

# Short debug
log "Bucket IAM (first lines)"
gsutil iam get "gs://${CLOUDBUILD_BUCKET}" | head -n 60 || true

log "Cloud Build bucket ready. You can now run:"
echo "  gcloud builds submit --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE} ./api"

# If your organization restricts the default *_cloudbuild bucket, use a custom bucket instead:
#   STAGING_BUCKET="${PROJECT_ID}-buildsrc"
#   gsutil mb -p "$PROJECT_ID" -l "$REGION" "gs://${STAGING_BUCKET}" || true
#   gsutil iam ch "serviceAccount:${CB_RUNTIME_SA}:roles/storage.admin" "gs://${STAGING_BUCKET}"
#   [[ -n "${DEPLOY_SA:-}" ]] && gsutil iam ch "serviceAccount:${DEPLO_]()]()


echo
echo "Setup finished with:"
echo "  PROJECT_ID=${PROJECT_ID}"
echo "  PROJECT_NUMBER=${PROJECT_NUMBER}"
echo "  REGION=${REGION}"
echo "  REPO=${REPO}"
echo "  SERVICE=${SERVICE}"
echo "  RUNTIME_SA=${RUNTIME_SA}"
echo "  DATASET=${DATASET}  TABLE=${TABLE}"
echo "  SECRET=${SECRET_NAME}"
echo "  DEPLOY_SA=${DEPLOY_SA}"
echo "  CLOUDBUILD_BUCKET=gs://${CLOUDBUILD_BUCKET}"
echo
echo "You can now run 'gcloud builds submit --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}:test .' from your CI or Cloud Shell (impersonating ${DEPLOY_SA})."
