#!/usr/bin/env bash
set -euo pipefail

# Helper to apply repo kustomize overlays that reference files outside the overlay directory.
# `kubectl apply -k` uses restrictive load rules and will fail for these overlays.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/render.sh"

OVERLAY_DIR="${1:-}"
if [ -z "$OVERLAY_DIR" ]; then
  echo "Usage: $0 <overlay-dir>" >&2
  echo "Example: $0 kustomize/overlays/production" >&2
  exit 2
fi

if ! command -v kustomize &> /dev/null; then
  echo "ERROR: kustomize is not installed. Run ./scripts/install-dev-tools.sh or ./setup-v2.sh (installs a pinned kustomize)." >&2
  exit 1
fi

if ! command -v kubectl &> /dev/null; then
  echo "ERROR: kubectl is not installed. Install it or run ./scripts/install-dev-tools.sh." >&2
  exit 1
fi

homelab_load_config
kustomize build --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" | render_stream | apply_stream "$(basename "$OVERLAY_DIR").yaml"
