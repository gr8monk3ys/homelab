# Services

What `setup-v2.sh` installs, what each piece is for, and what exists in the
repo but is not wired into the installer. URLs are `<name>.<domain>` with the
domain from `config/homelab.yaml`.

## Infrastructure (installed by default)

| Component | Toggle (default) | Notes |
|---|---|---|
| MetalLB | `INSTALL_METALLB` (true) | LoadBalancer IPs on bare metal |
| Traefik | `INSTALL_TRAEFIK` (true) | Ingress controller, namespace `traefik-system` |
| cert-manager | `INSTALL_CERT_MANAGER` (true) | Local CA issuer `homelab-ca` by default; `letsencrypt-staging`/`letsencrypt-prod` issuers available for public domains (not `.local`/`.lan`) |
| External Secrets Operator | `INSTALL_EXTERNAL_SECRETS` (true) | Copies credentials from the central `secrets` namespace into app namespaces; see `docs/credentials.md` |
| local-path provisioner | always | Default storage class (host storage under K3s's data dir) |
| MinIO | always | S3-compatible object store; Velero backup target |
| Velero | `INSTALL_VELERO` (true) | Backup schedules below |
| ExternalDNS | `INSTALL_EXTERNAL_DNS` (false) | Cloudflare only; needs a real DNS zone and a `cloudflare-api-token` secret; runs `upsert-only` so it won't delete records it doesn't manage |
| CrowdSec | always | Agent + Traefik bouncer, wired into the request path: Traefik writes the access logs the agent reads, and the bouncer middleware is enforced on the `websecure` entrypoint |
| NetworkPolicies | always | `kubernetes/security/network-policies/` (default-deny for sensitive namespaces, DB access policies, egress rules). The separate `kubernetes/network-policies/` directory is a standalone toolkit the installer does not apply |
| Pod Security Admission | `POD_SECURITY_MODE` (audit) | `audit` warns only; set `enforce` to block non-compliant pods |
| Kyverno | `INSTALL_KYVERNO` (false) | Policy sets in `kubernetes/policy/kyverno/` (audit and enforce variants) |

## Monitoring (installed by default)

| Component | URL | Notes |
|---|---|---|
| Prometheus | internal | kube-prometheus-stack; PrometheusRules in `kubernetes/monitoring/alerts/` |
| Grafana | `grafana.` | Credentials via `grafana-admin` secret |
| Alertmanager | internal | Notification routing is opt-in: `CONFIGURE_ALERTING=true` + `docs/runbooks/alerting.md` |
| Blackbox exporter | internal | Synthetic HTTPS probes of key endpoints through Traefik |
| Uptime Kuma | `uptime.` | Standalone uptime monitoring and status pages |
| Loki | internal, optional | `INSTALL_LOGGING=true`; ship logs with `INSTALL_PROMTAIL=true`; see `docs/runbooks/logging.md` |

## Applications installed by default

**Core** (always):

| Service | URL | Purpose |
|---|---|---|
| Nextcloud | `nextcloud.` | Files/calendar/contacts. The one Helm-managed app (`helm/nextcloud/`), with a separate MySQL StatefulSet |
| Gitea | `git.` | Git hosting |
| Vaultwarden | `vault.` | Bitwarden-compatible password manager (admin panel at `/admin`) |
| Authelia | `auth.` | SSO/2FA; protects selected apps via Traefik ForwardAuth middleware |
| Homepage | `home.` | Dashboard with Kubernetes-aware widgets |

**Media** (`ENABLE_MEDIA_SERVICES=true` by default):

| Service | URL |
|---|---|
| Jellyfin | `jellyfin.` |
| Sonarr / Radarr / Prowlarr / Bazarr | `sonarr.` / `radarr.` / `prowlarr.` / `bazarr.` |
| Audiobookshelf | `audiobooks.` |

**Network** (`ENABLE_NETWORK_SERVICES=true` by default): Pi-hole (`pihole.`,
also provides wildcard DNS for the cluster), WireGuard (`vpn.`), dnsmasq DHCP.

**Content** (`ENABLE_CONTENT_SERVICES=true` by default): Calibre-web
(`books.`), SearXNG (`search.`), yarr (`rss.`).

**Productivity** (`ENABLE_PRODUCTIVITY_SERVICES=true` by default):
Paperless-ngx (`docs.`), Mealie (`recipes.`), Linkwarden (`bookmarks.`),
n8n (`automation.`).

## Applications that are opt-in

| Service | URL | Toggle |
|---|---|---|
| Immich (photos; server + ML + Postgres/pgvecto + Redis) | `photos.` | `ENABLE_AI_SERVICES=true` |
| Ollama (LLM runtime; large storage, heavy CPU/RAM) | `ai.` | `ENABLE_AI_SERVICES=true` |
| Open WebUI (chat UI for Ollama; behind Authelia) | `chat.` | `ENABLE_AI_SERVICES=true` |
| Drone CI | `drone.` | `ENABLE_DEV_SERVICES=true` |
| Harbor (container registry, installed via in-cluster Helm job) | — | `ENABLE_DEV_SERVICES=true` |
| ArgoCD | `argocd.` | `ENABLE_GITOPS=true` |

## In the repo but NOT installed

These directories under `kubernetes/services/` contain manifests the installer
never applies. They follow the same conventions (pinned images, security
contexts, ExternalSecrets) but have had less scrutiny — review before use,
then `kubectl apply -f kubernetes/services/<name>/`:

actual-budget, code-server, gatus, heimdall, home-assistant (+ Node-RED,
Zigbee2MQTT, Mosquitto), hoppscotch, jellyseerr, keycloak (ingress host
`keycloak.<domain>` — `auth.` belongs to Authelia), localai, matrix,
mattermost, metabase, navidrome, nocodb, outline, qbittorrent, romm, tautulli,
umami, whisper.

Older and higher-risk manifests that used to live in `extras/` and `legacy/`
are preserved on the `archive/legacy` branch.

## Dependencies

- Every web UI is reached through Traefik; certificates come from
  cert-manager.
- Every credential flows `generate-secrets.sh` → `secrets` namespace →
  ExternalSecret → app namespace. If ESO is down, new pods can't get secrets.
- Databases are separate StatefulSet-style Deployments per app (Postgres for
  Immich/Gitea/n8n etc., MySQL for Nextcloud, Redis where needed) — never
  sidecars.
- Open WebUI depends on Ollama; the arr-stack shares a common storage PVC.

## Backups

Velero schedules (`kubernetes/backup/velero/schedules.yaml`):

| Schedule | Cron | Scope |
|---|---|---|
| daily | `0 2 * * *` | Application namespaces |
| weekly | `0 3 * * 0` | All user namespaces |
| monthly | `0 4 1 * *` | Everything except system namespaces |
| critical | `0 */6 * * *` | Vaultwarden, Nextcloud, Gitea, and the `secrets` namespace |

Secret values themselves are backed up separately and encrypted:
`./scripts/backup-secrets.sh` (age). Restore order and verification:
`docs/runbooks/backup-restore.md`.

## Resource expectations

Every container declares CPU/memory requests and limits in its manifest —
check `kubernetes/services/<name>/` for specifics. Summed across the full
stack, memory requests alone are ~25 GiB; a default install with the AI and
dev toggles off fits comfortably in 16 GB, and a trimmed selection in 8 GB.
Prometheus (50Gi), MinIO (100Gi), Nextcloud (100Gi), and media libraries
dominate storage.

## Scaling and customization

- Config lives in each service's ConfigMap/Deployment; edit and
  `kubectl apply -f`, or change the source of truth here and re-run
  `./setup-v2.sh` (idempotent).
- HPAs exist for bursty services (Immich, Open WebUI, and others).
- Do not scale database Deployments past 1 replica — none are clustered.

## Adding a new service

Follow the checklist in `CLAUDE.md`: create
`kubernetes/services/<name>/` (namespace/deployment/service/ingress, plus
`pdb.yaml` and `servicemonitor.yaml` where warranted), add an ExternalSecret
for credentials and a matching entry in `scripts/generate-secrets.sh`, add a
NetworkPolicy under `kubernetes/security/network-policies/`, and wire the
directory into the appropriate `setup_*_services` function in `setup-v2.sh` —
a directory alone does not deploy.
