#!/bin/bash
set -euo pipefail

# Homelab Disaster Recovery Script
# Automated recovery procedures for homelab infrastructure

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

VERSIONS_FILE="${VERSIONS_FILE:-$HOMELAB_DIR/tools/versions.env}"
if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "ERROR: Missing versions file: $VERSIONS_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-velero}"
LOG_FILE="${HOMELAB_DIR}/disaster-recovery-$(date +%Y%m%d-%H%M%S).log"
SECRETS_BACKUP_FILE="${SECRETS_BACKUP_FILE:-}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOMELAB_DIR/.secrets/agekey.txt}"

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "${BLUE}${msg}${NC}"
    echo "$msg" >> "$LOG_FILE"
}

success() {
    local msg="$*"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    echo "[SUCCESS] $msg" >> "$LOG_FILE"
}

warning() {
    local msg="$*"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    echo "[WARNING] $msg" >> "$LOG_FILE"
}

error() {
    local msg="$*"
    echo -e "${RED}[ERROR]${NC} $msg"
    echo "[ERROR] $msg" >> "$LOG_FILE"
}

info() {
    local msg="$*"
    echo -e "${CYAN}[INFO]${NC} $msg"
    echo "[INFO] $msg" >> "$LOG_FILE"
}

prompt() {
    local msg="$*"
    echo -e "${BOLD}${msg}${NC}"
}

# Best-effort step runner: log failures instead of aborting, and track them
# so the calling function can print an honest summary.
FAILED_STEPS=()

run_step() {
    local desc="$1"
    shift
    log "$desc..."
    if "$@" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    fi
    error "Step failed: $desc"
    FAILED_STEPS+=("$desc")
    return 0
}

report_step_results() {
    local what="$1"
    if [ ${#FAILED_STEPS[@]} -eq 0 ]; then
        success "$what completed successfully"
        return 0
    fi
    error "$what completed with ${#FAILED_STEPS[@]} failed step(s):"
    local step
    for step in "${FAILED_STEPS[@]}"; do
        error "  - $step"
    done
    return 1
}

# Confirmation prompt
confirm() {
    local msg="$1"
    echo ""
    prompt "$msg"
    read -r -p "Type 'yes' to confirm: " response
    if [ "$response" != "yes" ]; then
        error "Operation cancelled by user"
        exit 1
    fi
}

# Initialize logging
init_log() {
    mkdir -p "$(dirname "$LOG_FILE")"
    cat > "$LOG_FILE" << EOF
================================================================================
Homelab Disaster Recovery Log
Started: $(date)
================================================================================

EOF
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    local missing=()

    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi

    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    fi

    if [ -n "${SECRETS_BACKUP_FILE:-}" ]; then
        if ! command -v age &> /dev/null; then
            missing+=("age")
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    success "All prerequisites met"
}

# Check cluster connectivity
check_cluster() {
    log "Checking cluster connectivity..."

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        info "Ensure kubeconfig is properly configured"
        exit 1
    fi

    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    success "Connected to cluster ($nodes nodes)"
}

# List available backups
list_available_backups() {
    log "Listing available backups..."

    if ! kubectl get namespace "$BACKUP_NAMESPACE" &> /dev/null; then
        warning "Velero namespace not found"
        return 1
    fi

    echo ""
    echo "Available Backups:"
    echo "=================="
    kubectl get backup -n "$BACKUP_NAMESPACE" \
        -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTimestamp,ITEMS:.status.itemsBackedUp \
        --sort-by=.metadata.creationTimestamp 2>/dev/null || {
        warning "No backups found"
        return 1
    }
    echo ""
}

# Restore from Velero backup
restore_from_backup() {
    local backup_name="${1:-}"

    if [ -z "$backup_name" ]; then
        list_available_backups
        echo ""
        read -r -p "Enter backup name to restore: " backup_name
    fi

    if [ -z "$backup_name" ]; then
        error "No backup name provided"
        exit 1
    fi

    # Verify backup exists
    if ! kubectl get backup -n "$BACKUP_NAMESPACE" "$backup_name" &> /dev/null; then
        error "Backup '$backup_name' not found"
        exit 1
    fi

    local backup_status
    backup_status=$(kubectl get backup -n "$BACKUP_NAMESPACE" "$backup_name" -o jsonpath='{.status.phase}')

    if [ "$backup_status" != "Completed" ]; then
        error "Backup '$backup_name' is not in Completed state (current: $backup_status)"
        exit 1
    fi

    confirm "This will restore from backup '$backup_name'. Continue?"

    local restore_name
    restore_name="restore-${backup_name}-$(date +%s)"
    log "Creating restore: $restore_name"

    if command -v velero &> /dev/null; then
        velero restore create "$restore_name" \
            --from-backup "$backup_name" \
            --wait 2>&1 | tee -a "$LOG_FILE"
    else
        # Use kubectl to create restore
        kubectl apply -f - << EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $restore_name
  namespace: $BACKUP_NAMESPACE
spec:
  backupName: $backup_name
  includedNamespaces:
  - '*'
  restorePVs: true
EOF
        log "Waiting for restore to complete..."
        kubectl wait --for=jsonpath='{.status.phase}'=Completed \
            restore/"$restore_name" -n "$BACKUP_NAMESPACE" \
            --timeout=1800s 2>/dev/null || true
    fi

    local restore_status
    restore_status=$(kubectl get restore -n "$BACKUP_NAMESPACE" "$restore_name" -o jsonpath='{.status.phase}' 2>/dev/null)

    if [ "$restore_status" = "Completed" ]; then
        success "Restore completed successfully"
    else
        warning "Restore status: $restore_status"
        info "Check restore details: kubectl describe restore $restore_name -n $BACKUP_NAMESPACE"
    fi
}

# Restore specific namespace
restore_namespace() {
    local namespace="${1:-}"
    local backup_name="${2:-}"

    if [ -z "$namespace" ]; then
        read -r -p "Enter namespace to restore: " namespace
    fi

    if [ -z "$backup_name" ]; then
        list_available_backups
        echo ""
        read -r -p "Enter backup name to restore from: " backup_name
    fi

    confirm "This will restore namespace '$namespace' from backup '$backup_name'. Continue?"

    local restore_name
    restore_name="restore-${namespace}-$(date +%s)"
    log "Creating namespace restore: $restore_name"

    if command -v velero &> /dev/null; then
        velero restore create "$restore_name" \
            --from-backup "$backup_name" \
            --include-namespaces "$namespace" \
            --wait 2>&1 | tee -a "$LOG_FILE"
    else
        kubectl apply -f - << EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $restore_name
  namespace: $BACKUP_NAMESPACE
spec:
  backupName: $backup_name
  includedNamespaces:
  - $namespace
  restorePVs: true
EOF
    fi

    success "Namespace restore initiated: $restore_name"
}

# Reinstall core infrastructure
reinstall_infrastructure() {
    confirm "This will reinstall core infrastructure components. Continue?"

    log "Reinstalling core infrastructure..."

    FAILED_STEPS=()

    # Storage provisioner
    run_step "Installing local-path-provisioner" \
        kubectl apply -f "$HOMELAB_DIR/kubernetes/storage/local-path-provisioner.yaml"

    # Secrets management
    run_step "Adding external-secrets Helm repo" \
        helm repo add external-secrets https://charts.external-secrets.io --force-update
    run_step "Updating Helm repos" helm repo update
    run_step "Installing External Secrets Operator" \
        helm upgrade --install external-secrets external-secrets/external-secrets \
        -n external-secrets --create-namespace \
        --version "${EXTERNAL_SECRETS_CHART_VERSION}" \
        --set installCRDs=true \
        --wait

    if [ -d "$HOMELAB_DIR/kubernetes/secrets" ]; then
        run_step "Applying secrets manifests" \
            kubectl apply -f "$HOMELAB_DIR/kubernetes/secrets/"
    fi

    # Ingress
    run_step "Adding traefik Helm repo" \
        helm repo add traefik https://traefik.github.io/charts --force-update
    run_step "Installing Traefik" \
        helm upgrade --install traefik traefik/traefik \
        -n traefik-system --create-namespace \
        --version "${TRAEFIK_CHART_VERSION}" \
        -f "$HOMELAB_DIR/kubernetes/ingress/traefik/values.yaml" \
        --wait

    # Cert-manager
    run_step "Adding jetstack Helm repo" \
        helm repo add jetstack https://charts.jetstack.io --force-update
    run_step "Installing cert-manager" \
        helm upgrade --install cert-manager jetstack/cert-manager \
        -n cert-manager --create-namespace \
        --version "${CERT_MANAGER_CHART_VERSION}" \
        --set installCRDs=true \
        --wait

    # Optional: restore encrypted secrets before (re)creating issuers/certificates.
    if [ -n "${SECRETS_BACKUP_FILE:-}" ]; then
        if [ ! -f "$SECRETS_BACKUP_FILE" ]; then
            warning "SECRETS_BACKUP_FILE was set but does not exist: $SECRETS_BACKUP_FILE"
            FAILED_STEPS+=("Restoring secrets from encrypted backup (file not found)")
        else
            run_step "Restoring secrets from encrypted backup: $SECRETS_BACKUP_FILE" \
                env AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" bash "$HOMELAB_DIR/scripts/restore-secrets.sh" "$SECRETS_BACKUP_FILE"
        fi
    fi

    if [ -d "$HOMELAB_DIR/kubernetes/ingress/cert-manager" ]; then
        run_step "Applying cert-manager issuers" \
            kubectl apply -f "$HOMELAB_DIR/kubernetes/ingress/cert-manager/"
    fi

    info "Note: Some components may take time to become ready"
    report_step_results "Core infrastructure reinstallation"
}

# Reinstall monitoring stack
reinstall_monitoring() {
    confirm "This will reinstall the monitoring stack. Continue?"

    log "Reinstalling monitoring stack..."

    FAILED_STEPS=()

    # Prometheus
    if [ -d "$HOMELAB_DIR/kubernetes/monitoring/prometheus" ]; then
        run_step "Adding prometheus-community Helm repo" \
            helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
        run_step "Updating Helm repos" helm repo update
        run_step "Installing kube-prometheus-stack" \
            helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
            -n monitoring --create-namespace \
            --version "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
            -f "$HOMELAB_DIR/kubernetes/monitoring/prometheus/values.yaml"
    fi

    # Loki
    if [ -d "$HOMELAB_DIR/kubernetes/services/loki" ]; then
        run_step "Installing Loki" \
            kubectl apply -f "$HOMELAB_DIR/kubernetes/services/loki/"
    fi

    # Promtail (optional; kept under extras/ due to required host mounts/capabilities)
    if [ -f "$HOMELAB_DIR/extras/kubernetes/services/loki/promtail-deployment.yaml" ]; then
        run_step "Installing Promtail (extras)" \
            kubectl apply -f "$HOMELAB_DIR/extras/kubernetes/services/loki/promtail-deployment.yaml"
    fi

    report_step_results "Monitoring stack reinstallation"
}

# Reinstall critical services
reinstall_critical_services() {
    local services=(
        "vaultwarden"
        "nextcloud"
        "gitea"
        "home-assistant"
    )

    confirm "This will reinstall critical services: ${services[*]}. Continue?"

    FAILED_STEPS=()

    for service in "${services[@]}"; do
        if [[ "$service" == "nextcloud" ]]; then
            run_step "Installing nextcloud (Helm)" \
                helm upgrade --install nextcloud "$HOMELAB_DIR/helm/nextcloud" \
                --namespace nextcloud \
                --create-namespace \
                --dependency-update \
                -f "$HOMELAB_DIR/helm/nextcloud/values.yaml"
            continue
        fi

        local service_path="$HOMELAB_DIR/kubernetes/services/$service"
        if [ -d "$service_path" ]; then
            # Apply namespace first if exists
            if [ -f "$service_path/namespace.yaml" ]; then
                run_step "Applying $service namespace" \
                    kubectl apply -f "$service_path/namespace.yaml"
            fi

            # Apply all manifests
            run_step "Installing $service" \
                kubectl apply -f "$service_path/"
        else
            warning "Service directory not found: $service_path"
            FAILED_STEPS+=("Installing $service (directory not found)")
        fi
    done

    report_step_results "Critical services reinstallation"
}

# Full cluster recovery
full_recovery() {
    confirm "This will perform a FULL cluster recovery. This is destructive! Continue?"

    log "Starting full cluster recovery..."

    echo ""
    prompt "Recovery Steps:"
    echo "1. Reinstall core infrastructure"
    echo "2. Reinstall monitoring"
    echo "3. Restore from backup (if available)"
    echo "4. Reinstall critical services"
    echo ""

    local failed_phases=0

    reinstall_infrastructure || failed_phases=$((failed_phases+1))
    sleep 30  # Wait for infrastructure

    reinstall_monitoring || failed_phases=$((failed_phases+1))
    sleep 30  # Wait for monitoring

    if kubectl get namespace "$BACKUP_NAMESPACE" &> /dev/null; then
        list_available_backups || true
        read -r -p "Enter backup name to restore (or press Enter to skip): " backup_name
        if [ -n "$backup_name" ]; then
            restore_from_backup "$backup_name"
        fi
    fi

    reinstall_critical_services || failed_phases=$((failed_phases+1))

    info "Check pod status: kubectl get pods -A"
    info "Review log file: $LOG_FILE"

    if [ "$failed_phases" -gt 0 ]; then
        error "Full recovery completed with failures in $failed_phases phase(s)"
        return 1
    fi

    success "Full recovery process completed"
}

# Verify cluster health
verify_health() {
    log "Verifying cluster health..."

    echo ""
    echo "Cluster Status:"
    echo "==============="

    # Nodes
    echo ""
    echo "Nodes:"
    kubectl get nodes

    # Namespaces
    echo ""
    echo "Namespaces:"
    kubectl get namespaces

    # Pods not running
    echo ""
    echo "Pods not in Running state:"
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || echo "All pods are healthy"

    # PVC status
    echo ""
    echo "PVC Status:"
    kubectl get pvc -A 2>/dev/null || echo "No PVCs found"

    echo ""
}

# Print menu
print_menu() {
    echo ""
    echo "================================================================================"
    echo "Homelab Disaster Recovery"
    echo "================================================================================"
    echo ""
    echo "Options:"
    echo "  1) List available backups"
    echo "  2) Restore from backup (full)"
    echo "  3) Restore specific namespace"
    echo "  4) Reinstall core infrastructure"
    echo "  5) Reinstall monitoring stack"
    echo "  6) Reinstall critical services"
    echo "  7) Full cluster recovery"
    echo "  8) Verify cluster health"
    echo "  9) Exit"
    echo ""
}

# Interactive mode
interactive_mode() {
    init_log
    check_prerequisites
    check_cluster

    while true; do
        print_menu
        read -r -p "Select option [1-9]: " choice

        case $choice in
            1) list_available_backups || true ;;
            2) restore_from_backup ;;
            3) restore_namespace ;;
            4) reinstall_infrastructure || true ;;
            5) reinstall_monitoring || true ;;
            6) reinstall_critical_services || true ;;
            7) full_recovery || true ;;
            8) verify_health ;;
            9)
                log "Exiting disaster recovery"
                exit 0
                ;;
            *)
                warning "Invalid option"
                ;;
        esac

        echo ""
        read -r -p "Press Enter to continue..."
    done
}

# Help text
show_help() {
    cat << EOF
Homelab Disaster Recovery Script

Usage: $0 [command] [options]

Commands:
  interactive         Run in interactive mode (default)
  restore             Restore from backup
  restore-namespace   Restore specific namespace
  infrastructure      Reinstall core infrastructure
  monitoring          Reinstall monitoring stack
  services            Reinstall critical services
  full                Full cluster recovery
  health              Verify cluster health
  help                Show this help message

Options:
  --backup NAME      Specify backup name for restore operations
  --namespace NAME   Specify namespace for restore operations

Environment Variables:
  BACKUP_NAMESPACE   Velero namespace (default: velero)

Examples:
  $0                                     # Interactive mode
  $0 restore --backup daily-backup-123   # Restore specific backup
  $0 restore-namespace --namespace vaultwarden --backup daily-backup-123
  $0 health                              # Check cluster health
  $0 full                                # Full recovery (interactive prompts)

EOF
}

# Main function
main() {
    local command="${1:-interactive}"
    shift || true

    local backup_name=""
    local namespace=""

    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --backup)
                backup_name="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    case "$command" in
        interactive)
            interactive_mode
            ;;
        restore)
            init_log
            check_prerequisites
            check_cluster
            restore_from_backup "$backup_name"
            ;;
        restore-namespace)
            init_log
            check_prerequisites
            check_cluster
            restore_namespace "$namespace" "$backup_name"
            ;;
        infrastructure)
            init_log
            check_prerequisites
            check_cluster
            reinstall_infrastructure
            ;;
        monitoring)
            init_log
            check_prerequisites
            check_cluster
            reinstall_monitoring
            ;;
        services)
            init_log
            check_prerequisites
            check_cluster
            reinstall_critical_services
            ;;
        full)
            init_log
            check_prerequisites
            check_cluster
            full_recovery
            ;;
        health)
            check_prerequisites
            check_cluster
            verify_health
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
