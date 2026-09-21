#!/bin/bash
# shellcheck shell=bash
#
# Helm seam. Every chart the installer, disaster recovery, the KinD harness
# and CI pull in goes through here, so a chart repo is listed once, a chart
# version is resolved once, values are rendered once, and render mode
# (HOMELAB_APPLY_MODE=render) never touches a cluster.
#
#   helm_repo_url <name>          URL of a chart repo from HELM_REPOS (the only list of repos)
#   helm_repos_add                add and update every repo (for callers that want them all;
#                                 the installer does not: see below)
#   helm_release <release> <chart> <namespace> [options]
#       --values <file>           values file with placeholders; rendered through render_to_tmpfile
#       --version-var <VAR>       chart version comes from $VAR (tools/versions.env); empty is fatal
#       --set k=v                 passed through (repeatable)
#       --wait-label <selector>   best-effort `kubectl wait` on pods with this label afterwards
#       --no-wait                 skip helm's own --wait
#       --timeout <seconds>       for --wait-label (default 300)
#       A chart is local when it starts with ./, / or helm/ (repo-relative)
#       and needs no repo at all; otherwise it is <repo>/<chart>, <repo> must
#       be in HELM_REPOS, and that one repo is added and updated lazily, the
#       first time a release needs it in this process. An unreachable repo
#       therefore fails only the release that needs it, never a pre-step.
#       In render mode it runs `helm template` with the same arguments and
#       writes the result through apply_stream "helm/<release>.yaml"; a chart
#       that cannot be templated (no network to the repo) is a warning, not a
#       failure, and its name is appended to HELM_RENDER_SKIPPED.
#   helm_infra_release <release> [options]
#       helm_release with the arguments HELM_INFRA_RELEASES lists for that release,
#       plus any options given here. Infrastructure phases call this.
#   helm_infra_field <release> <column>
#       one column of a row: chart, namespace, toggle, health-label, health-in.
#       The last three describe the piece, not the chart install, and are what
#       scripts/lib/health.sh checks it with; helm_release never sees them.
#   helm_infra_release_names     every release in the table, in install order
#   helm_template_all             render mode: every HELM_INFRA_RELEASES row;
#                                 returns 1 if any was skipped (CI decides how strict to be)
#
# Requires scripts/lib/common.sh and scripts/lib/render.sh.

if [[ -n "${HOMELAB_HELM_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_HELM_SOURCED=1

if [[ -z "${HOMELAB_RENDER_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/render.sh before scripts/lib/helm.sh" >&2
    exit 1
fi

# name=url. The only place a chart repo is listed. bitnami is the mysql
# subchart dependency of helm/nextcloud.
HELM_REPOS=(
    "prometheus-community=https://prometheus-community.github.io/helm-charts"
    "bitnami=https://charts.bitnami.com/bitnami"
    "jetstack=https://charts.jetstack.io"
    "traefik=https://traefik.github.io/charts"
    "external-secrets=https://charts.external-secrets.io"
    "external-dns=https://kubernetes-sigs.github.io/external-dns/"
    "metallb=https://metallb.github.io/metallb"
    "vmware-tanzu=https://vmware-tanzu.github.io/helm-charts"
    "kyverno=https://kyverno.github.io/kyverno/"
    "longhorn=https://charts.longhorn.io"
    "backube=https://backube.github.io/helm-charts/"
    "tailscale=https://pkgs.tailscale.com/helmcharts"
    "nfd=https://kubernetes-sigs.github.io/node-feature-discovery/charts"
    "nvdp=https://nvidia.github.io/k8s-device-plugin"
)

# Infrastructure releases: "<release> <chart> <namespace> [options]".
# One row per third-party chart the installer installs; the phase adds only
# what is special to it (preconditions, post-install waits). CI templates
# every row (helm_template_all), so a chart, version variable or values file
# is written here once.
#
# Three of the options describe the piece rather than the `helm upgrade`, and
# helm_release never sees them (helm_infra_release strips them; read them with
# helm_infra_field):
#
#   --toggle <VAR>[=<default>]  the installer toggle that switches the piece on.
#                               The default is what setup-v2.sh seeds VAR with
#                               and is only written here when it is false, so
#                               "unset" means on, as the installer means it.
#   --health-label <selector>   the pods scripts/lib/health.sh expects to find
#                               Running; defaults to --wait-label, which is the
#                               same selector wherever the install waits on it.
#                               Absent and no --wait-label: no pod check.
#   --health-in <ns>[,<ns>]     where health looks for the piece, when that is
#                               not (only) the namespace it is installed into.
#
# Adding a row therefore gives the piece a health check for free; ADR-0006.
HELM_INFRA_RELEASES=(
    "metallb metallb/metallb metallb-system --toggle INSTALL_METALLB --version-var METALLB_CHART_VERSION --wait-label app.kubernetes.io/name=metallb"
    "traefik traefik/traefik traefik-system --toggle INSTALL_TRAEFIK --health-label app.kubernetes.io/name=traefik --health-in traefik-system,kube-system --version-var TRAEFIK_CHART_VERSION --values kubernetes/ingress/traefik/values.yaml"
    "cert-manager jetstack/cert-manager cert-manager --toggle INSTALL_CERT_MANAGER --version-var CERT_MANAGER_CHART_VERSION --set installCRDs=true"
    "external-secrets external-secrets/external-secrets external-secrets --toggle INSTALL_EXTERNAL_SECRETS --version-var EXTERNAL_SECRETS_CHART_VERSION --set installCRDs=true --wait-label app.kubernetes.io/name=external-secrets"
    "external-dns external-dns/external-dns external-dns --toggle INSTALL_EXTERNAL_DNS=false --health-label app.kubernetes.io/name=external-dns --version-var EXTERNAL_DNS_CHART_VERSION --values kubernetes/dns/external-dns/values.yaml"
    "velero vmware-tanzu/velero velero --toggle INSTALL_VELERO --health-label app.kubernetes.io/name=velero --version-var VELERO_CHART_VERSION --values kubernetes/backup/velero/values.yaml"
    "kyverno kyverno/kyverno kyverno --toggle INSTALL_KYVERNO=false --health-label app.kubernetes.io/part-of=kyverno --version-var KYVERNO_CHART_VERSION --values kubernetes/policy/kyverno/values.yaml"
    "kube-prometheus-stack prometheus-community/kube-prometheus-stack monitoring --toggle INSTALL_MONITORING --version-var KUBE_PROMETHEUS_STACK_CHART_VERSION --values kubernetes/monitoring/prometheus/values.yaml"
    "blackbox-exporter prometheus-community/prometheus-blackbox-exporter monitoring --toggle INSTALL_BLACKBOX_EXPORTER --health-label app.kubernetes.io/name=prometheus-blackbox-exporter --version-var PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION --values kubernetes/monitoring/blackbox-exporter/values.yaml"
)

# The row options helm_release must never see: they describe the piece, not
# the chart install (see HELM_INFRA_RELEASES above). Each takes one value.
_HELM_INFRA_META_OPTS=" --toggle --health-label --health-in "

# Releases helm_release could not template in render mode (see helm_template_all).
HELM_RENDER_SKIPPED=()

helm_repo_url() {
    local name="$1" entry
    for entry in "${HELM_REPOS[@]}"; do
        if [[ "${entry%%=*}" == "$name" ]]; then
            echo "${entry#*=}"
            return 0
        fi
    done
    return 1
}

helm_repo_names() {
    local entry
    for entry in "${HELM_REPOS[@]}"; do
        echo "${entry%%=*}"
    done
}

# helm_repos_add: every repo in the table, idempotently, then one update.
# Not on the installer's path: a release fetches its own repo (_helm_repo_ensure).
helm_repos_add() {
    log "Adding Helm repositories..."
    local entry
    for entry in "${HELM_REPOS[@]}"; do
        # --force-update makes a re-add a no-op instead of an error.
        helm repo add "${entry%%=*}" "${entry#*=}" --force-update >/dev/null || \
            error "Failed to add Helm repository ${entry%%=*} (${entry#*=})"
    done
    helm repo update >/dev/null || error "Failed to update Helm repositories"
}

# Repos this process has already added and updated (one index fetch each).
HELM_REPOS_READY=" "

# _helm_repo_ensure <name> <release>: add the repo from the table and refresh
# its index, once per process. Unknown names are fatal: the table is the only
# list. An unreachable repo fails here, attributed to the release.
_helm_repo_ensure() {
    local name="$1" release="$2" url
    url="$(helm_repo_url "$name")" || \
        error "helm_release $release: unknown chart repo '$name' (add it to HELM_REPOS in scripts/lib/helm.sh)"
    [[ "$HELM_REPOS_READY" == *" $name "* ]] && return 0
    log "  Helm repo $name: $url"
    if ! helm repo add "$name" "$url" --force-update >/dev/null 2>&1 || \
       ! helm repo update "$name" >/dev/null 2>&1; then
        # Render mode never fails on network: the release is skipped instead.
        [[ "$HOMELAB_APPLY_MODE" == "render" ]] && return 1
        error "helm_release $release: cannot reach Helm repo $name ($url); check network/proxy or set the toggle for $release to false"
    fi
    HELM_REPOS_READY+="$name "
}

# _helm_chart_is_local <chart>
_helm_chart_is_local() {
    case "$1" in
        ./*|/*|helm/*) return 0 ;;
        *) return 1 ;;
    esac
}

# _helm_repo_path <path>: a repo-relative path made absolute; absolute paths pass through.
_helm_repo_path() {
    case "$1" in
        /*) echo "$1" ;;
        *)  echo "$HOMELAB_DIR/$1" ;;
    esac
}

helm_release() {
    [[ $# -ge 3 ]] || error "helm_release: usage: helm_release <release> <chart> <namespace> [options]"
    local release="$1" chart="$2" ns="$3"
    shift 3

    local values="" version_var="" wait_label="" timeout=300 do_wait=true
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --values)      values="$2"; shift 2 ;;
            --version-var) version_var="$2"; shift 2 ;;
            --set)         args+=(--set "$2"); shift 2 ;;
            --wait-label)  wait_label="$2"; shift 2 ;;
            --timeout)     timeout="$2"; shift 2 ;;
            --no-wait)     do_wait=false; shift ;;
            *)             error "helm_release $release: unknown option $1" ;;
        esac
    done

    # Version: resolved from the named variable, which tools/versions.env sets.
    if [[ -n "$version_var" ]]; then
        [[ -n "${!version_var:-}" ]] || error "Missing $version_var (set in tools/versions.env)"
        args+=(--version "${!version_var}")
    fi

    # Values: rendered like any manifest; the copy goes when this function returns.
    if [[ -n "$values" ]]; then
        local values_file values_tmp
        values_file="$(_helm_repo_path "$values")"
        [[ -f "$values_file" ]] || error "helm_release $release: values file not found: $values_file"
        values_tmp="$(render_to_tmpfile "$values_file")"
        # shellcheck disable=SC2064  # expand now: the path is fixed
        trap "rm -f '$values_tmp'" RETURN
        args+=(--values "$values_tmp")
    fi

    # Chart: a local directory (with its subchart dependencies) or <repo>/<chart>.
    local local_chart=false
    if _helm_chart_is_local "$chart"; then
        local_chart=true
        case "$chart" in
            helm/*) chart="$(_helm_repo_path "$chart")" ;;
        esac
        [[ -f "$chart/Chart.yaml" ]] || error "helm_release $release: no chart at $chart"
    else
        if ! _helm_repo_ensure "${chart%%/*}" "$release"; then
            warning "helm template $release: cannot reach Helm repo ${chart%%/*}; skipping"
            HELM_RENDER_SKIPPED+=("$release")
            return 0
        fi
    fi

    if [[ "$HOMELAB_APPLY_MODE" == "render" ]]; then
        _helm_render "$release" "$chart" "$ns" "$local_chart" "${args[@]}"
        return 0
    fi

    log "Installing $release (Helm chart $chart) into $ns..."
    local install_args=(--namespace "$ns" --create-namespace)
    [[ "$local_chart" == "true" ]] && install_args+=(--dependency-update)
    [[ "$do_wait" == "true" ]] && install_args+=(--wait)
    helm upgrade --install "$release" "$chart" "${install_args[@]}" "${args[@]}"

    if [[ -n "$wait_label" ]]; then
        kubectl wait --for=condition=Ready pods -l "$wait_label" -n "$ns" --timeout="${timeout}s" || \
            warning "$release: pods with $wait_label not Ready after ${timeout}s (continuing)"
    fi
}

# _helm_render <release> <chart> <namespace> <local:true|false> [helm args...]
# `helm template` with the same arguments, into apply_stream. Needs the chart
# repo (or the local chart's dependencies) reachable; when it is not, warn,
# record the release in HELM_RENDER_SKIPPED and carry on.
_helm_render() {
    local release="$1" chart="$2" ns="$3" local_chart="$4"
    shift 4
    # No RETURN trap here: it would replace the caller's (bash keeps one), so
    # every path below cleans up explicitly.
    local out tmp_chart=""
    out="$(mktemp "${TMPDIR:-/tmp}/homelab-helm.XXXXXX.yaml")"

    if [[ "$local_chart" == "true" ]]; then
        # Build dependencies in a copy so the working tree stays clean.
        tmp_chart="$(mktemp -d "${TMPDIR:-/tmp}/homelab-chart.XXXXXX")"
        cp -a "$chart/." "$tmp_chart/"
        if ! (cd "$tmp_chart" && helm dependency build >/dev/null 2>&1); then
            warning "helm template $release: dependency build failed for $chart (no access to its chart repo?); skipping"
            HELM_RENDER_SKIPPED+=("$release")
            rm -rf "$tmp_chart" "$out"
            return 0
        fi
        chart="$tmp_chart"
    fi

    log "Templating $release (Helm chart $chart) for $ns..."
    if helm template "$release" "$chart" --namespace "$ns" --skip-tests "$@" > "$out"; then
        apply_stream "helm/$release.yaml" < "$out"
    else
        warning "helm template $release failed (no access to its chart repo?); skipping"
        HELM_RENDER_SKIPPED+=("$release")
    fi
    rm -f "$out"
    [[ -n "$tmp_chart" ]] && rm -rf "$tmp_chart"
    return 0
}

# _helm_infra_row <release>: the row's columns after the release name
# ("chart namespace options..."), or rc 1 when there is no such row.
_helm_infra_row() {
    local release="$1" row
    for row in "${HELM_INFRA_RELEASES[@]}"; do
        if [[ "${row%% *}" == "$release" ]]; then
            echo "${row#* }"
            return 0
        fi
    done
    return 1
}

# helm_infra_release_args <release>: the row's helm_release arguments
# (chart namespace options...), with the piece's own columns removed.
helm_infra_release_args() {
    local release="$1" line args=() kept=() i
    line="$(_helm_infra_row "$release")" || return 1
    read -r -a args <<< "$line"
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "$_HELM_INFRA_META_OPTS" == *" ${args[i]} "* ]]; then
            i=$((i + 1))   # skip the option and its value
            continue
        fi
        kept+=("${args[i]}")
    done
    echo "${kept[*]}"
}

# helm_infra_field <release> <chart|namespace|toggle|health-label|health-in>
# One column of a row, empty when the row does not set it. This is how
# scripts/lib/health.sh learns where a piece lives, which pods prove it is up
# and which toggle decides whether it should be there at all.
helm_infra_field() {
    local release="$1" field="$2" line args=() i want="--$2"
    line="$(_helm_infra_row "$release")" || return 1
    read -r -a args <<< "$line"
    case "$field" in
        chart)     echo "${args[0]}"; return 0 ;;
        namespace) echo "${args[1]}"; return 0 ;;
    esac
    for ((i = 2; i < ${#args[@]} - 1; i++)); do
        if [[ "${args[i]}" == "$want" ]]; then
            echo "${args[i + 1]}"
            return 0
        fi
    done
    # A piece's pods are the ones the install waits for, unless it says otherwise.
    [[ "$field" == "health-label" ]] && helm_infra_field "$release" wait-label
    return 0
}

helm_infra_release_names() {
    local row
    for row in "${HELM_INFRA_RELEASES[@]}"; do
        echo "${row%% *}"
    done
}

# helm_infra_release <release> [extra helm_release options]
helm_infra_release() {
    local release="$1" row_args=()
    shift
    local line
    line="$(helm_infra_release_args "$release")" || \
        error "helm_infra_release: '$release' is not in HELM_INFRA_RELEASES (scripts/lib/helm.sh)"
    read -r -a row_args <<< "$line"
    helm_release "$release" "${row_args[@]}" "$@"
}

# helm_template_all: every infrastructure release, in render mode. Returns 1
# when any could not be templated; the caller decides whether that is fatal.
helm_template_all() {
    [[ "$HOMELAB_APPLY_MODE" == "render" ]] || error "helm_template_all: HOMELAB_APPLY_MODE must be render"
    HELM_RENDER_SKIPPED=()
    local release
    for release in $(helm_infra_release_names); do
        helm_infra_release "$release"
    done
    if [[ ${#HELM_RENDER_SKIPPED[@]} -gt 0 ]]; then
        warning "helm template skipped: ${HELM_RENDER_SKIPPED[*]}"
        return 1
    fi
    return 0
}
