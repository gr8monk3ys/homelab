#!/bin/bash
set -euo pipefail

# The homelab k3d cluster on a Linux Docker host (k3d/homelab.yaml).
#
#   ./scripts/k3d-cluster.sh render     print the rendered k3d config; no Docker
#   ./scripts/k3d-cluster.sh check      render, then check the host: Docker
#                                       reachable, cgroup v2, bulk path layout
#   ./scripts/k3d-cluster.sh create     check, then `k3d cluster create`
#
# Settings (environment):
#   BULK_HOST_PATH   host directory bound at /mnt/bulk in the node (default
#                    /mnt/bulk). It must already hold data/, immich/ and
#                    garage/: the bulk PVs use hostPath type Directory. Spaces
#                    are fine, e.g.
#                    BULK_HOST_PATH="/mnt/raid/50 Dev/52 homelab"
#   K3D_CONFIG       template (default k3d/homelab.yaml)
#   K3S_IMAGE_TAG    rancher/k3s tag (default from tools/versions.env)
#
# The cluster is named in the template (homelab: context k3d-homelab).
# Bring-up order: docs/runbooks/native-linux-host.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

K3D_CONFIG="${K3D_CONFIG:-$HOMELAB_DIR/k3d/homelab.yaml}"
BULK_HOST_PATH="${BULK_HOST_PATH:-/mnt/bulk}"
BULK_NODE_PATH="/mnt/bulk"
BULK_SUBDIRS=(data immich garage)

usage() {
    sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

# k3d_render: the template with the bulk bind source and the K3s image set.
# Only the first volume (the bulk bind) is rewritten.
k3d_render() {
    require_cmd yq "scripts/install-dev-tools.sh or mise"
    [[ -f "$K3D_CONFIG" ]] || error "k3d config not found: $K3D_CONFIG"
    case "$BULK_HOST_PATH" in
        /*) ;;
        *) error "BULK_HOST_PATH must be absolute: $BULK_HOST_PATH" ;;
    esac
    # k3d splits a volume spec on ':', so a colon in the path cannot be bound.
    [[ "$BULK_HOST_PATH" != *:* ]] || error "BULK_HOST_PATH must not contain ':': $BULK_HOST_PATH"
    local bulk="${BULK_HOST_PATH%/}"
    [[ -n "$bulk" ]] || bulk="/"
    K3D_BULK_BIND="${bulk}:${BULK_NODE_PATH}" \
    K3D_IMAGE="rancher/k3s:${K3S_IMAGE_TAG:?K3S_IMAGE_TAG missing from tools/versions.env}" \
        yq '.volumes[0].volume = strenv(K3D_BULK_BIND) | .image = strenv(K3D_IMAGE)' "$K3D_CONFIG"
}

# k3d_check_host: what must hold before a cluster is created. Never writes.
k3d_check_host() {
    local failed=0 sub
    require_cmd docker
    require_cmd k3d "mise use -g k3d@latest"
    require_cmd kubectl

    if ! docker info >/dev/null 2>&1; then
        warning "docker info failed: is the Docker service running and is $USER in the docker group?"
        failed=1
    elif [[ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" != "2" ]]; then
        warning "Docker reports cgroup v1; K3s 1.35+ refuses it (pass --kubelet-arg=fail-cgroupv1=false or move to cgroup v2)"
    fi

    if [[ "$BULK_HOST_PATH" == /run/media/* ]]; then
        warning "BULK_HOST_PATH is under /run/media (a udisks automount): it is absent after a reboot until someone logs in, and the node then binds an empty directory. Mount the disk from /etc/fstab instead (docs/runbooks/native-linux-host.md)."
    fi
    if [[ ! -d "$BULK_HOST_PATH" ]]; then
        warning "BULK_HOST_PATH is not a directory: $BULK_HOST_PATH"
        failed=1
    else
        for sub in "${BULK_SUBDIRS[@]}"; do
            if [[ ! -d "$BULK_HOST_PATH/$sub" ]]; then
                warning "missing $BULK_HOST_PATH/$sub (the bulk PVs need it to exist)"
                failed=1
            fi
        done
    fi

    if [[ "$failed" -ne 0 ]]; then
        error "host check failed (see warnings above)"
    fi
    success "host check passed (bulk: $BULK_HOST_PATH -> $BULK_NODE_PATH)"
}

k3d_create() {
    local name rendered
    name="$(yq '.metadata.name' "$K3D_CONFIG")"
    if k3d cluster get "$name" >/dev/null 2>&1; then
        error "k3d cluster '$name' already exists; delete it deliberately first (k3d cluster delete $name) or use it as is"
    fi
    rendered="$(mktemp "${TMPDIR:-/tmp}/k3d-homelab.XXXXXX.yaml")"
    # shellcheck disable=SC2064  # expand now: the path is fixed
    trap "rm -f '$rendered'" EXIT
    k3d_render > "$rendered"
    log "Creating k3d cluster '$name' (bulk: $BULK_HOST_PATH)..."
    k3d cluster create --config "$rendered"
    kubectl get nodes -L homelab.io/bulk
    success "Cluster '$name' is up; next: ./setup-v2.sh (docs/runbooks/native-linux-host.md)"
}

main() {
    case "${1:-}" in
        render) k3d_render ;;
        check)  k3d_render >/dev/null; k3d_check_host ;;
        create) k3d_render >/dev/null; k3d_check_host; k3d_create ;;
        *)      usage ;;
    esac
}

main "$@"
