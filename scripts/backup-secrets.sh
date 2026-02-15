#!/usr/bin/env bash
set -euo pipefail

# Encrypted backup of homelab secrets using age.
#
# By default this backs up:
# - All Secrets in the `secrets` namespace (excluding service-account tokens)
# - cert-manager root CA + ACME account keys if present (optional)

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
INCLUDE_CERT_MANAGER="${INCLUDE_CERT_MANAGER:-true}"

BACKUP_DIR="${BACKUP_DIR:-$HOMELAB_DIR/backups}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOMELAB_DIR/.secrets/agekey.txt}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" &>/dev/null || error "Missing required tool: $1"
}

ensure_age_identity() {
  if [[ -n "$AGE_RECIPIENT" ]]; then
    return 0
  fi

  if [[ ! -f "$AGE_IDENTITY_FILE" ]]; then
    log "Generating age identity at $AGE_IDENTITY_FILE"
    mkdir -p "$(dirname "$AGE_IDENTITY_FILE")"
    age-keygen -o "$AGE_IDENTITY_FILE" >/dev/null
    chmod 600 "$AGE_IDENTITY_FILE"
  fi

  AGE_RECIPIENT="$(age-keygen -y "$AGE_IDENTITY_FILE")"
  if [[ -z "${AGE_RECIPIENT:-}" ]]; then
    error "Failed to derive age recipient from $AGE_IDENTITY_FILE"
  fi
}

sanitize_secret_list() {
  # Reads a SecretList from stdin and writes a sanitized SecretList to stdout.
  yq -y '
    .items |= map(select(.type != "kubernetes.io/service-account-token")) |
    del(.items[].metadata.uid) |
    del(.items[].metadata.resourceVersion) |
    del(.items[].metadata.generation) |
    del(.items[].metadata.creationTimestamp) |
    del(.items[].metadata.managedFields) |
    del(.items[].metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
  '
}

sanitize_secret() {
  # Reads a Secret from stdin and writes a sanitized Secret to stdout.
  yq -y '
    del(.metadata.uid) |
    del(.metadata.resourceVersion) |
    del(.metadata.generation) |
    del(.metadata.creationTimestamp) |
    del(.metadata.managedFields) |
    del(.metadata.annotations."kubectl.kubernetes.io/last-applied-configuration")
  '
}

main() {
  require_cmd kubectl
  require_cmd yq
  require_cmd age
  require_cmd age-keygen

  if ! kubectl cluster-info &>/dev/null; then
    error "kubectl is not connected to a cluster"
  fi

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true

  ensure_age_identity

  local ts out_plain out_enc
  ts="$(date +%Y%m%d-%H%M%S)"
  out_plain="$(mktemp "${TMPDIR:-/tmp}/homelab-secrets.${ts}.XXXXXX.yaml")"
  out_enc="${BACKUP_DIR}/secrets-${SECRETS_NAMESPACE}-${ts}.yaml.age"

  log "Exporting secrets from namespace ${SECRETS_NAMESPACE}..."
  kubectl get secrets -n "$SECRETS_NAMESPACE" -o yaml | sanitize_secret_list > "$out_plain"

  if [[ "$INCLUDE_CERT_MANAGER" == "true" ]]; then
    local cm_secrets=(homelab-root-ca letsencrypt-prod letsencrypt-staging)
    local name
    for name in "${cm_secrets[@]}"; do
      if kubectl get secret -n cert-manager "$name" &>/dev/null; then
        log "Including cert-manager secret: cert-manager/${name}"
        printf "\n---\n" >> "$out_plain"
        kubectl get secret -n cert-manager "$name" -o yaml | sanitize_secret >> "$out_plain"
      fi
    done
  fi

  log "Encrypting to ${out_enc}..."
  age -r "$AGE_RECIPIENT" -o "$out_enc" "$out_plain"
  chmod 600 "$out_enc" || true
  rm -f "$out_plain"

  log "Encrypted secrets backup created:"
  log "  File: ${out_enc}"
  if [[ -f "$AGE_IDENTITY_FILE" ]]; then
    log "  Identity: ${AGE_IDENTITY_FILE} (keep this safe; required to restore)"
  else
    log "  Recipient: ${AGE_RECIPIENT}"
  fi
}

main "$@"
