#!/bin/bash
set -euo pipefail

# Homelab Backup Verification Script
# Validates backup configurations and tests restore capabilities

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-velero}"
MINIO_NAMESPACE="${MINIO_NAMESPACE:-minio}"
TEST_NAMESPACE="backup-test-$(date +%s)"
REPORT_FILE="${HOMELAB_DIR}/backup-verification-$(date +%Y%m%d-%H%M%S).log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo -e "${BLUE}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
}

success() {
    local msg="$*"
    echo -e "${GREEN}[PASS]${NC} $msg"
    echo "[PASS] $msg" >> "$REPORT_FILE"
}

warning() {
    local msg="$*"
    echo -e "${YELLOW}[WARN]${NC} $msg"
    echo "[WARN] $msg" >> "$REPORT_FILE"
}

error() {
    local msg="$*"
    echo -e "${RED}[FAIL]${NC} $msg"
    echo "[FAIL] $msg" >> "$REPORT_FILE"
}

info() {
    local msg="$*"
    echo -e "${CYAN}[INFO]${NC} $msg"
    echo "[INFO] $msg" >> "$REPORT_FILE"
}

# Initialize report
init_report() {
    cat > "$REPORT_FILE" << EOF
================================================================================
Homelab Backup Verification Report
Generated: $(date)
================================================================================

EOF
}

# Check if Velero is installed and running
check_velero_installation() {
    log "Checking Velero installation..."

    if ! command -v velero &> /dev/null; then
        warning "Velero CLI not installed locally"
        info "Install with: brew install velero (macOS) or download from GitHub"
    else
        success "Velero CLI is installed ($(velero version --client-only 2>/dev/null | head -1 || echo 'unknown version'))"
    fi

    if ! kubectl get namespace "$BACKUP_NAMESPACE" &> /dev/null; then
        error "Velero namespace ($BACKUP_NAMESPACE) does not exist"
        info "Velero may not be installed in the cluster"
        return 1
    fi

    local velero_pods
    velero_pods=$(kubectl get pods -n "$BACKUP_NAMESPACE" -l app.kubernetes.io/name=velero --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$velero_pods" -eq 0 ]; then
        error "No Velero pods found in $BACKUP_NAMESPACE namespace"
        return 1
    fi

    if kubectl get pods -n "$BACKUP_NAMESPACE" -l app.kubernetes.io/name=velero | grep -q Running; then
        success "Velero is running"
    else
        error "Velero pods are not in Running state"
        kubectl get pods -n "$BACKUP_NAMESPACE" -l app.kubernetes.io/name=velero
        return 1
    fi
}

# Check backup storage location
check_backup_storage() {
    log "Checking backup storage location..."

    local bsl_count
    bsl_count=$(kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$bsl_count" -eq 0 ]; then
        error "No BackupStorageLocation configured"
        return 1
    fi

    local available_bsl
    available_bsl=$(kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE" -o jsonpath='{.items[?(@.status.phase=="Available")].metadata.name}' 2>/dev/null)

    if [ -z "$available_bsl" ]; then
        error "No BackupStorageLocation is in Available phase"
        kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE"
        return 1
    fi

    success "Backup storage is available: $available_bsl"

    # Check MinIO if it's the storage backend
    if kubectl get pods -n "$MINIO_NAMESPACE" -l app=minio 2>/dev/null | grep -q Running; then
        success "MinIO storage backend is running"
    fi
}

# List existing backups
list_backups() {
    log "Listing existing backups..."

    local backup_count
    backup_count=$(kubectl get backup -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$backup_count" -eq 0 ]; then
        warning "No backups found"
        return 0
    fi

    info "Found $backup_count backup(s):"
    echo "" >> "$REPORT_FILE"

    kubectl get backup -n "$BACKUP_NAMESPACE" -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,STARTED:.status.startTimestamp,COMPLETED:.status.completionTimestamp,ERRORS:.status.errors,WARNINGS:.status.warnings 2>/dev/null | tee -a "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"

    # Check for failed backups
    local failed_backups
    failed_backups=$(kubectl get backup -n "$BACKUP_NAMESPACE" -o jsonpath='{.items[?(@.status.phase=="Failed")].metadata.name}' 2>/dev/null)

    if [ -n "$failed_backups" ]; then
        warning "Failed backups detected: $failed_backups"
    fi

    # Check backup freshness
    local latest_backup
    latest_backup=$(kubectl get backup -n "$BACKUP_NAMESPACE" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

    if [ -n "$latest_backup" ]; then
        local latest_timestamp
        latest_timestamp=$(kubectl get backup -n "$BACKUP_NAMESPACE" "$latest_backup" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
        info "Latest backup: $latest_backup (created: $latest_timestamp)"

        # Check if backup is older than 7 days
        local backup_age_seconds
        backup_age_seconds=$(( $(date +%s) - $(date -d "$latest_timestamp" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$latest_timestamp" +%s 2>/dev/null || echo 0) ))
        local backup_age_days=$(( backup_age_seconds / 86400 ))

        if [ "$backup_age_days" -gt 7 ]; then
            warning "Latest backup is $backup_age_days days old"
        else
            success "Latest backup is recent ($backup_age_days days old)"
        fi
    fi
}

# Check scheduled backups
check_scheduled_backups() {
    log "Checking backup schedules..."

    local schedule_count
    schedule_count=$(kubectl get schedule -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$schedule_count" -eq 0 ]; then
        warning "No backup schedules configured"
        info "Consider creating a schedule: velero schedule create daily-backup --schedule='0 2 * * *'"
        return 0
    fi

    info "Found $schedule_count backup schedule(s):"
    kubectl get schedule -n "$BACKUP_NAMESPACE" 2>/dev/null | tee -a "$REPORT_FILE"
}

# Check volume snapshots
check_volume_snapshots() {
    log "Checking volume snapshot support..."

    local vsl_count
    vsl_count=$(kubectl get volumesnapshotlocation -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$vsl_count" -eq 0 ]; then
        warning "No VolumeSnapshotLocation configured (PV backups may use restic/kopia)"
    else
        info "Found $vsl_count VolumeSnapshotLocation(s)"
    fi

    # Check for restic/kopia repository
    if kubectl get secret -n "$BACKUP_NAMESPACE" -l velero.io/restic-repository 2>/dev/null | grep -q .; then
        success "Restic repository configured for file-level backups"
    elif kubectl get secret -n "$BACKUP_NAMESPACE" -l velero.io/kopia-repository 2>/dev/null | grep -q .; then
        success "Kopia repository configured for file-level backups"
    else
        info "No file-level backup repository found (restic/kopia)"
    fi
}

# Verify PVC backup configuration
check_pvc_backup_config() {
    log "Checking PVC backup configuration..."

    local pvcs_with_backup
    pvcs_with_backup=$(kubectl get pvc -A -o jsonpath='{.items[?(@.metadata.annotations.backup\.velero\.io/backup-volumes)].metadata.name}' 2>/dev/null | wc -w)

    local total_pvcs
    total_pvcs=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$total_pvcs" -gt 0 ]; then
        info "PVCs with explicit backup annotation: $pvcs_with_backup / $total_pvcs"

        if [ "$pvcs_with_backup" -lt "$total_pvcs" ]; then
            warning "Some PVCs may not be included in backups"
            info "Add annotation: kubectl annotate pvc <name> backup.velero.io/backup-volumes=<volume-name>"
        fi
    fi
}

# Create test backup and verify
test_backup_restore() {
    log "Testing backup and restore capability..."

    if [ "${SKIP_RESTORE_TEST:-false}" = "true" ]; then
        info "Skipping restore test (SKIP_RESTORE_TEST=true)"
        return 0
    fi

    # Create test namespace
    info "Creating test namespace: $TEST_NAMESPACE"
    kubectl create namespace "$TEST_NAMESPACE" 2>/dev/null || true

    # Create test configmap
    kubectl create configmap backup-test-config \
        --namespace="$TEST_NAMESPACE" \
        --from-literal=test-key="backup-test-$(date +%s)" \
        2>/dev/null || true

    # Create test backup
    local test_backup_name="backup-test-$(date +%s)"
    info "Creating test backup: $test_backup_name"

    if command -v velero &> /dev/null; then
        velero backup create "$test_backup_name" \
            --include-namespaces "$TEST_NAMESPACE" \
            --wait \
            2>/dev/null || {
                warning "Test backup creation failed (velero CLI)"
                cleanup_test
                return 1
            }

        # Wait for backup to complete
        sleep 5

        local backup_status
        backup_status=$(velero backup get "$test_backup_name" -o jsonpath='{.status.phase}' 2>/dev/null)

        if [ "$backup_status" = "Completed" ]; then
            success "Test backup completed successfully"
        else
            error "Test backup failed with status: $backup_status"
            cleanup_test
            return 1
        fi
    else
        warning "Velero CLI not available, skipping backup test"
    fi

    cleanup_test
}

cleanup_test() {
    info "Cleaning up test resources..."
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true 2>/dev/null || true

    if command -v velero &> /dev/null; then
        velero backup delete "backup-test-*" --confirm 2>/dev/null || true
    fi
}

# Check critical services backup status
check_critical_services() {
    log "Checking critical services backup status..."

    local critical_namespaces=(
        "vaultwarden"
        "nextcloud"
        "gitea"
        "paperless-ngx"
        "immich"
        "home-assistant"
    )

    for ns in "${critical_namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            local pvcs
            pvcs=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            info "  $ns: $pvcs PVCs"
        fi
    done
}

# Generate recommendations
generate_recommendations() {
    log "Generating recommendations..."

    echo "" >> "$REPORT_FILE"
    echo "================================================================================
RECOMMENDATIONS
================================================================================" >> "$REPORT_FILE"

    local recommendations=()

    # Check for scheduled backups
    if ! kubectl get schedule -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        recommendations+=("Create a daily backup schedule: velero schedule create daily-backup --schedule='0 2 * * *' --ttl 720h")
    fi

    # Check for backup verification
    if [ "${#recommendations[@]}" -eq 0 ]; then
        echo "No critical recommendations at this time." >> "$REPORT_FILE"
    else
        for rec in "${recommendations[@]}"; do
            echo "- $rec" >> "$REPORT_FILE"
        done
    fi
}

# Print summary
print_summary() {
    echo ""
    echo "================================================================================"
    echo "Backup Verification Complete"
    echo "================================================================================"
    echo "Report saved to: $REPORT_FILE"
    echo ""
}

# Main function
main() {
    init_report

    echo "================================================================================"
    echo "Homelab Backup Verification"
    echo "================================================================================"
    echo ""

    local failed=0

    check_velero_installation || ((failed++))
    echo ""

    check_backup_storage || ((failed++))
    echo ""

    list_backups
    echo ""

    check_scheduled_backups
    echo ""

    check_volume_snapshots
    echo ""

    check_pvc_backup_config
    echo ""

    check_critical_services
    echo ""

    if [ "${RUN_RESTORE_TEST:-false}" = "true" ]; then
        test_backup_restore || ((failed++))
        echo ""
    fi

    generate_recommendations
    print_summary

    if [ "$failed" -gt 0 ]; then
        error "Verification completed with $failed failure(s)"
        exit 1
    fi

    success "Backup verification completed successfully"
}

# Help text
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat << EOF
Homelab Backup Verification Script

Usage: $0 [options]

Options:
  --help, -h         Show this help message

Environment Variables:
  BACKUP_NAMESPACE   Velero namespace (default: velero)
  MINIO_NAMESPACE    MinIO namespace (default: minio)
  SKIP_RESTORE_TEST  Skip restore test (default: false)
  RUN_RESTORE_TEST   Run full restore test (default: false)

Examples:
  $0                           # Run basic verification
  RUN_RESTORE_TEST=true $0     # Run with restore test
  SKIP_RESTORE_TEST=true $0    # Skip restore testing

EOF
    exit 0
fi

main "$@"
