#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Auto-detect / ask for variables (English)
# =========================================

# 1) PROJECT_ID → try to get it from current gcloud config
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "$PROJECT_ID" ]]; then
  echo "No PROJECT_ID found in gcloud config. Please enter your GCP Project ID:"
  read -r PROJECT_ID
fi
echo "Using PROJECT_ID=$PROJECT_ID"

# 2) REGION → default to us-central1 (you can list with: gcloud run regions list)
DEFAULT_REGION="us-central1"
echo "Enter region for Cloud Run / Artifact Registry [default: $DEFAULT_REGION]:"
read -r REGION
REGION="${REGION:-$DEFAULT_REGION}"
echo "Using REGION=$REGION"

# 3) REPO → Artifact Registry repository name
DEFAULT_REPO="n8n-repo"
echo "Enter Artifact Registry repo name [default: $DEFAULT_REPO]:"
read -r REPO
REPO="${REPO:-$DEFAULT_REPO}"
echo "Using REPO=$REPO"

# 4) SERVICE → Cloud Run service name
DEFAULT_SERVICE="metrics-api"
echo "Enter Cloud Run service name [default: $DEFAULT_SERVICE]:"
read -r SERVICE
SERVICE="${SERVICE:-$DEFAULT_SERVICE}"
echo "Using SERVICE=$SERVICE"

# 5) RUNTIME_SA → runtime Service Account (name only; email will be <name>@<project>.iam.gserviceaccount.com)
DEFAULT_RUNTIME_SA="cr-metrics"
echo "Enter runtime Service Account name [default: $DEFAULT_RUNTIME_SA]:"
read -r RUNTIME_SA
RUNTIME_SA="${RUNTIME_SA:-$DEFAULT_RUNTIME_SA}"
echo "Using RUNTIME_SA=$RUNTIME_SA"

# 6) DATASET/TABLE (keep fixed for now or change if needed)
DATASET="ads_warehouse"
TABLE="ads_spend_raw"
echo "Using BigQuery dataset=$DATASET table=$TABLE"

# 7) Secret (for x-api-key)
DEFAULT_SECRET="metrics-api-key"
echo "Enter Secret Manager name for API_KEY [default: $DEFAULT_SECRET]:"
read -r SECRET_NAME
SECRET_NAME="${SECRET_NAME:-$DEFAULT_SECRET}"

DEFAULT_API_KEY="super-secret"
echo "Enter initial API_KEY value [default: $DEFAULT_API_KEY]:"
read -r API_KEY_VALUE
API_KEY_VALUE="${API_KEY_VALUE:-$DEFAULT_API_KEY}"

# =========================================
# Variables are now set; the rest of your script
# can use them to create SA, roles, secret, repo, etc.
# =========================================

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
# 0) Project & APIs
# ----------------------------
log "Setting project: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

log "Enabling required APIs (idempotent)"
for api in run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com bigquery.googleapis.com secretmanager.googleapis.com; do
  gcloud services enable "$api" --project "$PROJECT_ID" >/dev/null
done

# ----------------------------
# 1) Artifact Registry repo
# ----------------------------
log "Creating Artifact Registry repo '$REPO' in $REGION (if not exists)"
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID" >/dev/null 2>&1 || log "Repo '$REPO' already exists"

# ----------------------------
# 2) Runtime Service Account + BQ roles
# ----------------------------
RUNTIME_SA_EMAIL="${RUNTIME_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

log "Creating runtime Service Account (if not exists): $RUNTIME_SA_EMAIL"
gcloud iam service-accounts describe "$RUNTIME_SA_EMAIL" \
  --project "$PROJECT_ID" >/dev/null 2>&1 || \
gcloud iam service-accounts create "$RUNTIME_SA" \
  --display-name="Cloud Run runtime for metrics" \
  --project "$PROJECT_ID" >/dev/null

log "Grant BigQuery roles to runtime SA (jobUser + dataViewer)"
grant_project_role "serviceAccount:${RUNTIME_SA_EMAIL}" "roles/bigquery.jobUser"
grant_project_role "serviceAccount:${RUNTIME_SA_EMAIL}" "roles/bigquery.dataViewer"
# If you need write access, replace dataViewer -> dataEditor.

# ----------------------------
# 3) Secret Manager for API_KEY
# ----------------------------
log "Creating Secret Manager secret '$SECRET_NAME' (if not exists)"
if gcloud secrets describe "$SECRET_NAME" --project "$PROJECT_ID" >/dev/null 2>&1; then
  log "Secret '$SECRET_NAME' exists; creating a new version with provided value"
  printf "%s" "$API_KEY_VALUE" | gcloud secrets versions add "$SECRET_NAME" \
    --data-file=- --project "$PROJECT_ID" >/dev/null
else
  printf "%s" "$API_KEY_VALUE" | gcloud secrets create "$SECRET_NAME" \
    --data-file=- \
    --replication-policy="automatic" \
    --project "$PROJECT_ID" >/dev/null
fi

log "Grant secret access to runtime SA"
gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project "$PROJECT_ID" >/dev/null

log "==> Infra ready! Artifact Registry + runtime SA + secret created."
echo ""
echo "Next steps (in your GitHub Actions workflow):"
echo "- Build image: gcloud builds submit --tag ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE} ./cloudrun-metrics"
echo "- Deploy: gcloud run deploy ${SERVICE} --image ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE} --region ${REGION} --service-account ${RUNTIME_SA_EMAIL} --allow-unauthenticated --set-env-vars PROJECT_ID=${PROJECT_ID},BQ_DATASET=${DATASET},BQ_TABLE=${TABLE} --set-secrets API_KEY=${SECRET_NAME}:latest"
