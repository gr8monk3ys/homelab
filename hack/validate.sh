#!/usr/bin/env bash
# Offline checks for the Flux tree. CI runs this; run it before a push.
#
#   1. yamllint over the repo.
#   2. kubeconform over clusters/homelab/*.yaml.
#   3. Every Flux Kustomization (clusters/homelab/*.yaml and apps/**/ks.yaml):
#      kustomize build (with its components) | flux envsubst --strict | kubeconform,
#      with cluster-settings, placeholder cluster-secrets and its own substitute.
#   4. Rules kubeconform cannot see, on the rendered objects:
#      - a single-replica Deployment with a PVC uses strategy Recreate;
#      - every container sets allowPrivilegeEscalation: false and drops ALL
#        capabilities, unless its pod carries homelab.io/security-exception;
#      - every app renders a NetworkPolicy, or its Namespace says why not in
#        homelab.io/no-network-policy;
#      - no Ingress (apps use an HTTPRoute on gateway/homelab).
#   5. No plain Secret: a Secret is a SOPS-encrypted *.sops.yaml, or has no
#      data: and every stringData value is a ${VAR} substitution.
#
# Needs: yamllint, kustomize, kubeconform, flux (for envsubst), yq.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
cluster_dir=clusters/homelab
schema_catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

for tool in yamllint kustomize kubeconform flux yq; do
  command -v "$tool" >/dev/null || { echo "validate: $tool is not installed" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
bad=0
fail() { echo "validate: $*" >&2; bad=1; }

kubeconform_run() {
  kubeconform -strict -summary \
    -schema-location default \
    -schema-location "$schema_catalog" \
    "$@"
}

echo "== yamllint"
yamllint -c .yamllint.yaml .

# cluster-settings values, and a placeholder for every cluster-secrets key.
while IFS=$'\t' read -r key value; do
  export "$key=$value"
done < <(yq -r '.data | to_entries | .[] | [.key, .value] | @tsv' "$cluster_dir/cluster-settings.yaml")
while read -r key; do
  export "$key=placeholder"
done < <(./hack/cluster-secrets.sh --keys)
export NTFY_URL=https://ntfy.example/topic B2_ENDPOINT=https://s3.example

echo "== kubeconform $cluster_dir"
mapfile -t cluster_files < <(find "$cluster_dir" -maxdepth 1 -name '*.yaml' | sort)
kubeconform_run "${cluster_files[@]}"

# One line per Flux Kustomization that reads this repo:
#   <file>\t<name>\t<path>\t<components,>\t<KEY=VALUE;...>
mapfile -t flux_ks < <(
  for f in "$cluster_dir"/*.yaml $(find apps -name ks.yaml | sort); do
    yq -r 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/*" and .spec.sourceRef.name == "flux-system")
      | [filename, .metadata.name, .spec.path, ((.spec.components // []) | join(",")),
         ((.spec.postBuild.substitute // {}) | to_entries | map(.key + "=" + .value) | join(";"))] | @tsv' "$f"
  done | grep -v '^$'
)
[[ ${#flux_ks[@]} -gt 0 ]] || { echo "validate: no Flux Kustomizations found" >&2; exit 1; }

app_names=()
for line in "${flux_ks[@]}"; do
  IFS=$'\t' read -r file name path components subs <<<"$line"
  path=${path#./}
  echo "== $name ($path)"
  if [[ $path == infrastructure/secrets && ! -f $path/cluster-secrets.sops.yaml ]]; then
    echo "skipped: cluster-secrets.sops.yaml not created yet (hack/cluster-secrets.sh)"
    continue
  fi
  [[ -f "$path/kustomization.yaml" ]] || { fail "$path has no kustomization.yaml"; continue; }

  # A throwaway kustomization adds the Flux-level components to the path.
  build=$tmp/build-$name
  mkdir -p "$build"
  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources: [\"$(realpath --relative-to="$build" "$root/$path")\"]"
    if [[ -n $components ]]; then
      echo "components:"
      IFS=, read -ra comps <<<"$components"
      for c in "${comps[@]}"; do echo "  - \"$(realpath -m --relative-to="$build" "$root/$path/$c")\""; done
    fi
  } >"$build/kustomization.yaml"

  out=$tmp/$name.yaml
  (
    IFS=';' read -ra pairs <<<"$subs"
    for kv in "${pairs[@]}"; do [[ -n $kv ]] && export "${kv%%=*}=${kv#*=}"; done
    kustomize build --load-restrictor LoadRestrictionsNone "$build" | flux envsubst --strict | yq "del(.sops)"
  ) >"$out" || { fail "$name: build or substitution failed"; continue; }
  kubeconform_run "$out" || bad=1
  [[ $file == apps/* ]] && app_names+=("$name")

  # Rules on the rendered objects.
  while IFS= read -r msg; do [[ -n $msg ]] && fail "$name: $msg"; done < <(yq -r '
    select(.kind == "Deployment"
      and ((.spec.replicas // 1) <= 1)
      and ([.spec.template.spec.volumes[]? | select(has("persistentVolumeClaim"))] | length > 0)
      and .spec.strategy.type != "Recreate")
    | "Deployment " + .metadata.name + " has a PVC and one replica: use strategy Recreate"' "$out")
  while IFS= read -r msg; do [[ -n $msg ]] && fail "$name: $msg"; done < <(yq -r '
    select(.kind == "Deployment" or .kind == "DaemonSet" or .kind == "StatefulSet" or .kind == "CronJob" or .kind == "Job")
    | (.spec.jobTemplate.spec.template // .spec.template) as $t
    | select(($t.metadata.annotations["homelab.io/security-exception"] // "") == "")
    | .metadata.name as $n
    | ($t.spec.containers + ($t.spec.initContainers // []))[]
    | select(.securityContext.allowPrivilegeEscalation != false or ((.securityContext.capabilities.drop // []) | contains(["ALL"]) | not))
    | $n + "/" + .name + ": set allowPrivilegeEscalation: false and capabilities.drop: [ALL] (or annotate the pod homelab.io/security-exception)"' "$out")
  if yq -e 'select(.kind == "Ingress")' "$out" >/dev/null 2>&1; then
    fail "$name: has an Ingress; expose it with an HTTPRoute on gateway/homelab"
  fi
  if [[ $file == apps/* ]] \
    && ! yq -e 'select(.kind == "NetworkPolicy")' "$out" >/dev/null 2>&1 \
    && ! yq -e 'select(.kind == "Namespace" and .metadata.annotations["homelab.io/no-network-policy"] != null)' "$out" >/dev/null 2>&1; then
    fail "$name: no NetworkPolicy; add one, or annotate its Namespace homelab.io/no-network-policy: <reason>"
  fi
done

# Every app ks is listed in its group's kustomization (else Flux never sees it).
listed=$(kustomize build apps | yq -r 'select(.kind == "Kustomization") | .metadata.name')
while IFS= read -r ks; do
  n=$(yq -r '.metadata.name' "$ks")
  grep -qx "$n" <<<"$listed" || fail "$ks is not listed in its group's kustomization.yaml"
done < <(find apps -name ks.yaml)

echo "== no plain Secrets"
while IFS= read -r file; do
  [[ $file == *.sops.yaml ]] && continue
  if ! yq -e 'select(.kind == "Secret") | (has("data") or ([.stringData[] | select(test("\$\{") | not)] | length > 0))' "$file" >/dev/null 2>&1; then
    continue
  fi
  fail "$file has a plain Secret; encrypt it as *.sops.yaml"
done < <(grep -rl --include='*.yaml' --include='*.yml' -E '^kind: Secret$' clusters infrastructure apps components || true)
while IFS= read -r file; do
  grep -q '^sops:' "$file" || fail "$file is not SOPS-encrypted"
done < <(find clusters infrastructure apps -name '*.sops.yaml')

[[ $bad -eq 0 ]] && echo "ok"
exit "$bad"
