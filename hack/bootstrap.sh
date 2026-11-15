#!/usr/bin/env bash
# Hand the cluster to Flux. Run once, after sudo ./host/setup.sh, as the owner:
#   GITHUB_TOKEN=<fine-grained PAT, this repo, contents+admin rw> ./hack/bootstrap.sh
#
#   1. flux-system/sops-age from ~/.config/sops/age/keys.txt, so Flux can
#      decrypt cluster-secrets.sops.yaml.
#   2. flux bootstrap github: installs Flux, adds a read-only deploy key, and
#      commits clusters/homelab/flux-system to BRANCH (default main).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GITHUB_TOKEN:?set GITHUB_TOKEN (README, Bring-up)}"
BRANCH=${BRANCH:-main}
key=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

[[ -f $key ]] || { echo "no age key at $key: restore it from the password manager" >&2; exit 1; }
[[ -f infrastructure/secrets/cluster-secrets.sops.yaml ]] || { echo "run ./hack/cluster-secrets.sh and commit its output first" >&2; exit 1; }
[[ $(kubectl config current-context) == default ]] || { echo "kubectl context is $(kubectl config current-context), expected the K3s 'default'" >&2; exit 1; }

flux check --pre
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey="$key" \
  --dry-run=client -o yaml | kubectl apply -f -

flux bootstrap github \
  --owner=gr8monk3ys \
  --repository=homelab \
  --branch="$BRANCH" \
  --path=clusters/homelab \
  --personal \
  --private=true

flux get kustomizations --watch
