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
#   name: paperless-ngx            # must equal the directory name
#   namespace: paperless-ngx
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
#     - apply: promtail-deployment.yaml
#       when: INSTALL_PROMTAIL         # env var that must be "true"
#
# A Helm-chart-managed service says so instead of listing steps:
#   kind: helm                     # default: manifests
#   chart: helm/nextcloud          # repo-relative chart dir, or <repo>/<chart> (repo in HELM_REPOS)
#   release: nextcloud             # optional; default: name
#   values: helm/nextcloud/values.yaml   # optional; repo-relative, rendered like a manifest
#   versionVar: FOO_CHART_VERSION  # optional; the tools/versions.env variable pinning the chart
#
# Rules the implementation applies to every service:
#   1. namespace.yaml is applied first.
#   2. steps run in order; a wait is best-effort (warns, continues).
#   3. every other *.yaml in the directory is applied afterwards, sorted,
#      except service.yaml, values files, and ServiceMonitors when the
#      Prometheus Operator CRD is absent.
#   4. the descriptor's `networkPolicies:` templates are rendered into the
#      namespace (scripts/lib/netpol.sh).
#   A kind: helm service replaces 2 and 3 with one helm_release
#   (scripts/lib/helm.sh); its directory holds only the descriptor and an
#   optional namespace.yaml.
#
# Requires scripts/lib/common.sh and scripts/lib/render.sh; sources
# scripts/lib/helm.sh itself.

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

SERVICES_DIR="${SERVICES_DIR:-$HOMELAB_DIR/kubernetes/services}"

# Group -> toggle. Order here is the install order.
SERVICE_GROUPS=(core media network dev content ai productivity home communication monitoring logging)

# Services with optin: true install only when named here (space or comma separated), or "all".
OPTIN_SERVICES="${OPTIN_SERVICES:-}"

service_group_toggle() {
    case "$1" in
        core)          echo "true" ;;
        media)         echo "${ENABLE_MEDIA_SERVICES:-true}" ;;
        network)       echo "${ENABLE_NETWORK_SERVICES:-true}" ;;
        dev)           echo "${ENABLE_DEV_SERVICES:-false}" ;;
        content)       echo "${ENABLE_CONTENT_SERVICES:-true}" ;;
        ai)            echo "${ENABLE_AI_SERVICES:-false}" ;;
        productivity)  echo "${ENABLE_PRODUCTIVITY_SERVICES:-true}" ;;
        home)          echo "${ENABLE_HOME_SERVICES:-false}" ;;
        communication) echo "${ENABLE_COMMUNICATION_SERVICES:-false}" ;;
        monitoring)    echo "${INSTALL_MONITORING:-true}" ;;
        logging)       echo "${INSTALL_LOGGING:-false}" ;;
        *)             echo "unknown" ;;
    esac
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
install_service() {
    local name dir desc ns
    dir="$(service_dir "$1")"
    desc="$dir/service.yaml"
    [[ -d "$dir" ]] || error "install_service: no such service directory: $dir"
    [[ -f "$desc" ]] || error "install_service: missing descriptor: $desc"

    name="$(service_field "$dir" '.name')"
    ns="$(service_field "$dir" '.namespace')"
    [[ "$name" == "$(basename "$dir")" ]] || error "install_service: $desc names '$name' but lives in $(basename "$dir")"
    [[ -n "$ns" ]] || error "install_service: $desc has no namespace"

    log "Installing service $name (namespace $ns)..."

    local has_servicemonitor_crd="false"
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        has_servicemonitor_crd="true"
    fi

    # 1. Namespace first.
    if [[ -f "$dir/namespace.yaml" ]]; then
        kubectl_apply_rendered_file "$dir/namespace.yaml"
    fi

    # kind: helm: the chart is the whole install; then isolation as usual.
    if [[ "$(service_field "$dir" '.kind' manifests)" == "helm" ]]; then
        _install_service_helm "$dir" "$name" "$ns"
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
    local rest=() base
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

    if [ ${#rest[@]} -gt 0 ]; then
        {
            for file in "${rest[@]}"; do
                render_file "$file"
                echo "---"
            done
        } | apply_stream "$(_render_label "$dir")/rest.yaml"
    fi

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
            # One service per subshell: install_service calls error() on a bad
            # descriptor, an unreachable chart repo or a rejected manifest, and
            # a single service must not take the rest of the catalogue with it.
            # Failures are collected and reported by services_report_failures.
            if ! (install_service "$name"); then
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

# services_check: every directory has a valid descriptor, every step file exists.
services_check() {
    local d name group desc failures=0 count i file when kind chart values
    for d in "$SERVICES_DIR"/*/; do
        name="$(basename "$d")"
        desc="$d/service.yaml"
        if [[ ! -f "$desc" ]]; then
            echo "MISSING descriptor: kubernetes/services/$name/service.yaml"
            failures=$((failures + 1))
            continue
        fi
        if [[ "$(service_field "$name" '.name')" != "$name" ]]; then
            echo "BAD name in $desc (expected $name)"
            failures=$((failures + 1))
        fi
        if [[ -z "$(service_field "$name" '.namespace')" ]]; then
            echo "BAD namespace in $desc"
            failures=$((failures + 1))
        fi
        group="$(service_field "$name" '.group')"
        if [[ "$(service_group_toggle "$group")" == "unknown" ]]; then
            echo "BAD group '$group' in $desc (known: ${SERVICE_GROUPS[*]})"
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

# ---------------------------------------------------------------------------
# GitOps: the ArgoCD app-of-apps is generated from the same catalogue, so the
# imperative installer and the GitOps path can never list different services.
# `scripts/services.sh argocd` writes the files; CI checks they are current.
# ---------------------------------------------------------------------------

# Group -> ArgoCD AppProject.
service_argocd_project() {
    local name="$1" group explicit
    explicit="$(service_field "$name" '.project')"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    group="$(service_field "$name" '.group')"
    case "$group" in
        media)                              echo "homelab-media" ;;
        ai)                                 echo "homelab-ai" ;;
        productivity|content|communication) echo "homelab-productivity" ;;
        *)                                  echo "homelab-infrastructure" ;;
    esac
}

# Installed by default: group on by default and not opt-in.
service_is_default() {
    local name="$1" group
    group="$(service_field "$name" '.group')"
    [[ "$(service_field "$name" '.optin' false)" != "true" ]] || return 1
    case "$group" in
        core|media|network|content|productivity|monitoring) return 0 ;;
        *) return 1 ;;
    esac
}

# services_argocd_applications <default|optional>: Application manifests to stdout.
services_argocd_applications() {
    local subset="$1" name ns project prio wave
    echo "---"
    echo "# GENERATED by scripts/services.sh argocd from kubernetes/services/*/service.yaml."
    echo "# Do not edit; change the descriptor and regenerate. CI fails if this is stale."
    echo "# repoURL is replaced by the kustomization's homelab-gitops-config ConfigMap."
    for name in $(services_all); do
        if [[ "$subset" == "default" ]]; then
            service_is_default "$name" || continue
        else
            service_is_default "$name" && continue
        fi
        ns="$(service_field "$name" '.namespace')"
        project="$(service_argocd_project "$name")"
        prio="$(service_field "$name" '.priority' 50)"
        wave=$(( (prio - 50) / 10 ))
        cat <<YAML
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $name
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
    homelab.service/group: $(service_field "$name" '.group')
  annotations:
    argocd.argoproj.io/sync-wave: "$wave"
spec:
  project: $project
  source:
YAML
        _services_argocd_source "$name"
        cat <<YAML
  destination:
    server: https://kubernetes.default.svc
    namespace: $ns
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
YAML
    done
}

# _services_argocd_source <name>: the Application's spec.source body (4-space
# indented). A manifests service is its directory; a kind: helm service is
# its chart (a repo-relative path, or a chart in one of HELM_REPOS) with the
# descriptor's values file.
_services_argocd_source() {
    local name="$1" excludes count i when file
    local kind chart release values version_var
    kind="$(service_field "$name" '.kind' manifests)"
    if [[ "$kind" != "helm" ]]; then
        # Files behind a `when:` toggle are installer-only; ArgoCD never applies them.
        excludes="service.yaml,values.yaml,*.values.yaml"
        count="$(yq -r '.steps | length' "$(service_descriptor "$name")" 2>/dev/null || echo 0)"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        for ((i = 0; i < count; i++)); do
            when="$(service_field "$name" ".steps[$i].when")"
            file="$(service_field "$name" ".steps[$i].apply")"
            [[ -n "$when" ]] && excludes+=",$file"
        done
        cat <<YAML
    repoURL: https://github.com/your-username/homelab.git
    targetRevision: HEAD
    path: kubernetes/services/$name
    directory:
      exclude: '{$excludes}'
YAML
        return 0
    fi

    chart="$(service_field "$name" '.chart')"
    release="$(service_field "$name" '.release' "$name")"
    values="$(service_field "$name" '.values')"
    version_var="$(service_field "$name" '.versionVar')"
    if _helm_chart_is_local "$chart"; then
        cat <<YAML
    repoURL: https://github.com/your-username/homelab.git
    targetRevision: HEAD
    path: ${chart#./}
YAML
    else
        cat <<YAML
    repoURL: $(helm_repo_url "${chart%%/*}")
    chart: ${chart#*/}
    targetRevision: ${!version_var:-"*"}
YAML
    fi
    echo "    helm:"
    echo "      releaseName: $release"
    if [[ -n "$values" ]]; then
        # valueFiles are relative to the chart path.
        case "$values" in
            "${chart#./}"/*) echo "      valueFiles: [${values#"${chart#./}"/}]" ;;
            *)               echo "      valueFiles: [$values]" ;;
        esac
    fi
}

# services_argocd_projects: AppProjects whose destinations follow the catalogue.
services_argocd_projects() {
    local project description name extra
    echo "---"
    echo "# GENERATED by scripts/services.sh argocd from kubernetes/services/*/service.yaml."
    echo "# Do not edit; change the descriptor and regenerate. CI fails if this is stale."
    for project in homelab-infrastructure homelab-media homelab-ai homelab-productivity homelab-security; do
        case "$project" in
            homelab-infrastructure) description="Homelab infrastructure components" ;;
            homelab-media)          description="Media and entertainment services" ;;
            homelab-ai)             description="AI/LLM services" ;;
            homelab-productivity)   description="Productivity, content and communication services" ;;
            homelab-security)       description="Security and authentication services" ;;
        esac
        cat <<YAML
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: $project
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
spec:
  description: $description
  sourceRepos:
  - https://github.com/your-username/homelab.git
  destinations:
YAML
        if [[ "$project" == "homelab-infrastructure" ]]; then
            echo "  - namespace: '*'"
            echo "    server: https://kubernetes.default.svc"
        else
            # Static, non-catalogue namespaces each project also owns.
            case "$project" in
                homelab-security) extra="crowdsec" ;;
                *)                extra="" ;;
            esac
            for name in $extra; do
                echo "  - namespace: $name"
                echo "    server: https://kubernetes.default.svc"
            done
            for name in $(services_all); do
                [[ "$(service_argocd_project "$name")" == "$project" ]] || continue
                echo "  - namespace: $(service_field "$name" '.namespace')"
                echo "    server: https://kubernetes.default.svc"
            done
        fi
        if [[ "$project" == "homelab-infrastructure" ]]; then
            cat <<'YAML'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
YAML
        fi
        cat <<'YAML'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
  orphanedResources:
    warn: true
YAML
    done
}

ARGOCD_DIR="${ARGOCD_DIR:-$HOMELAB_DIR/kubernetes/gitops/argocd}"

# services_argocd_write: regenerate the checked-in GitOps files.
services_argocd_write() {
    mkdir -p "$ARGOCD_DIR/apps/services"
    services_argocd_applications default  > "$ARGOCD_DIR/apps/services/default.yaml"
    services_argocd_applications optional > "$ARGOCD_DIR/apps/services/optional.yaml"
    services_argocd_projects              > "$ARGOCD_DIR/projects.yaml"
}

# services_argocd_check: fail if the checked-in files differ from the catalogue.
services_argocd_check() {
    local tmp rc=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/homelab-argocd.XXXXXX")"
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -rf '$tmp'" RETURN
    ARGOCD_DIR="$tmp" services_argocd_write
    diff -u "$ARGOCD_DIR/apps/services/default.yaml"  "$tmp/apps/services/default.yaml"  || rc=1
    diff -u "$ARGOCD_DIR/apps/services/optional.yaml" "$tmp/apps/services/optional.yaml" || rc=1
    diff -u "$ARGOCD_DIR/projects.yaml"               "$tmp/projects.yaml"               || rc=1
    if [[ "$rc" -ne 0 ]]; then
        echo "ArgoCD files are stale; run ./scripts/services.sh argocd" >&2
        return 1
    fi
    echo "argocd check: generated files are current"
}
