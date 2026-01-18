#!/bin/bash
set -euo pipefail

# Homelab Disaster Recovery Script
# Automated recovery procedures for homelab infrastructure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

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

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
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

    local restore_name="restore-${backup_name}-$(date +%s)"
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

    local restore_name="restore-${namespace}-$(date +%s)"
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

    # Storage provisioner
    log "Installing local-path-provisioner..."
    kubectl apply -f "$HOMELAB_DIR/kubernetes/storage/local-path-provisioner.yaml" 2>&1 | tee -a "$LOG_FILE" || true

    # Secrets management
    log "Installing External Secrets Operator..."
    if [ -f "$HOMELAB_DIR/kubernetes/secrets/external-secrets-operator.yaml" ]; then
        kubectl apply -f "$HOMELAB_DIR/kubernetes/secrets/external-secrets-operator.yaml" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    # Ingress
    log "Installing Traefik..."
    kubectl apply -f "$HOMELAB_DIR/kubernetes/ingress/" 2>&1 | tee -a "$LOG_FILE" || true

    # Cert-manager
    log "Installing cert-manager..."
    if [ -d "$HOMELAB_DIR/kubernetes/ingress/cert-manager" ]; then
        kubectl apply -f "$HOMELAB_DIR/kubernetes/ingress/cert-manager/" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    success "Core infrastructure reinstallation initiated"
    info "Note: Some components may take time to become ready"
}

# Reinstall monitoring stack
reinstall_monitoring() {
    confirm "This will reinstall the monitoring stack. Continue?"

    log "Reinstalling monitoring stack..."

    # Prometheus
    if [ -d "$HOMELAB_DIR/kubernetes/monitoring/prometheus" ]; then
        log "Installing Prometheus..."
        helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
            -n monitoring --create-namespace \
            -f "$HOMELAB_DIR/kubernetes/monitoring/prometheus/values.yaml" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    # Loki
    if [ -d "$HOMELAB_DIR/kubernetes/services/loki" ]; then
        log "Installing Loki..."
        kubectl apply -f "$HOMELAB_DIR/kubernetes/services/loki/" 2>&1 | tee -a "$LOG_FILE" || true
    fi

    success "Monitoring stack reinstallation initiated"
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

    for service in "${services[@]}"; do
        local service_path="$HOMELAB_DIR/kubernetes/services/$service"
        if [ -d "$service_path" ]; then
            log "Installing $service..."

            # Apply namespace first if exists
            if [ -f "$service_path/namespace.yaml" ]; then
                kubectl apply -f "$service_path/namespace.yaml" 2>&1 | tee -a "$LOG_FILE" || true
            fi

            # Apply all manifests
            kubectl apply -f "$service_path/" 2>&1 | tee -a "$LOG_FILE" || true
            success "$service installation initiated"
        else
            warning "Service directory not found: $service_path"
        fi
    done
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

    reinstall_infrastructure
    sleep 30  # Wait for infrastructure

    reinstall_monitoring
    sleep 30  # Wait for monitoring

    if kubectl get namespace "$BACKUP_NAMESPACE" &> /dev/null; then
        list_available_backups
        read -r -p "Enter backup name to restore (or press Enter to skip): " backup_name
        if [ -n "$backup_name" ]; then
            restore_from_backup "$backup_name"
        fi
    fi

    reinstall_critical_services

    success "Full recovery process completed"
    info "Check pod status: kubectl get pods -A"
    info "Review log file: $LOG_FILE"
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
            1) list_available_backups ;;
            2) restore_from_backup ;;
            3) restore_namespace ;;
            4) reinstall_infrastructure ;;
            5) reinstall_monitoring ;;
            6) reinstall_critical_services ;;
            7) full_recovery ;;
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
