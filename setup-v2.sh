#!/bin/bash
set -euo pipefail

# Enhanced Homelab Setup Script v2.0
# Features: Secret management, Helm charts, Kustomize, health checks

HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$HOMELAB_DIR/setup.log"
CONFIG_FILE="$HOMELAB_DIR/config/homelab.yaml"

# Configuration
ENVIRONMENT="${ENVIRONMENT:-production}"
DOMAIN="${DOMAIN:-homelab.local}"
TIMEZONE="${TIMEZONE:-UTC}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@homelab.local}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    exit 1
}

success() {
    log "✅ $*"
}

info() {
    log "ℹ️  $*"
}

warning() {
    log "⚠️  $*"
}

check_requirements() {
    log "Checking system requirements..."
    
    local missing_tools=()
    
    for tool in docker kubectl helm kustomize; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
    fi
    
    # Check Kubernetes cluster
    if ! kubectl cluster-info &> /dev/null; then
        error "Kubernetes cluster is not accessible"
    fi
    
    success "Requirements check completed"
}

install_tools() {
    log "Installing/updating tools..."

    # Pinned versions for reproducibility and security
    local HELM_VERSION="v3.14.0"
    local KUSTOMIZE_VERSION="v5.3.0"

    # Install/update Helm with version pinning
    if ! command -v helm &> /dev/null; then
        log "Installing Helm ${HELM_VERSION}..."
        local helm_script="/tmp/get-helm-3.sh"
        curl -fsSL -o "$helm_script" "https://raw.githubusercontent.com/helm/helm/${HELM_VERSION}/scripts/get-helm-3"
        chmod +x "$helm_script"
        DESIRED_VERSION="${HELM_VERSION}" bash "$helm_script"
        rm -f "$helm_script"
    fi

    # Install/update Kustomize with version pinning
    if ! command -v kustomize &> /dev/null; then
        log "Installing Kustomize ${KUSTOMIZE_VERSION}..."
        local kustomize_script="/tmp/install_kustomize.sh"
        curl -fsSL -o "$kustomize_script" "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/kustomize/${KUSTOMIZE_VERSION}/hack/install_kustomize.sh"
        chmod +x "$kustomize_script"
        bash "$kustomize_script" "${KUSTOMIZE_VERSION#v}" /tmp
        sudo mv /tmp/kustomize /usr/local/bin/
        rm -f "$kustomize_script"
    fi
    
    # Add Helm repositories
    log "Adding Helm repositories..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || log "WARNING: prometheus-community repo may already exist"
    helm repo add bitnami https://charts.bitnami.com/bitnami || log "WARNING: bitnami repo may already exist"
    helm repo add jetstack https://charts.jetstack.io || log "WARNING: jetstack repo may already exist"

    if ! helm repo update; then
        error "Failed to update Helm repositories"
    fi

    success "Tools installation completed"
}

setup_secrets() {
    log "Setting up secret management..."
    
    # Deploy External Secrets Operator
    kubectl apply -f kubernetes/secrets/external-secrets-operator.yaml
    
    # Wait for External Secrets Operator to be ready
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s
    
    # Deploy secret store
    kubectl apply -f kubernetes/secrets/secret-store.yaml
    
    # Generate all secrets
    log "Generating secure secrets..."
    bash scripts/generate-secrets.sh
    
    success "Secret management setup completed"
}

setup_infrastructure() {
    log "Setting up core infrastructure with Kustomize..."

    # Build manifests first to catch kustomize errors before applying
    local manifest_file="/tmp/homelab-infrastructure-$$.yaml"

    # Ensure temp file is cleaned up on exit or error
    cleanup_manifest() {
        rm -f "$manifest_file"
    }
    trap cleanup_manifest EXIT

    if ! kustomize build "kustomize/overlays/$ENVIRONMENT" > "$manifest_file"; then
        error "Kustomize build failed for environment: $ENVIRONMENT"
    fi

    # Apply built manifests
    if ! kubectl apply -f "$manifest_file"; then
        error "Failed to apply infrastructure manifests"
    fi

    # Cleanup temp file
    rm -f "$manifest_file"
    trap - EXIT

    # Wait for core services
    kubectl wait --for=condition=Ready pods -l app=traefik -n kube-system --timeout=300s

    success "Infrastructure setup completed"
}

setup_storage() {
    log "Setting up persistent storage..."
    
    # Apply storage manifests via Kustomize
    kubectl apply -k kubernetes/storage/
    
    # Wait for storage to be ready
    kubectl wait --for=condition=Ready pods -l app=local-path-provisioner -n local-path-storage --timeout=300s
    
    success "Storage setup completed"
}

setup_ingress() {
    log "Setting up ingress controller and certificates..."
    
    # Install cert-manager with Helm
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.13.0 \
        --set installCRDs=true \
        --wait
    
    # Apply certificate issuers
    kubectl apply -f kubernetes/ingress/cert-manager/
    
    success "Ingress setup completed"
}

setup_monitoring() {
    log "Setting up monitoring stack with Helm..."
    
    # Install Prometheus stack
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --values kubernetes/monitoring/prometheus/values.yaml \
        --wait
    
    # Deploy additional monitoring components
    kubectl apply -f kubernetes/monitoring/uptime-kuma/
    
    success "Monitoring setup completed"
}

setup_core_services() {
    log "Setting up core services with Helm..."
    
    # Install NextCloud using our custom Helm chart
    helm upgrade --install nextcloud helm/nextcloud \
        --namespace nextcloud \
        --create-namespace \
        --wait
    
    # Install other services
    kubectl apply -f kubernetes/services/vaultwarden/
    kubectl apply -f kubernetes/services/gitea/
    kubectl apply -f kubernetes/services/jellyfin/
    
    success "Core services setup completed"
}

setup_network_services() {
    log "Setting up network services..."
    
    kubectl apply -f kubernetes/services/pihole/
    kubectl apply -f kubernetes/services/wireguard/
    kubectl apply -f kubernetes/services/dnsmasq-dhcp/
    
    success "Network services setup completed"
}

setup_development_services() {
    log "Setting up development services..."
    
    kubectl apply -f kubernetes/services/harbor/
    kubectl apply -f kubernetes/services/drone/
    
    success "Development services setup completed"
}

setup_content_services() {
    log "Setting up content services..."

    kubectl apply -f kubernetes/services/searxng/
    kubectl apply -f kubernetes/services/calibre-web/
    kubectl apply -f kubernetes/services/yarr/

    success "Content services setup completed"
}

setup_loadbalancer() {
    log "Setting up MetalLB load balancer..."

    # Add MetalLB Helm repo
    helm repo add metallb https://metallb.github.io/metallb || log "WARNING: metallb repo may already exist"
    helm repo update

    # Install MetalLB
    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --create-namespace \
        --wait

    # Wait for MetalLB to be ready
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=metallb -n metallb-system --timeout=300s

    # Apply IP address pool and L2 advertisement
    kubectl apply -f kubernetes/loadbalancing/metallb/ipaddresspool.yaml
    kubectl apply -f kubernetes/loadbalancing/metallb/l2advertisement.yaml

    success "MetalLB setup completed"
}

setup_backup() {
    log "Setting up Velero backup..."

    # Add Velero Helm repo
    helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || log "WARNING: vmware-tanzu repo may already exist"
    helm repo update

    # Create namespace
    kubectl apply -f kubernetes/backup/velero/namespace.yaml

    # Install Velero with Helm
    helm upgrade --install velero vmware-tanzu/velero \
        --namespace velero \
        --values kubernetes/backup/velero/values.yaml \
        --wait

    # Apply backup schedules
    kubectl apply -f kubernetes/backup/velero/schedules.yaml

    success "Velero backup setup completed"
}

setup_security() {
    log "Setting up CrowdSec security..."

    kubectl apply -f kubernetes/security/crowdsec/namespace.yaml
    kubectl apply -f kubernetes/security/crowdsec/configmap.yaml
    kubectl apply -f kubernetes/security/crowdsec/deployment.yaml

    # Wait for CrowdSec to be ready
    kubectl wait --for=condition=Ready pods -l app=crowdsec -n crowdsec --timeout=300s || log "WARNING: CrowdSec may take longer to start"

    success "CrowdSec security setup completed"
}

setup_network_policies() {
    log "Setting up network policies for service isolation..."

    # Apply all network policies
    kubectl apply -f kubernetes/security/network-policies/namespace.yaml
    kubectl apply -f kubernetes/security/network-policies/default-deny-policies.yaml
    kubectl apply -f kubernetes/security/network-policies/egress-policies.yaml
    kubectl apply -f kubernetes/security/network-policies/database-policies.yaml
    kubectl apply -f kubernetes/security/network-policies/sensitive-services-policies.yaml
    kubectl apply -f kubernetes/security/network-policies/infrastructure-policies.yaml
    kubectl apply -f kubernetes/security/network-policies/media-services-policies.yaml

    success "Network policies setup completed"
}

setup_pod_disruption_budgets() {
    log "Setting up PodDisruptionBudgets for critical services..."

    kubectl apply -f kubernetes/security/pod-disruption-budgets.yaml

    success "PodDisruptionBudgets setup completed"
}

setup_resource_quotas() {
    log "Setting up ResourceQuotas for namespace resource limits..."

    kubectl apply -f kubernetes/security/resource-quotas.yaml

    success "ResourceQuotas setup completed"
}

setup_pod_security_standards() {
    log "Setting up Pod Security Standards for namespaces..."

    kubectl apply -f kubernetes/security/pod-security-standards.yaml

    success "Pod Security Standards setup completed"
}

setup_authentication() {
    log "Setting up Authelia SSO/2FA..."

    kubectl apply -f kubernetes/services/authelia/namespace.yaml
    kubectl apply -f kubernetes/services/authelia/configmap.yaml
    kubectl apply -f kubernetes/services/authelia/redis-deployment.yaml

    # Wait for Redis
    kubectl wait --for=condition=Ready pods -l app=authelia-redis -n authelia --timeout=300s

    kubectl apply -f kubernetes/services/authelia/deployment.yaml
    kubectl apply -f kubernetes/services/authelia/middleware.yaml

    success "Authelia SSO setup completed"
}

setup_media_services() {
    log "Setting up media services..."

    # Jellyfin
    kubectl apply -f kubernetes/services/jellyfin/namespace.yaml
    kubectl apply -f kubernetes/services/jellyfin/deployment.yaml

    # Arr Stack
    kubectl apply -f kubernetes/services/arr-stack/namespace.yaml
    kubectl apply -f kubernetes/services/arr-stack/shared-storage.yaml
    kubectl apply -f kubernetes/services/arr-stack/sonarr-deployment.yaml
    kubectl apply -f kubernetes/services/arr-stack/radarr-deployment.yaml
    kubectl apply -f kubernetes/services/arr-stack/prowlarr-deployment.yaml
    kubectl apply -f kubernetes/services/arr-stack/bazarr-deployment.yaml

    # Audiobookshelf
    kubectl apply -f kubernetes/services/audiobookshelf/namespace.yaml
    kubectl apply -f kubernetes/services/audiobookshelf/deployment.yaml

    success "Media services setup completed"
}

setup_ai_services() {
    log "Setting up AI services..."

    # Immich (photos with ML)
    kubectl apply -f kubernetes/services/immich/namespace.yaml
    kubectl apply -f kubernetes/services/immich/postgres-deployment.yaml
    kubectl apply -f kubernetes/services/immich/redis-deployment.yaml

    # Wait for Immich dependencies
    kubectl wait --for=condition=Ready pods -l app=immich-postgres -n immich --timeout=300s || log "WARNING: Immich postgres may take longer"
    kubectl wait --for=condition=Ready pods -l app=immich-redis -n immich --timeout=300s || log "WARNING: Immich redis may take longer"

    kubectl apply -f kubernetes/services/immich/server-deployment.yaml
    kubectl apply -f kubernetes/services/immich/microservices-deployment.yaml
    kubectl apply -f kubernetes/services/immich/machine-learning-deployment.yaml

    # Ollama (local LLM)
    kubectl apply -f kubernetes/services/ollama/namespace.yaml
    kubectl apply -f kubernetes/services/ollama/deployment.yaml

    success "AI services setup completed"
}

setup_productivity_services() {
    log "Setting up productivity services..."

    # Paperless-ngx
    kubectl apply -f kubernetes/services/paperless-ngx/namespace.yaml
    kubectl apply -f kubernetes/services/paperless-ngx/postgres-deployment.yaml
    kubectl apply -f kubernetes/services/paperless-ngx/redis-deployment.yaml

    # Wait for Paperless dependencies
    kubectl wait --for=condition=Ready pods -l app=paperless-postgres -n paperless-ngx --timeout=300s || log "WARNING: Paperless postgres may take longer"

    kubectl apply -f kubernetes/services/paperless-ngx/deployment.yaml

    # n8n
    kubectl apply -f kubernetes/services/n8n/namespace.yaml
    kubectl apply -f kubernetes/services/n8n/postgres-deployment.yaml

    kubectl wait --for=condition=Ready pods -l app=n8n-postgres -n n8n --timeout=300s || log "WARNING: n8n postgres may take longer"

    kubectl apply -f kubernetes/services/n8n/deployment.yaml

    # Mealie
    kubectl apply -f kubernetes/services/mealie/namespace.yaml
    kubectl apply -f kubernetes/services/mealie/deployment.yaml

    # Linkwarden
    kubectl apply -f kubernetes/services/linkwarden/namespace.yaml
    kubectl apply -f kubernetes/services/linkwarden/postgres-deployment.yaml

    kubectl wait --for=condition=Ready pods -l app=linkwarden-postgres -n linkwarden --timeout=300s || log "WARNING: Linkwarden postgres may take longer"

    kubectl apply -f kubernetes/services/linkwarden/deployment.yaml

    success "Productivity services setup completed"
}

setup_dashboard() {
    log "Setting up Homepage dashboard..."

    kubectl apply -f kubernetes/services/homepage/namespace.yaml
    kubectl apply -f kubernetes/services/homepage/rbac.yaml
    kubectl apply -f kubernetes/services/homepage/configmap.yaml
    kubectl apply -f kubernetes/services/homepage/deployment.yaml

    success "Homepage dashboard setup completed"
}

setup_gitops() {
    log "Setting up GitOps with ArgoCD..."

    # Pinned ArgoCD version for reproducibility and security
    local ARGOCD_VERSION="v2.10.0"

    # Install ArgoCD with pinned version
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    log "Installing ArgoCD ${ARGOCD_VERSION}..."
    kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    # Wait for ArgoCD to be ready
    kubectl wait --for=condition=Ready pods --all -n argocd --timeout=600s

    # Apply ArgoCD applications
    kubectl apply -f kubernetes/gitops/argocd/

    success "GitOps setup completed"
}

run_health_checks() {
    log "Running health checks..."
    
    local failed_checks=()
    
    # Check core services
    for service in traefik external-secrets-operator cert-manager; do
        if ! kubectl get pods -A -l app=$service -o jsonpath='{.items[*].status.phase}' | grep -q Running; then
            failed_checks+=("$service")
        fi
    done
    
    # Check namespaces
    for ns in nextcloud monitoring argocd; do
        if ! kubectl get ns $ns &> /dev/null; then
            failed_checks+=("namespace-$ns")
        fi
    done
    
    if [ ${#failed_checks[@]} -ne 0 ]; then
        warning "Failed health checks: ${failed_checks[*]}"
        warning "Some services may not be ready yet. Check logs with: kubectl logs -f deployment/<service>"
    else
        success "All health checks passed"
    fi
}

get_access_info() {
    log "Retrieving access information..."

    echo ""
    echo "🎉 Homelab setup completed successfully!"
    echo ""
    echo "🔗 Service URLs (add to /etc/hosts: <server-ip> <domain>):"
    echo ""
    echo "   Infrastructure:"
    echo "   📊 Grafana: https://grafana.$DOMAIN"
    echo "   ⚙️  ArgoCD: https://argocd.$DOMAIN"
    echo "   🏠 Homepage: https://home.$DOMAIN"
    echo ""
    echo "   Media:"
    echo "   🎬 Jellyfin: https://jellyfin.$DOMAIN"
    echo "   📺 Sonarr: https://sonarr.$DOMAIN"
    echo "   🎥 Radarr: https://radarr.$DOMAIN"
    echo "   🔍 Prowlarr: https://prowlarr.$DOMAIN"
    echo "   💬 Bazarr: https://bazarr.$DOMAIN"
    echo "   🎧 Audiobookshelf: https://audiobooks.$DOMAIN"
    echo ""
    echo "   Productivity:"
    echo "   📁 Nextcloud: https://nextcloud.$DOMAIN"
    echo "   📄 Paperless: https://docs.$DOMAIN"
    echo "   📸 Immich: https://photos.$DOMAIN"
    echo "   🍲 Mealie: https://recipes.$DOMAIN"
    echo "   🔖 Linkwarden: https://bookmarks.$DOMAIN"
    echo "   🔄 n8n: https://automation.$DOMAIN"
    echo ""
    echo "   AI:"
    echo "   🤖 Ollama API: https://ai.$DOMAIN"
    echo "   💬 Open WebUI: https://chat.$DOMAIN"
    echo ""
    echo "   Security:"
    echo "   🔐 Vaultwarden: https://vault.$DOMAIN"
    echo "   🔒 Authelia: https://auth.$DOMAIN"
    echo "   🛡️  Gitea: https://git.$DOMAIN"
    echo ""
    echo "🔐 Retrieve credentials securely (not logged):"
    echo "   Grafana:     kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d && echo"
    echo "   ArgoCD:      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   Nextcloud:   kubectl get secret nextcloud-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   Paperless:   kubectl get secret paperless-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo ""
    echo "🔧 Management commands:"
    echo "   View logs: kubectl logs -f deployment/<service> -n <namespace>"
    echo "   Scale service: kubectl scale deployment <service> --replicas=<count> -n <namespace>"
    echo "   Update config: helm upgrade <release> <chart> --values <values-file>"
    echo "   Backup status: velero schedule get && velero backup get"
    echo "   CrowdSec decisions: kubectl exec -n crowdsec deploy/crowdsec-agent -- cscli decisions list"
    echo ""
    echo "📚 Documentation: $HOMELAB_DIR/docs/"
    echo "🐛 Troubleshooting: kubectl get events --sort-by='.lastTimestamp' -A"
}

backup_configuration() {
    log "Creating configuration backup..."

    local backup_dir="$HOMELAB_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    # Backup Kubernetes resources (excluding secrets to avoid plaintext credential exposure)
    kubectl get all,configmaps,pv,pvc -A -o yaml > "$backup_dir/kubernetes-resources.yaml"

    # Backup secret names only (not values) for reference
    kubectl get secrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name > "$backup_dir/secrets-inventory.txt"
    log "Note: Secret values not backed up. Use 'kubectl get secret <name> -n <ns> -o yaml' to retrieve if needed."

    # Backup Helm releases
    helm list -A -o yaml > "$backup_dir/helm-releases.yaml"

    # Backup important configs
    cp -r "$HOMELAB_DIR/config" "$backup_dir/"
    cp -r "$HOMELAB_DIR/helm" "$backup_dir/"
    cp -r "$HOMELAB_DIR/kustomize" "$backup_dir/"

    # Secure backup directory permissions
    chmod -R 600 "$backup_dir"/*
    chmod 700 "$backup_dir"

    log "Configuration backup created: $backup_dir"
}

main() {
    log "Starting enhanced homelab setup (v2.0)..."
    log "Environment: $ENVIRONMENT"
    log "Domain: $DOMAIN"
    log "Timezone: $TIMEZONE"

    check_requirements
    install_tools
    setup_secrets
    setup_infrastructure
    setup_storage

    # Phase 1: Infrastructure improvements
    setup_loadbalancer
    setup_backup
    setup_security
    setup_network_policies
    setup_pod_disruption_budgets
    setup_resource_quotas
    setup_pod_security_standards

    setup_ingress
    setup_monitoring

    # Phase 2: Core and authentication
    setup_core_services
    setup_authentication

    # Media services (Jellyfin, Arr Stack, Audiobookshelf)
    setup_media_services

    setup_network_services
    setup_development_services
    setup_content_services

    # Phase 3: AI and productivity
    setup_ai_services
    setup_productivity_services

    # Phase 4: Dashboard (last, after all services)
    setup_dashboard

    setup_gitops
    run_health_checks
    backup_configuration
    get_access_info

    success "Enhanced homelab setup completed successfully!"
    log "Total setup time: $SECONDS seconds"
}

# Cleanup function
cleanup() {
    if [[ -n "${cleanup_needed:-}" ]]; then
        log "Performing cleanup..."
        # Add any cleanup tasks here
    fi
}
trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi