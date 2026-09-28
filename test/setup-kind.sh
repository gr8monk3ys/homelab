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
# A deliberate subset of the groups, not the installer's defaults: three
# groups that fit in a KinD smoke test. Names must be rows of SERVICE_GROUPS
# (scripts/lib/services.sh); their own toggles do not apply here.
KIND_SERVICE_GROUPS="${KIND_SERVICE_GROUPS:-core network content}"
LOGFILE="$SCRIPT_DIR/kind-setup.log"
export LOGFILE

# The harness is a caller of the installer's modules, not a second installer:
# charts come from the helm seam (HELM_INFRA_RELEASES), readiness and the
# access summary from the health seam, services from the catalogue. What stays
# here is what is genuinely KinD-specific: the cluster, its port mappings and
# the KIND_* toggles.
source "$SCRIPT_DIR/../scripts/lib/common.sh"
source "$SCRIPT_DIR/../scripts/lib/render.sh"
source "$SCRIPT_DIR/../scripts/lib/services.sh"
source "$SCRIPT_DIR/../scripts/lib/netpol.sh"
source "$SCRIPT_DIR/../scripts/lib/helm.sh"
source "$SCRIPT_DIR/../scripts/lib/health.sh"
homelab_load_config

# What this run actually installed (infrastructure pieces as named in
# HEALTH_INFRA, then catalogue services). Recorded in the homelab-harness
# ConfigMap so report_health and test/validate.sh check exactly this set rather
# than everything the default toggles would install (#37). KinD ships
# local-path-provisioner, so it is always present.
HARNESS_INSTALLED=(local-path)

record_harness() {
    kubectl create configmap homelab-harness -n kube-system \
        --from-literal=installed="${HARNESS_INSTALLED[*]}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log "Recorded harness contents: ${HARNESS_INSTALLED[*]}"
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

    # Every catalogue PVC asks for the K3s class name `local-path`; KinD ships
    # the same provisioner as `standard`. Without the alias, any service with a
    # volume stays Pending whenever KIND_ENABLE_STORAGE=false (#38).
    if ! kubectl get storageclass local-path >/dev/null 2>&1; then
        kubectl apply -f - >/dev/null <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
        log "Created the local-path StorageClass alias (KinD's provisioner)"
    fi

    log "Kind cluster created successfully"
}

setup_ingress() {
    log "Setting up ingress controller..."

    # KinD has no LoadBalancer: Traefik is reached through the node ports the
    # kind config maps to the host (30080/30443). The harness does not run
    # CrowdSec, so the websecure entrypoint's bouncer middleware would not
    # exist and Traefik would drop every HTTPS route (#38); leave it off here.
    # Everything else about the release is the table's row.
    helm_infra_release traefik \
        --set service.type=NodePort \
        --set ports.web.nodePort=30080 \
        --set ports.websecure.nodePort=30443 \
        --set 'ports.websecure.http.middlewares=null'
    HARNESS_INSTALLED+=(traefik)

    log "Ingress controller setup completed"
}

setup_cert_manager() {
    log "Setting up cert-manager..."

    helm_infra_release cert-manager

    kubectl_apply_rendered_dir "$HOMELAB_DIR/kubernetes/ingress/cert-manager"
    HARNESS_INSTALLED+=(cert-manager)

    log "cert-manager setup completed"
}

setup_external_secrets() {
    log "Setting up External Secrets Operator..."

    # Create the central secrets namespace first.
    kubectl_apply_rendered_file "$HOMELAB_DIR/kubernetes/secrets/secrets-namespace.yaml"

    # Wait for kube-root-ca ConfigMap (used by ClusterSecretStore caProvider).
    for _ in $(seq 1 30); do
        if kubectl get configmap -n secrets kube-root-ca.crt &> /dev/null; then
            break
        fi
        sleep 1
    done

    helm_infra_release external-secrets

    kubectl_apply_rendered_file "$HOMELAB_DIR/kubernetes/secrets/secret-store-rbac.yaml"
    kubectl_apply_rendered_file "$HOMELAB_DIR/kubernetes/secrets/secret-store.yaml"

    # Generate (or create-missing) all source-of-truth secrets.
    bash "$HOMELAB_DIR/scripts/generate-secrets.sh"
    HARNESS_INSTALLED+=(external-secrets)

    log "External Secrets setup completed"
}

setup_storage() {
    log "Setting up storage..."

    if [[ "$KIND_ENABLE_STORAGE" != "true" ]]; then
        log "Skipping storage (KIND_ENABLE_STORAGE=$KIND_ENABLE_STORAGE)"
        return 0
    fi

    # Storage + Garage, through the render seam the installer uses. The
    # bootstrap Job is replaced like setup-v2.sh does (its template is immutable).
    kubectl_apply_rendered_dir "$HOMELAB_DIR/kubernetes/storage" || \
        log "WARNING: Failed to apply kubernetes/storage/ (some components may already exist in Kind)"
    kubectl -n garage-system delete job garage-bootstrap --ignore-not-found >/dev/null 2>&1 || true
    if kubectl_apply_rendered_dir "$HOMELAB_DIR/kubernetes/storage/garage"; then
        HARNESS_INSTALLED+=(garage)
    else
        log "WARNING: Failed to apply kubernetes/storage/garage/ (some components may already exist in Kind)"
    fi

    log "Storage setup completed"
}

deploy_core_services() {
    log "Deploying core services..."

    # Services come from the catalogue (kubernetes/services/*/service.yaml);
    # Nextcloud is one of them (kind: helm, installed through the same
    # install_service). KIND_SERVICES names them explicitly; otherwise every
    # non-opt-in service in KIND_SERVICE_GROUPS (default: core network content)
    # is deployed. KIND_ENABLE_NEXTCLOUD=false leaves Nextcloud out.
    local services=()
    if [[ -n "$KIND_SERVICES" ]]; then
        # Each named service brings what its descriptor `requires:`, first (#35).
        local requested=()
        read -r -a requested <<<"$KIND_SERVICES"
        read -r -a services <<<"$(services_with_requires "${requested[@]}")"
        log "Using KIND_SERVICES override: $KIND_SERVICES -> ${services[*]}"
    else
        local group name
        for group in $KIND_SERVICE_GROUPS; do
            for name in $(services_in_group "$group"); do
                if [[ "$name" == "nextcloud" && "$KIND_ENABLE_NEXTCLOUD" != "true" ]]; then
                    log "Skipping Nextcloud (KIND_ENABLE_NEXTCLOUD=$KIND_ENABLE_NEXTCLOUD)"
                    continue
                fi
                service_enabled "$name" && services+=("$name")
            done
        done
        log "Deploying groups [$KIND_SERVICE_GROUPS]: ${services[*]}"
    fi

    local failed_services=()
    for service in "${services[@]}"; do
        if [ -d "$HOMELAB_DIR/kubernetes/services/$service" ]; then
            # Same code path as setup-v2.sh: rendered, ordered, waited on.
            run_isolated install_service "$service"
            if [[ "$RUN_ISOLATED_STATUS" -ne 0 ]]; then
                log "WARNING: Failed to deploy $service"
                failed_services+=("$service")
            else
                HARNESS_INSTALLED+=("$service")
            fi
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

    # Ensure Grafana admin secret exists in monitoring (via ExternalSecret) before installing the chart.
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl_apply_rendered_file "$HOMELAB_DIR/kubernetes/monitoring/prometheus/external-secrets.yaml" || \
        log "WARNING: Failed to apply Grafana ExternalSecret (ESO must be running)"

    # A monitoring stack that will not come up in KinD is a warning, not a
    # failed harness; the rest of the cluster is still worth testing.
    if helm_infra_release kube-prometheus-stack; then
        HARNESS_INSTALLED+=(kube-prometheus-stack)
    else
        log "WARNING: kube-prometheus-stack Helm install failed"
    fi

    kubectl_apply_rendered_dir "$HOMELAB_DIR/kubernetes/monitoring/uptime-kuma" || \
        log "WARNING: Failed to deploy uptime-kuma"

    # Optional: Garage ServiceMonitor (requires Prometheus Operator CRDs from kube-prometheus-stack)
    if kubectl get namespace garage-system &>/dev/null; then
        kubectl_apply_rendered_file "$HOMELAB_DIR/kubernetes/monitoring/servicemonitors/garage.yaml" 2>/dev/null || true
    fi

    log "Monitoring setup completed"
}

report_health() {
    log "Reporting cluster health (scripts/lib/health.sh)..."

    # Best-effort: the harness answers "did it deploy", not "is it all green".
    # It checks exactly what this run installed (HARNESS_INSTALLED), not what
    # the installer's default toggles would have installed (#37).
    if health_report --all --only "${HARNESS_INSTALLED[*]}"; then
        log "Everything this run installed is healthy"
    else
        log "Some services may still be starting. Check with: kubectl get pods -A"
    fi
}

show_access_info() {
    log "Kind cluster setup completed!"
    echo ""
    echo "Your Kind testing cluster is ready!"
    echo ""
    echo "Cluster Info:"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Context: kind-$CLUSTER_NAME"
    echo ""

    # Hostnames and URLs come from the catalogue via the health seam; only the
    # KinD node ports below are this harness's own.
    access_summary

    echo ""
    echo "KinD access (no LoadBalancer; Traefik is on the node ports the kind"
    echo "config maps to localhost). Point the hostnames above at 127.0.0.1 in"
    echo "/etc/hosts, then:"
    echo "  Traefik:           http://localhost:30080"
    echo "  Services (HTTP):   http://<service>.$DOMAIN:30080"
    echo "  Services (HTTPS):  https://<service>.$DOMAIN:30443"
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
            record_harness
            report_health
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
