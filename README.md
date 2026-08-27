# Homelab

**Status: not yet proven end-to-end on a live cluster.** The manifests are
consistent and CI-validated (yamllint, shellcheck, kubeconform, helm lint,
kustomize build), and subsets have run on KinD, but nobody has deployed the
whole stack to a real K3s node and watched it stay up. Deploy a subset,
verify, then grow.

A self-hosted Kubernetes homelab on K3s. One installer (`setup-v2.sh`) deploys
the infrastructure layer (MetalLB, Traefik, cert-manager, External Secrets,
MinIO, Velero, kube-prometheus-stack) and 23 of the 43 application directories
under `kubernetes/services/`; the other 20 are maintained manifests you apply
by hand.

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
| Logging | Loki (+ optional Promtail) | off |
| Security | CrowdSec agent, NetworkPolicies, Pod Security Admission (audit), optional Kyverno | mixed, see below |
| GitOps | ArgoCD (+ optional KSOPS for encrypted secrets in git) | off |

Security posture, honestly stated: pod security contexts, drop-ALL
capabilities, and resource limits are enforced in the manifests themselves;
Pod Security Admission defaults to `audit` (warns, does not block), Kyverno is
opt-in, NetworkPolicies cover the sensitive namespaces rather than every
namespace, and the CrowdSec Traefik bouncer is enforced on the `websecure`
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
| `ENABLE_GITOPS` | `false` | ArgoCD (`APPLY_GITOPS_MANIFESTS` for the app-of-apps) |
| `INSTALL_TRAEFIK` | `true` | Traefik ingress controller |
| `INSTALL_CERT_MANAGER` | `true` | cert-manager + TLS issuers |
| `INSTALL_EXTERNAL_SECRETS` | `true` | External Secrets Operator |
| `INSTALL_MONITORING` | `true` | kube-prometheus-stack + Uptime Kuma |
| `INSTALL_BLACKBOX_EXPORTER` | `true` | Synthetic HTTPS probes via blackbox-exporter |
| `INSTALL_LOGGING` | `false` | Loki (`INSTALL_PROMTAIL` for shipping) |
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
WireGuard. Opt-in via the toggles: Immich, Ollama, Open WebUI, Drone, Harbor,
ArgoCD. The full catalog with URLs, plus the 20 manifest-only directories, is
in `docs/services.md`.

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
./scripts/ci.sh                  # the full lint/validate gate CI runs
just                             # task shortcuts (just validate, just ci, just kind-smoke, ...)
cd test && ./setup-kind.sh       # throwaway KinD cluster for testing
```

Tool and chart versions are pinned in `tools/versions.env`; Dependabot
bumps the GitHub Actions. CI is one workflow (`.github/workflows/ci.yml`)
that runs `scripts/ci.sh` on pull requests — the repo is private, so
Actions minutes are capped and nothing runs on a schedule.

## Repository layout

```
setup-v2.sh                  # installer (idempotent; safe to re-run)
config/homelab.yaml          # domain/email/timezone/issuer defaults
kubernetes/
  ingress/  storage/  backup/  monitoring/  dns/       # infrastructure
  secrets/                   # ExternalSecrets + SOPS store
  security/                  # CrowdSec + NetworkPolicies (applied by installer)
  network-policies/          # standalone policy toolkit (manual, not installed)
  policy/kyverno/            # optional policy-as-code (audit + enforce sets)
  services/<name>/           # one directory per application
  gitops/argocd/             # optional ArgoCD app-of-apps
helm/nextcloud/              # the one Helm-chart-managed app
kustomize/overlays/production/  # the single overlay (one node, one environment)
scripts/                     # secrets, backup/restore, validation, DR
ansible/                     # host provisioning (base system, security, backups)
docs/                        # credentials reference + day-2 runbooks
test/                        # KinD configs, Compose stack, validation suite
```

## Troubleshooting

Symptom-to-fix table: `docs/runbooks/README.md`. Installer output goes to
`setup.log`.

## License

GPL-3.0 — see [LICENSE](LICENSE).
