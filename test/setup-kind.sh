#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="${CLUSTER_NAME:-homelab-test}"
KIND_CONFIG="${KIND_CONFIG:-$SCRIPT_DIR/kind-config.yaml}"

# Optional toggles for faster smoke tests (defaults preserve existing behavior).
KIND_ENABLE_STORAGE="${KIND_ENABLE_STORAGE:-true}"
KIND_ENABLE_MONITORING="${KIND_ENABLE_MONITORING:-true}"
KIND_ENABLE_NEXTCLOUD="${KIND_ENABLE_NEXTCLOUD:-true}"
KIND_SERVICES="${KIND_SERVICES:-}"
LOGFILE="$SCRIPT_DIR/kind-setup.log"

# If repo-local tools are installed (see scripts/install-dev-tools.sh), prefer them.
TOOLS_DIR="${TOOLS_DIR:-$HOMELAB_DIR/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
    PATH="$TOOLS_DIR/bin:$PATH"
fi
if [[ -d "$TOOLS_DIR/venv/bin" ]]; then
    PATH="$TOOLS_DIR/venv/bin:$PATH"
fi
export PATH

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    exit 1
}

VERSIONS_FILE="${VERSIONS_FILE:-$HOMELAB_DIR/tools/versions.env}"
if [[ ! -f "$VERSIONS_FILE" ]]; then
    error "Missing versions file: $VERSIONS_FILE"
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

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

    local OS
    local ARCH
    OS=$(detect_os)
    ARCH=$(detect_arch)
    log "Detected platform: ${OS}/${ARCH}"

    if ! command -v docker &> /dev/null; then
        error "Docker is required but not installed"
    fi

    # Prefer installing the pinned toolchain into .tools/ over system-wide installs.
    if ! command -v kind &> /dev/null || ! command -v kubectl &> /dev/null || ! command -v helm &> /dev/null; then
        log "Missing kind/kubectl/helm; installing repo-local toolchain (tools/versions.env)..."
        "$HOMELAB_DIR/scripts/install-dev-tools.sh"
    fi

    command -v kind &> /dev/null || error "kind is required but was not found in PATH"
    command -v kubectl &> /dev/null || error "kubectl is required but was not found in PATH"
    command -v helm &> /dev/null || error "helm is required but was not found in PATH"

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
    local kind_args=(
        --name "$CLUSTER_NAME"
        --config "$KIND_CONFIG"
    )
    if [[ -n "${KIND_NODE_IMAGE:-}" ]]; then
        log "Using Kind node image: $KIND_NODE_IMAGE"
        kind_args+=(--image "$KIND_NODE_IMAGE")
    fi
    kind create cluster "${kind_args[@]}"

    # Wait for cluster to be ready
    kubectl wait --for=condition=Ready nodes --all --timeout=300s

    log "Kind cluster created successfully"
}

setup_ingress() {
    log "Setting up ingress controller..."

    # Install Traefik
    helm repo add traefik https://traefik.github.io/charts
    helm repo update

    helm upgrade --install traefik traefik/traefik \
        --namespace traefik-system \
        --create-namespace \
        --version "$TRAEFIK_CHART_VERSION" \
        --values "$HOMELAB_DIR/kubernetes/ingress/traefik/values.yaml" \
        --set service.type=NodePort \
        --set ports.web.nodePort=30080 \
        --set ports.websecure.nodePort=30443 \
        --wait

    log "Ingress controller setup completed"
}

setup_cert_manager() {
    log "Setting up cert-manager..."

    helm repo add jetstack https://charts.jetstack.io
    helm repo update

    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version "$CERT_MANAGER_CHART_VERSION" \
        --set installCRDs=true \
        --wait

    kubectl apply -f "$HOMELAB_DIR/kubernetes/ingress/cert-manager/"

    log "cert-manager setup completed"
}

setup_external_secrets() {
    log "Setting up External Secrets Operator..."

    # Create the central secrets namespace first.
    kubectl apply -f "$HOMELAB_DIR/kubernetes/secrets/secrets-namespace.yaml"

    # Wait for kube-root-ca ConfigMap (used by ClusterSecretStore caProvider).
    for _ in $(seq 1 30); do
        if kubectl get configmap -n secrets kube-root-ca.crt &> /dev/null; then
            break
        fi
        sleep 1
    done

    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update

    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets \
        --create-namespace \
        --version "$EXTERNAL_SECRETS_CHART_VERSION" \
        --set installCRDs=true \
        --wait

    kubectl apply -f "$HOMELAB_DIR/kubernetes/secrets/secret-store-rbac.yaml"
    kubectl apply -f "$HOMELAB_DIR/kubernetes/secrets/secret-store.yaml"

    # Generate (or create-missing) all source-of-truth secrets.
    bash "$HOMELAB_DIR/scripts/generate-secrets.sh"

    log "External Secrets setup completed"
}

setup_storage() {
    log "Setting up storage..."

    if [[ "$KIND_ENABLE_STORAGE" != "true" ]]; then
        log "Skipping storage (KIND_ENABLE_STORAGE=$KIND_ENABLE_STORAGE)"
        return 0
    fi

    # Storage + MinIO (kustomize bundle).
    kubectl apply -k "$HOMELAB_DIR/kubernetes/storage/" || \
        log "WARNING: Failed to apply kubernetes/storage/ (some components may already exist in Kind)"

    log "Storage setup completed"
}

deploy_core_services() {
    log "Deploying core services..."

    if [[ "$KIND_ENABLE_NEXTCLOUD" == "true" ]]; then
        # Nextcloud is managed via the repo Helm chart (matches setup-v2.sh).
        helm upgrade --install nextcloud "$HOMELAB_DIR/helm/nextcloud" \
            --namespace nextcloud \
            --create-namespace \
            --wait || log "WARNING: Nextcloud Helm install failed"
    else
        log "Skipping Nextcloud (KIND_ENABLE_NEXTCLOUD=$KIND_ENABLE_NEXTCLOUD)"
    fi

    # Deploy services one by one to avoid resource conflicts
    local services=()
    if [[ -n "$KIND_SERVICES" ]]; then
        IFS=' ' read -r -a services <<<"$KIND_SERVICES"
        log "Using KIND_SERVICES override: ${services[*]}"
    else
        services=(
            "pihole"
            "vaultwarden"
            "jellyfin"
            "gitea"
            "homepage"
            "searxng"
            "calibre-web"
            "yarr"
        )
    fi

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

    if [[ "$KIND_ENABLE_MONITORING" != "true" ]]; then
        log "Skipping monitoring (KIND_ENABLE_MONITORING=$KIND_ENABLE_MONITORING)"
        return 0
    fi

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Ensure Grafana admin secret exists in monitoring (via ExternalSecret) before installing the chart.
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f "$HOMELAB_DIR/kubernetes/monitoring/prometheus/external-secrets.yaml" || \
        log "WARNING: Failed to apply Grafana ExternalSecret (ESO must be running)"

    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --version "$KUBE_PROMETHEUS_STACK_CHART_VERSION" \
        --values "$HOMELAB_DIR/kubernetes/monitoring/prometheus/values.yaml" \
        --wait || log "WARNING: kube-prometheus-stack Helm install failed"

    kubectl apply -f "$HOMELAB_DIR/kubernetes/monitoring/uptime-kuma/" || \
        log "WARNING: Failed to deploy uptime-kuma"

    # Optional: MinIO ServiceMonitor (requires Prometheus Operator CRDs from kube-prometheus-stack)
    if kubectl get namespace minio-system &>/dev/null; then
        kubectl apply -f "$HOMELAB_DIR/kubernetes/monitoring/servicemonitors/minio.yaml" 2>/dev/null || true
    fi

    log "Monitoring setup completed"
}

wait_for_services() {
    log "Waiting for services to be ready..."

    local services_ready=true

    # Wait for some key services with status reporting
    if ! kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=traefik -n traefik-system --timeout=300s 2>/dev/null; then
        log "WARNING: Traefik pods not ready within timeout"
        services_ready=false
    fi

    if ! kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s 2>/dev/null; then
        log "WARNING: External Secrets pods not ready within timeout"
        services_ready=false
    fi

    if ! kubectl wait --for=condition=Ready pods -n cert-manager --timeout=300s 2>/dev/null; then
        log "WARNING: cert-manager pods not ready within timeout"
        services_ready=false
    fi

    if [[ -z "$KIND_SERVICES" || " $KIND_SERVICES " == *" pihole "* ]]; then
        if ! kubectl wait --for=condition=Ready pods -l app=pihole -n pihole --timeout=300s 2>/dev/null; then
            log "WARNING: Pi-hole pods not ready within timeout"
            services_ready=false
        fi
    fi

    if [[ "$KIND_ENABLE_NEXTCLOUD" == "true" ]]; then
        if ! kubectl wait --for=condition=Ready pods -n nextcloud --timeout=300s 2>/dev/null; then
            log "WARNING: Nextcloud pods not ready within timeout"
            services_ready=false
        fi
    fi

    if [[ -z "$KIND_SERVICES" || " $KIND_SERVICES " == *" homepage "* ]]; then
        if ! kubectl wait --for=condition=Ready pods -n homepage --timeout=300s 2>/dev/null; then
            log "WARNING: Homepage pods not ready within timeout"
            services_ready=false
        fi
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
    if [[ "$KIND_ENABLE_STORAGE" == "true" ]]; then
        echo "127.0.0.1 minio.homelab.local"
    fi
    echo "127.0.0.1 search.homelab.local"
    echo "127.0.0.1 books.homelab.local"
    echo "127.0.0.1 rss.homelab.local"
    echo ""
    echo "Access services at:"
    echo "🌐 Traefik: http://localhost:30080 (HTTP) -> redirects to HTTPS when configured"
    echo "📊 Services (HTTP):  http://<service>.homelab.local:30080"
    echo "📊 Services (HTTPS): https://<service>.homelab.local:30443"
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
            setup_cert_manager
            setup_external_secrets
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
