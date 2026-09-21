# Homelab

**Status: verified against a live Kubernetes API, not yet on a real node.**
Every check in `scripts/ci.sh` passes, every service in the catalogue has been
applied through the installer's own code path to a real `kube-apiserver`
(with the External Secrets, Traefik, cert-manager and Prometheus Operator CRDs
loaded) and the installer has run end to end against it with the Helm-based
infrastructure disabled. What has not happened yet: pods scheduling on a real
K3s node and staying up. Deploy a subset, verify, then grow.

A self-hosted Kubernetes homelab on K3s. One installer (`setup-v2.sh`) deploys
the infrastructure layer (MetalLB, Traefik, cert-manager, External Secrets,
MinIO, Velero, kube-prometheus-stack) and the **service catalogue**: every
directory under `kubernetes/services/` carries a `service.yaml` descriptor
(group, opt-in, ordered install steps, network isolation), and one code path,
`install_service`, installs any of them. There are 64: 18 install under the
default toggles, 37 more are opt-in by name, and the rest wait on a group
toggle. `./scripts/services.sh list` prints the catalogue.

Running 64 services on one node is not the intent and would not fit; the
catalogue is a menu, not a target. Pick the handful you actually want.

## How it fits together

- **Catalogue.** `kubernetes/services/<name>/service.yaml` is the interface;
  `scripts/lib/services.sh` is the implementation. The installer, disaster
  recovery, the KinD harness, the validator, CI and the generated ArgoCD
  app-of-apps all read the same catalogue, so a service cannot be half-wired.
- **Render seam.** Manifests carry placeholders (`homelab.local`,
  `admin@homelab.local`, `UTC`, the `homelab-ca` issuer). Everything that
  reaches a cluster goes through `scripts/lib/render.sh`; nothing is applied
  raw.
- **Isolation.** Each descriptor lists the NetworkPolicy templates it wants
  (or `[]` with a reason). Cross-namespace rules live in
  `kubernetes/security/network-policies/`.
- **Secrets.** One table in `scripts/lib/secrets.sh` feeds two adapters: live
  Kubernetes Secrets (`generate-secrets.sh`) or SOPS-encrypted files for
  GitOps (`sops-bootstrap.sh`). `scripts/secrets-check.sh` fails CI when an
  `ExternalSecret` asks for a secret nobody produces, or vice versa.
- **Decisions** are in `docs/adr/`; the vocabulary is in `CONTEXT.md`.

## Secrets design

No credential is committed, not as a default and not as an example. Two paths:

- **Generated (default).** `scripts/generate-secrets.sh` creates random
  credentials as Kubernetes Secrets in one central `secrets` namespace.
  External Secrets Operator copies each into the namespace that needs it, so
  app manifests only ever reference an `ExternalSecret`. The installer prints
  the `kubectl` command to read each secret instead of the value.
- **GitOps (opt-in).** `scripts/sops-bootstrap.sh` generates an age key and
  SOPS-encrypts Secret manifests into `kubernetes/secrets/sops/`
  (`.sops.yaml` holds only the public recipient). ArgoCD decrypts them at
  sync time through KSOPS. The age private key lives in `local/`, which is
  gitignored.

`scripts/validate-setup.sh` greps the rendered cluster state for hardcoded
passwords as one of its checks. `docs/credentials.md` lists every secret name.

## Stack

| Layer | Components | Default |
|---|---|---|
| Cluster | K3s (any conformant Kubernetes works) | assumed present |
| Load balancing | MetalLB | on |
| Ingress + TLS | Traefik, cert-manager (local CA `homelab-ca`; Let's Encrypt issuers available) | on |
| Secrets | External Secrets Operator over a central `secrets` namespace; SOPS/age for GitOps | on |
| Storage | local-path provisioner, MinIO (S3-compatible) | on |
| Backups | Velero (daily/weekly/monthly + 6-hourly critical schedules) | on |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), blackbox-exporter, Uptime Kuma | on |
| Logging | Loki (+ optional Grafana Alloy log shipper) | off |
| Security | CrowdSec agent, NetworkPolicies, Pod Security Admission (audit), optional Kyverno | mixed, see below |
| GitOps | ArgoCD (+ optional KSOPS for encrypted secrets in git) | off |

Security posture, honestly stated: pod security contexts, drop-ALL
capabilities, and resource limits are enforced in the manifests themselves;
Pod Security Admission defaults to `audit` (warns, does not block), Kyverno is
opt-in, NetworkPolicies default-deny the 28 service namespaces whose
descriptor declares `networkPolicies:` (Homepage and Home Assistant are left
open because they need the kube API and the LAN), and the CrowdSec Traefik bouncer is enforced on the `websecure`
entrypoint (Traefik writes access logs the agent reads; decisions are applied
via bouncer middleware). See `docs/runbooks/hardening.md` to tighten the rest.

## Requirements

- A running Kubernetes cluster (K3s recommended) and `kubectl` access
- `helm` (or let the installer fetch pinned tools into `.tools/`)
- RAM: ~8 GB for a minimal subset; 32 GB+ recommended for the full stack
  (pod memory *requests* alone total ~25 GiB)
- 100 GB+ storage (more for media/photo libraries)

## Quick start

**1. Configure first.** Edit `config/homelab.yaml` (or export env vars, which
take precedence) — at minimum your domain and email:

```yaml
homelab:
  domain: example.lan      # every service becomes <name>.<domain>
  email: you@example.com
  timezone: America/Los_Angeles
```

Without this step everything deploys under the placeholder domain
`homelab.local`.

**2. Deploy.**

```bash
./setup-v2.sh              # generates missing secrets, installs everything
```

**3. Validate and get access info.**

```bash
./scripts/validate-setup.sh
```

The installer ends with a banner listing every service URL and the exact
`kubectl` commands to retrieve each credential (nothing is printed to logs).
See `docs/credentials.md` for the full secret reference.

## Feature toggles

Env vars, checked at install time (`VAR=value ./setup-v2.sh`):

| Toggle | Default | Controls |
|---|---|---|
| `ENABLE_MEDIA_SERVICES` | `true` | Jellyfin, Sonarr/Radarr/Prowlarr/Bazarr, Audiobookshelf |
| `ENABLE_NETWORK_SERVICES` | `true` | Pi-hole, WireGuard, dnsmasq (DHCP) |
| `ENABLE_CONTENT_SERVICES` | `true` | Calibre-web, SearXNG, yarr |
| `ENABLE_PRODUCTIVITY_SERVICES` | `true` | Paperless-ngx, Mealie, Linkwarden, n8n |
| `ENABLE_AI_SERVICES` | `false` | Ollama, Open WebUI, Immich |
| `ENABLE_DEV_SERVICES` | `false` | Drone CI, Harbor registry |
| `ENABLE_HOME_SERVICES` | `false` | Home Assistant, Mosquitto, Node-RED, Zigbee2MQTT |
| `ENABLE_COMMUNICATION_SERVICES` | `false` | Matrix (Synapse + Element), Mattermost |
| `OPTIN_SERVICES` | empty | Space-separated names of `optin: true` services to add (or `all`); see `docs/services.md` |
| `ENABLE_GITOPS` | `false` | ArgoCD (`APPLY_GITOPS_MANIFESTS` for the app-of-apps) |
| `INSTALL_TRAEFIK` | `true` | Traefik ingress controller |
| `INSTALL_CERT_MANAGER` | `true` | cert-manager + TLS issuers |
| `INSTALL_EXTERNAL_SECRETS` | `true` | External Secrets Operator |
| `INSTALL_MONITORING` | `true` | kube-prometheus-stack + Uptime Kuma |
| `INSTALL_BLACKBOX_EXPORTER` | `true` | Synthetic HTTPS probes via blackbox-exporter |
| `INSTALL_LOGGING` | `false` | Loki (`INSTALL_ALLOY` for shipping) |
| `INSTALL_VELERO` / `INSTALL_METALLB` | `true` | Backups / LoadBalancer IPs |
| `INSTALL_EXTERNAL_DNS` | `false` | Cloudflare DNS automation (needs API token) |
| `INSTALL_KYVERNO` | `false` | Policy engine (`KYVERNO_POLICY_MODE=audit\|enforce`) |
| `POD_SECURITY_MODE` | `audit` | PSA labels: `off` / `audit` / `enforce` |
| `CONFIGURE_ALERTING` | `false` | Alertmanager notification routing |
| `BACKUP_SECRETS` | `false` | Age-encrypted secret export during install |

## Services

Installed by default: Homepage, Grafana, Uptime Kuma, Nextcloud, Vaultwarden,
Gitea, Authelia, Jellyfin, Sonarr/Radarr/Prowlarr/Bazarr, Audiobookshelf,
Paperless-ngx, Mealie, Linkwarden, n8n, Calibre-web, SearXNG, yarr, Pi-hole,
WireGuard. Opt-in via the group toggles: Immich, Ollama, Open WebUI, Drone,
Harbor, Home Assistant, Matrix, Mattermost, ArgoCD. Opt-in by name
(`OPTIN_SERVICES="gatus jellyseerr ..."`): Actual Budget, cloudflared,
code-server, CyberChef, Frigate, Gatus, Heimdall, Homebox, Hoppscotch,
Intel and NVIDIA device plugins, IT-Tools, Jellyseerr, Keycloak, Kiwix,
kured, LocalAI, Longhorn, Metabase, Miniflux, Navidrome, NocoDB,
node-feature-discovery, ntfy, Outline, qBittorrent, Reloader, Renovate,
RomM, snapshot-controller, Stirling-PDF, system-upgrade-controller,
Tailscale operator, Tautulli, Umami, VolSync, Whisper. The full catalogue
with URLs is in `docs/services.md`, or run `./scripts/services.sh list`.
Host prerequisites for the storage, remote-access and hardware pieces are
in `docs/runbooks/storage-and-hardware.md`.

## DNS

With Pi-hole enabled, the installer configures wildcard DNS for `*.<domain>`
pointing at Traefik (disable with `CONFIGURE_WILDCARD_DNS=false`). Point your
clients or router DHCP at the Pi-hole service IP:

```bash
kubectl -n pihole get svc pihole-dns
```

## Backups

- **Velero** (on by default): daily 02:00 app-data backup, weekly Sunday
  03:00, monthly, and 6-hourly for critical namespaces —
  `kubernetes/backup/velero/schedules.yaml`.
- **Secrets**: `./scripts/backup-secrets.sh` writes an age-encrypted export;
  restore with `./scripts/restore-secrets.sh <file>`. Do this before rebuilds.
- Verify: `./scripts/verify-backups.sh`. Restore procedures:
  `docs/runbooks/backup-restore.md`.

## GitOps (optional)

`ENABLE_GITOPS=true` installs ArgoCD. To manage encrypted secrets in git:

```bash
./scripts/sops-bootstrap.sh            # age key + SOPS-encrypt secret manifests
./scripts/configure-argocd-ksops.sh    # KSOPS decryption in ArgoCD
```

Details: `docs/runbooks/gitops-secrets.md`. Set `gitops.repo_url` in
`config/homelab.yaml` — the ArgoCD manifests contain placeholders until then.

## Development

```bash
./scripts/install-dev-tools.sh   # pinned toolchain into .tools/ (no sudo)
pre-commit install               # fast local checks on commit
./scripts/ci.sh                  # the full gate CI runs (see below)
./scripts/services.sh list       # the catalogue; check / render / install / argocd
./scripts/secrets-check.sh       # secret producer vs consumer drift
just                             # task shortcuts (just validate, just ci, just kind-smoke, ...)
cd test && ./setup-kind.sh       # throwaway KinD cluster for testing
```

`scripts/ci.sh` runs, in order: `bash -n`, shellcheck, yamllint, kubeconform
on the raw manifests, the catalogue check (every directory has a valid
descriptor with an isolation decision), the ArgoCD freshness check (generated
app-of-apps matches the catalogue), the secret drift check, a render of every
service and every infrastructure manifest with non-default domain, email,
timezone and issuer validated by kubeconform, helm lint, and the ArgoCD
kustomize builds.

## Adding a service

Create `kubernetes/services/<name>/` with `namespace.yaml`, the workload
manifests and a `service.yaml` (see `docs/services.md`). If it needs a
credential, add one line to the table in `scripts/lib/secrets.sh` and an
`ExternalSecret` in the directory. Run `./scripts/services.sh argocd` to
regenerate the GitOps files, then `./scripts/ci.sh`. Nothing in the installer
changes.

## What to add next

`docs/research/homelab-additions.md` compares this repo with Project NOMAD
and four well-known Kubernetes homelabs and ranks fifteen additions with
sources: Renovate, Reloader (now in the catalogue), Kiwix (in), Gatus with
gatus-sidecar, ntfy (in), Cloudflare Tunnel or Tailscale, system-upgrade-
controller and kured, Longhorn, VolSync, Home Assistant with Frigate, GPU
device plugins, Stirling-PDF and IT-Tools (in), Homebox (in), Miniflux, and
the NOMAD knowledge stack (Kolibri, PMTiles maps).

Tool and chart versions are pinned in `tools/versions.env`; Dependabot
bumps the GitHub Actions. CI is one workflow (`.github/workflows/ci.yml`)
that runs `scripts/ci.sh` on pull requests — the repo is private, so
Actions minutes are capped and nothing runs on a schedule.

## Repository layout

```
setup-v2.sh                  # installer (idempotent; safe to re-run)
config/homelab.yaml          # domain/email/timezone/issuer/GitOps URL (env vars override)
kubernetes/
  ingress/  storage/  backup/  monitoring/  dns/       # infrastructure
  secrets/                   # ExternalSecrets + SOPS store
  security/                  # CrowdSec + NetworkPolicies (static rules + per-namespace templates)
  policy/kyverno/            # optional policy-as-code (audit + enforce sets)
  services/<name>/           # one directory per application
  gitops/argocd/             # optional ArgoCD app-of-apps
helm/nextcloud/              # the one Helm chart; installed like any service via kubernetes/services/nextcloud/service.yaml (kind: helm)
scripts/                     # installer libraries (scripts/lib/: common, render, services, netpol, helm, secrets, tools), backup/restore, validation, DR
docs/adr/                    # decisions; docs/research/ holds research notes; CONTEXT.md is the glossary
ansible/                     # host prep for K3s nodes: packages, hardening, host backups (just ansible-prep)
docs/                        # credentials reference, day-2 runbooks, ADRs, research
test/                        # KinD harness configs and the validation suite
```

## Troubleshooting

Symptom-to-fix table: `docs/runbooks/README.md`. Installer output goes to
`setup.log`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
