#!/usr/bin/env bash
set -euo pipefail

# Helper to apply repo kustomize overlays that reference files outside the overlay directory.
# `kubectl apply -k` uses restrictive load rules and will fail for these overlays.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# If repo-local tools are installed (see scripts/install-dev-tools.sh), prefer them.
TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
  PATH="$TOOLS_DIR/bin:$PATH"
fi
if [[ -d "$TOOLS_DIR/venv/bin" ]]; then
  PATH="$TOOLS_DIR/venv/bin:$PATH"
fi
export PATH

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

kustomize build --load-restrictor LoadRestrictionsNone "$OVERLAY_DIR" | kubectl apply -f -
