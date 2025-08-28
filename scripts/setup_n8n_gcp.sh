#!/usr/bin/env bash
set -euo pipefail

# ============================
# Configurable variables
# ============================
PROJECT_ID="n8n-ads-spend"                 # GCP project id
LOCATION="us"                              # Artifact Registry location (e.g., us, us-central1)
REGION="us-central1"                       # Compute Engine region
ZONE="us-central1-a"                       # Compute Engine zone
REPO_NAME="n8n-repo"                       # Artifact Registry repository name
IMAGE_NAME="n8n"                           # Docker image name
BUCKET_NAME="gs://n8n-ads-spend-data"      # GCS bucket for CSVs (change if needed)

# Service Accounts
GITHUB_SA_NAME="github-test"               # github-test@PROJECT_ID.iam.gserviceaccount.com
GITHUB_SA_EMAIL="${GITHUB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Workload Identity Federation (for GitHub OIDC)
POOL_ID="github-pool"
PROVIDER_ID="github-provider"
GITHUB_REPO="octavioeac/ads-spend"         # Repo allowed to assume the SA
GITHUB_BRANCH="refs/heads/main"            # Branch allowed (main)

# VM settings
VM_NAME="n8n-vm"
MACHINE_TYPE="e2-micro"                    # e2-standard-2 reduce the cost in gcp
BOOT_DISK_SIZE="30GB"

# ============================
# Helpers
# ============================
green() { printf "\033[0;32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[0;33m%s\033[0m\n" "$*"; }
exists() { command -v "$1" >/dev/null 2>&1; }

# ============================
# Pre-flight checks
# ============================
if ! exists gcloud; then
  echo "gcloud CLI is required. Install: https://cloud.google.com/sdk/docs/install"
  exit 1
fi

green "[1/13] Setting active project"
gcloud config set project "${PROJECT_ID}" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")"

# ============================
# Enable required APIs
# ============================
green "[2/13] Enabling required APIs"
gcloud services enable \
  artifactregistry.googleapis.com \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com

# ============================
# Create Artifact Registry repo (Docker)
# ============================
green "[3/13] Ensuring Artifact Registry repository"
if ! gcloud artifacts repositories describe "${REPO_NAME}" --location="${LOCATION}" >/dev/null 2>&1; then
  gcloud artifacts repositories create "${REPO_NAME}" \
    --repository-format=docker \
    --location="${LOCATION}" \
    --description="Docker repo for n8n"
else
  yellow "Repo ${REPO_NAME} already exists in ${LOCATION}"
fi

# ============================
# Create Service Account for GitHub Actions
# ============================
green "[4/13] Ensuring GitHub Service Account: ${GITHUB_SA_EMAIL}"
if ! gcloud iam service-accounts describe "${GITHUB_SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${GITHUB_SA_NAME}" \
    --display-name="GitHub Actions SA"
else
  yellow "Service account ${GITHUB_SA_EMAIL} already exists"
fi

# ============================
# Grant roles to GitHub SA (least privilege)
# -Artifact Registry writer to push images
# -Workload Identity User binding will be added later on the SA
# -Storage roles on bucket (objectAdmin gives read/write on objects)
# ============================
green "[5/13] Granting roles to GitHub SA"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GITHUB_SA_EMAIL}" \
  --role="roles/artifactregistry.writer"

# Allow SA to read/write objects in the bucket (restrict to bucket scope)
if gsutil ls "${BUCKET_NAME}" >/dev/null 2>&1; then
  yellow "Granting Storage Object Admin on bucket ${BUCKET_NAME} to ${GITHUB_SA_EMAIL}"
  gcloud storage buckets add-iam-policy-binding "${BUCKET_NAME}" \
    --member="serviceAccount:${GITHUB_SA_EMAIL}" \
    --role="roles/storage.objectAdmin"
else
  yellow "Bucket ${BUCKET_NAME} not found. Skip bucket IAM (you can adjust BUCKET_NAME or create it later)."
fi

# ============================
# Workload Identity Federation: Pool and Provider (GitHub OIDC)
# ============================
green "[6/13] Ensuring Workload Identity Pool"
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --location="global" \
    --display-name="GitHub Pool"
else
  yellow "Pool ${POOL_ID} already exists"
fi

green "[7/13] Ensuring OIDC Provider for GitHub"
if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --location="global" \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub OIDC Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.actor=assertion.actor,attribute.workflow=assertion.workflow,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="attribute.repository=='${GITHUB_REPO}' && attribute.ref=='${GITHUB_BRANCH}'"
else
  yellow "Provider ${PROVIDER_ID} already exists in pool ${POOL_ID}"
fi

# ============================
# Allow identities from the pool to impersonate the GitHub SA
# This is the critical binding for google-github-actions/auth OIDC flow
# ============================
green "[8/13] Binding Workload Identity User on the GitHub SA"
gcloud iam service-accounts add-iam-policy-binding "${GITHUB_SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"

# ============================
# (Optional) Admin roles for you to manage WI pools/providers
# ============================
green "[9/13] (Optional) Grant you Workload Identity Pool Admin"
MY_USER="user:octavio.avarezdelcastillo@gmail.com"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="${MY_USER}" \
  --role="roles/iam.workloadIdentityPoolAdmin" || true

# ============================
# Configure Docker to push to Artifact Registry
# ============================
green "[10/13] Configuring Docker auth for Artifact Registry"
gcloud auth configure-docker "${LOCATION}-docker.pkg.dev" -q

# ============================
# Create VM for n8n (Docker host)
# ============================
green "[11/13] Creating Compute Engine VM (if not exists)"
if ! gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
  gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="debian-11" \
    --image-project="debian-cloud" \
    --boot-disk-size="${BOOT_DISK_SIZE}" \
    --tags="http-server,https-server,n8n-server"
else
  yellow "VM ${VM_NAME} already exists in ${ZONE}"
fi

# ============================
# Enable OS Login (recommended) and add metadata at project level
# ============================
green "[12/13] Enabling OS Login at project level"
gcloud compute project-info add-metadata \
  --metadata enable-oslogin=TRUE

# ============================
# Firewall rules for n8n (port 5678) and optional HTTP (80)
# ============================
green "[13/13] Ensuring firewall rules"
# n8n default port
if ! gcloud compute firewall-rules describe "allow-n8n-5678" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "allow-n8n-5678" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:5678 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="n8n-server"
else
  yellow "Firewall rule allow-n8n-5678 already exists"
fi

# Optional HTTP 80 (handy for reverse proxy)
if gcloud compute firewall-rules describe "allow-n8n-http" >/dev/null 2>&1; then
  gcloud compute firewall-rules delete "allow-n8n-http" --quiet || true
fi
gcloud compute firewall-rules create "allow-n8n-http" \
  --allow=tcp:80 \
  --direction=INGRESS \
  --priority=1000 \
  --network=default

green "============================================"
green "All set!"
green "Next steps:"
echo "- In GitHub Actions, use google-github-actions/auth with:"
echo "    service_account: ${GITHUB_SA_EMAIL}"
echo "    workload_identity_provider: projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
echo "- Push image to: ${LOCATION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:<tag>"
echo "- SSH into VM and run your n8n Docker container."
green "============================================"
