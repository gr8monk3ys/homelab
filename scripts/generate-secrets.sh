#!/bin/bash
set -euo pipefail

# Generate the homelab's source-of-truth secrets in the central `secrets`
# namespace; ExternalSecrets copy them into each service's namespace.
#
# The secret table lives in scripts/lib/secrets.sh (`secrets_catalogue`);
# this script is the kubectl adapter around it.
#
# Usage: scripts/generate-secrets.sh [--list]
#   --list   print the table (name and key=policy per secret); needs no cluster
#
# ROTATE_SECRETS=true   regenerate secrets that already exist (default: keep them)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/render.sh"
source "$SCRIPT_DIR/lib/secrets.sh"

if [[ "${1:-}" == "--list" ]]; then
    SECRETS_ADAPTER=list secrets_catalogue
    exit 0
fi

# ADMIN_EMAIL (used for the Authelia users DB): defaults <- config/homelab.yaml <- env.
homelab_load_config

check_dependencies() {
    local missing=()
    command -v openssl &> /dev/null || missing+=("openssl")
    command -v kubectl &> /dev/null || missing+=("kubectl")
    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}. Please install them first."
    fi
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster. Ensure kubectl is configured correctly."
    fi
    log "All dependencies verified"
}

check_dependencies

log "Generating secure secrets for homelab services..."

kubectl create namespace "$SECRETS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

SECRETS_ADAPTER=kubectl secrets_catalogue

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
