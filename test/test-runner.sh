#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*"
    exit 1
}

show_help() {
    cat << EOF
Homelab Test Runner

Usage: $0 [command] [options]

Commands:
  validate [type]     - Run validation tests
    all              - Run all validations (default)
    config           - Validate configuration files
    k8s              - Validate Kubernetes setup
    docker           - Validate Docker Compose setup
    connectivity     - Test service connectivity
    
  docker              - Test with Docker Compose
    up               - Start Docker Compose stack
    down             - Stop Docker Compose stack
    logs [service]   - View logs
    ps               - Show running containers
    test             - Run full Docker Compose test
    
  kind                - Test with Kind (Kubernetes in Docker)
    setup            - Create Kind cluster and deploy
    cleanup          - Delete Kind cluster
    test             - Run full Kind test
    info             - Show access information
    
  full-test           - Run comprehensive test suite
  clean               - Clean up all test environments
  
Examples:
  $0 validate config           # Check configuration files
  $0 docker up                 # Start Docker Compose stack
  $0 kind setup               # Create Kind cluster
  $0 full-test                # Run all tests
  $0 clean                    # Clean up everything
EOF
}

validate_command() {
    local validation_type="${1:-all}"
    
    log "Running validation: $validation_type"
    "$SCRIPT_DIR/validate.sh" "$validation_type"
}

docker_command() {
    local action="${1:-help}"
    
    case "$action" in
        "up")
            log "Starting Docker Compose stack..."
            cd "$SCRIPT_DIR"
            docker-compose up -d
            log "Docker Compose stack started"
            log "Access services via http://localhost with .homelab.local domains"
            ;;
        "down")
            log "Stopping Docker Compose stack..."
            cd "$SCRIPT_DIR"
            docker-compose down
            log "Docker Compose stack stopped"
            ;;
        "logs")
            local service="${2:-}"
            cd "$SCRIPT_DIR"
            if [ -n "$service" ]; then
                docker-compose logs -f "$service"
            else
                docker-compose logs -f
            fi
            ;;
        "ps")
            cd "$SCRIPT_DIR"
            docker-compose ps
            ;;
        "test")
            log "Running full Docker Compose test..."
            cd "$SCRIPT_DIR"
            
            # Start stack
            docker-compose up -d
            
            # Wait for services
            log "Waiting for services to start..."
            sleep 30
            
            # Run validation
            "$SCRIPT_DIR/validate.sh" connectivity
            
            log "Docker Compose test completed"
            ;;
        *)
            echo "Docker commands: up, down, logs [service], ps, test"
            ;;
    esac
}

kind_command() {
    local action="${1:-help}"
    
    case "$action" in
        "setup")
            log "Setting up Kind cluster..."
            "$SCRIPT_DIR/setup-kind.sh" setup
            ;;
        "cleanup")
            log "Cleaning up Kind cluster..."
            "$SCRIPT_DIR/setup-kind.sh" cleanup
            ;;
        "test")
            log "Running full Kind test..."
            "$SCRIPT_DIR/setup-kind.sh" setup
            
            # Wait for services
            log "Waiting for services to be ready..."
            sleep 60
            
            # Run validation
            "$SCRIPT_DIR/validate.sh" k8s
            "$SCRIPT_DIR/validate.sh" connectivity
            
            log "Kind test completed"
            ;;
        "info")
            "$SCRIPT_DIR/setup-kind.sh" info
            ;;
        *)
            echo "Kind commands: setup, cleanup, test, info"
            ;;
    esac
}

full_test() {
    log "Running comprehensive test suite..."
    
    echo "========================================="
    echo "         HOMELAB COMPREHENSIVE TEST"
    echo "========================================="
    echo ""
    
    # Step 1: Validate configurations
    log "Step 1/4: Validating configurations..."
    validate_command "config"
    echo ""
    
    # Step 2: Test Docker Compose
    log "Step 2/4: Testing Docker Compose setup..."
    docker_command "test"
    docker_command "down"
    echo ""
    
    # Step 3: Test Kind
    log "Step 3/4: Testing Kind (Kubernetes) setup..."
    kind_command "test"
    kind_command "cleanup"
    echo ""
    
    # Step 4: Final validation
    log "Step 4/4: Final validation..."
    validate_command "all"
    echo ""
    
    log "Comprehensive test completed!"
    echo ""
    echo "🎉 All tests completed successfully!"
    echo "Your homelab setup is ready for deployment."
}

clean_all() {
    log "Cleaning up all test environments..."
    
    # Clean Docker Compose
    cd "$SCRIPT_DIR"
    docker-compose down -v 2>/dev/null || true
    
    # Clean Kind
    "$SCRIPT_DIR/setup-kind.sh" cleanup 2>/dev/null || true
    
    # Clean logs
    rm -f "$SCRIPT_DIR"/*.log
    
    log "Cleanup completed"
}

main() {
    local command="${1:-help}"
    shift || true
    
    case "$command" in
        "validate")
            validate_command "$@"
            ;;
        "docker")
            docker_command "$@"
            ;;
        "kind")
            kind_command "$@"
            ;;
        "full-test")
            full_test
            ;;
        "clean")
            clean_all
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            echo "Unknown command: $command"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi