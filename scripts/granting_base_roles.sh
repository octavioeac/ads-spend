#!/usr/bin/env bash
set -euo pipefail
# --------------------------------------------------------------------
# This script configures Google Cloud IAM roles and enables APIs
# required for the CI/CD pipeline (GitHub Actions) to:
#
# 1. Enable core APIs (Cloud Build, Artifact Registry, Cloud Run,
#    and Secret Manager).
# 2. Grant the pipeline service account permissions to:
#      - Submit builds to Cloud Build and upload sources
#      - Push images to Artifact Registry
#      - Deploy services to Cloud Run
#      - Impersonate the Cloud Run runtime service account
#      - Access secrets from Secret Manager
# 3. (Optional) Ensure access to the Cloud Build staging bucket
#    in case of permission issues.
#
# Goal:
# After running this script once, the CI/CD service account
# (e.g., github-test@n8n-ads-spend.iam.gserviceaccount.com)
# will have the correct roles to build, push, and deploy
# the `metrics-api` service to Cloud Run automatically
# from GitHub Actions without permission errors.
# --------------------------------------------------------------------


PROJECT_ID="n8n-ads-spend"
DEPLOY_SA="github-test@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Enabling required APIs..."
gcloud services enable \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"

echo "Granting base roles to the CI/CD service account: $DEPLOY_SA"

# Allow the service account to use project services
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/serviceusage.serviceUsageConsumer"

# Permissions to submit builds to Cloud Build
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/cloudbuild.builds.editor"
# Alternatively, use roles/cloudbuild.builds.submitter if you want least privilege

# Permissions to push images to Artifact Registry
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/artifactregistry.writer"

# Permissions to deploy services to Cloud Run
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/run.admin"

# Allow this CI/CD SA to impersonate the Cloud Run runtime service account
gcloud iam service-accounts add-iam-policy-binding \
  cr-metrics@${PROJECT_ID}.iam.gserviceaccount.com \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project="$PROJECT_ID"

# Permissions to access secrets in Secret Manager
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEPLOY_SA}" \
  --role="roles/secretmanager.secretAccessor"

# (Optional) Grant direct access to the Cloud Build staging bucket if needed
gsutil iam ch serviceAccount:${DEPLOY_SA}:roles/storage.objectAdmin gs://${PROJECT_ID}_cloudbuild || true

echo "Configuration completed successfully ........ ."
