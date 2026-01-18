#!/bin/bash
set -euo pipefail

# Homelab Validation Script
# Comprehensive health checks for the modernized homelab

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}✅${NC} $*"
}

warning() {
    echo -e "${YELLOW}⚠️${NC} $*"
}

error() {
    echo -e "${RED}❌${NC} $*"
}

check_kubernetes() {
    log "Checking Kubernetes cluster..."
    
    if ! kubectl cluster-info &> /dev/null; then
        error "Kubernetes cluster is not accessible"
        return 1
    fi
    
    local nodes_ready
    nodes_ready=$(kubectl get nodes --no-headers | awk '{print $2}' | grep -c Ready || true)
    
    if [ "$nodes_ready" -eq 0 ]; then
        error "No Kubernetes nodes are Ready"
        return 1
    fi
    
    success "Kubernetes cluster is accessible ($nodes_ready nodes ready)"
}

check_secrets() {
    log "Checking secret management..."
    
    # Check if External Secrets Operator is running
    if ! kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets | grep -q Running; then
        error "External Secrets Operator is not running"
        return 1
    fi
    
    # Check if secrets namespace exists
    if ! kubectl get namespace secrets &> /dev/null; then
        error "Secrets namespace does not exist"
        return 1
    fi
    
    # Check for generated secrets
    local secrets_count
    secrets_count=$(kubectl get secrets -n secrets --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' ' || echo "0")
    
    if [ "$secrets_count" -lt 5 ]; then
        warning "Only $secrets_count secrets found in secrets namespace (expected at least 5)"
        warning "Run: ./scripts/generate-secrets.sh"
    else
        success "Secret management is configured ($secrets_count secrets)"
    fi
}

check_storage() {
    log "Checking storage..."
    
    # Check storage class
    if ! kubectl get storageclass local-path &> /dev/null; then
        error "local-path storage class not found"
        return 1
    fi
    
    # Check if local-path-provisioner is running
    if ! kubectl get pods -n local-path-storage -l app=local-path-provisioner | grep -q Running; then
        warning "local-path-provisioner may not be running"
    else
        success "Storage provisioner is running"
    fi
}

check_ingress() {
    log "Checking ingress..."
    
    # Check Traefik
    if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik | grep -q Running; then
        error "Traefik ingress controller is not running"
        return 1
    fi
    
    # Check cert-manager
    if ! kubectl get pods -n cert-manager | grep -q Running; then
        warning "cert-manager may not be running"
    else
        success "Ingress and certificate management is configured"
    fi
}

check_monitoring() {
    log "Checking monitoring stack..."
    
    # Check if monitoring namespace exists
    if ! kubectl get namespace monitoring &> /dev/null; then
        warning "Monitoring namespace does not exist"
        return 0
    fi
    
    # Check Prometheus
    if ! kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus | grep -q Running; then
        warning "Prometheus is not running"
    fi
    
    # Check Grafana
    if ! kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana | grep -q Running; then
        warning "Grafana is not running"
    fi
    
    success "Monitoring stack is configured"
}

check_core_services() {
    log "Checking core services..."

    local services=("nextcloud" "gitea" "vaultwarden")
    local healthy_services=0

    for service in "${services[@]}"; do
        if kubectl get namespace "$service" &> /dev/null; then
            if kubectl get pods -n "$service" | grep -q Running; then
                success "$service is running"
                ((healthy_services++))
            else
                warning "$service namespace exists but pods are not running"
            fi
        else
            warning "$service namespace does not exist"
        fi
    done

    if [ $healthy_services -eq 0 ]; then
        error "No core services are running"
        return 1
    fi

    success "$healthy_services core services are healthy"
}

check_loadbalancer() {
    log "Checking MetalLB load balancer..."

    if ! kubectl get namespace metallb-system &> /dev/null; then
        warning "MetalLB namespace does not exist"
        return 0
    fi

    if kubectl get pods -n metallb-system -l app.kubernetes.io/name=metallb | grep -q Running; then
        success "MetalLB is running"
    else
        warning "MetalLB pods are not running"
    fi

    # Check IP address pools
    local pools
    pools=$(kubectl get ipaddresspools -n metallb-system --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "$pools" -gt 0 ]; then
        success "$pools IP address pools configured"
    else
        warning "No IP address pools configured"
    fi
}

check_backup() {
    log "Checking Velero backup..."

    if ! kubectl get namespace velero &> /dev/null; then
        warning "Velero namespace does not exist"
        return 0
    fi

    if kubectl get pods -n velero | grep -q Running; then
        success "Velero is running"
    else
        warning "Velero pods are not running"
    fi

    # Check backup schedules
    local schedules
    schedules=$(kubectl get schedules.velero.io -n velero --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [ "$schedules" -gt 0 ]; then
        success "$schedules backup schedules configured"
    else
        warning "No backup schedules configured"
    fi
}

check_crowdsec() {
    log "Checking CrowdSec security..."

    if ! kubectl get namespace crowdsec &> /dev/null; then
        warning "CrowdSec namespace does not exist"
        return 0
    fi

    if kubectl get pods -n crowdsec -l app=crowdsec | grep -q Running; then
        success "CrowdSec agent is running"
    else
        warning "CrowdSec agent is not running"
    fi

    if kubectl get pods -n crowdsec -l component=bouncer | grep -q Running; then
        success "CrowdSec bouncer is running"
    else
        warning "CrowdSec bouncer is not running"
    fi
}

check_authelia() {
    log "Checking Authelia SSO..."

    if ! kubectl get namespace authelia &> /dev/null; then
        warning "Authelia namespace does not exist"
        return 0
    fi

    if kubectl get pods -n authelia -l app=authelia | grep -q Running; then
        success "Authelia is running"
    else
        warning "Authelia is not running"
    fi

    if kubectl get pods -n authelia -l app=authelia-redis | grep -q Running; then
        success "Authelia Redis is running"
    else
        warning "Authelia Redis is not running"
    fi
}

check_media_services() {
    log "Checking media services..."

    local media_services=("jellyfin" "arr-stack" "audiobookshelf")
    local healthy_count=0

    for ns in "${media_services[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            if kubectl get pods -n "$ns" | grep -q Running; then
                success "$ns is running"
                ((healthy_count++))
            else
                warning "$ns namespace exists but pods are not running"
            fi
        else
            warning "$ns namespace does not exist"
        fi
    done

    success "$healthy_count media services are healthy"
}

check_ai_services() {
    log "Checking AI services..."

    # Check Immich
    if kubectl get namespace immich &> /dev/null; then
        if kubectl get pods -n immich -l app=immich-server | grep -q Running; then
            success "Immich is running"
        else
            warning "Immich is not running"
        fi
    else
        warning "Immich namespace does not exist"
    fi

    # Check Ollama
    if kubectl get namespace ollama &> /dev/null; then
        if kubectl get pods -n ollama -l app=ollama | grep -q Running; then
            success "Ollama is running"
        else
            warning "Ollama is not running"
        fi
    else
        warning "Ollama namespace does not exist"
    fi
}

check_productivity_services() {
    log "Checking productivity services..."

    local services=("paperless-ngx" "n8n" "mealie" "linkwarden" "homepage")
    local healthy_count=0

    for ns in "${services[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            if kubectl get pods -n "$ns" | grep -q Running; then
                success "$ns is running"
                ((healthy_count++))
            else
                warning "$ns namespace exists but pods are not running"
            fi
        else
            warning "$ns namespace does not exist"
        fi
    done

    success "$healthy_count productivity services are healthy"
}

check_external_secrets() {
    log "Checking External Secrets..."
    
    local external_secrets
    external_secrets=$(kubectl get externalsecrets -A --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' \n' || echo "0")
    
    if [ "$external_secrets" -eq 0 ]; then
        warning "No External Secrets found"
        warning "Secrets may not be properly configured"
    else
        success "$external_secrets External Secrets configured"
    fi
}

check_helm_releases() {
    log "Checking Helm releases..."
    
    if ! command -v helm &> /dev/null; then
        warning "Helm is not installed"
        return 0
    fi
    
    local releases
    releases=$(helm list -A --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' ' || echo "0")
    
    if [ "$releases" -eq 0 ]; then
        warning "No Helm releases found"
    else
        success "$releases Helm releases deployed"
        helm list -A
    fi
}

check_security() {
    log "Checking security configuration..."

    # Check for hardcoded passwords in configs (use --files-with-matches to avoid exposing passwords)
    local files_with_passwords
    files_with_passwords=$(grep -rl "password.*:" "$HOMELAB_DIR/kubernetes" --include="*.yaml" 2>/dev/null | xargs -r grep -L "secretKeyRef" 2>/dev/null || true)
    if [ -n "$files_with_passwords" ]; then
        error "Found potential hardcoded passwords in Kubernetes manifests"
        echo "Files to review:"
        echo "$files_with_passwords" | head -5
        return 1
    fi

    # Check for base64 encoded secrets in manifests (show filenames only, not content)
    local secret_files
    secret_files=$(find "$HOMELAB_DIR/kubernetes" -name "*.yaml" -exec grep -l "data:" {} \; 2>/dev/null | xargs -r grep -l "password\|secret" 2>/dev/null | grep -v external-secret || true)
    if [ -n "$secret_files" ]; then
        warning "Found YAML files with potential hardcoded secrets:"
        echo "$secret_files" | head -5
    fi

    success "No hardcoded passwords found in manifests"
}

check_network_policies() {
    log "Checking network policies..."
    
    local network_policies
    network_policies=$(kubectl get networkpolicies -A --no-headers 2>/dev/null | wc -l 2>/dev/null | tr -d ' ' || echo "0")
    
    if [ "$network_policies" -eq 0 ]; then
        warning "No network policies found"
        warning "Consider implementing network segmentation"
    else
        success "$network_policies network policies configured"
    fi
}

show_access_info() {
    log "Gathering access information..."
    
    echo ""
    echo "🔗 Service Access URLs:"
    echo "   Add to /etc/hosts: <your-server-ip> <domain>"
    echo ""
    
    # Check for ingress resources
    kubectl get ingress -A --no-headers 2>/dev/null | while read -r namespace name class hosts address ports age; do
        echo "   🌐 $name: https://$hosts"
    done
    
    echo ""
    echo "🔐 Retrieve service passwords securely (not logged):"
    echo "   Nextcloud: kubectl get secret nextcloud-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   Grafana:   kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo"
    echo "   ArgoCD:    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
    echo ""
}

show_troubleshooting() {
    echo ""
    echo "🔧 Troubleshooting Commands:"
    echo "   kubectl get pods -A                          # Check all pods"
    echo "   kubectl get events --sort-by='.lastTimestamp' -A  # Recent events"  
    echo "   kubectl logs -f deployment/<name> -n <ns>    # Service logs"
    echo "   kubectl describe pod <name> -n <ns>          # Pod details"
    echo ""
    echo "📊 Monitoring:"
    echo "   kubectl top nodes                            # Node resource usage"
    echo "   kubectl top pods -A                          # Pod resource usage"
    echo ""
}

main() {
    echo "🔍 Homelab Validation Report"
    echo "================================"

    local failed_checks=0

    check_kubernetes || ((failed_checks++))
    check_secrets || ((failed_checks++))
    check_storage || ((failed_checks++))
    check_ingress || ((failed_checks++))

    echo ""
    echo "--- Infrastructure ---"
    check_loadbalancer
    check_backup
    check_crowdsec

    echo ""
    echo "--- Core Services ---"
    check_monitoring
    check_core_services || ((failed_checks++))

    echo ""
    echo "--- Authentication ---"
    check_authelia

    echo ""
    echo "--- Media Services ---"
    check_media_services

    echo ""
    echo "--- AI Services ---"
    check_ai_services

    echo ""
    echo "--- Productivity Services ---"
    check_productivity_services

    echo ""
    echo "--- Configuration ---"
    check_external_secrets
    check_helm_releases
    check_security || ((failed_checks++))
    check_network_policies

    echo ""
    echo "================================"

    if [ $failed_checks -eq 0 ]; then
        success "All critical checks passed! 🎉"
        echo ""
        show_access_info
    else
        error "$failed_checks critical checks failed"
        echo ""
        echo "❗ Please address the failed checks before using your homelab in production"
    fi

    show_troubleshooting
}

main "$@"