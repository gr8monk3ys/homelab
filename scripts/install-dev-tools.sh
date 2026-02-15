#!/usr/bin/env bash
set -euo pipefail

# Installs a pinned toolchain into a repo-local directory (no sudo).
#
# This is intended for contributors who want to run ./scripts/ci.sh (and pre-commit)
# without installing system-wide binaries.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TOOLS_DIR="${TOOLS_DIR:-$REPO_ROOT/.tools}"
BIN_DIR="$TOOLS_DIR/bin"
VENV_DIR="$TOOLS_DIR/venv"
TMP_DIR="$TOOLS_DIR/tmp"

FORCE="${FORCE:-false}"

VERSIONS_FILE="${VERSIONS_FILE:-$REPO_ROOT/tools/versions.env}"
if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "ERROR: Missing versions file: $VERSIONS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

detect_os() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux|darwin) echo "$os" ;;
    *) die "Unsupported OS: $os" ;;
  esac
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac
}

ensure_dirs() {
  mkdir -p "$BIN_DIR" "$TMP_DIR"
}

should_install() {
  local path="$1"
  if [[ "$FORCE" == "true" ]]; then
    return 0
  fi
  [[ ! -x "$path" ]]
}

download() {
  local url="$1"
  local out="$2"
  curl -fsSL -o "$out" "$url"
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

install_helm() {
  local os arch url tmpdir tarball extracted
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/helm"; then
    return 0
  fi

  log "Installing helm ${HELM_VERSION} ..."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-helm.XXXXXX")"
  tarball="$tmpdir/helm.tgz"
  url="https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz"

  download "$url" "$tarball"
  tar -xzf "$tarball" -C "$tmpdir"
  extracted="$tmpdir/${os}-${arch}/helm"
  [[ -f "$extracted" ]] || die "helm binary not found after extraction"
  install -m 0755 "$extracted" "$BIN_DIR/helm"
  rm -rf "$tmpdir"
}

install_kind() {
  local os arch url tmp
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/kind"; then
    return 0
  fi

  log "Installing kind ${KIND_VERSION} ..."
  url="https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}"
  tmp="$TMP_DIR/kind.tmp"
  download "$url" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/kind"
}

install_kubectl() {
  local os arch base_url tmp sha expected actual
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/kubectl"; then
    return 0
  fi

  log "Installing kubectl ${KUBECTL_VERSION} ..."
  base_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${os}/${arch}"
  tmp="$TMP_DIR/kubectl.tmp"
  sha="$TMP_DIR/kubectl.sha256"

  download "${base_url}/kubectl" "$tmp"
  download "${base_url}/kubectl.sha256" "$sha"

  expected="$(tr -d '[:space:]' <"$sha")"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${expected}  ${tmp}" | sha256sum -c - >/dev/null
  else
    actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "kubectl checksum verification failed"
  fi

  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/kubectl"
  rm -f "$sha"
}

install_kustomize() {
  local script

  if ! should_install "$BIN_DIR/kustomize"; then
    return 0
  fi

  log "Installing kustomize ${KUSTOMIZE_VERSION} ..."
  script="$TMP_DIR/install_kustomize.sh"
  download "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/kustomize/${KUSTOMIZE_VERSION}/hack/install_kustomize.sh" "$script"
  chmod +x "$script"
  bash "$script" "${KUSTOMIZE_VERSION#v}" "$BIN_DIR" >/dev/null
  [[ -x "$BIN_DIR/kustomize" ]] || die "kustomize install script did not produce $BIN_DIR/kustomize"
}

install_kubeconform() {
  local os arch url tmpdir tarball
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/kubeconform"; then
    return 0
  fi

  log "Installing kubeconform ${KUBECONFORM_VERSION} ..."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-kubeconform.XXXXXX")"
  tarball="$tmpdir/kubeconform.tgz"
  url="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-${os}-${arch}.tar.gz"

  download "$url" "$tarball"
  tar -xzf "$tarball" -C "$tmpdir"
  [[ -f "$tmpdir/kubeconform" ]] || die "kubeconform binary not found after extraction"
  install -m 0755 "$tmpdir/kubeconform" "$BIN_DIR/kubeconform"
  rm -rf "$tmpdir"
}

install_velero() {
  local os arch url tmpdir tarball extracted
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/velero"; then
    return 0
  fi
  [[ -n "${VELERO_CLI_VERSION:-}" ]] || die "VELERO_CLI_VERSION is not set (tools/versions.env)"

  log "Installing velero ${VELERO_CLI_VERSION} ..."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-velero.XXXXXX")"
  tarball="$tmpdir/velero.tgz"
  url="https://github.com/vmware-tanzu/velero/releases/download/${VELERO_CLI_VERSION}/velero-${VELERO_CLI_VERSION}-${os}-${arch}.tar.gz"

  download "$url" "$tarball"
  tar -xzf "$tarball" -C "$tmpdir"
  extracted="$tmpdir/velero-${VELERO_CLI_VERSION}-${os}-${arch}/velero"
  [[ -f "$extracted" ]] || die "velero binary not found after extraction"
  install -m 0755 "$extracted" "$BIN_DIR/velero"
  rm -rf "$tmpdir"
}

install_yq() {
  local os arch url tmp
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/yq"; then
    return 0
  fi

  log "Installing yq ${YQ_VERSION} ..."
  url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${os}_${arch}"
  tmp="$TMP_DIR/yq.tmp"
  download "$url" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/yq"
}

install_age() {
  local os arch url tmpdir tarball age_bin age_keygen_bin
  os="$(detect_os)"
  arch="$(detect_arch)"

  if [[ "$FORCE" != "true" && -x "$BIN_DIR/age" && -x "$BIN_DIR/age-keygen" ]]; then
    return 0
  fi

  log "Installing age ${AGE_VERSION} ..."
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-age.XXXXXX")"
  tarball="$tmpdir/age.tgz"
  url="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${os}-${arch}.tar.gz"

  download "$url" "$tarball"
  tar -xzf "$tarball" -C "$tmpdir"

  age_bin="$(find "$tmpdir" -type f -name age -perm -111 2>/dev/null | head -n 1 || true)"
  age_keygen_bin="$(find "$tmpdir" -type f -name age-keygen -perm -111 2>/dev/null | head -n 1 || true)"
  [[ -n "${age_bin:-}" && -n "${age_keygen_bin:-}" ]] || die "Failed to locate age binaries after extraction"

  install -m 0755 "$age_bin" "$BIN_DIR/age"
  install -m 0755 "$age_keygen_bin" "$BIN_DIR/age-keygen"
  rm -rf "$tmpdir"
}

install_sops() {
  local os arch url tmp
  os="$(detect_os)"
  arch="$(detect_arch)"

  if ! should_install "$BIN_DIR/sops"; then
    return 0
  fi
  [[ -n "${SOPS_VERSION:-}" ]] || die "SOPS_VERSION is not set (tools/versions.env)"

  log "Installing sops ${SOPS_VERSION} ..."
  url="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.${os}.${arch}"
  tmp="$TMP_DIR/sops.tmp"
  download "$url" "$tmp"
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/sops"
}

main() {
  need_cmd curl
  need_cmd tar
  need_cmd install

  ensure_dirs
  install_python_tools
  install_kind
  install_kubectl
  install_helm
  install_kustomize
  install_kubeconform
  install_velero
  install_yq
  install_age
  install_sops

  log "Done."
  log "Add repo-local tools to your PATH (optional):"
  echo "  export PATH=\"$BIN_DIR:$VENV_DIR/bin:\$PATH\""
}

main "$@"
