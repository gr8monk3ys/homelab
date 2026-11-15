---
status: accepted
date: 2026-11-11
supersedes: 0001, 0002, 0003, 0004, 0005, 0006, 0007, 0008, 0009, 0010
---

# Flux GitOps replaces the Bash installer

The Bash installer (`setup-v2.sh`, `scripts/`, the `kubernetes/services/`
descriptor catalogue, `helm/`, `ansible/`, `test/`) grew to 65 services and
its own render seam, secret table, phase list and toggle algebra
(ADRs 0001 to 0009). On one PC it ran a handful of those services. On
2026-11-11 the owner wiped the k3d cluster (it held no personal data) and
chose a rebuild with a small catalogue: media (the arr stack, qBittorrent
behind gluetun, Seerr; Plex native on Windows) and photos plus files
(Immich, OpenCloud). The plan is in the owner's report
`2026-11-11-homelab-rebuild-plan.md`.

We replace the installer with Flux. Git is the desired state; Flux's
controllers in the cluster pull it and reconcile.

## Decision

- **Flux, not Argo CD.** Flux decrypts SOPS natively (no KSOPS), has no UI to
  run, and Renovate reads its `HelmRelease`, `OCIRepository` and
  `GitRepository` objects without regex managers.
- **Three layers, ordered by `dependsOn`** in `clusters/homelab/`:
  `infrastructure-controllers` (CRDs and operators), then
  `infrastructure-configs` (objects that need those CRDs and webhooks), then
  `apps`. Each waits for the previous one to be Ready.
- **Gateway API on the Traefik K3s bundles.** A `HelmChartConfig` turns on
  Traefik's Gateway API provider; the chart version follows the K3s version.
  K3s 1.37 also installs the standard-channel Gateway API CRDs (v1.6.3, the
  version its Traefik 3.7 is built against), so the repo does not ship them.
  One Gateway (`gateway/homelab`) with a wildcard certificate from a LAN CA;
  apps attach `HTTPRoute`s to it.
- **cert-manager and CloudNativePG as `HelmRelease`s** with charts from OCI
  registries, pinned by tag. CloudNativePG serves Immich only; the other apps
  keep SQLite or no database.
- **Secrets are SOPS files with age**, `*.sops.yaml` next to the app that
  uses them. Flux decrypts them with the `flux-system/sops-age` Secret. The
  private key is never in Git.
- **One substitution mechanism**: Flux `postBuild.substituteFrom` the
  `cluster-settings` ConfigMap (`${DOMAIN}`, `${TIMEZONE}`).
- **Kustomize overlays stay out**, as ADR 0003 decided, for the same reason:
  one cluster, one environment. Each layer is a plain kustomization that lists
  its files.
- **CI is offline**: `hack/validate.sh` runs yamllint, then
  `kustomize build | flux envsubst --strict | kubeconform` on every path a
  cluster Kustomization names, and fails on a plain `Secret`.

## Consequences

- ADRs 0001 to 0009 describe code that no longer exists on `main`; they are
  marked superseded and kept for history. ADR 0010 (Garage as the in-cluster
  S3 store) is superseded with them; rebuild session 3 decides backups again
  (Garage with CNPG and Volsync, or a Windows-side restic job) in a new ADR.
- The old tree is on the `archive/bash-installer` branch (main at 2ae75af).
- No public exposure: access is LAN plus Tailscale, so Authelia and CrowdSec
  are not carried over. Add them only if something goes public.
- No Prometheus stack. Uptime alerts (Gatus plus ntfy) come in session 4 if
  wanted.
- `flux bootstrap github` needs a GitHub token, so it is the owner's step
  (README). Until then a cluster can be pointed at the repo by hand.
- K3s pins Traefik and the Gateway API CRDs. Updating either is a K3s image
  update in `k3d/homelab.yaml` and a cluster re-create.
- Docker Desktop here runs cgroup v1 (WSL 2.4, kernel 5.15), which kubelets
  since Kubernetes 1.35 refuse by default. `k3d/homelab.yaml` passes
  `--kubelet-arg=fail-cgroupv1=false` until WSL moves to cgroup v2.
