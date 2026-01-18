#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
LOGFILE="$SCRIPT_DIR/validation.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    return 1
}

success() {
    log "SUCCESS: $*"
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
        error "$service_name returned HTTP $http_code (expected $expected_code) at $url"
        return 1
    fi
}

check_kubernetes_resources() {
    log "Checking Kubernetes resources..."
    
    # Check if kubectl is available and cluster is accessible
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot access Kubernetes cluster"
        return 1
    fi
    
    success "Kubernetes cluster is accessible"
    
    # Check namespaces
    local namespaces=(
        "pihole"
        "wireguard"
        "gitea"
        "harbor"
        "drone"
        "dnsmasq-dhcp"
        "nextcloud"
        "vaultwarden"
        "jellyfin"
        "heimdall"
        "monitoring"
        "traefik-system"
    )
    
    for ns in "${namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            success "Namespace $ns exists"
        else
            log "WARNING: Namespace $ns not found"
        fi
    done
    
    # Check pods status using structured output for reliability
    log "Checking pod status..."
    local failed_pods=0
    local pod_info

    # Use JSON output for reliable parsing - catches all non-healthy states
    while IFS= read -r pod_info; do
        if [ -n "$pod_info" ]; then
            local ns name phase
            ns=$(echo "$pod_info" | cut -d'|' -f1)
            name=$(echo "$pod_info" | cut -d'|' -f2)
            phase=$(echo "$pod_info" | cut -d'|' -f3)
            error "Pod not healthy: $ns/$name (status: $phase)"
            ((failed_pods++))
        fi
    done < <(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.status.phase}{"\n"}{end}' 2>/dev/null | grep -v -E '\|(Running|Succeeded)$' || true)

    if [ $failed_pods -eq 0 ]; then
        success "All pods are running or completed"
    else
        error "$failed_pods pods are not running properly"
    fi
}

check_docker_compose() {
    log "Checking Docker Compose setup..."
    
    if [ ! -f "$SCRIPT_DIR/docker-compose.yml" ]; then
        error "Docker Compose file not found"
        return 1
    fi
    
    success "Docker Compose file found"
    
    # Validate Docker Compose file
    if docker-compose -f "$SCRIPT_DIR/docker-compose.yml" config &> /dev/null; then
        success "Docker Compose file is valid"
    else
        error "Docker Compose file has syntax errors"
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
        if docker-compose -f "$SCRIPT_DIR/docker-compose.yml" config --services | grep -q "^$service$"; then
            success "Service $service is defined"
        else
            error "Service $service is not defined"
        fi
    done
}

check_configuration_files() {
    log "Checking configuration files..."
    
    local required_files=(
        "$HOMELAB_DIR/config/homelab.yaml"
        "$HOMELAB_DIR/setup.sh"
        "$SCRIPT_DIR/docker-compose.yml"
        "$SCRIPT_DIR/kind-config.yaml"
        "$SCRIPT_DIR/setup-kind.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            success "File exists: $file"
        else
            error "Missing file: $file"
        fi
    done
    
    # Check if setup script is executable
    if [ -x "$HOMELAB_DIR/setup.sh" ]; then
        success "Setup script is executable"
    else
        error "Setup script is not executable"
    fi
}

check_kubernetes_manifests() {
    log "Checking Kubernetes manifests..."
    
    local service_dirs=(
        "pihole"
        "wireguard"
        "gitea"
        "harbor"
        "drone"
        "dnsmasq-dhcp"
        "nextcloud"
        "vaultwarden"
        "jellyfin"
        "heimdall"
    )
    
    for service in "${service_dirs[@]}"; do
        local service_dir="$HOMELAB_DIR/kubernetes/services/$service"
        if [ -d "$service_dir" ]; then
            success "Service directory exists: $service"
            
            # Check for required files
            if [ -f "$service_dir/namespace.yaml" ]; then
                success "$service has namespace.yaml"
            else
                log "WARNING: $service missing namespace.yaml"
            fi
            
            if [ -f "$service_dir/deployment.yaml" ]; then
                success "$service has deployment.yaml"
            else
                log "WARNING: $service missing deployment.yaml"
            fi
        else
            error "Service directory missing: $service"
        fi
    done
}

validate_service_connectivity() {
    log "Validating service connectivity (requires running environment)..."
    
    # Common service endpoints to test
    local services=(
        "Pi-hole:http://pihole.homelab.local"
        "Nextcloud:http://nextcloud.homelab.local"
        "Vaultwarden:http://vault.homelab.local"
        "Jellyfin:http://jellyfin.homelab.local"
        "Grafana:http://grafana.homelab.local"
        "Gitea:http://git.homelab.local"
        "MinIO:http://minio.homelab.local"
        "Dashboard:http://dashboard.homelab.local"
    )
    
    local connectivity_failures=0
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service_name service_url <<< "$service_info"
        if ! check_service_health "$service_name" "$service_url"; then
            ((connectivity_failures++))
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
            error "YAML syntax error in: $yaml_file"
            ((syntax_errors++))
        fi
    done < <(find "$HOMELAB_DIR" \( -name "*.yaml" -o -name "*.yml" \) -print0)

    if [ $syntax_errors -eq 0 ]; then
        success "All YAML files have valid syntax"
    else
        error "$syntax_errors YAML files have syntax errors"
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
    success_count=$(grep -c "SUCCESS:" "$LOGFILE" 2>/dev/null || echo "0")
    error_count=$(grep -c "ERROR:" "$LOGFILE" 2>/dev/null || echo "0")
    
    echo "Summary:"
    echo "✅ Successful checks: $success_count"
    echo "❌ Failed checks: $error_count"
    echo ""
    
    if [ "$error_count" -gt 0 ]; then
        echo "Errors found:"
        grep "ERROR:" "$LOGFILE" | sed 's/.*ERROR: /- /'
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
            check_configuration_files
            run_yaml_syntax_check
            ;;
        "k8s")
            check_kubernetes_manifests
            check_kubernetes_resources
            ;;
        "docker")
            check_docker_compose
            ;;
        "connectivity")
            validate_service_connectivity
            ;;
        "all"|*)
            check_configuration_files
            run_yaml_syntax_check
            check_kubernetes_manifests
            check_docker_compose
            if kubectl cluster-info &> /dev/null; then
                check_kubernetes_resources
            else
                log "Skipping Kubernetes checks (cluster not accessible)"
            fi
            validate_service_connectivity
            ;;
    esac
    
    generate_report
    
    log "Validation completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi