#!/usr/bin/env bash
# Assertions on the k3d cluster config (k3d/homelab.yaml) as
# scripts/k3d-cluster.sh renders it: the bulk bind source follows
# BULK_HOST_PATH (spaces included), the node path stays /mnt/bulk (the path
# every bulk PV names), the image follows tools/versions.env, and paths k3d
# cannot bind are refused. No Docker, no cluster; needs yq.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"
require_cmd yq

SCRIPT="$HOMELAB_DIR/scripts/k3d-cluster.sh"
CONFIG="$HOMELAB_DIR/k3d/homelab.yaml"

FAILURES=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

expect_eq() {
    local want="$1" got="$2" what="$3"
    if [[ "$got" == "$want" ]]; then ok "$what"; else fail "$what: want '$want', got '$got'"; fi
}

render() { BULK_HOST_PATH="$1" "$SCRIPT" render 2>/dev/null; }

out="$(render "/mnt/raid/50 Dev/52 homelab")"
expect_eq "/mnt/raid/50 Dev/52 homelab:/mnt/bulk" "$(yq '.volumes[0].volume' <<<"$out")" "a path with spaces is bound as one volume"
expect_eq "server:0" "$(yq '.volumes[0].nodeFilters[0]' <<<"$out")" "the bind goes to the labelled node"
expect_eq "rancher/k3s:${K3S_IMAGE_TAG}" "$(yq '.image' <<<"$out")" "the image follows K3S_IMAGE_TAG"

out="$(render "/srv/bulk/")"
expect_eq "/srv/bulk:/mnt/bulk" "$(yq '.volumes[0].volume' <<<"$out")" "a trailing slash is dropped"

out="$(BULK_HOST_PATH='' "$SCRIPT" render 2>/dev/null)"
expect_eq "/mnt/bulk:/mnt/bulk" "$(yq '.volumes[0].volume' <<<"$out")" "unset BULK_HOST_PATH means /mnt/bulk"

if render "relative/path" >/dev/null; then fail "a relative path is refused"; else ok "a relative path is refused"; fi
if render "/mnt/a:b" >/dev/null; then fail "a path with ':' is refused"; else ok "a path with ':' is refused"; fi

# The template itself, for `k3d cluster create --config k3d/homelab.yaml` by hand.
expect_eq "rancher/k3s:${K3S_IMAGE_TAG}" "$(yq '.image' "$CONFIG")" "the template's image matches tools/versions.env"
expect_eq "homelab.io/bulk=true" "$(yq '.options.k3s.nodeLabels[] | select(.nodeFilters[0] == "server:0") | .label' "$CONFIG")" "the bulk node carries homelab.io/bulk=true"
expect_eq "--disable=traefik" "$(yq '.options.k3s.extraArgs[].arg' "$CONFIG" | grep -x -- '--disable=traefik')" "the K3s Traefik is off (the installer brings its own)"

if [[ "$FAILURES" -ne 0 ]]; then
    echo "k3d config: $FAILURES assertion(s) failed"
    exit 1
fi
echo "k3d config: all assertions passed"
