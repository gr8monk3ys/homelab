#!/bin/bash
set -euo pipefail

# Script to generate secure random passwords for homelab services
# This replaces all hardcoded passwords with proper Kubernetes secrets

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

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

# Check dependencies first
check_dependencies

log "Generating secure secrets for homelab services..."

# Create secrets namespace if it doesn't exist
kubectl create namespace secrets --dry-run=client -o yaml | kubectl apply -f -

# Core infrastructure secrets
log "Creating core infrastructure secrets..."

# MinIO root credentials (used by minio-system deployment)
kubectl create secret generic minio-config \
    --from-literal=root-user="minioadmin" \
    --from-literal=root-password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# MinIO S3 credentials (used by services like Velero for bucket access)
kubectl create secret generic minio-credentials \
    --from-literal=access-key="$(generate_password 20)" \
    --from-literal=secret-key="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Database passwords
log "Creating database secrets..."

kubectl create secret generic mysql-root-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic nextcloud-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitea-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic harbor-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Application admin passwords
log "Creating application admin secrets..."

kubectl create secret generic nextcloud-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vaultwarden-admin \
    --from-literal=admin-token="$(generate_secret_key)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gitea-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic harbor-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Service-specific secrets
log "Creating service-specific secrets..."

kubectl create secret generic pihole-config \
    --from-literal=web-password="$(generate_password)" \
    --from-literal=dns-servers="1.1.1.1;8.8.8.8" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic wireguard-config \
    --from-literal=ui-password="$(generate_password)" \
    --from-literal=internal-subnet="10.13.13.0" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic searxng-config \
    --from-literal=secret-key="$(generate_secret_key)" \
    --from-literal=instance-name="Homelab Search" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

YARR_PASSWORD="$(generate_password)"
kubectl create secret generic yarr-config \
    --from-literal=auth-user="admin" \
    --from-literal=auth-password="$YARR_PASSWORD" \
    --from-literal=auth-credentials="admin:$YARR_PASSWORD" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

DRONE_DB_PASSWORD="$(generate_password)"
kubectl create secret generic drone-config \
    --from-literal=gitea-client-id="$(generate_secret_key 16)" \
    --from-literal=gitea-client-secret="$(generate_secret_key)" \
    --from-literal=rpc-secret="$(generate_secret_key)" \
    --from-literal=db-password="$DRONE_DB_PASSWORD" \
    --from-literal=database-url="postgres://drone:${DRONE_DB_PASSWORD}@drone-db:5432/drone?sslmode=disable" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# New services secrets
log "Creating secrets for new services..."

# Velero MinIO credentials
kubectl create secret generic velero-minio-credentials \
    --from-literal=access-key="velero" \
    --from-literal=secret-key="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# CrowdSec secrets
kubectl create secret generic crowdsec-config \
    --from-literal=bouncer-api-key="$(generate_secret_key 32)" \
    --from-literal=enroll-key="" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Authelia secrets
kubectl create secret generic authelia-secrets \
    --from-literal=jwt-secret="$(generate_secret_key 64)" \
    --from-literal=session-secret="$(generate_secret_key 64)" \
    --from-literal=storage-encryption-key="$(generate_secret_key 64)" \
    --from-literal=redis-password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Authelia users database (stored as YAML content)
# Generate a password hash for the admin user
AUTHELIA_ADMIN_PASSWORD="$(generate_password)"
log "Authelia admin password generated (save this): $AUTHELIA_ADMIN_PASSWORD"

# Create users database YAML content
# Note: In production, generate the hash with:
#   docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'yourpassword'
AUTHELIA_USERS_DB=$(cat <<'USERS_EOF'
---
users:
  admin:
    displayname: "Admin User"
    # Password hash - regenerate in production with proper hash
    password: "$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_PROPER_HASH"
    email: admin@homelab.local
    groups:
      - admins
      - users
USERS_EOF
)

kubectl create secret generic authelia-users \
    --from-literal=users_database.yml="$AUTHELIA_USERS_DB" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "WARNING: Authelia users database created with placeholder hash."
log "         Generate proper password hash with:"
log "         docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'"
log "         Then update the secret manually."

# Immich secrets
kubectl create secret generic immich-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Ollama/Open WebUI secrets
kubectl create secret generic ollama-config \
    --from-literal=webui-secret="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Paperless-ngx secrets
kubectl create secret generic paperless-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic paperless-admin \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --from-literal=secret-key="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# n8n secrets
kubectl create secret generic n8n-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic n8n-config \
    --from-literal=encryption-key="$(generate_secret_key 32)" \
    --from-literal=jwt-secret="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Linkwarden secrets
kubectl create secret generic linkwarden-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic linkwarden-config \
    --from-literal=nextauth-secret="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# ============================================
# NEW SERVICES - Added during expansion
# ============================================

log "Creating Smart Home service secrets..."

# Home Assistant secrets
kubectl create secret generic home-assistant-token \
    --from-literal=token="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Node-RED secrets
kubectl create secret generic node-red-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Mosquitto MQTT secrets
kubectl create secret generic mosquitto-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating AI/LLM service secrets..."

# Open WebUI secrets
kubectl create secret generic open-webui-secret \
    --from-literal=secret="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# LocalAI secrets
kubectl create secret generic localai-api-key \
    --from-literal=api-key="$(generate_secret_key 32)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Communication service secrets..."

# Matrix/Synapse secrets
kubectl create secret generic synapse-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic synapse-registration-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --from-literal=macaroon-secret-key="$(generate_secret_key 64)" \
    --from-literal=form-secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Mattermost secrets
kubectl create secret generic mattermost-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Observability service secrets..."

# Netdata cloud claim token (optional - leave empty if not using Netdata Cloud)
kubectl create secret generic netdata-claim-token \
    --from-literal=token="" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Development tool secrets..."

# Code-Server secrets
kubectl create secret generic code-server-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Outline wiki secrets
kubectl create secret generic outline-secret-key \
    --from-literal=key="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic outline-utils-secret \
    --from-literal=key="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic outline-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Hoppscotch secrets
kubectl create secret generic hoppscotch-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hoppscotch-jwt-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hoppscotch-session-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Data/Analytics service secrets..."

# Umami secrets
kubectl create secret generic umami-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic umami-app-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# Metabase secrets
kubectl create secret generic metabase-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic metabase-encryption-key \
    --from-literal=key="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# NocoDB secrets
kubectl create secret generic nocodb-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic nocodb-jwt-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Security service secrets..."

# Keycloak secrets
kubectl create secret generic keycloak-admin-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic keycloak-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating Entertainment service secrets..."

# RomM secrets
kubectl create secret generic romm-db-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic romm-db-root-password \
    --from-literal=password="$(generate_password)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic romm-auth-secret \
    --from-literal=secret="$(generate_secret_key 64)" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

# RomM IGDB credentials (optional - for game metadata)
kubectl create secret generic romm-igdb-client-id \
    --from-literal=id="" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic romm-igdb-client-secret \
    --from-literal=secret="" \
    --namespace=secrets \
    --dry-run=client -o yaml | kubectl apply -f -

log "All secrets generated successfully!"
log ""
log "🔐 Security Notice:"
log "   - All passwords are now randomly generated and stored in Kubernetes secrets"
log "   - Secrets are stored in the 'secrets' namespace"
log "   - Access admin passwords with: kubectl get secret <secret-name> -n secrets -o jsonpath='{.data.password}' | base64 -d"
log ""
log "📝 Next steps:"
log "   1. Update your service deployments to use these secrets"
log "   2. Remove hardcoded passwords from configuration files"
log "   3. Document the new secret access patterns"