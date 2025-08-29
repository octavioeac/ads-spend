#!/usr/bin/env bash
set -euo pipefail

########################################
# Inputs (edit these)
########################################
PROJECT_ID="n8n-ads-spend"
REGION="us-central1"
REPO="n8n-repo"                 # Artifact Registry repo
SERVICE="metrics-api"           # Cloud Run service name
RUNTIME_SA="cr-metrics"         # Runtime SA name (will be created)
DATASET="ads_warehouse"
TABLE="ads_spend_raw"
SECRET_NAME="metrics-api-key"
API_KEY_VALUE="super-secret"    # API key value for x-api-key header

echo "==> Set project"
gcloud config set project "${PROJECT_ID}"

echo "==> Enable required APIs (idempotent)"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  bigquery.googleapis.com \
  secretmanager.googleapis.com

########################################
# Artifact Registry repo
########################################
echo "==> Create Artifact Registry repo (if not exists)"
gcloud artifacts repositories create "${REPO}" \
  --repository-format=docker \
  --location="${REGION}" || echo "Repo ${REPO} already exists"

########################################
# Runtime Service Account + BigQuery roles
########################################
RUNTIME_SA_EMAIL="${RUNTIME_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Create runtime SA (if not exists)"
gcloud iam service-accounts create "${RUNTIME_SA}" \
  --display-name="Cloud Run runtime for metrics" || echo "SA ${RUNTIME_SA} already exists"

echo "==> Grant BigQuery roles to runtime SA"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/bigquery.jobUser" || true

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/bigquery.dataViewer" || true
# If you need write access to BQ, use dataEditor instead of dataViewer.

########################################
# Secret Manager (API_KEY)
########################################
echo "==> Create secret for API key (if not exists)"
echo -n "${API_KEY_VALUE}" | gcloud secrets create "${SECRET_NAME}" --data-file=- \
  --replication-policy="automatic" || echo "Secret ${SECRET_NAME} already exists"

echo "==> Grant secret access to runtime SA"
gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${RUNTIME_SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" || true

########################################
# Build & Deploy
########################################
IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${SERVICE}"

echo "==> Build image with Cloud Build"
gcloud builds submit --tag "${IMAGE_URI}" ./cloudrun-metrics

echo "==> Deploy to Cloud Run"
gcloud run deploy "${SERVICE}" \
  --image "${IMAGE_URI}" \
  --region "${REGION}" \
  --platform managed \
  --service-account "${RUNTIME_SA_EMAIL}" \
  --allow-unauthenticated \
  --set-env-vars PROJECT_ID="${PROJECT_ID}",BQ_DATASET="${DATASET}",BQ_TABLE="${TABLE}" \
  --set-secrets API_KEY="${SECRET_NAME}:latest"

URL="$(gcloud run services describe ${SERVICE} --region ${REGION} --format 'value(status.url)')"
echo "==> DONE. Service URL: ${URL}"
echo "Test:"
echo "curl -H \"x-api-key: ${API_KEY_VALUE}\" \"${URL}/metrics\""
