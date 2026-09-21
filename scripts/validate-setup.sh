#!/bin/bash
set -euo pipefail

# Homelab validation: cluster health from scripts/lib/health.sh (the catalogue
# decides what "healthy" means per service), plus the checks that are not
# "is X healthy": node readiness, the storage class, generated-secret count,
# MetalLB pools, Velero schedules, Helm releases, network-policy count and the
# hardcoded-password scan of the manifests.
#
# Critical (exit 1): cluster unreachable, no Ready node, storage class missing,
# infrastructure unhealthy, hardcoded passwords. Everything else warns. Only
# an unreachable cluster stops the run; the health report explains the rest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_COLOR="${LOG_COLOR:-true}"

source "$SCRIPT_DIR/lib/health.sh"

CRITICAL=0
critical() {
    warning "CRITICAL: $*"
    CRITICAL=$((CRITICAL + 1))
}

check_kubernetes() {
    log "Checking Kubernetes cluster..."
    if ! kubectl cluster-info &> /dev/null; then
        critical "Kubernetes cluster is not accessible"
        return 1
    fi
    local nodes_ready
    nodes_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -c '^Ready' || true)
    if [ "$nodes_ready" -eq 0 ]; then
        critical "No Kubernetes nodes are Ready"
        return 0
    fi
    success "Kubernetes cluster is accessible ($nodes_ready nodes ready)"
}

check_secrets() {
    log "Checking generated secrets..."
    if ! kubectl get namespace secrets &> /dev/null; then
        warning "Secrets namespace does not exist; run ./scripts/generate-secrets.sh"
        return 0
    fi
    local secrets_count
    secrets_count=$(kubectl get secrets -n secrets --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$secrets_count" -lt 5 ]; then
        warning "Only $secrets_count secrets in the secrets namespace (expected at least 5); run ./scripts/generate-secrets.sh"
    else
        success "Secret management is configured ($secrets_count secrets)"
    fi
}

check_storage_class() {
    log "Checking storage class..."
    if ! kubectl get storageclass local-path &> /dev/null; then
        critical "local-path storage class not found"
        return 1
    fi
    success "local-path storage class exists"
}

check_loadbalancer_pools() {
    kubectl get namespace metallb-system &> /dev/null || return 0
    local pools
    pools=$(kubectl get ipaddresspools -n metallb-system --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$pools" -gt 0 ]; then
        success "$pools MetalLB IP address pools configured"
    else
        warning "No MetalLB IP address pools configured"
    fi
}

check_backup_schedules() {
    kubectl get namespace velero &> /dev/null || return 0
    local schedules
    schedules=$(kubectl get schedules.velero.io -n velero --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$schedules" -gt 0 ]; then
        success "$schedules Velero backup schedules configured"
    else
        warning "No Velero backup schedules configured"
    fi
}

check_helm_releases() {
    log "Checking Helm releases..."
    if ! command -v helm &> /dev/null; then
        warning "Helm is not installed"
        return 0
    fi
    local releases
    releases=$(helm list -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$releases" -eq 0 ]; then
        warning "No Helm releases found"
    else
        success "$releases Helm releases deployed"
        helm list -A
    fi
}

check_security() {
    log "Checking security configuration..."

    # Hardcoded passwords in manifests (show filenames only, not content).
    # Skips SOPS-encrypted secrets and files that reference secrets indirectly
    # (secretKeyRef/remoteRef/existingSecret). Flags only password-like keys
    # that carry a non-empty inline value.
    local files_with_passwords
    files_with_passwords="$(
        while IFS= read -r -d '' f; do
            if grep -qE "secretKeyRef|remoteRef|existingSecret" "$f" 2>/dev/null; then
                continue
            fi
            if grep -E "^[[:space:]-]*[\"']?[A-Za-z0-9_.-]*[Pp]assword[\"']?:" "$f" 2>/dev/null | \
                grep -vE ":[[:space:]]*(\"\"|'')?[[:space:]]*(#.*)?$" | grep -q .; then
                echo "$f"
            fi
        done < <(find "$HOMELAB_DIR/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) -not -path "*/secrets/sops/*" -print0 2>/dev/null)
    )"
    if [ -n "$files_with_passwords" ]; then
        critical "Potential hardcoded passwords in Kubernetes manifests; files to review:"
        echo "$files_with_passwords" | head -5
        return 1
    fi

    # Inline Secret data in manifests (filenames only).
    local secret_files
    secret_files="$(
        while IFS= read -r -d '' f; do
            case "$f" in
                *external-secret*) continue ;;
                */secrets/sops/*) continue ;;
            esac
            if grep -qE "secretKeyRef|remoteRef|existingSecret" "$f" 2>/dev/null; then
                continue
            fi
            if grep -qE "^kind:[[:space:]]*Secret[[:space:]]*$" "$f" 2>/dev/null && grep -qE "^[[:space:]]*data:" "$f" 2>/dev/null; then
                echo "$f"
            fi
        done < <(find "$HOMELAB_DIR/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
    )"
    if [ -n "$secret_files" ]; then
        warning "YAML files with potential hardcoded secrets:"
        echo "$secret_files" | head -5
    else
        success "No hardcoded passwords found in manifests"
    fi
}

check_network_policies() {
    local network_policies
    network_policies=$(kubectl get networkpolicies -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$network_policies" -eq 0 ]; then
        warning "No network policies found; consider implementing network segmentation"
    else
        success "$network_policies network policies configured"
    fi
}

show_troubleshooting() {
    echo ""
    echo "Troubleshooting:"
    echo "   kubectl get pods -A                                # all pods"
    echo "   kubectl get events --sort-by='.lastTimestamp' -A   # recent events"
    echo "   kubectl logs -f deployment/<name> -n <ns>          # service logs"
    echo "   kubectl describe pod <name> -n <ns>                # pod details"
    echo "   kubectl top nodes; kubectl top pods -A             # resource usage"
    echo ""
}

main() {
    echo "Homelab Validation Report"
    echo "================================"

    # The manifest scan needs no cluster; run it first so it always reports.
    check_security || true

    if ! check_kubernetes; then
        echo ""
        error "Cluster checks skipped: $CRITICAL critical check(s) failed"
    fi
    check_storage_class || true
    check_secrets || true

    echo ""
    echo "--- Infrastructure (installed toggles) ---"
    health_report --infra --enabled-only || critical "Infrastructure is not healthy"
    check_loadbalancer_pools
    check_backup_schedules

    echo ""
    echo "--- Services (enabled in the catalogue) ---"
    health_report --services --enabled-only || warning "Some services are not healthy yet"

    echo ""
    echo "--- Configuration ---"
    check_helm_releases
    check_network_policies

    echo ""
    echo "================================"
    if [ "$CRITICAL" -eq 0 ]; then
        success "All critical checks passed"
        echo ""
        access_summary
        show_troubleshooting
        return 0
    fi
    show_troubleshooting
    error "$CRITICAL critical check(s) failed; address them before using the homelab in production"
}

main "$@"
