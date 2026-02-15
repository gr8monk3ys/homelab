#!/bin/bash
set -euo pipefail

# Configure Pi-hole (dnsmasq) to resolve *.<domain> to Traefik's LoadBalancer IP.
#
# This avoids per-machine /etc/hosts entries. Clients must use Pi-hole as their DNS server.

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

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        error "Missing required command: $cmd"
    fi
}

resolve_hostname_to_ip() {
    local hostname="$1"

    if command -v python3 &> /dev/null; then
        python3 - "$hostname" <<'PY'
import socket, sys
hostname = sys.argv[1]
ips = []
try:
    for family, _, _, _, sockaddr in socket.getaddrinfo(hostname, None):
        if family == socket.AF_INET:
            ips.append(sockaddr[0])
except socket.gaierror:
    pass
print(next(iter(ips), ""))
PY
        return 0
    fi

    # Fallback: macOS typically has `dig`, but don't hard-require it.
    if command -v dig &> /dev/null; then
        dig +short A "$hostname" | head -n 1 || true
        return 0
    fi

    echo ""
}

get_traefik_lb_ip() {
    local namespace="$1"
    local service="$2"
    local wait_seconds="$3"

    local start now ip hostname resolved
    start="$(date +%s)"

    while true; do
        ip="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [[ -n "${ip:-}" ]]; then
            echo "$ip"
            return 0
        fi

        hostname="$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
        if [[ -n "${hostname:-}" ]]; then
            resolved="$(resolve_hostname_to_ip "$hostname")"
            if [[ -n "${resolved:-}" ]]; then
                echo "$resolved"
                return 0
            fi
        fi

        now="$(date +%s)"
        if (( now - start >= wait_seconds )); then
            error "Timed out waiting for Traefik LoadBalancer IP (service ${namespace}/${service})"
        fi
        sleep 5
    done
}

wait_for_pihole_ready() {
    local namespace="$1"
    local workload="$2"
    local wait_seconds="$3"

    # Prefer rollout status if a deployment was provided (default).
    if [[ "$workload" == deploy/* || "$workload" == deployment/* ]]; then
        kubectl -n "$namespace" rollout status "$workload" "--timeout=${wait_seconds}s"
        return 0
    fi

    # Best-effort fallback.
    kubectl -n "$namespace" wait --for=condition=Ready pod -l app=pihole "--timeout=${wait_seconds}s" 2>/dev/null || true
}

main() {
    require_cmd kubectl

    local domain
    domain="${DOMAIN:-homelab.local}"
    domain="${domain%.}" # tolerate trailing dot
    if [[ -z "${domain:-}" ]]; then
        error "DOMAIN is empty"
    fi

    local traefik_namespace traefik_service pihole_namespace pihole_workload dnsmasq_conf wait_seconds
    traefik_namespace="${TRAEFIK_NAMESPACE:-traefik-system}"
    traefik_service="${TRAEFIK_SERVICE:-traefik}"
    pihole_namespace="${PIHOLE_NAMESPACE:-pihole}"
    pihole_workload="${PIHOLE_WORKLOAD:-deploy/pihole}"
    dnsmasq_conf="${DNSMASQ_CONF_FILE:-/etc/dnsmasq.d/02-homelab-wildcard.conf}"
    wait_seconds="${WAIT_SECONDS:-300}"

    log "Configuring wildcard DNS in Pi-hole..."
    log "  Domain:             ${domain}"
    log "  Traefik service:    ${traefik_namespace}/${traefik_service}"
    log "  Pi-hole workload:   ${pihole_namespace}/${pihole_workload}"
    log "  dnsmasq config:     ${dnsmasq_conf}"

    local traefik_ip
    traefik_ip="$(get_traefik_lb_ip "$traefik_namespace" "$traefik_service" "$wait_seconds")"
    log "Detected Traefik LoadBalancer IP: ${traefik_ip}"

    # Ensure Pi-hole is up before we exec into it.
    wait_for_pihole_ready "$pihole_namespace" "$pihole_workload" "$wait_seconds"

    local desired
    desired="$(
        cat <<EOF
# Managed by homelab repo: scripts/configure-wildcard-dns.sh
# Route all *.${domain} to Traefik.
address=/.${domain}/${traefik_ip}
EOF
    )"

    local existing
    existing="$(kubectl -n "$pihole_namespace" exec "$pihole_workload" -- sh -c "cat '$dnsmasq_conf' 2>/dev/null || true" || true)"

    if [[ "${existing:-}" == "${desired}" ]]; then
        log "Wildcard DNS already configured (no changes)."
        log "Test from a client using Pi-hole DNS: dig @<pihole-dns-ip> home.${domain}"
        return 0
    fi

    log "Writing dnsmasq wildcard config into Pi-hole..."
    printf '%s' "$desired" | kubectl -n "$pihole_namespace" exec -i "$pihole_workload" -- sh -c "cat > '$dnsmasq_conf'"

    log "Reloading Pi-hole DNS..."
    if kubectl -n "$pihole_namespace" exec "$pihole_workload" -- pihole restartdns reload &> /dev/null; then
        log "Pi-hole DNS reloaded."
    elif kubectl -n "$pihole_namespace" exec "$pihole_workload" -- pihole restartdns &> /dev/null; then
        log "Pi-hole DNS restarted."
    else
        log "Pi-hole CLI restart failed; restarting the deployment as a fallback..."
        kubectl -n "$pihole_namespace" rollout restart "$pihole_workload"
        wait_for_pihole_ready "$pihole_namespace" "$pihole_workload" "$wait_seconds"
    fi

    log "Wildcard DNS configured: *.${domain} -> ${traefik_ip}"
    log "Next: point your router/DHCP or clients to the Pi-hole DNS service IP (kubectl -n pihole get svc pihole-dns)."
}

main "$@"
