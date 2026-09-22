# Services

What `setup-v2.sh` installs and what each piece is for. URLs are
`<name>.<domain>` with the domain from `config/homelab.yaml`.

Applications are a **catalogue**: every `kubernetes/services/<name>/` carries a
`service.yaml` descriptor (namespace, group, opt-in flag, ordered install
steps). `./scripts/services.sh list` prints it; `./scripts/services.sh check`
is what CI runs. A service's `group` is one row of `SERVICE_GROUPS` in
`scripts/lib/services.sh` -- the one place a group's toggle, its default and
its ArgoCD AppProject are written, in install order. The installer seeds its
toggles from it and the generated app-of-apps reads the same defaults, so this
table is a copy for readers; change the rows, not this:

| Group | Toggle (default) | ArgoCD project |
|---|---|---|
| `core` | always | `homelab-infrastructure` |
| `media` | `ENABLE_MEDIA_SERVICES` (true) | `homelab-media` |
| `network` | `ENABLE_NETWORK_SERVICES` (true) | `homelab-infrastructure` |
| `dev` | `ENABLE_DEV_SERVICES` (false) | `homelab-infrastructure` |
| `content` | `ENABLE_CONTENT_SERVICES` (true) | `homelab-productivity` |
| `ai` | `ENABLE_AI_SERVICES` (false) | `homelab-ai` |
| `productivity` | `ENABLE_PRODUCTIVITY_SERVICES` (true) | `homelab-productivity` |
| `home` | `ENABLE_HOME_SERVICES` (false) | `homelab-infrastructure` |
| `communication` | `ENABLE_COMMUNICATION_SERVICES` (false) | `homelab-productivity` |
| `monitoring` | `INSTALL_MONITORING` (true) | `homelab-infrastructure` |
| `logging` | `INSTALL_LOGGING` (false) | `homelab-infrastructure` |

A descriptor's own `project:` wins over its group's (Authelia, Keycloak and
Vaultwarden are in `homelab-security`). A group's default is also what
"installed by default" means in the generated app-of-apps.

The same catalogue generates the ArgoCD app-of-apps
(`kubernetes/gitops/argocd/apps/services/`, see `kubernetes/gitops/argocd/README.md`),
drives the KinD harness (`KIND_SERVICE_GROUPS`, default `core network content`)
and `test/validate.sh`.

A service marked `optin: true` additionally needs its name in
`OPTIN_SERVICES` (space or comma separated, or `all`):

```bash
OPTIN_SERVICES="gatus jellyseerr navidrome" ./setup-v2.sh
./scripts/services.sh install gatus      # one service into the current cluster
```

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
| NetworkPolicies | always | Per-namespace isolation is declared in each service's `service.yaml` (`networkPolicies:`, rendered from `kubernetes/security/network-policies/templates/` by `scripts/lib/netpol.sh`); infrastructure namespaces, Nextcloud and the finer per-pod DB/egress rules stay in `kubernetes/security/network-policies/*.yaml` |
| Pod Security Admission | `POD_SECURITY_MODE` (audit) | `audit` warns only; set `enforce` to block non-compliant pods |
| Kyverno | `INSTALL_KYVERNO` (false) | Policy sets in `kubernetes/policy/kyverno/` (audit and enforce variants) |

Every Helm-installed piece above is one row of `HELM_INFRA_RELEASES` in
`scripts/lib/helm.sh` (chart, namespace, version variable, values, toggle and
the pod selector its health check looks for), and
`./scripts/validate-setup.sh --infra` checks exactly those rows plus
local-path, MinIO, CrowdSec and ArgoCD. See ADR-0006.

## Monitoring (installed by default)

| Component | URL | Notes |
|---|---|---|
| Prometheus | internal | kube-prometheus-stack; PrometheusRules in `kubernetes/monitoring/alerts/` |
| Grafana | `grafana.` | Credentials via `grafana-admin` secret |
| Alertmanager | internal | Notification routing is opt-in: `CONFIGURE_ALERTING=true` + `docs/runbooks/alerting.md` |
| Blackbox exporter | internal | Synthetic HTTPS probes of key endpoints through Traefik |
| Uptime Kuma | `uptime.` | Standalone uptime monitoring and status pages |
| Loki | internal, optional | `INSTALL_LOGGING=true`; ship logs with `INSTALL_ALLOY=true` (Grafana Alloy, which replaced the end-of-life Promtail); see `docs/runbooks/logging.md` |

## Applications installed by default

**Core** (always):

| Service | URL | Purpose |
|---|---|---|
| Nextcloud | `nextcloud.` | Files/calendar/contacts. Helm chart (`helm/nextcloud/`) declared with `kind: helm` in its descriptor; separate MySQL StatefulSet |
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

## Applications behind a group toggle

| Service | URL | Toggle |
|---|---|---|
| Immich (photos; server + ML + Postgres/pgvecto + Redis) | `photos.` | `ENABLE_AI_SERVICES=true` |
| Ollama (LLM runtime; large storage, heavy CPU/RAM) | `ai.` | `ENABLE_AI_SERVICES=true` |
| Open WebUI (chat UI for Ollama; behind Authelia) | `chat.` | `ENABLE_AI_SERVICES=true` |
| Drone CI (no runner by default, see note below) | `drone.` | `ENABLE_DEV_SERVICES=true` |
| Harbor (container registry, installed via in-cluster Helm job) | — | `ENABLE_DEV_SERVICES=true` |
| Home Assistant, Mosquitto, Node-RED, Zigbee2MQTT | `hass.`, `nodered.`, `zigbee.` | `ENABLE_HOME_SERVICES=true` |
| Matrix (Synapse + Element) | `matrix.`, `element.` | `ENABLE_COMMUNICATION_SERVICES=true` |
| Mattermost | `mattermost.` | `ENABLE_COMMUNICATION_SERVICES=true` |
| ArgoCD | `argocd.` | `ENABLE_GITOPS=true` |

> **Drone has no runner.** Drone CI installs without a build runner, which is the
> secure default: the usual runner mounts the host Docker socket. A Docker-socket
> runner manifest is preserved on the `archive/legacy` branch if you want it.

## Opt-in services (`OPTIN_SERVICES`)

These have had less scrutiny than the defaults; they follow the same
conventions (pinned images, security contexts, ExternalSecrets) and their
secrets are already generated. Add them by name:

| Service | URL | Group |
|---|---|---|
| Actual Budget | `budget.` | productivity |
| Cloudflare Tunnel (`cloudflared`; no URL, publishes services outbound-only; needs the user-supplied `cloudflare-tunnel-token` secret) | — | network |
| code-server | `code.` | dev |
| CyberChef | `cyberchef.` | productivity |
| Frigate (local NVR; needs Mosquitto from Home Assistant and, realistically, a Coral or iGPU) | `frigate.` | home |
| Gatus | `status.` | monitoring |
| Heimdall | `dashboard.` | core |
| Homebox | `inventory.` | productivity |
| Hoppscotch | `hoppscotch.` | dev |
| Intel device plugin (no URL; exposes `gpu.intel.com/i915` for transcoding and detection) | — | core |
| IT-Tools | `tools.` | productivity |
| Jellyseerr | `requests.` | media |
| Keycloak (`auth.` belongs to Authelia) | `keycloak.` | core |
| Kiwix (offline ZIM reader; download ZIMs yourself, see the deployment comments) | `library.` | content |
| kured (no URL; reboots the node when `/var/run/reboot-required` appears; hostPID + privileged by design) | — | core |
| LocalAI | `localai.` | ai |
| Longhorn (distributed block storage, snapshots, backups to MinIO; needs open-iscsi on the host) | `longhorn.` | core |
| Metabase | `metabase.` | productivity |
| Miniflux (feed reader, Postgres-backed; overlaps yarr) | `reader.` | content |
| Navidrome | `music.` | media |
| NocoDB | `nocodb.` | productivity |
| node-feature-discovery (no URL; labels nodes so the device plugins can target them) | — | core |
| ntfy | `ntfy.` | productivity |
| NVIDIA device plugin (no URL; exposes `nvidia.com/gpu`; needs the NVIDIA container toolkit on the host) | — | core |
| Outline | `wiki.` | productivity |
| qBittorrent | `torrent.` | media |
| Reloader (no URL; workloads opt in with the `reloader.stakater.com/auto: "true"` annotation) | — | core |
| Renovate (no URL; nightly CronJob opening dependency PRs, needs the user-supplied `renovate-token` secret and the repo name in its ConfigMap) | — | dev |
| RomM | `games.` | media |
| snapshot-controller (no URL; CSI VolumeSnapshot support, prerequisite for VolSync snapshot copies) | — | core |
| Stirling-PDF | `pdf.` | productivity |
| system-upgrade-controller (no URL; k3s server/agent upgrade Plans on the stable channel, opt in per node with `kubectl label node <name> k3s-upgrade=true`) | — | core |
| Tailscale operator (no URL; exposes services on your tailnet; needs the user-supplied `tailscale-oauth` secret) | — | network |
| Tautulli (Plex statistics; Plex-only, so it is useful here only if you run Plex somewhere alongside this cluster's Jellyfin) | `stats.` | media |
| Umami | `analytics.` | productivity |
| VolSync (no URL; PVC replication and restic backups to MinIO) | — | core |
| Whisper | `whisper.` | ai |

Storage, remote access and hardware acceleration (Longhorn, VolSync,
snapshot-controller, the Tailscale operator, node-feature-discovery and the
Intel/NVIDIA device plugins) have host prerequisites: see
`docs/runbooks/storage-and-hardware.md`.

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

Create `kubernetes/services/<name>/` with `namespace.yaml`, the workload
manifests (plus `pdb.yaml` and `servicemonitor.yaml` where warranted), an
ExternalSecret for credentials and a matching entry in
`scripts/generate-secrets.sh`, and a `service.yaml` descriptor:

```yaml
namespace: <name>
group: productivity     # picks the toggle (table above)
optin: true             # omit for services that should install by default
url: <host-prefix>
description: One line
steps:                  # only when order matters; everything else applies after, sorted
  - apply: postgres-deployment.yaml
    wait: app=<name>-postgres
networkPolicies: [default-deny, allow-dns, allow-ingress, allow-monitoring, allow-same-namespace]
```

`networkPolicies:` is the service's network isolation. Each name is a policy
template in `kubernetes/security/network-policies/templates/`; the installer
renders every listed template into the service's namespace
(`scripts/lib/netpol.sh`). The five above are the standard set: deny
everything, then allow DNS, Traefik, Prometheus scraping and same-namespace
traffic (app to its database). Add `allow-external-https` only when the app
fetches from the internet (feeds, models, webhooks); it excludes private
ranges, so it never opens the LAN or other namespaces. Leave the key out for
a service that must talk to the LAN or the Kubernetes API (Home Assistant,
Homepage) until a template expresses that. An unknown template name fails
the install and `./scripts/ci.sh`. Cross-namespace rules (one app reaching
another's database) are not templates; add them to
`kubernetes/security/network-policies/*.yaml`.

Nothing in `setup-v2.sh` changes. `./scripts/ci.sh` fails on a directory
without a descriptor, and renders every service through the same code path
the installer uses.
