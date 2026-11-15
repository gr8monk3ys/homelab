# Homelab

**Status (2026-11-14): written, not yet running.** The Flux tree validates
offline (`hack/validate.sh`); no cluster runs it yet. Bring-up is
[docs/runbooks/bring-up.md](docs/runbooks/bring-up.md). The old Bash installer
and its 65-service catalogue are on the `archive/bash-installer` branch
(ADR 0011).

A small single-node Kubernetes homelab: K3s running natively on one Arch Linux
PC (RTX 3090, a 3-disk RAID 5 for media; photos on the SSD), managed by [Flux](https://fluxcd.io). Git is the
desired state; Flux in the cluster pulls `main` and applies it.

```
GitHub (main) ──Flux pulls──▶ K3s "homelab" (systemd on the Arch host)
  infrastructure  Traefik (Gateway API), cert-manager + LAN CA, CloudNativePG,
                  VolSync → Backblaze B2, kube-prometheus-stack → ntfy,
                  SMART + RAID + GPU alerts, NVIDIA device plugin (time-sliced),
                  k8s-gateway (LAN DNS for *.home.arpa)
  apps/media      Prowlarr, Sonarr, Radarr, Bazarr, qBittorrent behind gluetun,
                  Seerr, Jellyfin (NVENC)
  apps/photos     Immich (CUDA machine learning) + CloudNativePG Postgres
  apps/files      OpenCloud
```

## Layout

| Path | What |
|---|---|
| `host/` | `setup.sh` (run with sudo): nvidia-container-toolkit, the RAID at `/mnt/raid`, the Immich library on the SSD, ufw rules for K3s, K3s pinned and configured. |
| `clusters/homelab/` | What Flux reconciles: `cluster-secrets` → `infrastructure-controllers` → `infrastructure-configs` → `apps`, and `cluster-settings`. `flux bootstrap` adds `flux-system/`. |
| `infrastructure/` | `secrets/` (the one SOPS file), `controllers/` (operators, charts, exporters), `configs/` (issuers, Gateway, DNS, alert rules). |
| `apps/<group>/<app>/` | `ks.yaml` (the app's Flux Kustomization) and `app/` (its manifests). A group shares a namespace. |
| `components/volsync/` | Nightly restic backup of PVC `${APP}` to B2; an app opts in from its `ks.yaml`. |
| `hack/` | `validate.sh` (CI), `cluster-secrets.sh`, `bootstrap.sh`, `restore.sh`. |
| `docs/` | ADRs (0011–0013 current; `adr/superseded/` is the installer's history), runbooks. |

## Backups

Every app's config PVC and the Immich library (photos and Immich's nightly
database dumps) go to Backblaze B2 nightly with restic (VolSync). Media is not
backed up offsite. A stale backup fires an alert. Restore with
`./hack/restore.sh <namespace> <app>`; prove it monthly with `--test`.
[docs/runbooks/disaster-recovery.md](docs/runbooks/disaster-recovery.md) says
what survives what.

## Secrets

Every credential is in `infrastructure/secrets/cluster-secrets.sops.yaml`
(made by `hack/cluster-secrets.sh`), encrypted with SOPS and age; Flux
substitutes its keys like `cluster-settings`. CI fails on any other plain
Secret. The age private key is `~/.config/sops/age/keys.txt` and must also be
in the password manager: without it nothing in Git decrypts.

## Updates

Renovate (`renovate.json5`, the hosted app) opens PRs weekly. Patch and digest
bumps merge themselves once CI passes; minors and majors wait for review, and a
K3s minor waits for a tick on the Dependency Dashboard (apply with
`sudo ./host/setup.sh`).

## Checks

```bash
./hack/validate.sh
```

Needs `yamllint`, `kustomize`, `kubeconform`, `yq` and the `flux` CLI. CI runs
the same script on every PR. It renders every Flux Kustomization and fails on
schema errors, unknown `${VAR}`s, a plain Secret, an Ingress, a missing
NetworkPolicy, a single-replica Deployment with a PVC that is not `Recreate`,
and a container that keeps privilege escalation or capabilities.
