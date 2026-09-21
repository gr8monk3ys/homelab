#!/bin/bash
# shellcheck shell=bash
#
# Shared preamble for every script in this repo. Source it, don't run it:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"        # from scripts/
#   source "$SCRIPT_DIR/../scripts/lib/common.sh"   # from test/
#
# It provides, once:
#   HOMELAB_DIR / REPO_ROOT   repo root
#   PATH                      repo-local toolchain (.tools/bin, .tools/venv/bin) first
#   tools/versions.env        sourced (HELM_VERSION, *_CHART_VERSION, ...)
#   log / success / warning / info / error   one log family; LOGFILE, if set, is tee'd
#   detect_os / detect_arch   normalised uname
#
# A script that needs different semantics (a non-exiting error(), colours)
# defines its own function after sourcing; the later definition wins.

if [[ -n "${HOMELAB_COMMON_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_COMMON_SOURCED=1

HOMELAB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="${HOMELAB_DIR:-$(cd "$HOMELAB_LIB_DIR/../.." && pwd)}"
REPO_ROOT="$HOMELAB_DIR"
export HOMELAB_DIR REPO_ROOT

# Prefer the pinned, repo-local toolchain (scripts/install-dev-tools.sh).
TOOLS_DIR="${TOOLS_DIR:-$HOMELAB_DIR/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
    PATH="$TOOLS_DIR/bin:$PATH"
fi
if [[ -d "$TOOLS_DIR/venv/bin" ]]; then
    PATH="$TOOLS_DIR/venv/bin:$PATH"
fi
export PATH

# Pinned tool and chart versions. Missing file is fatal: every consumer needs it.
VERSIONS_FILE="${VERSIONS_FILE:-$HOMELAB_DIR/tools/versions.env}"
if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "ERROR: Missing versions file: $VERSIONS_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$line" | tee -a "$LOGFILE"
    else
        echo "$line"
    fi
}

success() { log "✅ $*"; }
warning() { log "⚠️  $*"; }
info()    { log "$*"; }

error() {
    log "ERROR: $*"
    exit 1
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             error "Unsupported architecture: $(uname -m)" ;;
    esac
}

detect_os() {
    case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
        linux)  echo "linux" ;;
        darwin) echo "darwin" ;;
        *)      error "Unsupported OS: $(uname -s)" ;;
    esac
}
