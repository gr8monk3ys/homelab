#!/usr/bin/env bash
set -euo pipefail

# Restore an encrypted secrets backup created by scripts/backup-secrets.sh.

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

AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOMELAB_DIR/.secrets/agekey.txt}"

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

main() {
  local backup_file="${1:-}"
  if [[ -z "$backup_file" ]]; then
    echo "Usage: $0 <path/to/secrets-*.yaml.age>" >&2
    exit 2
  fi

  require_cmd kubectl
  require_cmd age

  if [[ ! -f "$backup_file" ]]; then
    error "Backup file not found: $backup_file"
  fi

  if [[ ! -f "$AGE_IDENTITY_FILE" ]]; then
    error "Age identity file not found: $AGE_IDENTITY_FILE"
  fi

  if ! kubectl cluster-info &>/dev/null; then
    error "kubectl is not connected to a cluster"
  fi

  # Ensure namespaces exist before applying secrets into them.
  kubectl create namespace secrets --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

  log "Restoring secrets from ${backup_file}..."
  age -d -i "$AGE_IDENTITY_FILE" "$backup_file" | kubectl apply -f -
  log "Restore completed."
}

main "$@"
