#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="homelab-test"
LOGFILE="$SCRIPT_DIR/kind-setup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    exit 1
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        arm64)   echo "arm64" ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac
}

detect_os() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)  echo "linux" ;;
        darwin) echo "darwin" ;;
        *)      error "Unsupported OS: $os" ;;
    esac
}

check_requirements() {
    log "Checking requirements for Kind testing..."

    # Pinned versions for reproducibility
    local KIND_VERSION="v0.20.0"
    local KUBECTL_VERSION="v1.29.0"
    local HELM_VERSION="v3.14.0"

    local OS
    local ARCH
    OS=$(detect_os)
    ARCH=$(detect_arch)
    log "Detected platform: ${OS}/${ARCH}"

    if ! command -v kind &> /dev/null; then
        log "Installing Kind ${KIND_VERSION}..."
        curl -fsSL -o ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
    fi

    if ! command -v kubectl &> /dev/null; then
        log "Installing kubectl ${KUBECTL_VERSION}..."
        curl -fsSL -o ./kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
        # Verify checksum
        curl -fsSL -o ./kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256"
        echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - || error "kubectl checksum verification failed"
        rm -f kubectl.sha256
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi

    if ! command -v helm &> /dev/null; then
        log "Installing Helm ${HELM_VERSION}..."
        local helm_script="/tmp/get-helm-3.sh"
        curl -fsSL -o "$helm_script" "https://raw.githubusercontent.com/helm/helm/${HELM_VERSION}/scripts/get-helm-3"
        chmod +x "$helm_script"
        DESIRED_VERSION="${HELM_VERSION}" bash "$helm_script"
        rm -f "$helm_script"
    fi

    if ! command -v docker &> /dev/null; then
        error "Docker is required but not installed"
    fi

    log "Requirements check completed"
}

create_cluster() {
    log "Creating Kind cluster: $CLUSTER_NAME"
    
    # Delete existing cluster if it exists
    if kind get clusters | grep -q "$CLUSTER_NAME"; then
        log "Deleting existing cluster..."
        kind delete cluster --name "$CLUSTER_NAME"
    fi
    
    # Create new cluster
    kind create cluster --name "$CLUSTER_NAME" --config "$SCRIPT_DIR/kind-config.yaml"
    
    # Wait for cluster to be ready
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log "Kind cluster created successfully"
}

setup_ingress() {
    log "Setting up ingress controller..."
    
    # Install Traefik
    helm repo add traefik https://traefik.github.io/charts
    helm repo update
    
    helm install traefik traefik/traefik \
        --namespace traefik-system \
        --create-namespace \
        --set service.type=NodePort \
        --set ports.web.nodePort=30080 \
        --set ports.websecure.nodePort=30443 \
        --wait
    
    log "Ingress controller setup completed"
}

setup_storage() {
    log "Setting up storage..."

    # Apply local path provisioner (already included in Kind)
    if ! kubectl apply -f "$HOMELAB_DIR/kubernetes/storage/local-path-provisioner.yaml"; then
        log "WARNING: Failed to apply local-path-provisioner (may already exist in Kind)"
    fi

    log "Storage setup completed"
}

deploy_core_services() {
    log "Deploying core services..."

    # Deploy services one by one to avoid resource conflicts
    services=(
        "pihole"
        "nextcloud"
        "vaultwarden"
        "jellyfin"
        "heimdall"
        "gitea"
        "minio"
        "searxng"
        "calibre-web"
        "yarr"
    )

    local failed_services=()
    for service in "${services[@]}"; do
        if [ -d "$HOMELAB_DIR/kubernetes/services/$service" ]; then
            log "Deploying $service..."
            if ! kubectl apply -f "$HOMELAB_DIR/kubernetes/services/$service/"; then
                log "WARNING: Failed to deploy $service"
                failed_services+=("$service")
            fi
            sleep 10  # Give services time to start
        fi
    done

    if [ ${#failed_services[@]} -gt 0 ]; then
        log "WARNING: Some services failed to deploy: ${failed_services[*]}"
    fi

    log "Core services deployment completed"
}

setup_monitoring() {
    log "Setting up monitoring..."

    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Apply monitoring configs if they exist
    if [ -d "$HOMELAB_DIR/kubernetes/monitoring" ]; then
        if ! kubectl apply -f "$HOMELAB_DIR/kubernetes/monitoring/"; then
            log "WARNING: Some monitoring components failed to deploy"
        fi
    fi

    log "Monitoring setup completed"
}

wait_for_services() {
    log "Waiting for services to be ready..."

    local services_ready=true

    # Wait for some key services with status reporting
    if ! kubectl wait --for=condition=Ready pods -l app=traefik -n traefik-system --timeout=300s 2>/dev/null; then
        log "WARNING: Traefik pods not ready within timeout"
        services_ready=false
    fi

    if ! kubectl wait --for=condition=Ready pods -l app=pihole -n pihole --timeout=300s 2>/dev/null; then
        log "WARNING: Pi-hole pods not ready within timeout"
        services_ready=false
    fi

    if ! kubectl wait --for=condition=Ready pods -l app=nextcloud -n nextcloud --timeout=300s 2>/dev/null; then
        log "WARNING: Nextcloud pods not ready within timeout"
        services_ready=false
    fi

    if [ "$services_ready" = true ]; then
        log "All key services are ready"
    else
        log "Some services may still be starting. Check with: kubectl get pods -A"
    fi
}

show_access_info() {
    log "Kind cluster setup completed!"
    echo ""
    echo "🎉 Your Kind testing cluster is ready!"
    echo ""
    echo "Cluster Info:"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Context: kind-$CLUSTER_NAME"
    echo ""
    echo "Add these entries to /etc/hosts:"
    echo "127.0.0.1 homelab.local"
    echo "127.0.0.1 pihole.homelab.local"
    echo "127.0.0.1 nextcloud.homelab.local"
    echo "127.0.0.1 vault.homelab.local"
    echo "127.0.0.1 jellyfin.homelab.local"
    echo "127.0.0.1 grafana.homelab.local"
    echo "127.0.0.1 git.homelab.local"
    echo "127.0.0.1 dashboard.homelab.local"
    echo "127.0.0.1 minio.homelab.local"
    echo "127.0.0.1 search.homelab.local"
    echo "127.0.0.1 books.homelab.local"
    echo "127.0.0.1 rss.homelab.local"
    echo ""
    echo "Access services at:"
    echo "🌐 Traefik Dashboard: http://localhost:30080/dashboard/"
    echo "📊 Services: http://<service>.homelab.local:30080"
    echo ""
    echo "Useful commands:"
    echo "kubectl get pods --all-namespaces"
    echo "kubectl get services --all-namespaces"
    echo "kubectl get ingress --all-namespaces"
    echo ""
    echo "To delete the cluster:"
    echo "kind delete cluster --name $CLUSTER_NAME"
}

cleanup() {
    log "Cleaning up Kind cluster..."
    kind delete cluster --name "$CLUSTER_NAME" || true
    log "Cleanup completed"
}

main() {
    case "${1:-setup}" in
        "setup")
            log "Starting Kind cluster setup..."
            check_requirements
            create_cluster
            setup_ingress
            setup_storage
            setup_monitoring
            deploy_core_services
            wait_for_services
            show_access_info
            ;;
        "cleanup")
            cleanup
            ;;
        "info")
            show_access_info
            ;;
        *)
            echo "Usage: $0 [setup|cleanup|info]"
            echo "  setup   - Create and configure Kind cluster (default)"
            echo "  cleanup - Delete Kind cluster"
            echo "  info    - Show access information"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi