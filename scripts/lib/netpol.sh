#!/bin/bash
# shellcheck shell=bash
#
# Per-namespace NetworkPolicy module.
#
# The interface is one line in a service descriptor:
#
#   networkPolicies: [default-deny, allow-dns, allow-ingress, allow-monitoring, allow-same-namespace]
#
# Each name is a policy template under kubernetes/security/network-policies/
# templates/<name>.yaml: a NetworkPolicy whose metadata.namespace is the
# literal PLACEHOLDER_NAMESPACE. The implementation renders every listed
# template for the service's namespace and pushes the result through the
# same apply_stream adapter every other manifest takes (kubectl or render
# mode), so a descriptor is the one place a service's isolation is defined.
#
#   install_service_network_policies <service-dir> <namespace>
#       Reads networkPolicies: from <service-dir>/service.yaml. No key or an
#       empty list is a no-op. An unknown template name is fatal (error).
#   netpol_templates_list
#       Template names, one per line: the vocabulary a descriptor may use.
#
# Seam: the caller (install_service in services.sh) passes the directory and
# the namespace it already resolved; this module never re-reads toggles or
# talks to a cluster directly, so it works unchanged in render mode.
#
# Requires scripts/lib/common.sh, scripts/lib/render.sh and
# scripts/lib/services.sh (for service_field and _render_label).

if [[ -n "${HOMELAB_NETPOL_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_NETPOL_SOURCED=1

if [[ -z "${HOMELAB_SERVICES_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/services.sh before scripts/lib/netpol.sh" >&2
    exit 1
fi

NETPOL_TEMPLATES_DIR="${NETPOL_TEMPLATES_DIR:-$HOMELAB_DIR/kubernetes/security/network-policies/templates}"
NETPOL_NAMESPACE_PLACEHOLDER="PLACEHOLDER_NAMESPACE"

netpol_templates_list() {
    local f
    for f in "$NETPOL_TEMPLATES_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        basename "$f" .yaml
    done
}

# _netpol_template_check <name>: the template exists, or error (fatal).
# Prints nothing on success so callers never need to redirect it; error()
# logs to stdout, and a redirect would swallow the message.
_netpol_template_check() {
    local name="$1"
    # Names are file stems; reject anything that could escape the directory.
    [[ "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || \
        error "networkPolicies: invalid template name '$name' (lowercase letters, digits and dashes)"
    [[ -f "$NETPOL_TEMPLATES_DIR/$name.yaml" ]] || \
        error "networkPolicies: unknown template '$name' (known: $(netpol_templates_list | tr '\n' ' '))"
}

# _netpol_render_template <name> <namespace>: rendered policy on stdout.
# Placeholders go through render_file like any manifest; the namespace is the
# one substitution this module adds.
_netpol_render_template() {
    _netpol_template_check "$1"
    render_file "$NETPOL_TEMPLATES_DIR/$1.yaml" | sed "s/${NETPOL_NAMESPACE_PLACEHOLDER}/$2/g"
}

# install_service_network_policies <service-dir> <namespace>
install_service_network_policies() {
    local dir="$1" ns="$2" desc
    [[ -d "$dir" ]] || error "install_service_network_policies: no such directory: $dir"
    [[ -n "$ns" ]] || error "install_service_network_policies: namespace is required"
    desc="$dir/service.yaml"
    [[ -f "$desc" ]] || error "install_service_network_policies: missing descriptor: $desc"

    local kind
    kind="$(yq -r '.networkPolicies | type' "$desc" 2>/dev/null || echo '!!null')"
    case "$kind" in
        '!!null'|null|'') return 0 ;;
        '!!seq'|array) ;;
        *) error "$desc: networkPolicies must be a list of template names (got $kind)" ;;
    esac

    local templates=() name
    while IFS= read -r name; do
        [[ -n "$name" ]] && templates+=("$name")
    done < <(yq -r '.networkPolicies[]' "$desc" 2>/dev/null)
    [[ ${#templates[@]} -gt 0 ]] || return 0

    # Validate every name before rendering anything: the render below runs in
    # a pipeline subshell where error() could not stop the caller, and an
    # early check leaves no half-applied set behind.
    for name in "${templates[@]}"; do
        _netpol_template_check "$name"
    done

    log "  network policies for $ns: ${templates[*]}"
    {
        for name in "${templates[@]}"; do
            _netpol_render_template "$name" "$ns"
            echo "---"
        done
    } | apply_stream "$(_render_label "$dir")/network-policies.yaml"
}
