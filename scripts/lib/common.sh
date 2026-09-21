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
#   log / success / warning / info / error   one log family:
#       LOGFILE=<path>   if set, every line is also appended there, uncoloured
#       LOG_COLOR=true   colour the terminal line (default: plain; the file
#                        copy is never coloured)
#   detect_os / detect_arch   normalised uname
#
# A script that needs different semantics (a non-exiting error()) defines
# its own function after sourcing; the later definition wins. Colour and a
# per-script report file are not reasons to redefine: set the two variables.

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

# _log_line <ansi-colour> <text>: the one place a log line is written.
_log_line() {
    local colour="$1" line
    shift
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "$line" >> "$LOGFILE"
    fi
    if [[ "${LOG_COLOR:-false}" == "true" && -n "$colour" ]]; then
        printf '\033[%sm%s\033[0m\n' "$colour" "$line"
    else
        echo "$line"
    fi
}

log()     { _log_line "0;34" "$*"; }
success() { _log_line "0;32" "✅ $*"; }
warning() { _log_line "1;33" "⚠️  $*"; }
info()    { _log_line "0;36" "$*"; }

error() {
    # To stderr, so a caller that silences stdout (CI, >/dev/null) still sees why.
    _log_line "0;31" "ERROR: $*" >&2
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
