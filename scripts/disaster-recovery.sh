#!/bin/bash
set -euo pipefail

# Homelab Disaster Recovery Script
# Automated recovery procedures for homelab infrastructure.
#
# Reinstall phases are the installer's own: this script sources setup-v2.sh
# and runs its setup_* functions, so a phase cannot behave differently here
# than it does on install. Recovery does run a SUBSET of the installer's
# phases, and the subset is deliberate: see reinstall_infrastructure (no
# MetalLB), reinstall_monitoring, reinstall_critical_services and
# reinstall_security. Anything outside those four is not restored.
# What is DR-specific lives here: Velero restores, the encrypted secrets
# restore, confirmation prompts, per-step failure tracking and reporting.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/render.sh"
source "$SCRIPT_DIR/lib/services.sh"
homelab_load_config

BOLD='\033[1m'
NC='\033[0m'

# Configuration
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-velero}"
LOG_FILE="${HOMELAB_DIR}/disaster-recovery-$(date +%Y%m%d-%H%M%S).log"
SECRETS_BACKUP_FILE="${SECRETS_BACKUP_FILE:-}"
AGE_IDENTITY_FILE="${AGE_IDENTITY_FILE:-$HOMELAB_DIR/.secrets/agekey.txt}"
# Services reinstalled by `services` / step 4 of `full`. Names in the core
# group (Nextcloud included) come back through setup_service_group core; any other
# name is installed from its descriptor regardless of its group toggle.
CRITICAL_SERVICES="${CRITICAL_SERVICES:-vaultwarden nextcloud gitea home-assistant}"

# common.sh owns the log family; colour and a per-script report file are set,
# not reimplemented (see its header). Only error() is redefined, for the one
# reason common.sh sanctions: here it must not exit, because run_step runs the
# installer's phases in a child bash where the installer's exiting error()
# applies and a failed phase is recorded rather than fatal.
LOG_COLOR=true

error() {
    log "ERROR: $*" >&2
}

prompt() {
    echo -e "${BOLD}$*${NC}"
}

# The installer is the one owner of every install phase (chart versions,
# values files, apply order). Sourcing it only defines its functions and
# reads its toggles; main() runs only when it is executed directly.
LOGFILE="$LOG_FILE"
source "$HOMELAB_DIR/setup-v2.sh"

# Best-effort step runner: log failures instead of aborting, and track them
# so the calling function can print an honest summary.
#
# Each step runs in a child bash that re-sources setup-v2.sh from the repo
# root (the phases apply repo-relative paths) with `set -e` in force and the
# installer's exiting error(). A subshell would not do: bash ignores `set -e`
# inside `cmd || ...` and `if cmd` contexts, which is how the reinstall_*
# functions are called, so a failing helm in the middle of a phase would
# otherwise go unrecorded. Toggles (INSTALL_*, ENABLE_*, OPTIN_SERVICES) and
# the effective DOMAIN/TIMEZONE/... reach the child through the environment,
# which is why the child re-runs homelab_load_config. The child's log family
# writes to stdout only; this process tees it into LOG_FILE.
FAILED_STEPS=()

run_step() {
    local desc="$1"
    shift
    log "$desc..."
    local status=0
    bash -c '
        set -euo pipefail
        cd "$HOMELAB_DIR"
        source ./setup-v2.sh
        LOGFILE=""
        homelab_load_config
        "$@"
    ' run_step "$@" 2>&1 | tee -a "$LOG_FILE" || status=$?
    if [ "$status" -eq 0 ]; then
        return 0
    fi
    error "Step failed (exit $status): $desc"
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
# Deliberately not require_cmd (scripts/lib/common.sh): that exits on the
# first missing tool, and someone rebuilding a cluster should learn everything
# they need to install in one pass, not one round trip per tool. The probes for
# velero further down are a different thing again -- an optional feature is
# present or it is not, and neither is a prerequisite.
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

# Reinstall core infrastructure: the installer's storage, secrets, ingress
# and backup phases. MetalLB (setup_loadbalancer) is deliberately not part of
# this, as it never was: a LoadBalancer pool is site-specific and survives
# most recoveries; run ./setup-v2.sh if it is gone.
reinstall_infrastructure() {
    confirm "This will reinstall core infrastructure components. Continue?"

    log "Reinstalling core infrastructure via the installer's phases..."

    FAILED_STEPS=()

    # The installer's relative order: ingress, secrets, storage, backup. Storage
    # must follow secrets: MinIO's manifest carries an ExternalSecret, whose CRD
    # only exists once setup_secrets has installed External Secrets. In the
    # other order the ExternalSecret is rejected, MinIO never gets credentials,
    # and Velero's backup target is that MinIO. test/dr-phases.sh holds DR to
    # the installer's order.
    run_step "Ingress: Traefik, cert-manager, issuers (setup_ingress)" setup_ingress

    # Optional: restore encrypted secrets BEFORE setup_secrets, because
    # generate-secrets.sh keeps any secret that already exists.
    if [ -n "${SECRETS_BACKUP_FILE:-}" ]; then
        if [ ! -f "$SECRETS_BACKUP_FILE" ]; then
            warning "SECRETS_BACKUP_FILE was set but does not exist: $SECRETS_BACKUP_FILE"
            FAILED_STEPS+=("Restoring secrets from encrypted backup (file not found)")
        else
            # Absolute path: run_step changes to the repo root.
            local secrets_backup_abs
            secrets_backup_abs="$(cd "$(dirname "$SECRETS_BACKUP_FILE")" && pwd)/$(basename "$SECRETS_BACKUP_FILE")"
            run_step "Restoring secrets from encrypted backup: $secrets_backup_abs" \
                env AGE_IDENTITY_FILE="$AGE_IDENTITY_FILE" bash "$HOMELAB_DIR/scripts/restore-secrets.sh" "$secrets_backup_abs"
        fi
    fi

    run_step "Secret management: ESO, ClusterSecretStore, generated secrets (setup_secrets)" setup_secrets
    run_step "Storage (setup_storage)" setup_storage
    info "MetalLB is not reinstalled by disaster recovery; run ./setup-v2.sh if the LoadBalancer is missing."
    run_step "Velero (setup_backup)" setup_backup

    info "Note: Some components may take time to become ready"
    report_step_results "Core infrastructure reinstallation"
}

# Reinstall the cluster's security posture: the installer's own security,
# Pod Security Standards, PDB, quota, policy-as-code and NetworkPolicy phases,
# in the installer's relative order and at the installer's point: after the
# infrastructure and monitoring, before services. These phases now touch only
# infrastructure namespaces, which exist by then; each skips a namespace a
# switched-off toggle never created. Everything that lives in a service's
# namespace (its Pod Security labels, quota, PDB and policies) comes back with
# the service itself, through install_service (docs/adr/0009).
#
# Without this stage a recovered cluster would come back with no static
# NetworkPolicies, no Kyverno policies and no infrastructure PDBs, quotas or
# Pod Security labels -- silently, at the moment they are least likely to be
# audited.
reinstall_security() {
    confirm "This will reapply cluster security policies. Continue?"

    log "Reapplying the security posture via the installer's phases..."

    FAILED_STEPS=()

    run_step "Security: RBAC and static policies (setup_security)" setup_security
    run_step "Pod Security Standards (setup_pod_security_standards)" setup_pod_security_standards
    run_step "PodDisruptionBudgets (setup_pod_disruption_budgets)" setup_pod_disruption_budgets
    run_step "ResourceQuotas (setup_resource_quotas)" setup_resource_quotas
    run_step "Policy as code: Kyverno (setup_policy_as_code)" setup_policy_as_code
    run_step "Static NetworkPolicies (setup_network_policies)" setup_network_policies

    report_step_results "Security posture reinstallation"
}

# Reinstall monitoring stack: the installer's monitoring and logging phases.
# Loki only comes back when INSTALL_LOGGING=true, exactly as on install.
reinstall_monitoring() {
    confirm "This will reinstall the monitoring stack. Continue?"

    log "Reinstalling monitoring stack via the installer's phases..."

    FAILED_STEPS=()

    run_step "Monitoring: kube-prometheus-stack, alerts, ServiceMonitors, Uptime Kuma (setup_monitoring)" setup_monitoring
    run_step "Logging: Loki and Grafana datasource (setup_logging)" setup_logging

    report_step_results "Monitoring stack reinstallation"
}

# Reinstall critical services: setup_service_group core covers the core group
# (Nextcloud included); every other name in CRITICAL_SERVICES installs from
# its descriptor.
reinstall_critical_services() {
    local services=()
    read -r -a services <<< "${CRITICAL_SERVICES//,/ }"

    confirm "This will reinstall critical services: ${services[*]}. Continue?"

    FAILED_STEPS=()

    local core_names=" "
    local name
    for name in $(services_in_group core); do
        core_names+="$name "
    done

    run_step "Core services: the core group (setup_service_group core)" setup_service_group core

    local service
    for service in "${services[@]}"; do
        if [[ "$core_names" == *" $service "* ]]; then
            continue
        fi
        if [ -f "$HOMELAB_DIR/kubernetes/services/$service/service.yaml" ]; then
            run_step "Installing $service (install_service)" install_service "$service"
        else
            warning "Service descriptor not found: kubernetes/services/$service/service.yaml"
            FAILED_STEPS+=("Installing $service (descriptor not found)")
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
    echo "3. Reapply the security posture"
    echo "4. Restore from backup (if available)"
    echo "5. Reinstall critical services"
    echo ""

    local failed_phases=0

    reinstall_infrastructure || failed_phases=$((failed_phases+1))
    sleep 30  # Wait for infrastructure

    reinstall_monitoring || failed_phases=$((failed_phases+1))
    sleep 30  # Wait for monitoring

    # The installer's point for these phases: after the infrastructure, before
    # services. See reinstall_security.
    reinstall_security || failed_phases=$((failed_phases+1))

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
    echo "Nodes:"
    kubectl get nodes
    echo ""
    # Same interface the installer and validators use (scripts/lib/health.sh).
    health_report --all || true
    echo ""
    echo "PVC Status:"
    kubectl get pvc -A 2>/dev/null || echo "No PVCs found"
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
    echo "  7) Reapply the security posture"
    echo "  8) Full cluster recovery"
    echo "  9) Verify cluster health"
    echo " 10) Exit"
    echo ""
}

# Interactive mode
interactive_mode() {
    init_log
    check_prerequisites
    check_cluster

    while true; do
        print_menu
        read -r -p "Select option [1-10]: " choice

        case $choice in
            1) list_available_backups || true ;;
            2) restore_from_backup ;;
            3) restore_namespace ;;
            4) reinstall_infrastructure || true ;;
            5) reinstall_monitoring || true ;;
            6) reinstall_critical_services || true ;;
            7) reinstall_security || true ;;
            8) full_recovery || true ;;
            9) verify_health ;;
            10)
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
  security            Reapply NetworkPolicies, PSA, PDBs, quotas and Kyverno
  full                Full cluster recovery
  health              Verify cluster health
  help                Show this help message

Options:
  --backup NAME      Specify backup name for restore operations
  --namespace NAME   Specify namespace for restore operations

Environment Variables:
  BACKUP_NAMESPACE     Velero namespace (default: velero)
  CRITICAL_SERVICES    Services for 'services' (default: vaultwarden nextcloud gitea home-assistant)
  SECRETS_BACKUP_FILE  Encrypted secrets backup restored before secrets are generated
  INSTALL_*/ENABLE_*   Installer toggles apply unchanged (e.g. INSTALL_LOGGING=true for Loki)

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
        security)
            init_log
            check_prerequisites
            check_cluster
            reinstall_security
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
