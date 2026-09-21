#!/bin/bash
set -euo pipefail

# Service catalogue CLI. The same code path setup-v2.sh uses.
#
#   ./scripts/services.sh list                 catalogue (name, group, opt-in, url)
#   ./scripts/services.sh check                every dir has a valid descriptor
#   ./scripts/services.sh render <dir> [name…] render enabled-or-named services into <dir>, no cluster
#   ./scripts/services.sh install <name…>      install services into the current cluster
#   ./scripts/services.sh argocd [--check]     (re)generate the ArgoCD app-of-apps and projects
#   ./scripts/services.sh render-file <file>   render one repo file to stdout
#
# Toggles (ENABLE_*_SERVICES, OPTIN_SERVICES) and DOMAIN/TIMEZONE/… are read
# exactly as setup-v2.sh reads them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/render.sh"
source "$SCRIPT_DIR/lib/services.sh"
source "$SCRIPT_DIR/lib/netpol.sh"

usage() {
    sed -n '4,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

cmd="${1:-}"
shift || true

case "$cmd" in
    list)
        services_table
        ;;
    check)
        command -v yq >/dev/null 2>&1 || error "yq is required (scripts/install-dev-tools.sh)"
        services_check
        ;;
    render)
        out="${1:-}"
        [[ -n "$out" ]] || usage
        shift
        mkdir -p "$out"
        HOMELAB_APPLY_MODE=render
        HOMELAB_RENDER_DIR="$(cd "$out" && pwd)"
        export HOMELAB_APPLY_MODE HOMELAB_RENDER_DIR
        homelab_load_config >/dev/null
        if [[ $# -gt 0 ]]; then
            for name in "$@"; do install_service "$name"; done
        else
            for name in $(services_all); do install_service "$name"; done
        fi
        ;;
    argocd)
        if [[ "${1:-}" == "--check" ]]; then
            services_argocd_check
        else
            services_argocd_write
            echo "wrote kubernetes/gitops/argocd/{projects.yaml,apps/services/default.yaml,apps/services/optional.yaml}"
        fi
        ;;
    render-file)
        [[ $# -eq 1 ]] || usage
        homelab_load_config >/dev/null 2>&1
        render_file "$1"
        ;;
    install)
        [[ $# -gt 0 ]] || usage
        homelab_load_config
        for name in "$@"; do install_service "$name"; done
        ;;
    *)
        usage
        ;;
esac
