#!/bin/bash
set -euo pipefail

# Homelab backup verification: Velero and MinIO health come from
# scripts/lib/health.sh; this script keeps the backup logic (storage location,
# backups, schedules, snapshot locations, pod-volume annotations, the optional
# backup/restore round trip) and takes the namespaces it inspects from the
# service catalogue instead of a hand-kept list.
#
# Every line also goes to REPORT_FILE (common.sh's LOGFILE).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
BACKUP_NAMESPACE="${BACKUP_NAMESPACE:-velero}"
TEST_NAMESPACE="backup-test-$(date +%s)"
REPORT_FILE="${REPORT_FILE:-$(dirname "$SCRIPT_DIR")/backup-verification-$(date +%Y%m%d-%H%M%S).log}"
LOGFILE="$REPORT_FILE"   # common.sh appends every log line here
export LOGFILE
LOG_COLOR="${LOG_COLOR:-true}"

source "$SCRIPT_DIR/lib/health.sh"

# Initialize report
init_report() {
    cat > "$REPORT_FILE" << EOF
================================================================================
Homelab Backup Verification Report
Generated: $(date)
================================================================================

EOF
}

# Velero CLI locally, Velero workloads in the cluster (scripts/lib/health.sh).
check_velero_installation() {
    log "Checking Velero installation..."

    if ! command -v velero &> /dev/null; then
        warning "Velero CLI not installed locally"
        info "Install with: ./scripts/install-dev-tools.sh (repo-local), or brew install velero (macOS), or download from GitHub"
    else
        success "Velero CLI is installed ($(velero version --client-only 2>/dev/null | head -1 || echo 'unknown version'))"
    fi

    local line rc=0
    line="$(infra_healthy velero)" || rc=$?
    case "$rc" in
        0) success "$line" ;;
        2) warning "$line"; return 2 ;;
        *) warning "$line"; return 1 ;;
    esac
}

# Check backup storage location
check_backup_storage() {
    log "Checking backup storage location..."

    local bsl_count
    bsl_count=$(kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

    if [ "$bsl_count" -eq 0 ]; then
        warning "No BackupStorageLocation configured"
        return 1
    fi

    local available_bsl
    available_bsl=$(kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE" -o jsonpath='{.items[?(@.status.phase=="Available")].metadata.name}' 2>/dev/null)

    if [ -z "$available_bsl" ]; then
        warning "No BackupStorageLocation is in Available phase"
        kubectl get backupstoragelocation -n "$BACKUP_NAMESPACE"
        return 1
    fi

    success "Backup storage is available: $available_bsl"

    # MinIO, when it is the storage backend.
    local line
    if line="$(infra_healthy minio)"; then
        success "$line (storage backend)"
    else
        warning "$line"
    fi

    check_backup_shares_fate "$available_bsl"
}

# check_backup_shares_fate <bsl names>
#
# A backup that lives on the disk it is backing up is not a backup. The
# default target here is the in-cluster MinIO, which on a single node with
# the local-path provisioner sits on that node's own disk: one disk failure
# loses the data and the backup together. This says so, every run, until the
# target points somewhere else.
check_backup_shares_fate() {
    local bsl_names="$1" name bucket_url in_cluster=""

    for name in $bsl_names; do
        bucket_url="$(kubectl get backupstoragelocation "$name" -n "$BACKUP_NAMESPACE" \
            -o jsonpath='{.spec.config.s3Url}' 2>/dev/null || true)"
        case "$bucket_url" in
            *.svc.cluster.local*|*.svc:*|*minio.minio*) in_cluster+="${in_cluster:+ }$name" ;;
        esac
    done

    [[ -n "$in_cluster" ]] || return 0

    # Only a real risk while the object store shares a node with the workloads.
    local node_count storage_class
    node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
    storage_class="$(kubectl get pvc -n minio-system -o jsonpath='{.items[0].spec.storageClassName}' 2>/dev/null || true)"

    warning "BackupStorageLocation '$in_cluster' points at the in-cluster object store."
    if [[ "$node_count" == "1" || "$storage_class" == "local-path" ]]; then
        warning "  That store is on this node's own disk (${node_count} node, storageClass '${storage_class:-unknown}')."
        warning "  A disk failure loses the data AND its backups. Point Velero at a NAS, an"
        warning "  external S3 bucket or another machine: docs/runbooks/backup-restore.md."
    else
        info "  Confirm that store is not on the same disk as the volumes it backs up."
    fi
}

# List existing backups
list_backups() {
    log "Listing existing backups..."

    local backup_count
    backup_count=$(kubectl get backup -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

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
    schedule_count=$(kubectl get schedule -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

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
    vsl_count=$(kubectl get volumesnapshotlocation -n "$BACKUP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

    if [ "$vsl_count" -eq 0 ]; then
        warning "No VolumeSnapshotLocation configured (PV backups may use kopia file-level backups via the node agent)"
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

# Verify pod volume backup configuration
check_pvc_backup_config() {
    log "Checking pod volume backup configuration..."

    local pods_with_backup
    pods_with_backup=$(kubectl get pods -A -o jsonpath='{.items[?(@.metadata.annotations.backup\.velero\.io/backup-volumes)].metadata.name}' 2>/dev/null | wc -w | tr -d ' ' || true)

    local total_pvcs
    total_pvcs=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)

    if [ "$total_pvcs" -gt 0 ]; then
        info "Pods with explicit backup-volumes annotation: $pods_with_backup (PVCs in cluster: $total_pvcs)"

        if [ "$pods_with_backup" -eq 0 ]; then
            warning "No pods opt volumes into file-level backups"
            info "Add annotation to the pod template: backup.velero.io/backup-volumes=<volume-name>"
        fi
    fi
}

# Create test backup and verify
test_backup_restore() {
    log "Testing backup and restore capability..."

    # Create test namespace
    info "Creating test namespace: $TEST_NAMESPACE"
    kubectl create namespace "$TEST_NAMESPACE" 2>/dev/null || true

    # Create test configmap
    local original_value
    original_value="backup-test-$(date +%s)"
    kubectl create configmap backup-test-config \
        --namespace="$TEST_NAMESPACE" \
        --from-literal=test-key="$original_value" \
        2>/dev/null || true

    # Create test backup
    local test_backup_name
    test_backup_name="backup-test-$(date +%s)"
    info "Creating test backup: $test_backup_name"

    if command -v velero &> /dev/null; then
        velero backup create "$test_backup_name" \
            --include-namespaces "$TEST_NAMESPACE" \
            --labels homelab-backup-test=true \
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
            warning "Test backup failed with status: $backup_status"
            cleanup_test
            return 1
        fi

        if [ "${RUN_RESTORE_TEST:-false}" = "true" ]; then
            info "Deleting test namespace to simulate disaster: $TEST_NAMESPACE"
            kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true >/dev/null 2>&1 || true

            # Wait for namespace to be fully deleted before restoring.
            for _ in $(seq 1 120); do
                if ! kubectl get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then
                    break
                fi
                sleep 1
            done

            local restore_name
            restore_name="restore-${test_backup_name}"
            info "Creating restore: $restore_name (from backup $test_backup_name)"
            velero restore create "$restore_name" \
                --from-backup "$test_backup_name" \
                --labels homelab-backup-test=true \
                --wait \
                2>/dev/null || {
                warning "Restore creation failed"
                cleanup_test
                return 1
            }

            # Verify restored resource.
            local restored_value
            restored_value="$(kubectl -n "$TEST_NAMESPACE" get configmap backup-test-config -o jsonpath='{.data.test-key}' 2>/dev/null || true)"
            if [ "$restored_value" = "$original_value" ]; then
                success "Restore verified (configmap value matches)"
            else
                warning "Restore verification failed (expected '$original_value', got '$restored_value')"
                cleanup_test
                return 1
            fi
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
        velero restore delete --selector homelab-backup-test=true --confirm 2>/dev/null || true
        velero backup delete --selector homelab-backup-test=true --confirm 2>/dev/null || true
    fi
}

# PVCs per service namespace, from the catalogue: what a backup has to cover.
check_service_volumes() {
    log "Checking service volumes (catalogue namespaces present in the cluster)..."

    local name ns pvcs total=0 with_pvcs=0
    for name in $(services_all); do
        ns="$(service_field "$name" '.namespace')"
        kubectl get namespace "$ns" &> /dev/null || continue
        pvcs=$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
        [ "$pvcs" -gt 0 ] || continue
        info "  $name ($ns): $pvcs PVCs"
        total=$((total + pvcs))
        with_pvcs=$((with_pvcs + 1))
    done
    info "$with_pvcs service namespace(s) hold $total PVC(s)"
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

    local rc=0
    check_velero_installation || rc=$?
    if [ "$rc" -eq 2 ]; then
        error "No cluster access; nothing to verify (report: $REPORT_FILE)"
    fi
    [ "$rc" -eq 0 ] || failed=$((failed+1))
    echo ""

    check_backup_storage || failed=$((failed+1))
    echo ""

    list_backups
    echo ""

    check_scheduled_backups
    echo ""

    check_volume_snapshots
    echo ""

    check_pvc_backup_config
    echo ""

    check_service_volumes
    echo ""

    if [ "${RUN_RESTORE_TEST:-false}" = "true" ]; then
        test_backup_restore || failed=$((failed+1))
        echo ""
    fi

    generate_recommendations
    print_summary

    if [ "$failed" -gt 0 ]; then
        error "Verification completed with $failed failure(s)"
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
  REPORT_FILE        Where the report is written (default: backup-verification-<stamp>.log in the repo root)
  RUN_RESTORE_TEST   Run full backup/restore test (default: false)

Examples:
  $0                           # Run basic verification
  RUN_RESTORE_TEST=true $0     # Run with backup/restore test

EOF
    exit 0
fi

main "$@"
