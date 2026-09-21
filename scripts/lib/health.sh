#!/bin/bash
# shellcheck shell=bash
#
# Health seam: the one answer to "is X healthy" for every script that asks
# (the installer's health checks and access summary, disaster recovery,
# scripts/validate-setup.sh, scripts/verify-backups.sh, test/validate.sh).
# Services come from the catalogue (their descriptor's namespace: and url:);
# infrastructure is the fixed set the installer knows.
#
#   service_healthy <name>     namespace exists, every Deployment/StatefulSet in
#                              it is fully ready, its ExternalSecrets are Ready,
#                              and an Ingress carries <url>.<DOMAIN>.
#                              Prints one line "OK|FAIL <name>: <reason>".
#   service_url <name>         https://<url>.<DOMAIN>, or nothing when the
#                              descriptor has no url:.
#   infra_healthy <piece>      one of HEALTH_INFRA (below): namespace exists,
#                              the installer's pod selector is Running, and every
#                              workload in the namespace is ready. Same one line.
#   health_report [--services|--infra|--all] [--enabled-only]
#                              a table plus a summary line; --enabled-only keeps
#                              services service_enabled says install and infra
#                              whose INSTALL_* toggle is true. Default: --all.
#   access_summary [--all]     service URLs grouped by descriptor group (enabled
#                              services unless --all), the DNS hint and the
#                              credential-retrieval commands.
#
# Return codes: 0 healthy, 1 unhealthy, 2 no cluster (kubectl missing or the
# API server unreachable). Nothing here exits the caller; a missing cluster
# is one FAIL line and rc 2, so validators can decide what that means.
#
# Cluster reads are kubectl -o jsonpath only: no yq/jq on the hot path, and
# the catalogue is read through scripts/lib/services.sh.
#
# Sources scripts/lib/common.sh, render.sh and services.sh itself when the
# caller has not, and loads config/homelab.yaml so DOMAIN is effective.

if [[ -n "${HOMELAB_HEALTH_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_HEALTH_SOURCED=1

if [[ -z "${HOMELAB_COMMON_SOURCED:-}" ]]; then
    # shellcheck source=scripts/lib/common.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi
if [[ -z "${HOMELAB_RENDER_SOURCED:-}" ]]; then
    # shellcheck source=scripts/lib/render.sh
    source "$HOMELAB_LIB_DIR/render.sh"
    homelab_load_config >/dev/null 2>&1 || true
fi
if [[ -z "${HOMELAB_SERVICES_SOURCED:-}" ]]; then
    # shellcheck source=scripts/lib/services.sh
    source "$HOMELAB_LIB_DIR/services.sh"
fi

# The infrastructure the installer brings up, in the order it does.
HEALTH_INFRA=(local-path metallb traefik cert-manager external-secrets minio monitoring velero crowdsec argocd)

# piece -> "<namespace>[,<fallback namespace>] <pod selector or -> <toggle variable>"
_health_infra_spec() {
    case "$1" in
        local-path)       echo "local-path-storage app=local-path-provisioner INSTALL_LOCAL_PATH" ;;
        metallb)          echo "metallb-system app.kubernetes.io/name=metallb INSTALL_METALLB" ;;
        traefik)          echo "traefik-system,kube-system app.kubernetes.io/name=traefik INSTALL_TRAEFIK" ;;
        cert-manager)     echo "cert-manager - INSTALL_CERT_MANAGER" ;;
        external-secrets) echo "external-secrets app.kubernetes.io/name=external-secrets INSTALL_EXTERNAL_SECRETS" ;;
        minio)            echo "minio-system app=minio INSTALL_MINIO" ;;
        monitoring)       echo "monitoring - INSTALL_MONITORING" ;;
        velero)           echo "velero app.kubernetes.io/name=velero INSTALL_VELERO" ;;
        crowdsec)         echo "crowdsec app=crowdsec INSTALL_CROWDSEC" ;;
        argocd)           echo "argocd - ENABLE_GITOPS" ;;
        *)                return 1 ;;
    esac
}

# infra_enabled <piece>: the installer's toggle for it (unset means the
# installer's default: on, except GitOps).
infra_enabled() {
    local spec toggle
    spec="$(_health_infra_spec "$1")" || return 1
    toggle="${spec##* }"
    case "$toggle" in
        ENABLE_GITOPS) [[ "${ENABLE_GITOPS:-false}" == "true" ]] ;;
        *)             [[ "${!toggle:-true}" == "true" ]] ;;
    esac
}

# ---------------------------------------------------------------------------
# Cluster access. Probed once per process; HEALTH_REASON carries the message.
# ---------------------------------------------------------------------------

HEALTH_REASON=""
HEALTH_CLUSTER_STATE=""   # "" unknown, ok, none
HEALTH_KUBECTL_TIMEOUT="${HEALTH_KUBECTL_TIMEOUT:-15s}"

_kubectl() {
    kubectl --request-timeout="$HEALTH_KUBECTL_TIMEOUT" "$@" 2>/dev/null
}

# _health_cluster: 0 when the API server answers, else 2 with HEALTH_REASON set.
_health_cluster() {
    if [[ -z "$HEALTH_CLUSTER_STATE" ]]; then
        if ! command -v kubectl >/dev/null 2>&1; then
            HEALTH_CLUSTER_STATE="none"
            HEALTH_CLUSTER_REASON="no cluster access (kubectl not found)"
        elif ! _kubectl get --raw=/readyz >/dev/null; then
            HEALTH_CLUSTER_STATE="none"
            HEALTH_CLUSTER_REASON="no cluster access (API server unreachable; KUBECONFIG=${KUBECONFIG:-~/.kube/config})"
        else
            HEALTH_CLUSTER_STATE="ok"
        fi
    fi
    if [[ "$HEALTH_CLUSTER_STATE" != "ok" ]]; then
        HEALTH_REASON="$HEALTH_CLUSTER_REASON"
        return 2
    fi
    return 0
}

_ns_exists() {
    _kubectl get namespace "$1" -o name >/dev/null
}

# _scan_workloads <ns>: sets HEALTH_WORKLOADS (Deployments, StatefulSets and
# DaemonSets seen) and HEALTH_UNREADY ("kind/name ready/wanted" lines for the
# ones not fully ready; replicas 0 counts as ready). Variables, not stdout,
# so the caller is not a subshell.
_scan_workloads() {
    local ns="$1" kind_name ready wanted
    HEALTH_WORKLOADS=0
    HEALTH_UNREADY=""
    while IFS='|' read -r kind_name ready wanted; do
        [[ -n "$kind_name" ]] || continue
        HEALTH_WORKLOADS=$((HEALTH_WORKLOADS + 1))
        ready="${ready:-0}"; wanted="${wanted:-0}"
        if [[ "$wanted" != "0" && "$ready" != "$wanted" ]]; then
            HEALTH_UNREADY+="${HEALTH_UNREADY:+, }$kind_name $ready/$wanted"
        fi
    done < <(
        _kubectl get deployments,statefulsets -n "$ns" -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}|{.status.readyReplicas}|{.spec.replicas}{"\n"}{end}'
        _kubectl get daemonsets -n "$ns" -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}|{.status.numberReady}|{.status.desiredNumberScheduled}{"\n"}{end}'
    )
}

# _scan_externalsecrets <ns>: sets HEALTH_ES_UNREADY to the comma-joined names
# of ExternalSecrets without Ready=True (empty when the CRD is absent).
_scan_externalsecrets() {
    local ns="$1" name status
    HEALTH_ES_UNREADY=""
    crd_exists externalsecrets.external-secrets.io || return 0
    while IFS='|' read -r name status; do
        [[ -n "$name" ]] || continue
        [[ "$status" == "True" ]] || HEALTH_ES_UNREADY+="${HEALTH_ES_UNREADY:+, }$name"
    done < <(_kubectl get externalsecrets -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}|{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}')
}

# _pods_running <ns> <selector>: 0 when at least one matching pod is Running.
_pods_running() {
    _kubectl get pods -n "$1" -l "$2" -o jsonpath='{.items[*].status.phase}' | grep -qw Running
}

# _ingress_has_host <ns> <host>
_ingress_has_host() {
    _kubectl get ingress -n "$1" -o jsonpath='{.items[*].spec.rules[*].host}' | tr ' ' '\n' | grep -qx "$2"
}

# _join <sep> <items...>
_join() {
    local sep="$1" out="" item
    shift
    for item in "$@"; do
        out+="${out:+$sep}$item"
    done
    echo "$out"
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

service_url() {
    local url
    [[ -f "$(service_descriptor "$1")" ]] || return 0
    url="$(service_field "$1" '.url')"
    [[ -n "$url" ]] && echo "https://$url.$DOMAIN"
    return 0
}

# _service_health <name>: rc 0/1/2, HEALTH_REASON set. No output.
_service_health() {
    local name="$1" ns url host problems=()
    if [[ ! -f "$(service_descriptor "$name")" ]]; then
        HEALTH_REASON="not in the catalogue (no kubernetes/services/$name/service.yaml)"
        return 1
    fi
    _health_cluster || return 2
    ns="$(service_field "$name" '.namespace')"
    if ! _ns_exists "$ns"; then
        HEALTH_REASON="namespace $ns missing (not installed)"
        return 1
    fi

    _scan_workloads "$ns"
    if [[ "$HEALTH_WORKLOADS" -eq 0 ]]; then
        problems+=("no workloads in $ns")
    elif [[ -n "$HEALTH_UNREADY" ]]; then
        problems+=("$HEALTH_UNREADY")
    fi

    _scan_externalsecrets "$ns"
    [[ -z "$HEALTH_ES_UNREADY" ]] || problems+=("ExternalSecret not Ready: $HEALTH_ES_UNREADY")

    url="$(service_field "$name" '.url')"
    if [[ -n "$url" ]]; then
        host="$url.$DOMAIN"
        _ingress_has_host "$ns" "$host" || problems+=("no Ingress for $host")
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        HEALTH_REASON="$(_join '; ' "${problems[@]}")"
        return 1
    fi
    HEALTH_REASON="$HEALTH_WORKLOADS workload(s) ready in $ns${url:+, https://$url.$DOMAIN}"
    return 0
}

service_healthy() {
    local rc=0
    _service_health "$1" || rc=$?
    _health_print "$rc" "$1"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

# _infra_health <piece>: rc 0/1/2, HEALTH_REASON set. No output.
_infra_health() {
    local piece="$1" spec namespaces selector ns="" candidate problems=()
    if ! spec="$(_health_infra_spec "$piece")"; then
        HEALTH_REASON="unknown infrastructure piece (known: ${HEALTH_INFRA[*]})"
        return 1
    fi
    _health_cluster || return 2
    read -r namespaces selector _ <<< "$spec"
    for candidate in ${namespaces//,/ }; do
        if _ns_exists "$candidate"; then
            ns="$candidate"
            break
        fi
    done
    if [[ -z "$ns" ]]; then
        HEALTH_REASON="namespace ${namespaces//,/ or } missing (not installed)"
        return 1
    fi

    _scan_workloads "$ns"
    if [[ "$HEALTH_WORKLOADS" -eq 0 ]]; then
        problems+=("no workloads in $ns")
    elif [[ -n "$HEALTH_UNREADY" ]]; then
        problems+=("$HEALTH_UNREADY")
    fi
    if [[ "$selector" != "-" ]] && ! _pods_running "$ns" "$selector"; then
        problems+=("no Running pod with $selector")
    fi

    if [[ ${#problems[@]} -gt 0 ]]; then
        HEALTH_REASON="$(_join '; ' "${problems[@]}")"
        return 1
    fi
    HEALTH_REASON="$HEALTH_WORKLOADS workload(s) ready in $ns"
    return 0
}

infra_healthy() {
    local rc=0
    _infra_health "$1" || rc=$?
    _health_print "$rc" "$1"
    return "$rc"
}

# _health_print <rc> <name>: the one-line form.
_health_print() {
    case "$1" in
        0) echo "OK $2: $HEALTH_REASON" ;;
        *) echo "FAIL $2: $HEALTH_REASON" ;;
    esac
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

# health_report [--services|--infra|--all] [--enabled-only]
health_report() {
    local scope="all" enabled_only=false arg
    for arg in "$@"; do
        case "$arg" in
            --services)     scope="services" ;;
            --infra)        scope="infra" ;;
            --all)          scope="all" ;;
            --enabled-only) enabled_only=true ;;
            *) echo "health_report: unknown option $arg" >&2; return 1 ;;
        esac
    done

    if ! _health_cluster; then
        echo "FAIL cluster: $HEALTH_REASON"
        return 2
    fi

    local ok=0 failed=0 skipped=0 rc name
    printf '%-4s %-16s %-18s %s\n' STATE KIND NAME DETAIL
    if [[ "$scope" != "services" ]]; then
        for name in "${HEALTH_INFRA[@]}"; do
            if [[ "$enabled_only" == "true" ]] && ! infra_enabled "$name"; then
                skipped=$((skipped + 1))
                continue
            fi
            rc=0; _infra_health "$name" || rc=$?
            _health_row "$rc" infrastructure "$name"
            if [[ "$rc" -eq 0 ]]; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
        done
    fi
    if [[ "$scope" != "infra" ]]; then
        for name in $(services_all); do
            if [[ "$enabled_only" == "true" ]] && ! service_enabled "$name"; then
                skipped=$((skipped + 1))
                continue
            fi
            rc=0; _service_health "$name" || rc=$?
            _health_row "$rc" "$(service_field "$name" '.group')" "$name"
            if [[ "$rc" -eq 0 ]]; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
        done
    fi
    echo "health: $ok ok, $failed failed, $skipped skipped (disabled)"
    [[ "$failed" -eq 0 ]]
}

_health_row() {
    local state="FAIL"
    [[ "$1" -eq 0 ]] && state="OK"
    printf '%-4s %-16s %-18s %s\n' "$state" "$2" "$3" "$HEALTH_REASON"
}

# access_summary [--all]: where everything is, from the catalogue.
access_summary() {
    local all=false group name url line
    [[ "${1:-}" == "--all" ]] && all=true

    echo "Service URLs (DOMAIN=$DOMAIN):"
    echo ""
    if [[ "$HEALTH_CLUSTER_STATE" != "none" ]] && _health_cluster && _kubectl -n pihole get svc pihole-dns -o name >/dev/null; then
        echo "  DNS: wildcard DNS via Pi-hole (no /etc/hosts): kubectl -n pihole get svc pihole-dns"
        echo "       or ./scripts/configure-wildcard-dns.sh"
    else
        echo "  DNS: add /etc/hosts entries (<ingress-ip> <service>.$DOMAIN), or enable"
        echo "       wildcard DNS via Pi-hole: CONFIGURE_WILDCARD_DNS=true ./setup-v2.sh"
    fi
    echo ""
    echo "  infrastructure:"
    [[ "${INSTALL_MONITORING:-true}" == "true" ]] && echo "    grafana             https://grafana.$DOMAIN"
    [[ "${ENABLE_GITOPS:-false}" == "true" ]]    && echo "    argocd              https://argocd.$DOMAIN"
    echo "    minio               https://minio.$DOMAIN"
    for group in "${SERVICE_GROUPS[@]}"; do
        line=""
        for name in $(services_in_group "$group"); do
            url="$(service_url "$name")"
            [[ -n "$url" ]] || continue
            if [[ "$all" != "true" ]] && ! service_enabled "$name"; then
                continue
            fi
            line+="$(printf '    %-19s %s\n' "$name" "$url")"$'\n'
        done
        [[ -n "$line" ]] || continue
        echo "  $group:"
        printf '%s' "$line"
    done
    echo ""
    echo "Credentials (retrieve securely; not logged):"
    echo "  Grafana:    kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "  ArgoCD:     kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "  Nextcloud:  kubectl get secret nextcloud-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "  Paperless:  kubectl get secret paperless-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "  Every generated secret: docs/credentials.md"
}
