#!/usr/bin/env bash
set -euo pipefail

# Configure ArgoCD repo-server to decrypt SOPS/age secrets via KSOPS (Kustomize exec plugin).
#
# This script is safe to re-run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/common.sh"

AGE_KEY_FILE="${AGE_KEY_FILE:-$REPO_ROOT/local/sops/age.key}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"

main() {
  require_cmd kubectl

  kubectl get ns "$ARGOCD_NS" >/dev/null 2>&1 || error "Namespace $ARGOCD_NS not found (install ArgoCD first)"
  kubectl -n "$ARGOCD_NS" get deploy argocd-repo-server >/dev/null 2>&1 || error "argocd-repo-server deployment not found"

  if [[ ! -f "$AGE_KEY_FILE" ]]; then
    error "Missing age key file: $AGE_KEY_FILE (run: ./scripts/sops-bootstrap.sh)"
  fi

  log "Creating/updating Secret ${ARGOCD_NS}/sops-age ..."
  kubectl -n "$ARGOCD_NS" create secret generic sops-age \
    --from-file=keys.txt="$AGE_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Configuring argocd-cm Kustomize build options ..."
  kubectl -n "$ARGOCD_NS" patch configmap argocd-cm \
    --type merge \
    --patch-file "$REPO_ROOT/kubernetes/gitops/argocd/ksops/argocd-cm.patch.json" >/dev/null

  log "Patching argocd-repo-server to add KSOPS + SOPS age key mount ..."
  kubectl -n "$ARGOCD_NS" patch deployment argocd-repo-server \
    --type strategic \
    --patch-file "$REPO_ROOT/kubernetes/gitops/argocd/ksops/argocd-repo-server-patch.yaml" >/dev/null

  log "Waiting for argocd-repo-server rollout ..."
  kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-repo-server --timeout=300s

  log "Done. You can now sync the ArgoCD Application: homelab-secrets"
}

main "$@"
