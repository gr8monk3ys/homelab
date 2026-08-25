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

FAILED_APPLIES=0

apply_policy() {
    local file="$1"
    local namespace="$2"

    if kubectl apply -f "$file" -n "$namespace" >/dev/null; then
        return 0
    fi
    warning "Failed to apply $(basename "$file") to $namespace"
    FAILED_APPLIES=$((FAILED_APPLIES+1))
    return 1
}

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

    local failed=0

    # Apply default deny
    apply_policy "$SCRIPT_DIR/default-deny.yaml" "$namespace" || failed=$((failed+1))

    # Apply common allows
    apply_policy "$SCRIPT_DIR/allow-dns.yaml" "$namespace" || failed=$((failed+1))
    apply_policy "$SCRIPT_DIR/allow-ingress.yaml" "$namespace" || failed=$((failed+1))
    apply_policy "$SCRIPT_DIR/allow-monitoring.yaml" "$namespace" || failed=$((failed+1))
    apply_policy "$SCRIPT_DIR/allow-same-namespace.yaml" "$namespace" || failed=$((failed+1))

    if [ "$failed" -eq 0 ]; then
        success "Applied base policies to $namespace"
    else
        warning "$namespace: $failed base policy(ies) failed to apply"
    fi
}

apply_external_access() {
    local namespace="$1"

    if ! kubectl get namespace "$namespace" &> /dev/null; then
        return 0
    fi

    log "Applying external HTTPS access to $namespace..."
    if apply_policy "$SCRIPT_DIR/allow-external-https.yaml" "$namespace"; then
        success "Applied external access to $namespace"
    fi
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
    if [ "$FAILED_APPLIES" -eq 0 ]; then
        echo "Network Policies Applied Successfully"
    else
        echo "Network Policies Applied With $FAILED_APPLIES Failure(s)"
    fi
    echo "========================================"
    echo ""
    echo "To verify a specific namespace:"
    echo "  kubectl get networkpolicy -n <namespace>"
    echo ""
    echo "To test connectivity:"
    echo "  kubectl run test --rm -it --image=busybox -n <namespace> -- wget -qO- <service>"
    echo ""

    if [ "$FAILED_APPLIES" -gt 0 ]; then
        exit 1
    fi
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
