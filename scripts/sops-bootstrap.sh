#!/usr/bin/env bash
set -euo pipefail

# Bootstraps SOPS/age for this repo and generates SOPS-encrypted Kubernetes Secrets
# under kubernetes/secrets/sops/.
#
# This script:
# - Creates an age keypair at local/sops/age.key (gitignored)
# - Writes SOPS-encrypted Secret manifests for the homelab into kubernetes/secrets/sops/secrets/
#
# The secret table lives in scripts/lib/secrets.sh (`secrets_catalogue`);
# this script is the sops adapter around it, so the encrypted files carry
# exactly the names and keys that scripts/generate-secrets.sh would create.
#
# It does NOT apply anything to a cluster. For ArgoCD integration, run:
#   ./scripts/configure-argocd-ksops.sh
#
# ROTATE_SOPS_SECRETS=true   regenerate even when encrypted files already exist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/render.sh"
source "$SCRIPT_DIR/lib/secrets.sh"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

AGE_KEY_FILE="${AGE_KEY_FILE:-$REPO_ROOT/local/sops/age.key}"
OUT_DIR="${OUT_DIR:-$SECRETS_SOPS_OUT_DIR}"
ROTATE_SOPS_SECRETS="${ROTATE_SOPS_SECRETS:-false}"

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

  # ADMIN_EMAIL (used for the Authelia users DB): defaults <- config/homelab.yaml <- env.
  homelab_load_config

  log "Generating SOPS-encrypted secrets into $OUT_DIR ..."
  SECRETS_ADAPTER=sops SECRETS_SOPS_OUT_DIR="$OUT_DIR" secrets_catalogue

  log "Done."
  log "Next:"
  log "  1) (Optional) Store $AGE_KEY_FILE somewhere safe (password manager / offline backup)"
  log "  2) Configure ArgoCD to decrypt secrets: ./scripts/configure-argocd-ksops.sh"
}

main "$@"
