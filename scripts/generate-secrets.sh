#!/bin/bash
set -euo pipefail

# Script to generate secure random passwords for homelab services
# This replaces all hardcoded passwords with proper Kubernetes secrets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

# If repo-local tools are installed (see scripts/install-dev-tools.sh), prefer them.
TOOLS_DIR="${TOOLS_DIR:-$HOMELAB_DIR/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
    PATH="$TOOLS_DIR/bin:$PATH"
fi
if [[ -d "$TOOLS_DIR/venv/bin" ]]; then
    PATH="$TOOLS_DIR/venv/bin:$PATH"
fi
export PATH

SECRETS_NAMESPACE="${SECRETS_NAMESPACE:-secrets}"
# By default, do not overwrite existing secrets. Set ROTATE_SECRETS=true to rotate.
ROTATE_SECRETS="${ROTATE_SECRETS:-false}"
CONFIG_FILE="${CONFIG_FILE:-$HOMELAB_DIR/config/homelab.yaml}"

# Default admin email (used for Authelia users DB). If unset, optionally read from config/homelab.yaml.
if [[ -z "${ADMIN_EMAIL-}" ]]; then
    ADMIN_EMAIL="admin@homelab.local"
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &> /dev/null; then
        cfg_email="$(yq -r '.homelab.email // empty' "$CONFIG_FILE" 2>/dev/null || true)"
        [[ -n "${cfg_email:-}" ]] && ADMIN_EMAIL="$cfg_email"
    fi
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*"
    exit 1
}

# Check required dependencies before proceeding
check_dependencies() {
    local missing=()

    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}. Please install them first."
    fi

    # Verify kubectl can connect to a cluster
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster. Ensure kubectl is configured correctly."
    fi

    log "All dependencies verified"
}

generate_password() {
    local length=${1:-32}
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

generate_secret_key() {
    local length=${1:-64}
    openssl rand -hex "$length"
}

upsert_secret() {
    local name="$1"
    shift

    if [[ "$ROTATE_SECRETS" != "true" ]] && kubectl get secret -n "$SECRETS_NAMESPACE" "$name" &> /dev/null; then
        log "Secret ${SECRETS_NAMESPACE}/${name} already exists; skipping (set ROTATE_SECRETS=true to rotate)."
        return 0
    fi

    kubectl create secret generic "$name" \
        --namespace="$SECRETS_NAMESPACE" \
        "$@" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Best-effort: generate an Authelia Argon2 password hash by running Authelia in-cluster.
# This avoids requiring Docker on the host.
generate_authelia_argon2_hash() {
    local password="$1"
    local image="${AUTHELIA_IMAGE:-authelia/authelia:4.38.18}"
    local pod_name
    pod_name="authelia-hashgen-$(date +%s)"

    local output
    if ! output=$(
        kubectl run "$pod_name" \
            --namespace="$SECRETS_NAMESPACE" \
            --image="$image" \
            --restart=Never \
            --rm \
            -i \
            --command -- \
            authelia crypto hash generate argon2 --password "$password" 2>/dev/null
    ); then
        return 1
    fi

    # Extract the first argon2 hash from the output.
    echo "$output" | grep -Eo '\$argon2[^[:space:]]+' | head -n 1
}

# Check dependencies first
check_dependencies

log "Generating secure secrets for homelab services..."

# Create secrets namespace if it doesn't exist
kubectl create namespace "$SECRETS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Core infrastructure secrets
log "Creating core infrastructure secrets..."

# MinIO root credentials (used by minio-system deployment)
upsert_secret minio-config \
    --from-literal=root-user="minioadmin" \
    --from-literal=root-password="$(generate_password)"

# MinIO S3 credentials (used by services like Velero for bucket access)
upsert_secret minio-credentials \
    --from-literal=access-key="$(generate_password 20)" \
    --from-literal=secret-key="$(generate_secret_key 32)"

# Database passwords
log "Creating database secrets..."

upsert_secret mysql-root-password \
    --from-literal=password="$(generate_password)"

upsert_secret nextcloud-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret gitea-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret harbor-db-password \
    --from-literal=password="$(generate_password)"

# Application admin passwords
log "Creating application admin secrets..."

upsert_secret nextcloud-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)"

upsert_secret grafana-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)"

upsert_secret vaultwarden-admin \
    --from-literal=admin-token="$(generate_secret_key)"

upsert_secret gitea-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)"

upsert_secret harbor-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)"

# Service-specific secrets
log "Creating service-specific secrets..."

upsert_secret pihole-config \
    --from-literal=web-password="$(generate_password)" \
    --from-literal=dns-servers="1.1.1.1;8.8.8.8"

upsert_secret wireguard-config \
    --from-literal=ui-password="$(generate_password)" \
    --from-literal=internal-subnet="10.13.13.0"

upsert_secret searxng-config \
    --from-literal=secret-key="$(generate_secret_key)" \
    --from-literal=instance-name="Homelab Search"

YARR_PASSWORD="$(generate_password)"
upsert_secret yarr-config \
    --from-literal=auth-user="admin" \
    --from-literal=auth-password="$YARR_PASSWORD" \
    --from-literal=auth-credentials="admin:$YARR_PASSWORD"

DRONE_DB_PASSWORD="$(generate_password)"
upsert_secret drone-config \
    --from-literal=gitea-client-id="$(generate_secret_key 16)" \
    --from-literal=gitea-client-secret="$(generate_secret_key)" \
    --from-literal=rpc-secret="$(generate_secret_key)" \
    --from-literal=db-password="$DRONE_DB_PASSWORD" \
    --from-literal=database-url="postgres://drone:${DRONE_DB_PASSWORD}@drone-db:5432/drone?sslmode=disable"

# New services secrets
log "Creating secrets for new services..."

# Velero MinIO credentials
upsert_secret velero-minio-credentials \
    --from-literal=access-key="velero" \
    --from-literal=secret-key="$(generate_secret_key 32)"

# CrowdSec secrets
upsert_secret crowdsec-config \
    --from-literal=bouncer-api-key="$(generate_secret_key 32)" \
    --from-literal=enroll-key=""

# Authelia secrets
upsert_secret authelia-secrets \
    --from-literal=jwt-secret="$(generate_secret_key 64)" \
    --from-literal=session-secret="$(generate_secret_key 64)" \
    --from-literal=storage-encryption-key="$(generate_secret_key 64)" \
    --from-literal=redis-password="$(generate_password)"

# Authelia admin credentials + users database (stored as YAML content)
AUTHELIA_ADMIN_USERNAME="admin"
AUTHELIA_ADMIN_PASSWORD="$(generate_password)"

# Store the plaintext password so you can retrieve it later (e.g. after a rebuild).
upsert_secret authelia-admin \
    --from-literal=username="$AUTHELIA_ADMIN_USERNAME" \
    --from-literal=password="$AUTHELIA_ADMIN_PASSWORD"

AUTHELIA_ADMIN_HASH="$(generate_authelia_argon2_hash "$AUTHELIA_ADMIN_PASSWORD" || true)"
if [ -z "${AUTHELIA_ADMIN_HASH:-}" ]; then
    log "WARNING: Failed to generate Authelia Argon2 hash automatically."
    log "         Using a placeholder hash. Replace it before exposing Authelia externally."
    AUTHELIA_ADMIN_HASH='$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_PROPER_HASH'
fi

AUTHELIA_USERS_DB=$(cat <<USERS_EOF
---
users:
  ${AUTHELIA_ADMIN_USERNAME}:
    displayname: "Admin User"
    password: "${AUTHELIA_ADMIN_HASH}"
    email: ${ADMIN_EMAIL}
    groups:
      - admins
      - users
USERS_EOF
)

upsert_secret authelia-users \
    --from-literal=users_database.yml="$AUTHELIA_USERS_DB"

# Immich secrets
upsert_secret immich-db-password \
    --from-literal=password="$(generate_password)"

# Paperless-ngx secrets
upsert_secret paperless-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret paperless-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --from-literal=secret-key="$(generate_secret_key 64)"

# n8n secrets
upsert_secret n8n-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret n8n-config \
    --from-literal=encryption-key="$(generate_secret_key 32)" \
    --from-literal=jwt-secret="$(generate_secret_key 32)"

# Linkwarden secrets
upsert_secret linkwarden-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret linkwarden-config \
    --from-literal=nextauth-secret="$(generate_secret_key 32)"

# ============================================
# NEW SERVICES - Added during expansion
# ============================================

log "Creating Smart Home service secrets..."

# Home Assistant secrets
upsert_secret home-assistant-token \
    --from-literal=token="$(generate_secret_key 64)"

# Node-RED secrets
upsert_secret node-red-password \
    --from-literal=password="$(generate_password)"

# Mosquitto MQTT secrets
upsert_secret mosquitto-password \
    --from-literal=password="$(generate_password)"

log "Creating AI/LLM service secrets..."

# Open WebUI secrets
upsert_secret open-webui-config \
    --from-literal=secret-key="$(generate_secret_key 32)"

# LocalAI secrets
upsert_secret localai-api-key \
    --from-literal=api-key="$(generate_secret_key 32)"

log "Creating Communication service secrets..."

# Matrix/Synapse secrets
upsert_secret synapse-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret synapse-registration-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --from-literal=macaroon-secret-key="$(generate_secret_key 64)" \
    --from-literal=form-secret="$(generate_secret_key 64)"

# Mattermost secrets
upsert_secret mattermost-db-password \
    --from-literal=password="$(generate_password)"

log "Creating Observability service secrets..."

# Netdata cloud claim token (optional - leave empty if not using Netdata Cloud)
upsert_secret netdata-claim-token \
    --from-literal=token=""

log "Creating Development tool secrets..."

# Code-Server secrets
upsert_secret code-server-password \
    --from-literal=password="$(generate_password)"

# Outline wiki secrets
upsert_secret outline-secret-key \
    --from-literal=key="$(generate_secret_key 64)"

upsert_secret outline-utils-secret \
    --from-literal=key="$(generate_secret_key 64)"

upsert_secret outline-db-password \
    --from-literal=password="$(generate_password)"

# Hoppscotch secrets
upsert_secret hoppscotch-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret hoppscotch-jwt-secret \
    --from-literal=secret="$(generate_secret_key 64)"

upsert_secret hoppscotch-session-secret \
    --from-literal=secret="$(generate_secret_key 64)"

log "Creating Data/Analytics service secrets..."

# Umami secrets
upsert_secret umami-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret umami-app-secret \
    --from-literal=secret="$(generate_secret_key 64)"

# Metabase secrets
upsert_secret metabase-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret metabase-encryption-key \
    --from-literal=key="$(generate_secret_key 64)"

# NocoDB secrets
upsert_secret nocodb-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret nocodb-jwt-secret \
    --from-literal=secret="$(generate_secret_key 64)"

log "Creating Security service secrets..."

# Keycloak secrets
upsert_secret keycloak-admin-password \
    --from-literal=password="$(generate_password)"

upsert_secret keycloak-db-password \
    --from-literal=password="$(generate_password)"

log "Creating Entertainment service secrets..."

# RomM secrets
upsert_secret romm-db-password \
    --from-literal=password="$(generate_password)"

upsert_secret romm-db-root-password \
    --from-literal=password="$(generate_password)"

upsert_secret romm-auth-secret \
    --from-literal=secret="$(generate_secret_key 64)"

# RomM IGDB credentials (optional - for game metadata)
upsert_secret romm-igdb-client-id \
    --from-literal=id=""

upsert_secret romm-igdb-client-secret \
    --from-literal=secret=""

log "All secrets generated successfully!"
log ""
log "🔐 Security Notice:"
log "   - Secrets are stored in the '${SECRETS_NAMESPACE}' namespace"
log "   - By default, existing secrets are left unchanged (set ROTATE_SECRETS=true to rotate)"
log "   - Read a field with: kubectl get secret <secret-name> -n ${SECRETS_NAMESPACE} -o jsonpath='{.data.<key>}' | base64 -d"
log ""
log "📝 Next steps:"
log "   1. Update your service deployments to use these secrets"
log "   2. Remove hardcoded passwords from configuration files"
log "   3. Document the new secret access patterns"
