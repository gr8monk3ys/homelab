#!/bin/bash
set -euo pipefail

# Local/CI quality gate for the repo.
#
# In CI, GitHub sets CI=true. In that case, missing tools are treated as errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

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
      ! -name "service.yaml" \
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

run_services_check() {
  # The service catalogue is the installer's interface, so CI tests through it:
  # every kubernetes/services/<name>/ has a valid service.yaml, and every service
  # renders (with non-default placeholders) into manifests kubeconform accepts.
  if ! require_cmd yq; then
    return 0
  fi

  log "services check (descriptors)..."
  "$REPO_ROOT/scripts/services.sh" check

  log "argocd check (generated app-of-apps is current)..."
  "$REPO_ROOT/scripts/services.sh" argocd --check

  log "secrets check (producer vs ExternalSecret consumers)..."
  "$REPO_ROOT/scripts/secrets-check.sh"

  if ! require_cmd kubeconform; then
    return 0
  fi

  log "services render + kubeconform (through install_service)..."
  local render_dir
  render_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-render.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: the path is fixed
  trap "rm -rf '$render_dir'" RETURN
  DOMAIN="ci.example.test" \
    ADMIN_EMAIL="ci@example.test" \
    TIMEZONE="Europe/Amsterdam" \
    CERT_MANAGER_CLUSTER_ISSUER="letsencrypt-staging" \
    "$REPO_ROOT/scripts/services.sh" render "$render_dir" >/dev/null

  # Infrastructure manifests go through the same seam (placeholders included).
  log "infrastructure render (through render_stream)..."
  local f rel
  while IFS= read -r f; do
    rel="${f#"$REPO_ROOT"/}"
    mkdir -p "$render_dir/$(dirname "$rel")"
    DOMAIN="ci.example.test" ADMIN_EMAIL="ci@example.test" TIMEZONE="Europe/Amsterdam" \
      CERT_MANAGER_CLUSTER_ISSUER="letsencrypt-staging" \
      "$REPO_ROOT/scripts/services.sh" render-file "$f" > "$render_dir/$rel"
  done < <(
    find "$REPO_ROOT/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) \
      ! -path "$REPO_ROOT/kubernetes/services/*" \
      ! -path "$REPO_ROOT/kubernetes/secrets/sops/*" \
      ! -name "values.yaml" ! -name "*.values.yaml" ! -name "*-patch.yaml" \
      ! -name "kustomization.yaml" -print | sort
  )

  if grep -rl "homelab\.local" "$render_dir" >/dev/null; then
    grep -rl 'homelab\.local' "$render_dir" | sed "s|^$render_dir/|  |"
    die "Rendered manifests above still contain the homelab.local placeholder"
  fi

  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$render_dir" -type f -name "*.yaml" -print | sort)

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

  # Every third-party chart the installer pins (HELM_INFRA_RELEASES in
  # scripts/lib/helm.sh) is templated in render mode, through the same
  # helm_release the installer uses, so CI never keeps its own chart list.
  if [[ "${CI:-}" != "true" && "${HELM_REMOTE_SMOKE:-false}" != "true" ]]; then
    log "helm template smoke (remote charts) skipped (set HELM_REMOTE_SMOKE=true to run locally)"
    return 0
  fi

  log "helm template smoke (remote charts, through helm_release)..."
  source "$SCRIPT_DIR/lib/render.sh"
  source "$SCRIPT_DIR/lib/helm.sh"

  local render_dir
  render_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-helm-smoke.XXXXXX")"
  # shellcheck disable=SC2064  # expand now: the path is fixed
  trap "rm -rf '$render_dir'" RETURN
  homelab_load_config >/dev/null

  # helm_template_all warns and skips a chart it cannot fetch; here that is a failure in CI.
  if ! (HOMELAB_APPLY_MODE=render HOMELAB_RENDER_DIR="$render_dir" helm_template_all); then
    if [[ "${CI:-}" == "true" ]]; then
      die "helm template failed for one or more charts (see warnings above)"
    fi
    warn "helm template skipped one or more charts (chart repos unreachable?)"
  fi
}

run_kustomize_build() {
  if ! require_cmd kustomize; then
    return 0
  fi

  # The only kustomizations in the repo are the ArgoCD app-of-apps and the
  # SOPS secret store (docs/adr/0003-no-kustomize-overlay.md). The SOPS one
  # needs the KSOPS exec plugin and an age key, so it is not built here.
  local dir
  for dir in \
    "$REPO_ROOT/kubernetes/gitops/argocd/apps/core" \
    "$REPO_ROOT/kubernetes/gitops/argocd/apps/full"; do
    if [[ -f "$dir/kustomization.yaml" ]]; then
      log "kustomize build (${dir#"$REPO_ROOT"/})..."
      kustomize build --load-restrictor LoadRestrictionsNone "$dir" >/dev/null
    fi
  done
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
  run_services_check
  run_helm_lint
  run_helm_remote_smoke
  run_kustomize_build
  run_docs_check

  log "All checks passed."
}

main "$@"
