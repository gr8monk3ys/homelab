#!/bin/bash
# shellcheck shell=bash
#
# Rendering seam. Every path that pushes repo manifests at a cluster (the
# installer, disaster recovery, the KinD test harness, CI) goes through here,
# so placeholders are substituted the same way everywhere.
#
# Requires scripts/lib/common.sh to be sourced first.
#
#   homelab_load_config        defaults <- config/homelab.yaml <- env overrides
#   render_stream              stdin -> stdout with placeholders replaced
#   render_file <file>         one file, rendered, to stdout
#   render_to_tmpfile <file>   rendered copy; prints its path (caller removes it)
#   apply_stream               stdin -> the apply adapter chosen by HOMELAB_APPLY_MODE
#   kubectl_apply_rendered_file <file>
#   kubectl_apply_rendered_dir <dir>   non-recursive; namespace.yaml first; skips service.yaml,
#                                      kustomization.yaml and values files; ServiceMonitors only when the CRD exists
#   apply_stream_existing_ns <label>   stdin -> apply_stream, minus documents for namespaces that do
#                                      not exist; never creates a namespace (see its comment)
#   kubectl_apply_rendered_file_existing_ns <file>
#   kubectl_apply_rendered_dir_existing_ns <dir>
#   crd_exists <crd-name>
#
# HOMELAB_APPLY_MODE selects the adapter behind apply_stream:
#   kubectl (default)  kubectl apply -f -
#   render             write rendered manifests under HOMELAB_RENDER_DIR
#                      (no cluster needed; what CI validates with kubeconform)
#
# Placeholders (the values manifests carry in git):
#   homelab.local                      -> DOMAIN
#   admin@homelab.local                -> ADMIN_EMAIL
#   value: "UTC"                       -> TIMEZONE
#   cluster-issuer: "homelab-ca"       -> CERT_MANAGER_CLUSTER_ISSUER
#   https://github.com/your-username/homelab.git -> GITOPS_REPO_URL

if [[ -n "${HOMELAB_RENDER_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_RENDER_SOURCED=1

if [[ -z "${HOMELAB_COMMON_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/common.sh before scripts/lib/render.sh" >&2
    exit 1
fi

CONFIG_FILE="${CONFIG_FILE:-$HOMELAB_DIR/config/homelab.yaml}"
HOMELAB_APPLY_MODE="${HOMELAB_APPLY_MODE:-kubectl}"
HOMELAB_RENDER_DIR="${HOMELAB_RENDER_DIR:-}"

# Capture explicit env overrides before defaults are assigned; env wins over config.
ENVIRONMENT_OVERRIDE="${ENVIRONMENT-}"
DOMAIN_OVERRIDE="${DOMAIN-}"
TIMEZONE_OVERRIDE="${TIMEZONE-}"
ADMIN_EMAIL_OVERRIDE="${ADMIN_EMAIL-}"
CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE="${CERT_MANAGER_CLUSTER_ISSUER-}"
GITOPS_REPO_URL_OVERRIDE="${GITOPS_REPO_URL-}"

ENVIRONMENT="production"
DOMAIN="homelab.local"
TIMEZONE="UTC"
ADMIN_EMAIL="admin@homelab.local"
CERT_MANAGER_CLUSTER_ISSUER="homelab-ca"
GITOPS_REPO_URL="https://github.com/your-username/homelab.git"

homelab_load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        if command -v yq &> /dev/null; then
            local cfg
            cfg="$(yq -r '.homelab.domain // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && DOMAIN="$cfg"
            cfg="$(yq -r '.homelab.timezone // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && TIMEZONE="$cfg"
            cfg="$(yq -r '.homelab.email // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && ADMIN_EMAIL="$cfg"
            cfg="$(yq -r '.homelab.environment // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && ENVIRONMENT="$cfg"
            cfg="$(yq -r '.ingress.cert_manager.cluster_issuer // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && CERT_MANAGER_CLUSTER_ISSUER="$cfg"
            cfg="$(yq -r '.gitops.repo_url // empty' "$CONFIG_FILE" 2>/dev/null || true)"
            [[ -n "$cfg" ]] && GITOPS_REPO_URL="$cfg"
        else
            warning "yq is not installed; skipping config parsing of $CONFIG_FILE"
        fi
    else
        warning "Config file not found at $CONFIG_FILE; using defaults and env overrides."
    fi

    [[ -n "${DOMAIN_OVERRIDE:-}" ]] && DOMAIN="$DOMAIN_OVERRIDE"
    [[ -n "${TIMEZONE_OVERRIDE:-}" ]] && TIMEZONE="$TIMEZONE_OVERRIDE"
    [[ -n "${ADMIN_EMAIL_OVERRIDE:-}" ]] && ADMIN_EMAIL="$ADMIN_EMAIL_OVERRIDE"
    [[ -n "${ENVIRONMENT_OVERRIDE:-}" ]] && ENVIRONMENT="$ENVIRONMENT_OVERRIDE"
    [[ -n "${CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE:-}" ]] && CERT_MANAGER_CLUSTER_ISSUER="$CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE"
    [[ -n "${GITOPS_REPO_URL_OVERRIDE:-}" ]] && GITOPS_REPO_URL="$GITOPS_REPO_URL_OVERRIDE"

    export ENVIRONMENT DOMAIN TIMEZONE ADMIN_EMAIL CERT_MANAGER_CLUSTER_ISSUER GITOPS_REPO_URL
    return 0
}

escape_sed_replacement() {
    # Escape replacement strings for sed (/, \, &).
    printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

render_stream() {
    local admin_email_esc domain_esc timezone_esc issuer_esc gitops_repo_url_esc
    admin_email_esc="$(escape_sed_replacement "$ADMIN_EMAIL")"
    domain_esc="$(escape_sed_replacement "$DOMAIN")"
    timezone_esc="$(escape_sed_replacement "$TIMEZONE")"
    issuer_esc="$(escape_sed_replacement "$CERT_MANAGER_CLUSTER_ISSUER")"
    gitops_repo_url_esc="$(escape_sed_replacement "$GITOPS_REPO_URL")"

    # Order matters for the email only: admin@homelab.local contains the domain
    # placeholder, so it is replaced before the domain. The repo URL does not
    # contain it (homelab.git, not homelab.local); its position is arbitrary.
    sed \
        -e "s/admin@homelab\\.local/${admin_email_esc}/g" \
        -e "s/https:\\/\\/github\\.com\\/your-username\\/homelab\\.git/${gitops_repo_url_esc}/g" \
        -e "s/homelab\\.local/${domain_esc}/g" \
        -e "s/value: \\\"UTC\\\"/value: \\\"${timezone_esc}\\\"/g" \
        -e "s/cert-manager\\.io\\/cluster-issuer: \\\"homelab-ca\\\"/cert-manager.io\\/cluster-issuer: \\\"${issuer_esc}\\\"/g"
}

render_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        error "render_file: file not found: $file"
    fi
    render_stream < "$file"
}

render_to_tmpfile() {
    local file="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/homelab-render.XXXXXX.yaml")"
    render_file "$file" > "$tmp"
    echo "$tmp"
}

crd_exists() {
    local crd="$1"
    if [[ "$HOMELAB_APPLY_MODE" == "render" ]]; then
        return 0
    fi
    kubectl get crd "$crd" >/dev/null 2>&1
}

# Adapter: where a rendered manifest stream goes.
# $1 is a label for the stream (used as the file name in render mode).
apply_stream() {
    local label="${1:-manifests}"
    case "$HOMELAB_APPLY_MODE" in
        kubectl)
            kubectl apply -f -
            ;;
        render)
            [[ -n "$HOMELAB_RENDER_DIR" ]] || error "HOMELAB_RENDER_DIR must be set in render mode"
            local out="$HOMELAB_RENDER_DIR/$label"
            mkdir -p "$(dirname "$out")"
            cat > "$out"
            ;;
        *)
            error "Unknown HOMELAB_APPLY_MODE: $HOMELAB_APPLY_MODE (kubectl|render)"
            ;;
    esac
}

# Label for a repo file in render mode: path relative to the repo root.
_render_label() {
    local file="$1"
    case "$file" in
        "$HOMELAB_DIR"/*) echo "${file#"$HOMELAB_DIR"/}" ;;
        *) echo "$file" ;;
    esac
}

kubectl_apply_rendered_file() {
    local file="$1"
    render_file "$file" | apply_stream "$(_render_label "$file")"
}

# _rendered_dir_stream <dir>: every manifest directly in <dir>, rendered, as one
# stream with namespace.yaml first. Skips service.yaml, kustomization.yaml and
# values files, and ServiceMonitors when the Prometheus Operator CRD is absent.
# Prints nothing (and returns 1) when the directory holds no manifest.
_rendered_dir_stream() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "rendered directory not found: $dir"
    fi

    local files=()
    local has_servicemonitor_crd="false"
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        has_servicemonitor_crd="true"
    fi

    local file base
    while IFS= read -r file; do
        base="$(basename "$file")"
        case "$base" in
            service.yaml|kustomization.yaml|values.yaml|*.values.yaml) continue ;;
            servicemonitor.yaml|servicemonitor.yml)
                [[ "$has_servicemonitor_crd" == "true" ]] || continue ;;
        esac
        files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) -print | sort)

    [[ ${#files[@]} -gt 0 ]] || return 1

    local f
    for f in "${files[@]}"; do
        [[ "$(basename "$f")" == "namespace.yaml" ]] || continue
        render_file "$f"
        echo "---"
    done
    for f in "${files[@]}"; do
        [[ "$(basename "$f")" != "namespace.yaml" ]] || continue
        render_file "$f"
        echo "---"
    done
}

kubectl_apply_rendered_dir() {
    local dir="$1" stream
    if ! stream="$(_rendered_dir_stream "$dir")"; then
        warning "No YAML files found under: $dir"
        return 0
    fi
    printf '%s\n' "$stream" | apply_stream "$(_render_label "$dir")/all.yaml"
}

# apply_stream_existing_ns <label>: apply_stream for a rendered stream that
# names namespaces the installer may not have created (a switched-off
# toggle never created them). It never creates a namespace: a Namespace
# document applies only if that namespace already exists (so labelling one
# cannot conjure it), and a namespaced document only if its namespace exists.
# Cluster-scoped documents always apply. What is skipped is named in a
# warning. Render mode applies everything, so CI still sees every document.
apply_stream_existing_ns() {
    local label="$1" stream
    stream="$(cat)"
    if [[ "$HOMELAB_APPLY_MODE" == "render" ]]; then
        printf '%s\n' "$stream" | apply_stream "$label"
        return 0
    fi

    local existing named ns missing=()
    existing=" $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}') "
    named="$(printf '%s\n' "$stream" | yq -N -r \
        'select(. != null and .kind != null) | select(.kind == "Namespace") | .metadata.name // ""'
        printf '%s\n' "$stream" | yq -N -r \
        'select(. != null and .kind != null) | select(.kind != "Namespace") | .metadata.namespace // ""')"
    for ns in $(printf '%s\n' "$named" | sort -u); do
        [[ "$existing" == *" $ns "* ]] || missing+=("$ns")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warning "$label: skipping documents for namespaces that do not exist: ${missing[*]}"
        warning "Re-run ./setup-v2.sh after enabling the toggles that create them."
    fi

    local regex filtered
    regex="^($(printf '%s' "${existing# }" | sed 's/ $//; s/ /|/g'))\$"
    filtered="$(printf '%s\n' "$stream" | NS_RE="$regex" yq '
        select(. != null and .kind != null) |
        select(
            (.kind == "Namespace" and (.metadata.name | test(strenv(NS_RE)))) or
            (.kind != "Namespace" and (((.metadata.namespace // "") == "") or (.metadata.namespace | test(strenv(NS_RE)))))
        )')"
    if [[ -z "${filtered//[[:space:]-]/}" ]]; then
        warning "$label: nothing to apply yet"
        return 0
    fi
    printf '%s\n' "$filtered" | apply_stream "$label"
}

# kubectl_apply_rendered_file_existing_ns <file> / kubectl_apply_rendered_dir_existing_ns <dir>:
# the file and directory appliers, through apply_stream_existing_ns.
kubectl_apply_rendered_file_existing_ns() {
    local file="$1"
    render_file "$file" | apply_stream_existing_ns "$(_render_label "$file")"
}

kubectl_apply_rendered_dir_existing_ns() {
    local dir="$1" stream
    if ! stream="$(_rendered_dir_stream "$dir")"; then
        warning "No YAML files found under: $dir"
        return 0
    fi
    printf '%s\n' "$stream" | apply_stream_existing_ns "$(_render_label "$dir")/all.yaml"
}
