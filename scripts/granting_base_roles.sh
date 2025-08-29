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
#   • Prepares impersonation of DEPLOY_SA for Cloud Shell usage
#   • Prints a summary of the configuration
#
# Safe to re-run (idempotent where possible).
# --------------------------------------------------------------------

echo "=== CI/CD Setup Wizard ==="

# ----------------------------
# Helpers
# ----------------------------
log() { echo -e "\n==> $*"; }

grant_project_role() {
  local member="$1" role="$2"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$member" \
    --role="$role" >/dev/null
}

# ----------------------------
# Interactive variables
# ----------------------------

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

# 6) BigQuery dataset/table (static defaults)
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
CB_RUNTIME_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# ----------------------------
# Enable APIs
# ----------------------------
log "Enabling required APIs on project ${PROJECT_ID}"
gcloud services enable \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  serviceusage.googleapis.com \
  --project="${PROJECT_ID}"

# ----------------------------
# IAM roles for DEPLOY_SA
# ----------------------------
log "Granting roles to CI/CD Service Account: ${DEPLOY_SA}"

grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/serviceusage.serviceUsageConsumer"
grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/cloudbuild.builds.editor"
grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/artifactregistry.writer"
grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/run.admin"
grant_project_role "serviceAccount:${DEPLOY_SA}" "roles/secretmanager.secretAccessor"

# ----------------------------
# Cloud Build service agent
# ----------------------------
log "Ensuring Cloud Build Service Agent exists and has its role"
gcloud beta services identity create \
  --service=cloudbuild.googleapis.com \
  --project="${PROJECT_ID}" || true
grant_project_role "serviceAccount:${CB_SERVICE_AGENT}" "roles/cloudbuild.serviceAgent"

# ----------------------------
# Default Compute Engine SA (optional)
# ----------------------------
log "Grant 'Cloud Build Service Account' to Default Compute Engine SA (optional)"
grant_project_role "serviceAccount:${DEFAULT_COMPUTE_SA}" "roles/cloudbuild.builds.builder"

# ----------------------------
# Allow DEPLOY_SA to impersonate runtime SA
# ----------------------------
log "Allow DEPLOY_SA to impersonate the Cloud Run runtime SA"
gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}"

# ----------------------------
# Cloud Build staging bucket
# ----------------------------
log "Ensuring Cloud Build staging bucket exists: gs://${CLOUDBUILD_BUCKET}"
if ! gsutil ls -p "${PROJECT_ID}" "gs://${CLOUDBUILD_BUCKET}" >/dev/null 2>&1; then
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${CLOUDBUILD_BUCKET}"
fi

log "Granting bucket-level and object permissions"
for SA in "${DEPLOY_SA}" "${CB_RUNTIME_SA}"; do
  gsutil iam ch "serviceAccount:${SA}:roles/storage.objectAdmin"        "gs://${CLOUDBUILD_BUCKET}"
  gsutil iam ch "serviceAccount:${SA}:roles/storage.legacyBucketReader" "gs://${CLOUDBUILD_BUCKET}"
  gsutil iam ch "serviceAccount:${SA}:roles/storage.legacyBucketWriter" "gs://${CLOUDBUILD_BUCKET}"
done

# ----------------------------
# Secret Manager (optional API_KEY secret)
# ----------------------------
log "Creating/updating Secret Manager secret for API_KEY"
if ! gcloud secrets describe "${SECRET_NAME}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  gcloud secrets create "${SECRET_NAME}" \
    --replication-policy="automatic" \
    --project "${PROJECT_ID}"
fi
if [[ -n "${API_KEY_VALUE}" ]]; then
  printf "%s" "${API_KEY_VALUE}" | gcloud secrets versions add "${SECRET_NAME}" \
    --data-file=- \
    --project "${PROJECT_ID}" || true
fi
gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor" \
  --project "${PROJECT_ID}" || true

# ----------------------------
# Impersonation setup
# ----------------------------
log "Configuring impersonation of DEPLOY_SA from your user"

gcloud iam service-accounts add-iam-policy-binding "${DEPLOY_SA}" \
  --member="user:octavio.avarezdelcastillo@gmail.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="${PROJECT_ID}" || true

# Option A: all gcloud commands impersonate DEPLOY_SA
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${DEPLOY_SA}"

# Option B: helper function to impersonate only specific commands
as_deploy_sa() {
  gcloud --impersonate-service-account="${DEPLOY_SA}" "$@"
}

echo
echo "Impersonation ready. Examples:"
echo "  gcloud builds submit --tag \"${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}:test\" ./api"
echo "  as_deploy_sa builds submit --tag \"${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}:test\" ./api"

# ----------------------------
# Summary
# ----------------------------
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
