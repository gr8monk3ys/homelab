# Homelab

**Status (2026-11-11): rebuild in progress.** The Flux skeleton (Traefik with
Gateway API, cert-manager, CloudNativePG, SOPS) reconciles on a fresh k3d
cluster on one PC. No apps yet: media comes in rebuild session 2, photos and
files in session 3. The old Bash installer and its 65-service catalogue are on
the `archive/bash-installer` branch (ADR 0011).

A small self-hosted Kubernetes homelab: K3s in Docker Desktop through k3d, on
one Windows PC, managed by [Flux](https://fluxcd.io). Git is the desired state;
Flux in the cluster pulls `main` and applies it.

```
GitHub (main) ──Flux pulls──▶ k3d cluster "homelab" (this PC)
                              ├─ infrastructure: Traefik (Gateway API), cert-manager, CloudNativePG, SOPS/age
                              ├─ apps/media:  Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent+gluetun, Seerr  (session 2)
                              ├─ apps/photos: Immich + CNPG Postgres                                      (session 3)
                              └─ apps/files:  OpenCloud                                                   (session 3)
Plex Media Server runs natively on Windows and reads D:\30 Media.
```

## Layout

| Path | What |
|---|---|
| `clusters/homelab/` | What Flux reconciles: three Kustomizations in order (`infrastructure-controllers` → `infrastructure-configs` → `apps`) and the `cluster-settings` ConfigMap. `flux bootstrap` adds `flux-system/`. |
| `infrastructure/controllers/` | Operators and their CRDs: the Traefik `HelmChartConfig`, cert-manager and CloudNativePG `HelmRelease`s. |
| `infrastructure/configs/` | Objects that need those CRDs: the LAN CA `ClusterIssuer`s, the wildcard certificate, the `gateway/homelab` Gateway. |
| `apps/{media,photos,files}/` | One kustomization per app group. |
| `k3d/homelab.yaml` | The cluster: one K3s server, Traefik kept, `D:\30 Media\homelab` bound at `/mnt/bulk`. |
| `hack/validate.sh` | The offline checks CI runs. |
| `docs/adr/` | Decisions. ADR 0011 is the rebuild. |

## Versions

| Piece | Pin | Where |
|---|---|---|
| K3s | v1.37.2+k3s1 (bundles Traefik chart 41.6.1, Traefik 3.7, Gateway API CRDs v1.6.3) | `k3d/homelab.yaml` |
| Flux | v2.10.0 | `flux install` / `flux bootstrap` |
| cert-manager | chart v1.21.3 | `infrastructure/controllers/cert-manager.yaml` |
| CloudNativePG | chart 0.29.1 (operator 1.30.1) | `infrastructure/controllers/cloudnative-pg.yaml` |

Renovate (`renovate.json5`) proposes updates weekly; nothing automerges.

## Local cluster

Run these from the Windows shell (PowerShell or Git Bash), not from WSL. A bind
made from a WSL distro breaks when that distro goes away. In Git Bash, set
`MSYS_NO_PATHCONV=1` first.

```bash
k3d cluster create --config k3d/homelab.yaml
```

Docker Desktop here still runs cgroup v1 (WSL 2.4.13, kernel 5.15). Kubernetes
1.35 and later refuse cgroup v1 unless told otherwise, so the config passes
`--kubelet-arg=fail-cgroupv1=false`. When `docker info` shows
`Cgroup Version: 2`, drop that argument and re-create the cluster.

## Bootstrap (the owner's step)

`flux bootstrap github` needs a GitHub token. Run it once, after this layout is
on `main`.

1. Put the age private key in the cluster, so Flux can decrypt secrets. The key
   is at `%APPDATA%\sops\age\keys.txt` (Git Bash: `$APPDATA/sops/age/keys.txt`).
   Skip this step if `kubectl -n flux-system get secret sops-age` already finds
   it.

   ```bash
   kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
   ```

   ```bash
   kubectl -n flux-system create secret generic sops-age --from-file=age.agekey="$APPDATA/sops/age/keys.txt"
   ```

2. Bootstrap. Use a fine-grained token for `gr8monk3ys/homelab` only, with
   Administration (read and write, to add the deploy key) and Contents (read
   and write). Flux commits `clusters/homelab/flux-system/` to `main`.

   ```bash
   GITHUB_TOKEN=<token> flux bootstrap github --owner=gr8monk3ys --repository=homelab --branch=main --path=clusters/homelab --personal --private=true
   ```

3. Check:

   ```bash
   flux get kustomizations
   ```

   `flux-system`, `infrastructure-controllers`, `infrastructure-configs` and
   `apps` should all be `True`.

## Secrets

Secrets are SOPS files encrypted with age, named `*.sops.yaml`, next to the
app that uses them. Only `data` and `stringData` are encrypted. Flux decrypts
them in the `infrastructure-configs` and `apps` layers. CI fails on a plain
`kind: Secret` and on a `*.sops.yaml` that is not encrypted.

```bash
sops --encrypt --in-place apps/media/vpn.sops.yaml
```

`.sops.yaml` holds the public key. The private key is never in Git. Keep a copy
of `%APPDATA%\sops\age\keys.txt` in the password manager: without it, no
encrypted file in this repo can be read again.

## Trust the LAN CA

Apps are `https://<app>.home.arpa` (`DOMAIN` in
`clusters/homelab/cluster-settings.yaml`). Point those names at this PC (a
router DNS entry, or the hosts file), then trust the CA once per device:

```bash
kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

On Windows, import `homelab-ca.crt` into "Trusted Root Certification
Authorities" (double-click it, or `certutil -addstore -user Root homelab-ca.crt`).

## Checks

```bash
./hack/validate.sh
```

It needs `yamllint`, `kustomize`, `kubeconform` and the `flux` CLI. CI
(`.github/workflows/ci.yml`) runs the same script on every PR and push to
`main`. The repo is private and Actions minutes are capped: one workflow,
nothing scheduled.
