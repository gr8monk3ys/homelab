#!/usr/bin/env bash
set -euo pipefail

# Bootstraps SOPS/age for this repo and generates SOPS-encrypted Kubernetes Secrets
# under kubernetes/secrets/sops/.
#
# This script:
# - Creates an age keypair at local/sops/age.key (gitignored)
# - Writes SOPS-encrypted Secret manifests for the homelab into kubernetes/secrets/sops/secrets/
#
# It does NOT apply anything to a cluster. For ArgoCD integration, run:
#   ./scripts/configure-argocd-ksops.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# If repo-local tools are installed (see scripts/install-dev-tools.sh), prefer them.
TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
  PATH="$TOOLS_DIR/bin:$PATH"
fi
export PATH

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

AGE_KEY_FILE="${AGE_KEY_FILE:-$REPO_ROOT/local/sops/age.key}"
SECRETS_NAMESPACE="${SECRETS_NAMESPACE:-secrets}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/kubernetes/secrets/sops/secrets}"
ROTATE_SOPS_SECRETS="${ROTATE_SOPS_SECRETS:-false}"

CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/config/homelab.yaml}"
AUTHELIA_IMAGE="${AUTHELIA_IMAGE:-authelia/authelia:4.38.18}"

generate_password() {
  local length="${1:-32}"
  openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

generate_secret_key() {
  local bytes="${1:-64}"
  openssl rand -hex "$bytes"
}

read_admin_email() {
  if [[ -n "${ADMIN_EMAIL-}" ]]; then
    echo "$ADMIN_EMAIL"
    return 0
  fi

  local email="admin@homelab.local"
  if [[ -f "$CONFIG_FILE" ]] && command -v yq >/dev/null 2>&1; then
    local cfg_email
    cfg_email="$(yq -r '.homelab.email // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ -n "${cfg_email:-}" ]] && email="$cfg_email"
  fi

  echo "$email"
}

generate_authelia_argon2_hash() {
  local password="$1"

  if command -v docker >/dev/null 2>&1; then
    local output
    output="$(
      docker run --rm "$AUTHELIA_IMAGE" \
        authelia crypto hash generate argon2 --password "$password" 2>/dev/null || true
    )"
    echo "$output" | grep -Eo '\$argon2[^[:space:]]+' | head -n 1
    return 0
  fi

  echo ""
}

encrypt_secret_yaml() {
  local plaintext="$1"
  local out="$2"

  # SOPS loads .sops.yaml config from the repo root. Since we encrypt temp files,
  # use --filename-override so creation_rules match the *target* path.
  sops --encrypt \
    --config "$REPO_ROOT/.sops.yaml" \
    --filename-override "$out" \
    "$plaintext" > "$out"
}

main() {
  need_cmd openssl
  need_cmd kubectl
  need_cmd sops
  need_cmd age-keygen

  cd "$REPO_ROOT"

  mkdir -p "$(dirname "$AGE_KEY_FILE")" "$OUT_DIR"

  if [[ ! -f "$AGE_KEY_FILE" ]]; then
    log "Generating age keypair at $AGE_KEY_FILE ..."
    rm -f "$AGE_KEY_FILE"
    age-keygen -o "$AGE_KEY_FILE" >/dev/null
    chmod 600 "$AGE_KEY_FILE"
  fi

  local age_recipient
  age_recipient="$(age-keygen -y "$AGE_KEY_FILE")"
  log "age public key: $age_recipient"

  if [[ "$ROTATE_SOPS_SECRETS" != "true" ]] && find "$OUT_DIR" -maxdepth 1 -type f -name "*.sops.yaml" -print -quit | grep -q .; then
    log "Encrypted secrets already exist in $OUT_DIR; skipping generation."
    log "To rotate/regenerate: ROTATE_SOPS_SECRETS=true ./scripts/sops-bootstrap.sh"
    return 0
  fi

  local admin_email
  admin_email="$(read_admin_email)"

  TMPDIR_CLEANUP="$(mktemp -d "${TMPDIR:-/tmp}/homelab-sops.XXXXXX")"
  trap 'rm -rf "$TMPDIR_CLEANUP"' EXIT
  local tmpdir="$TMPDIR_CLEANUP"

  log "Generating SOPS-encrypted secrets into $OUT_DIR ..."

  # Core infrastructure
  kubectl create secret generic minio-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=root-user="minioadmin" \
    --from-literal=root-password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/minio-config.yaml"
  encrypt_secret_yaml "$tmpdir/minio-config.yaml" "$OUT_DIR/minio-config.sops.yaml"

  kubectl create secret generic minio-credentials \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=access-key="$(generate_password 20)" \
    --from-literal=secret-key="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/minio-credentials.yaml"
  encrypt_secret_yaml "$tmpdir/minio-credentials.yaml" "$OUT_DIR/minio-credentials.sops.yaml"

  kubectl create secret generic velero-minio-credentials \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=access-key="velero" \
    --from-literal=secret-key="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/velero-minio-credentials.yaml"
  encrypt_secret_yaml "$tmpdir/velero-minio-credentials.yaml" "$OUT_DIR/velero-minio-credentials.sops.yaml"

  # Databases
  kubectl create secret generic mysql-root-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/mysql-root-password.yaml"
  encrypt_secret_yaml "$tmpdir/mysql-root-password.yaml" "$OUT_DIR/mysql-root-password.sops.yaml"

  kubectl create secret generic nextcloud-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/nextcloud-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/nextcloud-db-password.yaml" "$OUT_DIR/nextcloud-db-password.sops.yaml"

  kubectl create secret generic gitea-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/gitea-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/gitea-db-password.yaml" "$OUT_DIR/gitea-db-password.sops.yaml"

  kubectl create secret generic harbor-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/harbor-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/harbor-db-password.yaml" "$OUT_DIR/harbor-db-password.sops.yaml"

  kubectl create secret generic immich-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/immich-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/immich-db-password.yaml" "$OUT_DIR/immich-db-password.sops.yaml"

  kubectl create secret generic paperless-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/paperless-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/paperless-db-password.yaml" "$OUT_DIR/paperless-db-password.sops.yaml"

  kubectl create secret generic n8n-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/n8n-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/n8n-db-password.yaml" "$OUT_DIR/n8n-db-password.sops.yaml"

  kubectl create secret generic linkwarden-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/linkwarden-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/linkwarden-db-password.yaml" "$OUT_DIR/linkwarden-db-password.sops.yaml"

  kubectl create secret generic synapse-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/synapse-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/synapse-db-password.yaml" "$OUT_DIR/synapse-db-password.sops.yaml"

  kubectl create secret generic mattermost-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/mattermost-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/mattermost-db-password.yaml" "$OUT_DIR/mattermost-db-password.sops.yaml"

  kubectl create secret generic outline-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/outline-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/outline-db-password.yaml" "$OUT_DIR/outline-db-password.sops.yaml"

  kubectl create secret generic hoppscotch-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/hoppscotch-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/hoppscotch-db-password.yaml" "$OUT_DIR/hoppscotch-db-password.sops.yaml"

  kubectl create secret generic umami-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/umami-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/umami-db-password.yaml" "$OUT_DIR/umami-db-password.sops.yaml"

  kubectl create secret generic metabase-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/metabase-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/metabase-db-password.yaml" "$OUT_DIR/metabase-db-password.sops.yaml"

  kubectl create secret generic nocodb-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/nocodb-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/nocodb-db-password.yaml" "$OUT_DIR/nocodb-db-password.sops.yaml"

  kubectl create secret generic keycloak-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/keycloak-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/keycloak-db-password.yaml" "$OUT_DIR/keycloak-db-password.sops.yaml"

  kubectl create secret generic romm-db-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/romm-db-password.yaml"
  encrypt_secret_yaml "$tmpdir/romm-db-password.yaml" "$OUT_DIR/romm-db-password.sops.yaml"

  kubectl create secret generic romm-db-root-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/romm-db-root-password.yaml"
  encrypt_secret_yaml "$tmpdir/romm-db-root-password.yaml" "$OUT_DIR/romm-db-root-password.sops.yaml"

  # Admin/app credentials
  kubectl create secret generic nextcloud-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/nextcloud-admin.yaml"
  encrypt_secret_yaml "$tmpdir/nextcloud-admin.yaml" "$OUT_DIR/nextcloud-admin.sops.yaml"

  kubectl create secret generic grafana-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/grafana-admin.yaml"
  encrypt_secret_yaml "$tmpdir/grafana-admin.yaml" "$OUT_DIR/grafana-admin.sops.yaml"

  kubectl create secret generic gitea-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/gitea-admin.yaml"
  encrypt_secret_yaml "$tmpdir/gitea-admin.yaml" "$OUT_DIR/gitea-admin.sops.yaml"

  kubectl create secret generic harbor-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/harbor-admin.yaml"
  encrypt_secret_yaml "$tmpdir/harbor-admin.yaml" "$OUT_DIR/harbor-admin.sops.yaml"

  kubectl create secret generic vaultwarden-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=admin-token="$(generate_secret_key)" \
    --dry-run=client -o yaml > "$tmpdir/vaultwarden-admin.yaml"
  encrypt_secret_yaml "$tmpdir/vaultwarden-admin.yaml" "$OUT_DIR/vaultwarden-admin.sops.yaml"

  # Service configs
  kubectl create secret generic pihole-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=web-password="$(generate_password)" \
    --from-literal=dns-servers="1.1.1.1;8.8.8.8" \
    --dry-run=client -o yaml > "$tmpdir/pihole-config.yaml"
  encrypt_secret_yaml "$tmpdir/pihole-config.yaml" "$OUT_DIR/pihole-config.sops.yaml"

  kubectl create secret generic wireguard-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=ui-password="$(generate_password)" \
    --from-literal=internal-subnet="10.13.13.0" \
    --dry-run=client -o yaml > "$tmpdir/wireguard-config.yaml"
  encrypt_secret_yaml "$tmpdir/wireguard-config.yaml" "$OUT_DIR/wireguard-config.sops.yaml"

  kubectl create secret generic searxng-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret-key="$(generate_secret_key)" \
    --from-literal=instance-name="Homelab Search" \
    --dry-run=client -o yaml > "$tmpdir/searxng-config.yaml"
  encrypt_secret_yaml "$tmpdir/searxng-config.yaml" "$OUT_DIR/searxng-config.sops.yaml"

  local yarr_password
  yarr_password="$(generate_password)"
  kubectl create secret generic yarr-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=auth-user="admin" \
    --from-literal=auth-password="$yarr_password" \
    --from-literal=auth-credentials="admin:$yarr_password" \
    --dry-run=client -o yaml > "$tmpdir/yarr-config.yaml"
  encrypt_secret_yaml "$tmpdir/yarr-config.yaml" "$OUT_DIR/yarr-config.sops.yaml"

  local drone_db_password
  drone_db_password="$(generate_password)"
  kubectl create secret generic drone-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=gitea-client-id="$(generate_secret_key 16)" \
    --from-literal=gitea-client-secret="$(generate_secret_key)" \
    --from-literal=rpc-secret="$(generate_secret_key)" \
    --from-literal=db-password="$drone_db_password" \
    --from-literal=database-url="postgres://drone:${drone_db_password}@drone-db:5432/drone?sslmode=disable" \
    --dry-run=client -o yaml > "$tmpdir/drone-config.yaml"
  encrypt_secret_yaml "$tmpdir/drone-config.yaml" "$OUT_DIR/drone-config.sops.yaml"

  kubectl create secret generic crowdsec-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=bouncer-api-key="$(generate_secret_key 32)" \
    --from-literal=enroll-key="" \
    --dry-run=client -o yaml > "$tmpdir/crowdsec-config.yaml"
  encrypt_secret_yaml "$tmpdir/crowdsec-config.yaml" "$OUT_DIR/crowdsec-config.sops.yaml"

  kubectl create secret generic authelia-secrets \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=jwt-secret="$(generate_secret_key 64)" \
    --from-literal=session-secret="$(generate_secret_key 64)" \
    --from-literal=storage-encryption-key="$(generate_secret_key 64)" \
    --from-literal=redis-password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/authelia-secrets.yaml"
  encrypt_secret_yaml "$tmpdir/authelia-secrets.yaml" "$OUT_DIR/authelia-secrets.sops.yaml"

  local authelia_admin_user authelia_admin_pass authelia_admin_hash
  authelia_admin_user="admin"
  authelia_admin_pass="$(generate_password)"
  kubectl create secret generic authelia-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="$authelia_admin_user" \
    --from-literal=password="$authelia_admin_pass" \
    --dry-run=client -o yaml > "$tmpdir/authelia-admin.yaml"
  encrypt_secret_yaml "$tmpdir/authelia-admin.yaml" "$OUT_DIR/authelia-admin.sops.yaml"

  authelia_admin_hash="$(generate_authelia_argon2_hash "$authelia_admin_pass" || true)"
  if [[ -z "${authelia_admin_hash:-}" ]]; then
    log "WARNING: Failed to generate Authelia Argon2 hash (missing docker?). Using placeholder hash."
    authelia_admin_hash='$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_PROPER_HASH'
  fi

  cat > "$tmpdir/users_database.yml" <<EOF
---
users:
  ${authelia_admin_user}:
    displayname: "Admin User"
    password: "${authelia_admin_hash}"
    email: ${admin_email}
    groups:
      - admins
      - users
EOF

  kubectl create secret generic authelia-users \
    --namespace="$SECRETS_NAMESPACE" \
    --from-file=users_database.yml="$tmpdir/users_database.yml" \
    --dry-run=client -o yaml > "$tmpdir/authelia-users.yaml"
  encrypt_secret_yaml "$tmpdir/authelia-users.yaml" "$OUT_DIR/authelia-users.sops.yaml"

  kubectl create secret generic paperless-admin \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=username="admin" \
    --from-literal=password="$(generate_password)" \
    --from-literal=secret-key="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/paperless-admin.yaml"
  encrypt_secret_yaml "$tmpdir/paperless-admin.yaml" "$OUT_DIR/paperless-admin.sops.yaml"

  kubectl create secret generic n8n-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=encryption-key="$(generate_secret_key 32)" \
    --from-literal=jwt-secret="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/n8n-config.yaml"
  encrypt_secret_yaml "$tmpdir/n8n-config.yaml" "$OUT_DIR/n8n-config.sops.yaml"

  kubectl create secret generic linkwarden-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=nextauth-secret="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/linkwarden-config.yaml"
  encrypt_secret_yaml "$tmpdir/linkwarden-config.yaml" "$OUT_DIR/linkwarden-config.sops.yaml"

  kubectl create secret generic home-assistant-token \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=token="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/home-assistant-token.yaml"
  encrypt_secret_yaml "$tmpdir/home-assistant-token.yaml" "$OUT_DIR/home-assistant-token.sops.yaml"

  kubectl create secret generic node-red-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/node-red-password.yaml"
  encrypt_secret_yaml "$tmpdir/node-red-password.yaml" "$OUT_DIR/node-red-password.sops.yaml"

  kubectl create secret generic mosquitto-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/mosquitto-password.yaml"
  encrypt_secret_yaml "$tmpdir/mosquitto-password.yaml" "$OUT_DIR/mosquitto-password.sops.yaml"

  kubectl create secret generic open-webui-config \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret-key="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/open-webui-config.yaml"
  encrypt_secret_yaml "$tmpdir/open-webui-config.yaml" "$OUT_DIR/open-webui-config.sops.yaml"

  kubectl create secret generic localai-api-key \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=api-key="$(generate_secret_key 32)" \
    --dry-run=client -o yaml > "$tmpdir/localai-api-key.yaml"
  encrypt_secret_yaml "$tmpdir/localai-api-key.yaml" "$OUT_DIR/localai-api-key.sops.yaml"

  kubectl create secret generic synapse-registration-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --from-literal=macaroon-secret-key="$(generate_secret_key 64)" \
    --from-literal=form-secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/synapse-registration-secret.yaml"
  encrypt_secret_yaml "$tmpdir/synapse-registration-secret.yaml" "$OUT_DIR/synapse-registration-secret.sops.yaml"

  kubectl create secret generic netdata-claim-token \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=token="" \
    --dry-run=client -o yaml > "$tmpdir/netdata-claim-token.yaml"
  encrypt_secret_yaml "$tmpdir/netdata-claim-token.yaml" "$OUT_DIR/netdata-claim-token.sops.yaml"

  kubectl create secret generic code-server-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/code-server-password.yaml"
  encrypt_secret_yaml "$tmpdir/code-server-password.yaml" "$OUT_DIR/code-server-password.sops.yaml"

  kubectl create secret generic outline-secret-key \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=key="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/outline-secret-key.yaml"
  encrypt_secret_yaml "$tmpdir/outline-secret-key.yaml" "$OUT_DIR/outline-secret-key.sops.yaml"

  kubectl create secret generic outline-utils-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=key="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/outline-utils-secret.yaml"
  encrypt_secret_yaml "$tmpdir/outline-utils-secret.yaml" "$OUT_DIR/outline-utils-secret.sops.yaml"

  kubectl create secret generic hoppscotch-jwt-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/hoppscotch-jwt-secret.yaml"
  encrypt_secret_yaml "$tmpdir/hoppscotch-jwt-secret.yaml" "$OUT_DIR/hoppscotch-jwt-secret.sops.yaml"

  kubectl create secret generic hoppscotch-session-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/hoppscotch-session-secret.yaml"
  encrypt_secret_yaml "$tmpdir/hoppscotch-session-secret.yaml" "$OUT_DIR/hoppscotch-session-secret.sops.yaml"

  kubectl create secret generic umami-app-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/umami-app-secret.yaml"
  encrypt_secret_yaml "$tmpdir/umami-app-secret.yaml" "$OUT_DIR/umami-app-secret.sops.yaml"

  kubectl create secret generic metabase-encryption-key \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=key="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/metabase-encryption-key.yaml"
  encrypt_secret_yaml "$tmpdir/metabase-encryption-key.yaml" "$OUT_DIR/metabase-encryption-key.sops.yaml"

  kubectl create secret generic nocodb-jwt-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/nocodb-jwt-secret.yaml"
  encrypt_secret_yaml "$tmpdir/nocodb-jwt-secret.yaml" "$OUT_DIR/nocodb-jwt-secret.sops.yaml"

  kubectl create secret generic keycloak-admin-password \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=password="$(generate_password)" \
    --dry-run=client -o yaml > "$tmpdir/keycloak-admin-password.yaml"
  encrypt_secret_yaml "$tmpdir/keycloak-admin-password.yaml" "$OUT_DIR/keycloak-admin-password.sops.yaml"

  kubectl create secret generic romm-auth-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="$(generate_secret_key 64)" \
    --dry-run=client -o yaml > "$tmpdir/romm-auth-secret.yaml"
  encrypt_secret_yaml "$tmpdir/romm-auth-secret.yaml" "$OUT_DIR/romm-auth-secret.sops.yaml"

  kubectl create secret generic romm-igdb-client-id \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=id="" \
    --dry-run=client -o yaml > "$tmpdir/romm-igdb-client-id.yaml"
  encrypt_secret_yaml "$tmpdir/romm-igdb-client-id.yaml" "$OUT_DIR/romm-igdb-client-id.sops.yaml"

  kubectl create secret generic romm-igdb-client-secret \
    --namespace="$SECRETS_NAMESPACE" \
    --from-literal=secret="" \
    --dry-run=client -o yaml > "$tmpdir/romm-igdb-client-secret.yaml"
  encrypt_secret_yaml "$tmpdir/romm-igdb-client-secret.yaml" "$OUT_DIR/romm-igdb-client-secret.sops.yaml"

  log "Done."
  log "Next:"
  log "  1) (Optional) Store $AGE_KEY_FILE somewhere safe (password manager / offline backup)"
  log "  2) Configure ArgoCD to decrypt secrets: ./scripts/configure-argocd-ksops.sh"
}

main "$@"
