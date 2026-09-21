#!/usr/bin/env bash
set -euo pipefail

# Installs a pinned toolchain into a repo-local directory (no sudo).
#
# This is intended for contributors who want to run ./scripts/ci.sh (and pre-commit)
# without installing system-wide binaries. The binaries come from the table in
# scripts/lib/tools.sh; the linters come from pip into a venv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/tools.sh"

TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
BIN_DIR="$TOOLS_DIR/bin"
VENV_DIR="$TOOLS_DIR/venv"
TMP_DIR="$TOOLS_DIR/tmp"

FORCE="${FORCE:-false}"

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$TMP_DIR"
}

install_python_tools() {
  log "Installing Python tools into $VENV_DIR ..."

  need_cmd python3
  if [[ "$FORCE" == "true" && -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
  fi

  if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
  fi

  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -m pip install -U pip >/dev/null
  pip install \
    "pre-commit==${PRE_COMMIT_VERSION}" \
    "yamllint==${YAMLLINT_VERSION}" \
    "shellcheck-py==${SHELLCHECK_PY_VERSION}" >/dev/null
  deactivate || true
}

main() {
  local rc=0
  need_cmd curl
  need_cmd tar
  need_cmd install

  ensure_dirs
  install_python_tools
  tools_install || rc=$?

  log "Done."
  log "Add repo-local tools to your PATH (optional):"
  echo "  export PATH=\"$BIN_DIR:$VENV_DIR/bin:\$PATH\""
  return "$rc"
}

main "$@"
