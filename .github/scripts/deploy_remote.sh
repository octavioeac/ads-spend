#!/usr/bin/env bash
set -euo pipefail
IMAGE="$1"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "== Step 1/5: Ensure Docker is installed (avoid man-db/needrestart hangs) =="
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y -o Dpkg::Use-Pty=0

  # Skip manpages (optional; speeds up installs)
  echo 'path-exclude=/usr/share/man/*' | sudo tee /etc/dpkg/dpkg.cfg.d/99skip-manpages >/dev/null || true

  # Divert mandb to avoid long/hanging postinst
  if [ -x /usr/bin/mandb ]; then
    sudo dpkg-divert --local --rename --add /usr/bin/mandb || true
    sudo ln -sf /bin/true /usr/bin/mandb || true
  fi

  sudo apt-get install -y -o Dpkg::Use-Pty=0 --no-install-recommends docker.io
  sudo systemctl enable --now docker || true

  # Restore mandb
  if [ -L /usr/bin/mandb ]; then
    sudo rm -f /usr/bin/mandb || true
    sudo dpkg-divert --local --rename --remove /usr/bin/mandb || true
  fi

  # Ensure dpkg is clean
  sudo dpkg --configure -a || true
fi

echo "== Step 2/5: Prepare n8n environment file =="
sudo mkdir -p /data/n8n
{
  echo "N8N_BASIC_AUTH_ACTIVE=true"
  echo "N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}"
  echo "N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}"
  echo "N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}"
  echo "N8N_HOST=$(curl -s ifconfig.me || echo localhost)"
  echo "N8N_PROTOCOL=http"
} | sudo tee /data/n8n/.env >/dev/null

echo "== Step 3/5: Diagnostics (VM Service Account & scopes) =="
VM_SA_EMAIL=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email" || true)
echo "VM_SA_EMAIL=${VM_SA_EMAIL}"

echo "VM scopes:"
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" || true
echo

echo "== Step 4/5: Artifact Registry auth for ROOT (who runs 'sudo docker ...') =="
# Ensure root's Docker has the credential helper mapping
sudo mkdir -p /root/.docker
sudo gcloud auth configure-docker us-docker.pkg.dev --quiet || true

# Obtain an access token from metadata server tied to the VM's SA
ACCESS_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])' || true)

if [ -z "${ACCESS_TOKEN}" ]; then
  echo "!! Could not obtain metadata access token. Check that the VM has an attached Service Account and proper scopes."
  exit 21
fi

echo "${ACCESS_TOKEN}" | sudo docker login \
  -u oauth2accesstoken --password-stdin https://us-docker.pkg.dev

echo "== Step 5/5: Pull & run container =="
echo "Pulling image: ${IMAGE}"
if ! sudo docker pull "${IMAGE}"; then
  echo "!! docker pull failed (Unauthenticated or unauthorized)."
  echo ">> Ensure the VM's Service Account has 'roles/artifactregistry.reader':"
  echo "gcloud projects add-iam-policy-binding n8n-ads-spend \\"
  echo "  --member=\"serviceAccount:${VM_SA_EMAIL}\" \\"
  echo "  --role=\"roles/artifactregistry.reader\""
  echo "If scopes are restricted, add cloud-platform scope (requires VM restart)."
  exit 22
fi

# Replace running container
sudo docker rm -f n8n || true
sudo docker run -d --name n8n -p 80:5678 \
  --restart unless-stopped \
  --env-file /data/n8n/.env \
  -v /data/n8n:/home/node/.n8n \
  "${IMAGE}"

sleep 10
sudo docker logs n8n --tail=80 || true
