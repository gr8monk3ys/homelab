#!/bin/bash
# shellcheck shell=bash
#
# The service catalogue and the one way to install a service.
#
# A service is a directory under kubernetes/services/<name>/ that carries a
# service.yaml descriptor. The descriptor is the interface; this file is the
# implementation. Nothing else in the repo needs to know how a service is
# ordered, waited on, or gated.
#
#   namespace: paperless-ngx       # the service's name is its directory name
#   group: productivity            # see SERVICE_GROUPS below
#   optin: true                    # optional; only installs when named in OPTIN_SERVICES
#   priority: 50                   # optional; lower installs first within a group
#   project: homelab-security      # optional; ArgoCD AppProject (default: by group)
#   url: docs                      # optional; host prefix under DOMAIN, for the access summary
#   description: Document management
#   steps:                         # optional; ordered files with waits and conditions
#     - apply: postgres-deployment.yaml
#       wait: app=paperless-postgres   # kubectl wait pods -l <wait> in the namespace
#       timeout: 300                   # seconds; default 300
#     - apply: alloy-daemonset.yaml
#       when: INSTALL_ALLOY            # env var that must be "true"
#
# A Helm-chart-managed service says so instead of listing steps:
#   kind: helm                     # default: manifests
#   chart: helm/nextcloud          # repo-relative chart dir, or <repo>/<chart> (repo in HELM_REPOS)
#   release: nextcloud             # optional; default: name
#   values: helm/nextcloud/values.yaml   # optional; repo-relative, rendered like a manifest
#   versionVar: FOO_CHART_VERSION  # optional; the tools/versions.env variable pinning the chart
#
# Rules the implementation applies to every service:
#   1. namespace.yaml is applied first, through pod_security_mode_filter:
#      the file carries the namespace's Pod Security labels at their
#      enforce-mode levels, and POD_SECURITY_MODE relaxes or removes them.
#   2. steps run in order; a wait is best-effort (warns, continues).
#   3. every other *.yaml in the directory is applied afterwards, sorted,
#      except service.yaml, values files, and ServiceMonitors when the
#      Prometheus Operator CRD is absent. This is where everything else that
#      lives in the service's namespace goes (resourcequota.yaml, pdb.yaml,
#      networkpolicies.yaml): a service's namespace carries everything
#      applied into it (docs/adr/0009), so none of it waits on a central file.
#   4. the descriptor's `networkPolicies:` templates are rendered into the
#      namespace (scripts/lib/netpol.sh).
#   A kind: helm service replaces 2 with one helm_release
#   (scripts/lib/helm.sh), then applies 3 and 4 as usual.
#
# Requires scripts/lib/common.sh and scripts/lib/render.sh; sources
# scripts/lib/helm.sh itself.
#
# The catalogue is also the source of the generated ArgoCD app-of-apps, but
# that generation lives in scripts/lib/argocd.sh, which depends on this file
# and not the other way round; the install path here never calls into it.

if [[ -n "${HOMELAB_SERVICES_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_SERVICES_SOURCED=1

if [[ -z "${HOMELAB_RENDER_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/render.sh before scripts/lib/services.sh" >&2
    exit 1
fi
# shellcheck source=scripts/lib/helm.sh
source "$HOMELAB_LIB_DIR/helm.sh"

# Pod Security Admission mode, for every namespace the installer labels:
#   audit    enforce=privileged; audit and warn at the levels the file names
#            (the safe-migration default: nothing is rejected, violations are
#            reported; switch to enforce once the warnings are clean)
#   enforce  the labels exactly as the file names them
#   off      no Pod Security labels at all
# The levels themselves live with each namespace (a service's namespace.yaml;
# kubernetes/security/pod-security-standards.yaml for infrastructure).
POD_SECURITY_MODE="${POD_SECURITY_MODE:-audit}"

# pod_security_mode_filter: stdin -> stdout. Rewrites the Pod Security labels
# on every Namespace document for POD_SECURITY_MODE; every other document
# passes through unchanged. This is not a render placeholder (docs/adr/0008):
# it applies only to Namespace documents, and only on the way to a cluster.
pod_security_mode_filter() {
    case "$POD_SECURITY_MODE" in
        enforce)
            cat
            ;;
        audit)
            yq '(select(.kind == "Namespace" and .metadata.labels["pod-security.kubernetes.io/enforce"] != null) | .metadata.labels) |= (
                    .["pod-security.kubernetes.io/audit"] = (.["pod-security.kubernetes.io/audit"] // .["pod-security.kubernetes.io/enforce"]) |
                    .["pod-security.kubernetes.io/warn"] = (.["pod-security.kubernetes.io/warn"] // .["pod-security.kubernetes.io/enforce"]) |
                    .["pod-security.kubernetes.io/enforce"] = "privileged")'
            ;;
        off)
            yq '(select(.kind == "Namespace" and .metadata.labels != null) | .metadata.labels) |=
                    with_entries(select(.key | test("^pod-security\\.kubernetes\\.io/") | not))'
            ;;
        *)
            error "Invalid POD_SECURITY_MODE: $POD_SECURITY_MODE (expected: off|audit|enforce)"
            ;;
    esac
}

SERVICES_DIR="${SERVICES_DIR:-$HOMELAB_DIR/kubernetes/services}"

# The service groups: one row per group, and the only place a group is
# defined. Columns:
#
#   <group> <toggle variable|-> <default true|false> <ArgoCD AppProject>
#
# The toggle variable is the environment variable that switches the group on
# or off; "-" means the group has none and is always on (core). The default
# applies when that variable is unset: it is what setup-v2.sh seeds its
# ENABLE_*/INSTALL_* group toggles with, and what `service_is_default`
# (scripts/lib/argocd.sh) means by "installed by default". The project is the
# AppProject a service of this group lands in unless its descriptor names one.
#
# Row order is the install order: setup-v2.sh's group phases run top to bottom.
SERVICE_GROUPS=(
    "core          -                             true  homelab-infrastructure"
    "media         ENABLE_MEDIA_SERVICES         true  homelab-media"
    "network       ENABLE_NETWORK_SERVICES       true  homelab-infrastructure"
    "dev           ENABLE_DEV_SERVICES           false homelab-infrastructure"
    "content       ENABLE_CONTENT_SERVICES       true  homelab-productivity"
    "ai            ENABLE_AI_SERVICES            false homelab-ai"
    "productivity  ENABLE_PRODUCTIVITY_SERVICES  true  homelab-productivity"
    "home          ENABLE_HOME_SERVICES          false homelab-infrastructure"
    "communication ENABLE_COMMUNICATION_SERVICES false homelab-productivity"
    "monitoring    INSTALL_MONITORING            true  homelab-infrastructure"
    "logging       INSTALL_LOGGING               false homelab-infrastructure"
)

# Services with optin: true install only when named here (space or comma separated), or "all".
OPTIN_SERVICES="${OPTIN_SERVICES:-}"

# _service_group_row <group>: the row, or rc 1 for a group with no row.
_service_group_row() {
    local group="$1" row
    for row in "${SERVICE_GROUPS[@]}"; do
        if [[ "${row%% *}" == "$group" ]]; then
            echo "$row"
            return 0
        fi
    done
    return 1
}

# service_group_names: every group, in install order, one per line.
service_group_names() {
    local row
    for row in "${SERVICE_GROUPS[@]}"; do
        echo "${row%% *}"
    done
}

# service_group_field <group> <toggle|default|project>: one column, empty for
# a group with no row.
service_group_field() {
    local row toggle default project
    row="$(_service_group_row "$1")" || return 0
    read -r _ toggle default project <<< "$row"
    case "$2" in
        toggle)  echo "$toggle" ;;
        default) echo "$default" ;;
        project) echo "$project" ;;
        *)       error "service_group_field: unknown column '$2'" ;;
    esac
}

# service_group_toggle <group>: "true"/"false" as the environment and the
# table's default say, or "unknown" for a group with no row.
service_group_toggle() {
    local row var default
    row="$(_service_group_row "$1")" || { echo "unknown"; return 0; }
    read -r _ var default _ <<< "$row"
    if [[ "$var" == "-" ]]; then
        echo "$default"
    else
        echo "${!var:-$default}"
    fi
}

# service_group_toggles_apply: give every group's toggle variable its
# effective value, so a caller can read $ENABLE_MEDIA_SERVICES directly
# instead of restating the default. setup-v2.sh calls this at startup.
service_group_toggles_apply() {
    local row group var
    for row in "${SERVICE_GROUPS[@]}"; do
        read -r group var _ _ <<< "$row"
        [[ "$var" == "-" ]] && continue
        printf -v "$var" '%s' "$(service_group_toggle "$group")"
    done
}

# service_group_toggles_summary: "<group>=<true|false> ..." for a log line.
service_group_toggles_summary() {
    local group out=""
    for group in $(service_group_names); do
        out+="${out:+ }$group=$(service_group_toggle "$group")"
    done
    echo "$out"
}

service_dir() {
    local name="$1"
    case "$name" in
        */*) echo "${name%/}" ;;
        *)   echo "$SERVICES_DIR/$name" ;;
    esac
}

service_descriptor() {
    echo "$(service_dir "$1")/service.yaml"
}

# service_field <name> <yq expression> [default]
service_field() {
    local desc value
    desc="$(service_descriptor "$1")"
    value="$(yq -r "$2 // \"\"" "$desc" 2>/dev/null || true)"
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "${3:-}"
    else
        echo "$value"
    fi
}

# All service names that carry a descriptor, sorted.
services_all() {
    local d
    for d in "$SERVICES_DIR"/*/; do
        [[ -f "$d/service.yaml" ]] || continue
        basename "$d"
    done
}

# Names in a group, by priority then name.
services_in_group() {
    local group="$1" name
    for name in $(services_all); do
        if [[ "$(service_field "$name" '.group')" == "$group" ]]; then
            printf '%03d %s\n' "$(service_field "$name" '.priority' 50)" "$name"
        fi
    done | sort | awk '{print $2}'
}

service_is_optin_selected() {
    local name="$1" sel
    [[ "$OPTIN_SERVICES" == "all" ]] && return 0
    for sel in ${OPTIN_SERVICES//,/ }; do
        [[ "$sel" == "$name" ]] && return 0
    done
    return 1
}

# Should this service install under the current toggles?
service_enabled() {
    local name="$1" group toggle
    group="$(service_field "$name" '.group')"
    toggle="$(service_group_toggle "$group")"
    [[ "$toggle" == "true" ]] || return 1
    if [[ "$(service_field "$name" '.optin' false)" == "true" ]]; then
        service_is_optin_selected "$name" || return 1
    fi
    return 0
}

# install_service <name|dir>
# Renders and applies one service per the rules above. In render mode
# (HOMELAB_APPLY_MODE=render) nothing touches a cluster.
# _install_service_rest <dir> <has-servicemonitor-crd> "<stepped files>": rule 3,
# every other manifest in the service directory, in one apply.
_install_service_rest() {
    local dir="$1" has_servicemonitor_crd="$2" stepped="$3"
    local rest=() file base
    while IFS= read -r file; do
        base="$(basename "$file")"
        case "$base" in
            namespace.yaml|service.yaml|values.yaml|*.values.yaml) continue ;;
            servicemonitor.yaml|servicemonitor.yml)
                [[ "$has_servicemonitor_crd" == "true" ]] || continue ;;
        esac
        [[ "$stepped" == *" $base "* ]] && continue
        rest+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) -print | sort)

    [[ ${#rest[@]} -gt 0 ]] || return 0
    {
        for file in "${rest[@]}"; do
            render_file "$file"
            echo "---"
        done
    } | apply_stream "$(_render_label "$dir")/rest.yaml"
}

install_service() {
    local name dir desc ns
    dir="$(service_dir "$1")"
    desc="$dir/service.yaml"
    [[ -d "$dir" ]] || error "install_service: no such service directory: $dir"
    [[ -f "$desc" ]] || error "install_service: missing descriptor: $desc"

    name="$(basename "$dir")"
    ns="$(service_field "$dir" '.namespace')"
    [[ -n "$ns" ]] || error "install_service: $desc has no namespace"

    log "Installing service $name (namespace $ns)..."

    local has_servicemonitor_crd="false"
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        has_servicemonitor_crd="true"
    fi

    # 1. Namespace first, its Pod Security labels set for POD_SECURITY_MODE.
    if [[ -f "$dir/namespace.yaml" ]]; then
        render_file "$dir/namespace.yaml" | pod_security_mode_filter | \
            apply_stream "$(_render_label "$dir/namespace.yaml")"
    fi

    # kind: helm: the chart replaces the steps; the rest of the directory
    # (quota, PDB, policies) and isolation follow as usual.
    if [[ "$(service_field "$dir" '.kind' manifests)" == "helm" ]]; then
        _install_service_helm "$dir" "$name" "$ns"
        _install_service_rest "$dir" "$has_servicemonitor_crd" " "
        if declare -F install_service_network_policies >/dev/null; then
            install_service_network_policies "$dir" "$ns"
        fi
        success "Service $name installed"
        return 0
    fi

    # 2. Ordered steps.
    local stepped=" "
    local count i file when wait timeout
    count="$(yq -r '.steps | length' "$desc" 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    for ((i = 0; i < count; i++)); do
        file="$(service_field "$dir" ".steps[$i].apply")"
        when="$(service_field "$dir" ".steps[$i].when")"
        wait="$(service_field "$dir" ".steps[$i].wait")"
        timeout="$(service_field "$dir" ".steps[$i].timeout" 300)"
        [[ -n "$file" ]] || error "install_service: $desc step $i has no 'apply'"
        [[ -f "$dir/$file" ]] || error "install_service: $desc step $i names missing file $file"
        stepped+="$file "

        if [[ -n "$when" && "$HOMELAB_APPLY_MODE" != "render" && "${!when:-false}" != "true" ]]; then
            log "  skipping $file ($when is not true)"
            continue
        fi
        kubectl_apply_rendered_file "$dir/$file"
        if [[ -n "$wait" && "$HOMELAB_APPLY_MODE" != "render" ]]; then
            kubectl wait --for=condition=Ready pods -l "$wait" -n "$ns" --timeout="${timeout}s" || \
                warning "$name: pods with $wait not Ready after ${timeout}s (continuing)"
        fi
    done

    # 3. Everything else, sorted.
    _install_service_rest "$dir" "$has_servicemonitor_crd" "$stepped"

    # 4. Namespace isolation, from the descriptor's networkPolicies: list
    #    (scripts/lib/netpol.sh, when sourced).
    if declare -F install_service_network_policies >/dev/null; then
        install_service_network_policies "$dir" "$ns"
    fi

    success "Service $name installed"
}

# _install_service_helm <dir> <name> <namespace>: the helm_release call a
# kind: helm descriptor describes.
_install_service_helm() {
    local dir="$1" name="$2" ns="$3"
    local chart release values version_var args=()
    chart="$(service_field "$dir" '.chart')"
    release="$(service_field "$dir" '.release' "$name")"
    values="$(service_field "$dir" '.values')"
    version_var="$(service_field "$dir" '.versionVar')"
    [[ -n "$chart" ]] || error "install_service: $dir/service.yaml is kind: helm but has no chart"
    [[ -n "$values" ]] && args+=(--values "$values")
    [[ -n "$version_var" ]] && args+=(--version-var "$version_var")
    helm_release "$release" "$chart" "$ns" "${args[@]}"
}

# install_service_group <group>: every enabled service in the group, in order.
install_service_group() {
    local group="$1" name
    if [[ "$(service_group_toggle "$group")" != "true" ]]; then
        warning "Group '$group' is disabled; skipping its services."
        return 0
    fi
    for name in $(services_in_group "$group"); do
        if service_enabled "$name"; then
            # One service per subshell, errexit on: any failure inside it (a bad
            # descriptor, an unreachable chart repo, a rejected manifest, a
            # failed Helm release) fails that service, and a single service must
            # not take the rest of the catalogue with it. Failures are collected
            # and reported by services_report_failures. See run_isolated for why
            # this is not `if ! (install_service ...)`.
            run_isolated install_service "$name"
            if [[ "$RUN_ISOLATED_STATUS" -ne 0 ]]; then
                warning "Service $name failed to install; continuing with the rest."
                SERVICE_INSTALL_FAILURES+=("$name")
            fi
        else
            log "Skipping opt-in service $name (add it to OPTIN_SERVICES to install)"
        fi
    done
}

# Services that install_service_group could not install, in order.
SERVICE_INSTALL_FAILURES=()

# services_report_failures: name what failed, once, at the end of a run.
# Returns 1 when anything failed, so a caller can make it fatal if it wants.
services_report_failures() {
    [[ ${#SERVICE_INSTALL_FAILURES[@]} -eq 0 ]] && return 0
    warning "These services did not install: ${SERVICE_INSTALL_FAILURES[*]}"
    warning "Re-run ./scripts/services.sh install <name> after fixing the cause, or set its toggle to false."
    return 1
}

# service_groups_check: every group a descriptor names has a row in
# SERVICE_GROUPS. Prints one line per offender and returns the count, so a
# group added to a descriptor but not to the table cannot pass CI.
service_groups_check() {
    local name group failures=0
    for name in $(services_all); do
        group="$(service_field "$name" '.group')"
        if ! _service_group_row "$group" >/dev/null; then
            echo "BAD group '$group' in $(service_descriptor "$name") (known: $(service_group_names | tr '\n' ' ' | sed 's/ *$//'))"
            failures=$((failures + 1))
        fi
    done
    return "$failures"
}

# services_check: every directory has a valid descriptor, every step file exists.
# _services_check_rollout <dir>: a single-replica Deployment that mounts a
# ReadWriteOnce claim must use strategy Recreate (ReadWriteOnce restricts a
# volume to one node, not one pod: a rolling update would run two writers on
# one node, or stall when the new pod lands on another). A claim mounted by
# several Deployments needs all but one of them to carry a required
# podAffinity, so they land on the same node. A claim not declared in the
# service directory is treated as ReadWriteOnce. Prints one line per problem.
_services_check_rollout() {
    local dir="$1" name f claims rwx="" line dep replicas strategy affinity claim
    name="$(basename "$dir")"
    for f in "$dir"/*.yaml; do
        rwx+=" $(yq -N -r 'select(.kind == "PersistentVolumeClaim") | select(.spec.accessModes | contains(["ReadWriteOnce"]) | not) | .metadata.name' "$f" 2>/dev/null | tr '\n' ' ')"
    done
    declare -A mounters=() unpinned=()
    local reported=" "
    for f in "$dir"/*.yaml; do
        while IFS=' ' read -r dep replicas strategy affinity claims; do
            [[ -n "$dep" && -n "$claims" ]] || continue
            for claim in ${claims//,/ }; do
                [[ "$rwx" == *" $claim "* ]] && continue
                mounters[$claim]=$(( ${mounters[$claim]:-0} + 1 ))
                [[ "$affinity" -gt 0 ]] || unpinned[$claim]=$(( ${unpinned[$claim]:-0} + 1 ))
                if [[ "$replicas" -le 1 && "$strategy" != "Recreate" && "$reported" != *" $dep "* ]]; then
                    echo "BAD rollout in kubernetes/services/$name/$(basename "$f"): Deployment $dep mounts ReadWriteOnce claim $claim without strategy: Recreate"
                    reported+="$dep "
                fi
            done
        done < <(yq -N -r 'select(.kind == "Deployment") | [
                    .metadata.name,
                    (.spec.replicas // 1),
                    (.spec.strategy.type // "RollingUpdate"),
                    ((.spec.template.spec.affinity.podAffinity.requiredDuringSchedulingIgnoredDuringExecution // []) | length),
                    ([.spec.template.spec.volumes[]? | select(has("persistentVolumeClaim")) | .persistentVolumeClaim.claimName] | join(","))
                 ] | join(" ")' "$f" 2>/dev/null)
    done
    for claim in "${!mounters[@]}"; do
        if [[ "${mounters[$claim]}" -gt 1 && "${unpinned[$claim]:-0}" -gt 1 ]]; then
            echo "BAD sharing in kubernetes/services/$name: ReadWriteOnce claim $claim is mounted by ${mounters[$claim]} Deployments, ${unpinned[$claim]} of them without a required podAffinity to co-locate"
        fi
    done
    return 0
}

# _services_check_security_locality: nothing under kubernetes/security/ may name
# a service's namespace; what lives in a service namespace lives in the service
# directory (docs/adr/0009). The per-namespace policy templates are exempt.
_services_check_security_locality() {
    local service_ns f hit
    service_ns=" $(for d in "$SERVICES_DIR"/*/; do service_field "$(basename "$d")" '.namespace'; done | tr '\n' ' ') "
    while IFS= read -r f; do
        for hit in $(yq -N -r 'select(. != null and .kind != null) | (select(.kind == "Namespace") | .metadata.name), (select(.kind != "Namespace") | .metadata.namespace // "")' "$f" 2>/dev/null | sort -u); do
            if [[ "$service_ns" == *" $hit "* ]]; then
                echo "BAD locality in ${f#"$HOMELAB_DIR"/}: names service namespace '$hit'; move it into that service's directory (docs/adr/0009)"
            fi
        done
    done < <(find "$HOMELAB_DIR/kubernetes/security" -name '*.yaml' -not -path '*/network-policies/templates/*' | sort)
    return 0
}

services_check() {
    local d name desc failures=0 count i file when kind chart values
    for d in "$SERVICES_DIR"/*/; do
        name="$(basename "$d")"
        desc="$d/service.yaml"
        if [[ ! -f "$desc" ]]; then
            echo "MISSING descriptor: kubernetes/services/$name/service.yaml"
            failures=$((failures + 1))
            continue
        fi
        if [[ -z "$(service_field "$name" '.namespace')" ]]; then
            echo "BAD namespace in $desc"
            failures=$((failures + 1))
        fi
        kind="$(service_field "$name" '.kind' manifests)"
        case "$kind" in
            manifests) ;;
            helm)
                chart="$(service_field "$name" '.chart')"
                if [[ -z "$chart" ]]; then
                    echo "BAD kind: helm in $desc: no chart"
                    failures=$((failures + 1))
                elif _helm_chart_is_local "$chart"; then
                    if [[ ! -f "$(_helm_repo_path "$chart")/Chart.yaml" ]]; then
                        echo "BAD chart in $desc: no Chart.yaml at $chart"
                        failures=$((failures + 1))
                    fi
                elif ! helm_repo_url "${chart%%/*}" >/dev/null; then
                    echo "BAD chart in $desc: repo '${chart%%/*}' is not in HELM_REPOS (scripts/lib/helm.sh)"
                    failures=$((failures + 1))
                fi
                values="$(service_field "$name" '.values')"
                if [[ -n "$values" && ! -f "$(_helm_repo_path "$values")" ]]; then
                    echo "BAD values in $desc: file '$values' not found"
                    failures=$((failures + 1))
                fi
                ;;
            *)
                echo "BAD kind '$kind' in $desc (manifests|helm)"
                failures=$((failures + 1))
                ;;
        esac
        count="$(yq -r '.steps | length' "$desc" 2>/dev/null || echo 0)"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        for ((i = 0; i < count; i++)); do
            file="$(service_field "$name" ".steps[$i].apply")"
            if [[ -z "$file" || ! -f "$d/$file" ]]; then
                echo "BAD step $i in $desc: file '$file' not found"
                failures=$((failures + 1))
            fi
            when="$(service_field "$name" ".steps[$i].when")"
            if [[ -n "$when" && ! "$when" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                echo "BAD step $i in $desc: when '$when' is not an environment variable name"
                failures=$((failures + 1))
            fi
        done
        # Isolation is a decision every descriptor makes explicitly: a list of
        # templates, or [] with a comment saying why the namespace stays open.
        if [[ "$(yq -r '.networkPolicies | type' "$desc" 2>/dev/null)" != "!!seq" ]]; then
            echo "MISSING networkPolicies: list in $desc (use [] and a comment to leave the namespace open)"
            failures=$((failures + 1))
        fi
    done
    local problems
    for d in "$SERVICES_DIR"/*/; do
        problems="$(_services_check_rollout "$d")"
        if [[ -n "$problems" ]]; then
            echo "$problems"
            failures=$((failures + $(printf '%s\n' "$problems" | wc -l)))
        fi
    done
    problems="$(_services_check_security_locality)"
    if [[ -n "$problems" ]]; then
        echo "$problems"
        failures=$((failures + $(printf '%s\n' "$problems" | wc -l)))
    fi
    local group_failures=0
    service_groups_check || group_failures=$?
    failures=$((failures + group_failures))
    if [[ "$failures" -ne 0 ]]; then
        echo "services_check: $failures problem(s)"
        return 1
    fi
    echo "services_check: $(services_all | wc -l | tr -d ' ') services OK"
}

# services_table: one line per service for docs and the access summary.
services_table() {
    local name group optin url desc
    printf '%-18s %-14s %-6s %-12s %s\n' NAME GROUP OPTIN URL DESCRIPTION
    for name in $(services_all); do
        group="$(service_field "$name" '.group')"
        optin="$(service_field "$name" '.optin' false)"
        url="$(service_field "$name" '.url')"
        desc="$(service_field "$name" '.description')"
        printf '%-18s %-14s %-6s %-12s %s\n' "$name" "$group" "$optin" "${url:--}" "$desc"
    done
}
