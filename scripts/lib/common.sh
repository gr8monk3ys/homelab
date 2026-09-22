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
#   require_cmd <cmd> [hint]  the one dependency check; exits unless
#                             REQUIRE_CMD_SOFT=true, which warns and returns 1
#   detect_os / detect_arch   normalised uname
#   run_isolated <cmd...>     run cmd with errexit on in a subshell; sets
#                             RUN_ISOLATED_STATUS; call as a plain statement
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

# run_isolated <command> [args...]: run a command in a subshell with errexit on,
# so ANY failing command inside it fails it -- not only an explicit error() --
# without ending the caller. Sets RUN_ISOLATED_STATUS to the exit status and
# returns 0. Use it for "one failure must not take the rest down" loops.
#
# Call it as a plain statement. Never write `if ! (cmd)` or `cmd || ...` for
# this: bash ignores errexit inside if/while conditions, `!` and &&/|| lists,
# all the way down into subshells and functions, so `if ! (install_service x)`
# ran install_service with errexit OFF and reported a failed Helm release as
# installed. run_isolated detects being called in such a context and refuses.
run_isolated() {
    local restore=""
    [[ $- == *e* ]] && restore=1
    set +e
    # Probe: where bash ignores errexit, this subshell survives `false`.
    ( set -e; false; exit 0 )
    if [[ $? -eq 0 ]]; then
        [[ -z "$restore" ]] || set -e
        error "run_isolated $1: called inside a condition (if/!/&&/||), where bash ignores errexit; call it as a plain statement"
    fi
    ( set -e; "$@" )
    # shellcheck disable=SC2034  # read by the caller
    RUN_ISOLATED_STATUS=$?
    [[ -z "$restore" ]] || set -e
    return 0
}

# require_cmd <command> [hint]
#
# The one dependency check. <command> must be on PATH; if it is not, this
# exits through error(), with the optional hint appended in parentheses.
#
#   REQUIRE_CMD_SOFT=true   turn the exit into a warning and `return 1`, for a
#                           caller that skips an optional check instead of
#                           failing (scripts/ci.sh outside CI, the Helm section
#                           of scripts/validate-setup.sh). Set it per call:
#                           `REQUIRE_CMD_SOFT=true require_cmd helm || return 0`.
require_cmd() {
    local cmd="$1" hint="${2:-}" msg
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    msg="Missing required command: $cmd"
    [[ -n "$hint" ]] && msg="$msg ($hint)"
    if [[ "${REQUIRE_CMD_SOFT:-false}" == "true" ]]; then
        warning "$msg"
        return 1
    fi
    error "$msg"
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
