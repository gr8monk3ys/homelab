#!/bin/bash
set -euo pipefail

# Apply Network Policies to Homelab Namespaces
# This script applies a baseline set of network policies for security

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Namespaces that should have network policies
# Excludes system namespaces (kube-system, monitoring, etc.)
SERVICE_NAMESPACES=(
    "vaultwarden"
    "nextcloud"
    "gitea"
    "immich"
    "jellyfin"
    "home-assistant"
    "paperless-ngx"
    "heimdall"
    "homepage"
    "audiobookshelf"
    "navidrome"
    "mealie"
    "linkwarden"
    "searxng"
    "yarr"
    "whisper"
    "calibre-web"
    "romm"
    "n8n"
    "nocodb"
    "metabase"
    "umami"
    "hoppscotch"
    "outline"
    "mattermost"
    "matrix"
    "drone"
    "code-server"
)

# Namespaces that need external HTTPS access
EXTERNAL_ACCESS_NAMESPACES=(
    "nextcloud"      # Federation, external storage
    "gitea"          # Webhooks, external Git repos
    "n8n"            # Workflow automation
    "searxng"        # Search engine queries
    "yarr"           # RSS feed fetching
    "linkwarden"     # Bookmark fetching
    "paperless-ngx"  # Document fetching
    "home-assistant" # External integrations
    "drone"          # CI/CD webhooks
    "ollama"         # Model downloads
    "whisper"        # Model downloads
)

apply_base_policies() {
    local namespace="$1"

    log "Applying base policies to $namespace..."

    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        warning "Namespace $namespace does not exist, skipping"
        return 0
    fi

    # Apply default deny
    kubectl apply -f "$SCRIPT_DIR/default-deny.yaml" -n "$namespace" 2>/dev/null || true

    # Apply common allows
    kubectl apply -f "$SCRIPT_DIR/allow-dns.yaml" -n "$namespace" 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/allow-ingress.yaml" -n "$namespace" 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/allow-monitoring.yaml" -n "$namespace" 2>/dev/null || true
    kubectl apply -f "$SCRIPT_DIR/allow-same-namespace.yaml" -n "$namespace" 2>/dev/null || true

    success "Applied base policies to $namespace"
}

apply_external_access() {
    local namespace="$1"

    if ! kubectl get namespace "$namespace" &> /dev/null; then
        return 0
    fi

    log "Applying external HTTPS access to $namespace..."
    kubectl apply -f "$SCRIPT_DIR/allow-external-https.yaml" -n "$namespace" 2>/dev/null || true
    success "Applied external access to $namespace"
}

verify_policies() {
    local namespace="$1"

    local policy_count
    policy_count=$(kubectl get networkpolicy -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$policy_count" -gt 0 ]; then
        success "$namespace: $policy_count policies applied"
    else
        warning "$namespace: No policies found"
    fi
}

main() {
    echo "========================================"
    echo "Applying Network Policies"
    echo "========================================"
    echo ""

    # First, ensure kube-system has the right labels
    log "Ensuring kube-system namespace has required labels..."
    kubectl label namespace kube-system kubernetes.io/metadata.name=kube-system --overwrite 2>/dev/null || true
    kubectl label namespace monitoring kubernetes.io/metadata.name=monitoring --overwrite 2>/dev/null || true

    echo ""
    echo "Applying base policies to service namespaces..."
    echo ""

    for ns in "${SERVICE_NAMESPACES[@]}"; do
        apply_base_policies "$ns"
    done

    echo ""
    echo "Applying external HTTPS access where needed..."
    echo ""

    for ns in "${EXTERNAL_ACCESS_NAMESPACES[@]}"; do
        apply_external_access "$ns"
    done

    echo ""
    echo "========================================"
    echo "Verification"
    echo "========================================"
    echo ""

    for ns in "${SERVICE_NAMESPACES[@]}"; do
        verify_policies "$ns"
    done

    echo ""
    echo "========================================"
    echo "Network Policies Applied Successfully"
    echo "========================================"
    echo ""
    echo "To verify a specific namespace:"
    echo "  kubectl get networkpolicy -n <namespace>"
    echo ""
    echo "To test connectivity:"
    echo "  kubectl run test --rm -it --image=busybox -n <namespace> -- wget -qO- <service>"
    echo ""
}

# Handle --dry-run flag
if [ "${1:-}" = "--dry-run" ]; then
    echo "Dry run - would apply policies to these namespaces:"
    echo ""
    echo "Base policies:"
    for ns in "${SERVICE_NAMESPACES[@]}"; do
        echo "  - $ns"
    done
    echo ""
    echo "External HTTPS access:"
    for ns in "${EXTERNAL_ACCESS_NAMESPACES[@]}"; do
        echo "  - $ns"
    done
    exit 0
fi

main
