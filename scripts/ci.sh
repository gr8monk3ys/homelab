#!/bin/bash
set -euo pipefail

# Local/CI quality gate for the repo.
#
# In CI, GitHub sets CI=true. In that case, missing tools are treated as errors.

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

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ "${CI:-}" == "true" ]]; then
      die "Missing required command in CI: $cmd"
    fi
    warn "Missing command: $cmd (skipping related checks)"
    return 1
  fi
  return 0
}

run_bash_syntax() {
  log "Bash syntax check (bash -n)..."
  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$REPO_ROOT" -type f -name "*.sh" -print | sort)

  # Include top-level scripts without a .sh suffix.
  for f in "$REPO_ROOT/setup-v2.sh" "$REPO_ROOT/setup.sh" "$REPO_ROOT/setup.sh.deprecated"; do
    [[ -f "$f" ]] && files+=("$f")
  done

  local f
  for f in "${files[@]}"; do
    bash -n "$f"
  done
}

run_shellcheck() {
  if ! require_cmd shellcheck; then
    return 0
  fi

  log "ShellCheck..."
  local files=()
  [[ -f "$REPO_ROOT/setup-v2.sh" ]] && files+=("$REPO_ROOT/setup-v2.sh")

  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$REPO_ROOT/scripts" -type f -name "*.sh" -print | sort)

  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$REPO_ROOT/test" -type f -name "*.sh" -print | sort)

  # ShellCheck: follow sourced files (-x) and ignore info/style findings in CI.
  shellcheck -x -s bash -S warning "${files[@]}"
}

run_yamllint() {
  if ! require_cmd yamllint; then
    return 0
  fi

  log "yamllint..."
  [[ -f "$REPO_ROOT/.yamllint.yaml" ]] || die "Missing .yamllint.yaml"

  yamllint -c "$REPO_ROOT/.yamllint.yaml" \
    "$REPO_ROOT/.github" \
    "$REPO_ROOT/ansible" \
    "$REPO_ROOT/config" \
    "$REPO_ROOT/kubernetes" \
    "$REPO_ROOT/kustomize" \
    "$REPO_ROOT/helm"
}

run_kubeconform() {
  if ! require_cmd kubeconform; then
    return 0
  fi

  log "kubeconform (Kubernetes manifests)..."
  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(
    find "$REPO_ROOT/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) \
      ! -name "values.yaml" \
      ! -name "*.values.yaml" \
      ! -name "*.sops.yaml" \
      ! -name "*.sops.yml" \
      ! -name "*-patch.yaml" \
      ! -name "*-patch.yml" \
      ! -name "kustomization.yaml" \
      ! -name "kustomization.yml" \
      -print | sort
  )

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No Kubernetes YAML manifests found under kubernetes/ (unexpected)"
    return 0
  fi

  kubeconform \
    -strict \
    -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -summary \
    "${files[@]}"
}

run_helm_lint() {
  if ! require_cmd helm; then
    return 0
  fi

  log "helm lint..."
  local chart
  local found=false
  for chart in "$REPO_ROOT"/helm/*; do
    if [[ -f "$chart/Chart.yaml" ]]; then
      found=true
      # Avoid polluting the working tree with downloaded subcharts.
      local tmp_chart
      tmp_chart="$(mktemp -d "${TMPDIR:-/tmp}/homelab-chart.XXXXXX")"
      cp -a "$chart/." "$tmp_chart/"

      if ! (cd "$tmp_chart" && helm dependency build >/dev/null); then
        if [[ "${CI:-}" == "true" ]]; then
          die "helm dependency build failed for $chart"
        fi
        warn "helm dependency build failed for $chart (continuing with lint)"
      fi

      helm lint "$tmp_chart"
      rm -rf "$tmp_chart"
    fi
  done
  if [[ "$found" != "true" ]]; then
    warn "No Helm charts found under helm/*"
  fi
}

run_helm_remote_smoke() {
  if ! require_cmd helm; then
    return 0
  fi

  # This repo uses several third-party Helm charts with pinned versions.
  # Templating them in CI catches schema/template breakages early.
  if [[ "${CI:-}" != "true" && "${HELM_REMOTE_SMOKE:-false}" != "true" ]]; then
    log "helm template smoke (remote charts) skipped (set HELM_REMOTE_SMOKE=true to run locally)"
    return 0
  fi

  local versions_file="$REPO_ROOT/tools/versions.env"
  if [[ ! -f "$versions_file" ]]; then
    warn "Missing $versions_file; skipping helm template smoke"
    return 0
  fi
  # shellcheck disable=SC1090
  source "$versions_file"

  local required_vars=(
    TRAEFIK_CHART_VERSION
    CERT_MANAGER_CHART_VERSION
    EXTERNAL_SECRETS_CHART_VERSION
    KUBE_PROMETHEUS_STACK_CHART_VERSION
    METALLB_CHART_VERSION
    KYVERNO_CHART_VERSION
    VELERO_CHART_VERSION
    EXTERNAL_DNS_CHART_VERSION
    PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION
  )
  local missing=()
  local v
  for v in "${required_vars[@]}"; do
    if [[ -z "${!v:-}" ]]; then
      missing+=("$v")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    if [[ "${CI:-}" == "true" ]]; then
      die "Missing required version vars in tools/versions.env: ${missing[*]}"
    fi
    warn "Missing version vars (skipping helm template smoke): ${missing[*]}"
    return 0
  fi

  log "helm template smoke (remote charts)..."

  # Ensure repos exist (idempotent), then template pinned versions.
  helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null 2>&1 || true
  helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm template traefik traefik/traefik \
    --version "$TRAEFIK_CHART_VERSION" \
    --namespace traefik-system \
    --values "$REPO_ROOT/kubernetes/ingress/traefik/values.yaml" \
    >/dev/null

  helm template cert-manager jetstack/cert-manager \
    --version "$CERT_MANAGER_CHART_VERSION" \
    --namespace cert-manager \
    --set installCRDs=true \
    >/dev/null

  helm template external-secrets external-secrets/external-secrets \
    --version "$EXTERNAL_SECRETS_CHART_VERSION" \
    --namespace external-secrets \
    --set installCRDs=true \
    >/dev/null

  helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --version "$KUBE_PROMETHEUS_STACK_CHART_VERSION" \
    --namespace monitoring \
    --values "$REPO_ROOT/kubernetes/monitoring/prometheus/values.yaml" \
    >/dev/null

  helm template metallb metallb/metallb \
    --version "$METALLB_CHART_VERSION" \
    --namespace metallb-system \
    >/dev/null

  helm template kyverno kyverno/kyverno \
    --version "$KYVERNO_CHART_VERSION" \
    --namespace kyverno \
    --values "$REPO_ROOT/kubernetes/policy/kyverno/values.yaml" \
    >/dev/null

  helm template velero vmware-tanzu/velero \
    --version "$VELERO_CHART_VERSION" \
    --namespace velero \
    --values "$REPO_ROOT/kubernetes/backup/velero/values.yaml" \
    >/dev/null

  helm template external-dns external-dns/external-dns \
    --version "$EXTERNAL_DNS_CHART_VERSION" \
    --namespace external-dns \
    --values "$REPO_ROOT/kubernetes/dns/external-dns/values.yaml" \
    >/dev/null

  helm template blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
    --version "$PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION" \
    --namespace monitoring \
    --values "$REPO_ROOT/kubernetes/monitoring/blackbox-exporter/values.yaml" \
    >/dev/null
}

run_kustomize_build() {
  if ! require_cmd kustomize; then
    return 0
  fi

  log "kustomize build (overlays)..."
  if [[ ! -d "$REPO_ROOT/kustomize/overlays" ]]; then
    warn "No kustomize overlays directory found (kustomize/overlays)"
  else
    local overlay
    local found=false
    for overlay in "$REPO_ROOT"/kustomize/overlays/*; do
      if [[ -f "$overlay/kustomization.yaml" ]]; then
        found=true
        kustomize build --load-restrictor LoadRestrictionsNone "$overlay" >/dev/null
      fi
    done
    if [[ "$found" != "true" ]]; then
      warn "No overlays found under kustomize/overlays/*"
    fi
  fi

  # Validate additional kustomizations used directly by scripts and/or GitOps.
  local argocd_apps_core="$REPO_ROOT/kubernetes/gitops/argocd/apps/core"
  local argocd_apps_full="$REPO_ROOT/kubernetes/gitops/argocd/apps/full"
  if [[ -f "$argocd_apps_core/kustomization.yaml" ]]; then
    log "kustomize build (argocd apps: core)..."
    kustomize build --load-restrictor LoadRestrictionsNone "$argocd_apps_core" >/dev/null
  fi
  if [[ -f "$argocd_apps_full/kustomization.yaml" ]]; then
    log "kustomize build (argocd apps: full)..."
    kustomize build --load-restrictor LoadRestrictionsNone "$argocd_apps_full" >/dev/null
  fi
}

run_docs_check() {
  log "Docs check..."
  local required=("README.md" "CLAUDE.md")
  local missing=()
  local f
  for f in "${required[@]}"; do
    if [[ ! -f "$REPO_ROOT/$f" ]]; then
      missing+=("$f")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    die "Missing required docs: ${missing[*]}"
  fi
}

main() {
  cd "$REPO_ROOT"

  run_bash_syntax
  run_shellcheck
  run_yamllint
  run_kubeconform
  run_helm_lint
  run_helm_remote_smoke
  run_kustomize_build
  run_docs_check

  log "All checks passed."
}

main "$@"
