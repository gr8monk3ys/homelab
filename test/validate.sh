#!/bin/bash
set -euo pipefail

# KinD / Compose harness validation. Cluster health and service URLs come
# from scripts/lib/health.sh (the catalogue decides both); this script keeps
# the harness-specific checks: config files, YAML syntax, the Compose stack,
# the descriptor check, and HTTP reachability of each service URL.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
LOGFILE="${LOGFILE:-$SCRIPT_DIR/validation.log}"
: > "$LOGFILE"

source "$HOMELAB_DIR/scripts/lib/health.sh"
source "$HOMELAB_DIR/scripts/lib/netpol.sh"

FAILURES=0
# fail <msg>: a counted, non-fatal failure (common.sh's error() exits).
fail() {
    log "ERROR: $*"
    FAILURES=$((FAILURES+1))
}

compose_cmd() {
    if command -v docker-compose &> /dev/null; then
        docker-compose "$@"
    else
        docker compose "$@"
    fi
}

check_service_health() {
    local service_name="$1"
    local url="$2"
    local expected_code="${3:-200}"

    log "Checking $service_name at $url..."

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url" 2>/dev/null || echo "000")

    if [ "$http_code" = "$expected_code" ]; then
        success "$service_name is accessible (HTTP $http_code)"
        return 0
    else
        fail "$service_name returned HTTP $http_code (expected $expected_code) at $url"
        return 1
    fi
}

check_kubernetes_resources() {
    log "Checking Kubernetes resources (catalogue-enabled services and installed infrastructure)..."
    local rc=0
    health_report --all --enabled-only || rc=$?
    case "$rc" in
        0) success "Every enabled service and infrastructure piece is healthy" ;;
        2) fail "Cannot access Kubernetes cluster" ;;
        *) fail "Some services or infrastructure pieces are not healthy (see the table above)" ;;
    esac
    return "$rc"
}

check_docker_compose() {
    log "Checking Docker Compose setup..."

    if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        fail "Docker Compose file not found"
        return 1
    fi

    success "Docker Compose file found"

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        fail "Docker Compose is not available (install docker-compose or the docker compose plugin)"
        return 1
    fi

    # Validate Docker Compose file
    if compose_cmd -f "$SCRIPT_DIR/docker-compose.yml" config &> /dev/null; then
        success "Docker Compose file is valid"
    else
        fail "Docker Compose file has syntax errors"
        return 1
    fi

    # Check if services are defined
    local expected_services=(
        "traefik"
        "pihole"
        "nextcloud"
        "nextcloud-db"
        "vaultwarden"
        "jellyfin"
        "prometheus"
        "grafana"
        "gitea"
        "gitea-db"
        "minio"
        "heimdall"
    )

    for service in "${expected_services[@]}"; do
        if compose_cmd -f "$SCRIPT_DIR/docker-compose.yml" config --services | grep -q "^$service$"; then
            success "Service $service is defined"
        else
            fail "Service $service is not defined"
        fi
    done
}

check_configuration_files() {
    log "Checking configuration files..."

    local required_files=(
        "$HOMELAB_DIR/config/homelab.yaml"
        "$HOMELAB_DIR/setup-v2.sh"
        "$SCRIPT_DIR/docker-compose.yml"
        "$SCRIPT_DIR/kind-config.yaml"
        "$SCRIPT_DIR/setup-kind.sh"
    )

    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            success "File exists: $file"
        else
            fail "Missing file: $file"
        fi
    done

    # Check if setup script is executable
    if [ -x "$HOMELAB_DIR/setup-v2.sh" ]; then
        success "Setup script is executable"
    else
        fail "Setup script is not executable"
    fi
}

check_kubernetes_manifests() {
    log "Checking Kubernetes manifests..."

    # Nextcloud is deployed from the repo Helm chart, not kubernetes/services/
    if [ -f "$HOMELAB_DIR/helm/nextcloud/Chart.yaml" ]; then
        success "Nextcloud Helm chart exists"
    else
        fail "Nextcloud Helm chart missing: helm/nextcloud"
    fi

    # Every service directory must carry a valid descriptor (same check CI runs).
    if services_check; then
        success "Service catalogue is consistent"
    else
        fail "Service catalogue check failed"
    fi

    local name service_dir
    for name in $(services_all); do
        # A kind: helm service's chart owns its namespace.
        [ "$(service_field "$name" '.kind' manifests)" != "helm" ] || continue
        service_dir="$HOMELAB_DIR/kubernetes/services/$name"
        if [ -f "$service_dir/namespace.yaml" ]; then
            success "$name has namespace.yaml"
        else
            fail "$name missing namespace.yaml"
        fi
    done
}

validate_service_connectivity() {
    log "Validating service connectivity (requires running environment)..."

    # Endpoints: infrastructure UIs plus every enabled service's descriptor url.
    local services=("Grafana:https://grafana.$DOMAIN" "MinIO:https://minio.$DOMAIN")
    local name url
    for name in $(services_all); do
        service_enabled "$name" || continue
        url="$(service_url "$name")"
        [[ -n "$url" ]] && services+=("$name:$url")
    done

    local connectivity_failures=0
    for service_info in "${services[@]}"; do
        IFS=':' read -r service_name service_url <<< "$service_info"
        if ! check_service_health "$service_name" "$service_url"; then
            connectivity_failures=$((connectivity_failures+1))
        fi
        sleep 1  # Rate limiting
    done

    if [ $connectivity_failures -eq 0 ]; then
        success "All services are accessible"
    else
        log "WARNING: $connectivity_failures services are not accessible (this is normal if not running)"
    fi
}

run_yaml_syntax_check() {
    log "Checking YAML syntax..."

    local syntax_errors=0

    # Use null-terminated find to handle filenames with special characters safely
    while IFS= read -r -d '' yaml_file; do
        # Pass filename as argument to avoid shell injection
        if python3 -c "import yaml, sys; list(yaml.safe_load_all(open(sys.argv[1])))" "$yaml_file" 2>/dev/null; then
            log "YAML syntax OK: $(basename "$yaml_file")"
        else
            fail "YAML syntax error in: $yaml_file"
            syntax_errors=$((syntax_errors+1))
        fi
    done < <(find "$HOMELAB_DIR" \( -name "*.yaml" -o -name "*.yml" \) -not -path "*/helm/*/templates/*" -print0)

    if [ $syntax_errors -eq 0 ]; then
        success "All YAML files have valid syntax"
    else
        fail "$syntax_errors YAML files have syntax errors"
    fi
}

generate_report() {
    log "Generating validation report..."

    echo ""
    echo "========================================="
    echo "         HOMELAB VALIDATION REPORT"
    echo "========================================="
    echo "Generated: $(date)"
    echo "Log file: $LOGFILE"
    echo ""

    # Count successes and errors
    local success_count
    local error_count
    success_count=$(grep -c "✅" "$LOGFILE" 2>/dev/null || true)
    success_count=${success_count:-0}
    error_count=$FAILURES

    echo "Summary:"
    echo "✅ Successful checks: $success_count"
    echo "❌ Failed checks: $error_count"
    echo ""

    if [ "$error_count" -gt 0 ]; then
        echo "Errors found:"
        grep "ERROR:" "$LOGFILE" 2>/dev/null | sed 's/.*ERROR: /- /' | tail -n "$error_count"
        echo ""
    fi

    if [ "$error_count" -eq 0 ]; then
        echo "🎉 All validations passed! Your homelab setup looks good."
    else
        echo "⚠️  Some validations failed. Please review the errors above."
    fi

    echo ""
    echo "Full log available at: $LOGFILE"
}

main() {
    local test_type="${1:-all}"

    log "Starting homelab validation (type: $test_type)..."

    case "$test_type" in
        "config")
            check_configuration_files || true
            run_yaml_syntax_check || true
            ;;
        "k8s")
            check_kubernetes_manifests || true
            check_kubernetes_resources || true
            ;;
        "docker")
            check_docker_compose || true
            ;;
        "connectivity")
            validate_service_connectivity || true
            ;;
        "all"|*)
            check_configuration_files || true
            run_yaml_syntax_check || true
            check_kubernetes_manifests || true
            check_docker_compose || true
            check_kubernetes_resources || true
            validate_service_connectivity || true
            ;;
    esac

    generate_report

    log "Validation completed"

    if [ "$FAILURES" -gt 0 ]; then
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
