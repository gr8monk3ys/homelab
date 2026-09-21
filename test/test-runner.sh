#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib/common.sh"

show_help() {
    cat << EOF
Homelab Test Runner

Usage: $0 [command] [options]

Commands:
  validate [type]     - Run validation tests
    all              - Run all validations (default)
    config           - Validate configuration files
    k8s              - Validate Kubernetes setup
    connectivity     - Test service connectivity

  kind                - Test with Kind (Kubernetes in Docker)
    setup            - Create Kind cluster and deploy
    cleanup          - Delete Kind cluster
    test             - Run full Kind test
    info             - Show access information

  full-test           - Run comprehensive test suite
  clean               - Clean up all test environments

Examples:
  $0 validate config          # Check configuration files
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
    log "Step 1/3: Validating configurations..."
    validate_command "config"
    echo ""

    # Step 2: Test Kind
    log "Step 2/3: Testing Kind (Kubernetes) setup..."
    kind_command "test"
    kind_command "cleanup"
    echo ""

    # Step 3: Final validation
    log "Step 3/3: Final validation..."
    validate_command "all"
    echo ""

    log "Comprehensive test completed!"
    echo ""
    echo "🎉 All tests completed successfully!"
    echo "Your homelab setup is ready for deployment."
}

clean_all() {
    log "Cleaning up all test environments..."

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
