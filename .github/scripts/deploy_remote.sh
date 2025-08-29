#!/usr/bin/env bash
set -euo pipefail

# USAGE:
#   export SMTP_PROVIDER=gmail   # or 'sendgrid'
#   # --- For Gmail ---
#   export N8N_SMTP_USER="your_email@gmail.com"
#   export N8N_SMTP_PASS="APP_PASSWORD_16CH"
#   # --- For SendGrid ---
#   # export N8N_SMTP_USER="apikey"                # literal
#   # export N8N_SMTP_PASS="SG.xxxxxx_your_api_key" # your API key
#
#   export N8N_BASIC_AUTH_USER="admin"
#   export N8N_BASIC_AUTH_PASSWORD="change_this"
#   export N8N_ENCRYPTION_KEY="long_random_key_32+chars"
#
#   ./deploy_n8n.sh "us-docker.pkg.dev/YOUR_PROJECT/n8n-repo/n8n:TAG"

IMAGE="${1:-}"
if [[ -z "${IMAGE}" ]]; then
  echo "Usage: $0 <artifact-registry-image>"
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "== Step 0/6: Required environment variables =="
: "${N8N_BASIC_AUTH_USER:?Missing N8N_BASIC_AUTH_USER}"
: "${N8N_BASIC_AUTH_PASSWORD:?Missing N8N_BASIC_AUTH_PASSWORD}"
: "${N8N_ENCRYPTION_KEY:?Missing N8N_ENCRYPTION_KEY}"
: "${SMTP_PROVIDER:?Missing SMTP_PROVIDER (gmail|sendgrid)}"
: "${N8N_SMTP_USER:?Missing N8N_SMTP_USER}"
: "${N8N_SMTP_PASS:?Missing N8N_SMTP_PASS}"

SMTP_HOST=""; SMTP_PORT="587"; SMTP_SSL="false"
case "${SMTP_PROVIDER}" in
  gmail)
    SMTP_HOST="smtp.gmail.com"
    ;;
  sendgrid)
    SMTP_HOST="smtp.sendgrid.net"
    ;;
  *)
    echo "SMTP_PROVIDER must be 'gmail' or 'sendgrid'"
    exit 3
    ;;
esac

echo "== Step 1/6: Install Docker (avoid man-db/needrestart hangs) =="
if ! command -v docker >/dev/null 2>&1; then
  sudo apt-get update -y -o Dpkg::Use-Pty=0
  echo 'path-exclude=/usr/share/man/*' | sudo tee /etc/dpkg/dpkg.cfg.d/99skip-manpages >/dev/null || true
  if [ -x /usr/bin/mandb ]; then
    sudo dpkg-divert --local --rename --add /usr/bin/mandb || true
    sudo ln -sf /bin/true /usr/bin/mandb || true
  fi
  sudo apt-get install -y -o Dpkg::Use-Pty=0 --no-install-recommends docker.io curl jq
  sudo systemctl enable --now docker || true
  if [ -L /usr/bin/mandb ]; then
    sudo rm -f /usr/bin/mandb || true
    sudo dpkg-divert --local --rename --remove /usr/bin/mandb || true
  fi
  sudo dpkg --configure -a || true
fi

echo "== Step 2/6: Detect public IP and prepare n8n .env =="
# Public IP from metadata (more reliable than ifconfig.me)
PUBLIC_IP="$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(curl -s ifconfig.me || echo localhost)"
fi
echo "PUBLIC_IP=${PUBLIC_IP}"

sudo mkdir -p /data/n8n
sudo chmod 700 /data/n8n

cat <<EOF | sudo tee /data/n8n/.env >/dev/null
# --- Basic access to n8n ---
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

# --- Public URL (invitation links) ---
N8N_HOST=${PUBLIC_IP}
N8N_PROTOCOL=http
N8N_PORT=80
N8N_EDITOR_BASE_URL=http://${PUBLIC_IP}
N8N_SECURE_COOKIE=false

# --- SMTP for invitations ---
N8N_EMAIL_MODE=smtp
N8N_SMTP_HOST=${SMTP_HOST}
N8N_SMTP_PORT=${SMTP_PORT}
N8N_SMTP_USER=${N8N_SMTP_USER}
N8N_SMTP_PASS=${N8N_SMTP_PASS}
N8N_SMTP_SSL=${SMTP_SSL}
N8N_SMTP_SENDER="Data Team <${N8N_SMTP_USER}>"

# --- Recommended by n8n ---
DB_SQLITE_POOL_SIZE=5
N8N_RUNNERS_ENABLED=true
EOF

sudo chmod 600 /data/n8n/.env

echo "== Step 3/6: VM Service Account & scopes diagnostics =="
VM_SA_EMAIL="$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email" || true)"
echo "VM_SA_EMAIL=${VM_SA_EMAIL}"

echo "VM scopes:"
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes" || true
echo

echo "== Step 4/6: Artifact Registry auth (root) =="
sudo mkdir -p /root/.docker
sudo gcloud auth configure-docker us-docker.pkg.dev --quiet || true

ACCESS_TOKEN="$(curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | jq -r .access_token || true)"

if [[ -z "${ACCESS_TOKEN}" || "${ACCESS_TOKEN}" == "null" ]]; then
  echo "!! Could not obtain access_token. Ensure the VM has an attached SA and proper scopes (cloud-platform)."
  exit 21
fi

echo "${ACCESS_TOKEN}" | sudo docker login -u oauth2accesstoken --password-stdin https://us-docker.pkg.dev

echo "== Step 5/6: Open ports (local firewall) =="
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 80/tcp || true
  # If you will use proxy/SSL later, also open 443:
  # sudo ufw allow 443/tcp || true
fi

echo "== Step 6/6: Pull and run n8n container =="
echo "Pulling image: ${IMAGE}"
if ! sudo docker pull "${IMAGE}"; then
  cat >&2 <<ERR
!! docker pull failed (authz). Make sure the VM's Service Account has 'roles/artifactregistry.reader':
  gcloud projects add-iam-policy-binding YOUR_PROJECT \\
    --member="serviceAccount:${VM_SA_EMAIL}" \\
    --role="roles/artifactregistry.reader"
ERR
  exit 22
fi

sudo docker rm -f n8n || true
sudo docker run -d --name n8n -p 80:5678 \
  --restart unless-stopped \
  --env-file /data/n8n/.env \
  -v /data/n8n:/home/node/.n8n \
  "${IMAGE}"

echo "Waiting for n8n..."
sleep 10
sudo docker logs n8n --tail=120 || true

echo "== Healthcheck =="
curl -fsS "http://${PUBLIC_IP}/healthz" || true
echo
echo "Done. Open: http://${PUBLIC_IP}"
echo "To follow live logs: docker logs -f n8n | grep -i -E 'smtp|email|invite|error'"
