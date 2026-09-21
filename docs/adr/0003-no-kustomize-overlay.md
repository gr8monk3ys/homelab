---
status: accepted
date: 2026-09-21
---

# No kustomize overlay

The catalogue of service descriptors, rendered by `scripts/lib/render.sh`
from `config/homelab.yaml` and the environment, is the desired-state
description of the cluster; the installer, disaster recovery, the KinD
harness, CI and the generated ArgoCD app-of-apps all read it. We deleted
`kustomize/` (a base listing five infrastructure resources the installer
already applies, and one "production" overlay adding two labels and an
unmounted ConfigMap) and its only callers, `scripts/kustomize-apply.sh` and
`just kustomize-apply`, because a kustomize overlay would be a third copy of
the same desired state on a single-node cluster with one environment.

## Consequences

- The only kustomizations in the repo are the ArgoCD app-of-apps
  (`kubernetes/gitops/argocd/apps/{core,full}`) and the SOPS secret store
  (`kubernetes/secrets/sops`); `scripts/ci.sh` builds exactly those.
- Environment-specific variation is expressed through placeholders and
  toggles, not overlays. A second environment would mean a second
  `config/homelab.yaml` and toggle set, not a new overlay.
