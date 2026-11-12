#!/usr/bin/env bash
# Offline checks for the Flux tree. CI runs this; run it before a push.
#
#   1. yamllint over the repo.
#   2. kubeconform over clusters/homelab/*.yaml.
#   3. For every path a Flux Kustomization in clusters/homelab names:
#      kustomize build | flux envsubst --strict (with cluster-settings) | kubeconform.
#   4. No plain Secret: a Secret lives only in a SOPS-encrypted *.sops.yaml.
#
# Needs: yamllint, kustomize, kubeconform, flux (the CLI, for envsubst).
set -euo pipefail

cd "$(dirname "$0")/.."

cluster_dir=clusters/homelab
schema_catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

for tool in yamllint kustomize kubeconform flux; do
  command -v "$tool" >/dev/null || { echo "validate: $tool is not installed" >&2; exit 1; }
done

kubeconform_run() {
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location "$schema_catalog" \
    "$@"
}

echo "== yamllint"
yamllint -c .yamllint.yaml .

# cluster-settings.yaml data become the variables Flux substitutes at
# reconcile time. Lines look like:   DOMAIN: "home.arpa"
while IFS= read -r line; do
  key=${line%%:*}
  value=${line#*: }
  value=${value%\"}
  value=${value#\"}
  export "$key=$value"
done < <(sed -n '/^data:/,$p' "$cluster_dir/cluster-settings.yaml" | grep -E '^  [A-Z][A-Z0-9_]*: ' | sed 's/^  //')

echo "== kubeconform $cluster_dir"
mapfile -t cluster_files < <(find "$cluster_dir" -name '*.yaml' ! -name kustomization.yaml | sort)
kubeconform_run "${cluster_files[@]}"

# The paths of the Kustomizations in clusters/homelab that read this repo
# (the flux-system GitRepository). gateway-api-crds reads another source.
mapfile -t flux_paths < <(
  find "$cluster_dir" -maxdepth 1 -name '*.yaml' -exec grep -h -E '^  path: \./' {} + |
    sed -E 's/^  path: \.\///' | sort -u
)
[[ ${#flux_paths[@]} -gt 0 ]] || { echo "validate: no Flux paths found in $cluster_dir" >&2; exit 1; }

for path in "${flux_paths[@]}"; do
  echo "== kustomize build $path"
  [[ -f "$path/kustomization.yaml" ]] || { echo "validate: $path has no kustomization.yaml" >&2; exit 1; }
  kustomize build "$path" | flux envsubst --strict | kubeconform_run -
done

echo "== no plain Secrets"
bad=0
while IFS= read -r file; do
  [[ "$file" == *.sops.yaml ]] && continue
  echo "validate: $file has a plain Secret; encrypt it as *.sops.yaml (README, Secrets)" >&2
  bad=1
done < <(grep -rl --include='*.yaml' --include='*.yml' -E '^kind: Secret$' clusters infrastructure apps || true)
while IFS= read -r file; do
  grep -q '^sops:' "$file" || { echo "validate: $file is not SOPS-encrypted" >&2; bad=1; }
done < <(find clusters infrastructure apps -name '*.sops.yaml')
[[ $bad -eq 0 ]] && echo "ok"
exit "$bad"
