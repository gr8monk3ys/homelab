# Homelab additions: what else to run, and what peer homelabs do that we don't

Researched 2026-09-21 against primary sources (project READMEs, repo trees,
manifests). Every claim links to the source that owns it. Where a source was
blocked by the egress proxy it is said so; nothing below is inferred from
secondary write-ups.

## Summary

- **Project NOMAD** is an Apache-2.0, Docker-Compose-based "offline-first
  knowledge and education server" (37.7k stars). It is not a Kubernetes
  project, but its *catalog* maps cleanly onto new `kubernetes/services/<name>/`
  directories: Kiwix (offline Wikipedia/medical/DIY ZIMs), Kolibri (Khan Academy
  offline), PMTiles offline maps, Qdrant (RAG for the Ollama chat we already
  ship), CyberChef, FlatNotes, Stirling-PDF, Homebox, IT-Tools, Excalidraw,
  Meshtastic web. Half of what it bundles (Ollama, Vaultwarden, Jellyfin,
  Calibre-web) this repo already has.
- **Peer Kubernetes homelabs** (onedr0p, bjw-s, khuedoan, billimek) converge on
  a platform layer this repo lacks: Flux + Renovate for GitOps and dependency
  bumps, Cilium as CNI, Rook-Ceph or Longhorn for storage, external-secrets
  backed by 1Password/Bitwarden, Cloudflare Tunnel or Tailscale for ingress,
  Gateway API (Envoy Gateway) instead of Ingress, VolSync/Kopia-based PVC
  backups next to or instead of Velero, Reloader, Descheduler, Spegel,
  smartctl-exporter, and Gatus with auto-discovery.
- **Shortlist (top 15)** is at the end: Kiwix, Renovate, Reloader,
  Cloudflare Tunnel / Tailscale, ntfy, Gatus wired in with gatus-sidecar,
  system-upgrade-controller, Longhorn, VolSync, Miniflux, Karakeep, Homebox,
  Stirling-PDF, IT-Tools, Frigate, Homarr/Glance.

## 1. Project NOMAD (Crosstalk-Solutions/project-nomad)

**What it is.** "Project NOMAD is a self-contained, offline-first knowledge and
education server packed with critical tools, knowledge, and AI to keep you
informed and empowered — anytime, anywhere."
([README](https://github.com/Crosstalk-Solutions/project-nomad)). GitHub
metadata: Apache-2.0, TypeScript, 37,761 stars, 3,760 forks, created
2025-06-24, last push 2026-09-13, homepage projectnomad.us
([GitHub API via search](https://github.com/Crosstalk-Solutions/project-nomad)).
The homepage `www.projectnomad.us` was blocked by the egress proxy.

**How it deploys.** A one-line `curl … install/install_nomad.sh | sudo bash` on
"any Debian-based operating system" (Ubuntu 26.04 LTS recommended), or a
Docker Compose template
([README](https://github.com/Crosstalk-Solutions/project-nomad)). The installer
installs Docker CE, downloads `install/management_compose.yaml`, generates
`APP_KEY`/`DB_PASSWORD`/`MYSQL_*`, creates `/opt/project-nomad`, and detects
NVIDIA (installs nvidia-container-toolkit) or AMD (writes gfx markers for
ROCm) GPUs
([install_nomad.sh](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/install/install_nomad.sh)).
The core stack is a "Command Center" (AdonisJS) that orchestrates the other
apps over the Docker socket ("DooD" pattern; containers prefixed `nomad_`)
([FAQ](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/FAQ.md)).
Core compose services
([management_compose.yaml](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/install/management_compose.yaml)):

| Service | Image | Ports | Notes |
|---|---|---|---|
| admin | `ghcr.io/crosstalk-solutions/project-nomad:latest` | 8080:8080 | mounts `/var/run/docker.sock` |
| dozzle | `amir20/dozzle:v10.0` | 9999:8080 | log viewer, docker socket |
| mysql | `mysql:8.0` | — | |
| redis | `redis:7-alpine` | — | |
| updater | `ghcr.io/crosstalk-solutions/project-nomad-sidecar-updater:latest` | — | docker socket |
| disk-collector | `ghcr.io/crosstalk-solutions/project-nomad-disk-collector:latest` | — | mounts `/` read-only |

Hardware: minimum "2 GHz dual-core", "4GB RAM", "5 GB free"; with AI "AMD
Ryzen 7 or Intel Core i7", "32 GB", "NVIDIA RTX 3060 or AMD equivalent",
"250 GB … SSD" ([README](https://github.com/Crosstalk-Solutions/project-nomad)).
x86-64 only; ARM/macOS unsupported officially
([FAQ](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/FAQ.md)).

**Why it does not port as-is.** The Command Center is a Docker-socket
orchestrator; that is the one piece with no Kubernetes equivalent and it
violates this repo's container rules (drop-ALL, non-root). Everything it
*launches* is an ordinary upstream image, so the right move is to add those
apps as `kubernetes/services/<name>/` directories and let Homepage play the
role of the "Supply Depot" catalog.

**The app catalog** (exact strings from
[admin/database/seeders/service_seeder.ts](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/admin/database/seeders/service_seeder.ts)):

| NOMAD service | Image | Container port / volume | Already in this repo? |
|---|---|---|---|
| KIWIX | `ghcr.io/kiwix/kiwix-serve:3.8.1` | 8090, `/zim` | no |
| QDRANT | `qdrant/qdrant:v1.16` | 6333, 6334, `/qdrant/storage` | no |
| OLLAMA | `ollama/ollama:0.24.0` | 11434, `/root/.ollama` | yes (opt-in) |
| CYBERCHEF | `ghcr.io/gchq/cyberchef:10.24.0` | 8100 | no |
| FLATNOTES | `dullage/flatnotes:v5.5.4` | 8200, `/data` | no |
| KOLIBRI_GEN2 | `learningequality/kolibri:0.19.4` | 8310, 8311, `/kolibri` | no |
| STIRLING_PDF | `ghcr.io/stirling-tools/s-pdf:2.13.1` | 8400, `/configs`, `/logs` | no |
| FILEBROWSER | `filebrowser/filebrowser:v2` | 8410 | no |
| CALIBREWEB | `linuxserver/calibre-web:0.6.26-ls386` | 8420 | yes |
| IT_TOOLS | `ghcr.io/corentinth/it-tools:2024.10.22-7ca5933` | 8430 | no |
| EXCALIDRAW | `excalidraw/excalidraw:sha-4bfc5bb` | 8440 | no |
| MESHTASTIC_WEB | `ghcr.io/meshtastic/web:2.7.1` | 8450 | no |
| MESHCORE_WEB | `ghcr.io/axistem-dev/meshcore-web:v1.45.0` | 8500 (HTTPS) | no |
| HOMEBOX | `ghcr.io/sysadminsmedia/homebox:0.26.2` | 8470, `/data` | no |
| VAULTWARDEN | `vaultwarden/server:1.36.0` | 8480 | yes |
| JELLYFIN | `jellyfin/jellyfin:10.11.11` | 8490 | yes |

Ports above are NOMAD's host-side allocations; upstream defaults differ (Kiwix
8080, CyberChef 8080, FlatNotes 8080, Homebox 7745, IT-Tools 80).

Offline maps are not a container: the admin image bundles the `pmtiles` binary
(`/usr/local/bin/pmtiles`, per-arch SHA pinned in the
[Dockerfile](https://github.com/Crosstalk-Solutions/project-nomad/blob/main/Dockerfile))
and runs `pmtiles extract` jobs against the Protomaps CDN
([admin/constants/map_regions.ts](https://github.com/Crosstalk-Solutions/project-nomad/blob/main/admin/constants/map_regions.ts),
[run_extract_pmtiles_job.ts](https://github.com/Crosstalk-Solutions/project-nomad/blob/main/admin/app/jobs/run_extract_pmtiles_job.ts)).
Pre-built US state topo maps (28 MB Hawaii to 1,100 MB California, PMTiles,
2025-12) are catalogued in
[collections/maps.json](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/collections/maps.json)
and hosted in
[project-nomad-maps](https://github.com/Crosstalk-Solutions/project-nomad-maps).
ZIM content is a curated list of `download.kiwix.org` files in six categories
(Medicine, Survival, Education, DIY, Agriculture, Computing; 1 MB to 16.5 GB)
in [collections/kiwix-categories.json](https://raw.githubusercontent.com/Crosstalk-Solutions/project-nomad/main/collections/kiwix-categories.json);
`install/` ships `wikipedia_en_100_mini_2026-01.zim` as a starter
([install/ tree](https://github.com/Crosstalk-Solutions/project-nomad/tree/main/install)).

**Mapping onto this repo** (new directories, all fit the existing conventions):

- `kiwix/` — `ghcr.io/kiwix/kiwix-serve`, GPLv3+, "HTTP daemon serving ZIM
  files"; upstream runs `docker run -v /tmp/zim:/data -p 8080:8080
  ghcr.io/kiwix/kiwix-serve wikipedia.zim` or `'*.zim'`
  ([kiwix-tools](https://github.com/kiwix/kiwix-tools),
  [docker README](https://github.com/kiwix/kiwix-tools/blob/main/docker/server/README.md)).
  One PVC of ZIMs, optionally a CronJob that `curl`s from download.kiwix.org.
  No DB. Largest single win from NOMAD.
- `kolibri/` — `learningequality/kolibri`, MIT, "offline-first platform for
  teaching and learning" ([kolibri](https://github.com/learningequality/kolibri)).
  Single container, SQLite by default.
- `pmtiles/` — `pmtiles serve` from go-pmtiles (BSD-3-Clause; Dockerfile in
  repo) ([go-pmtiles](https://github.com/protomaps/go-pmtiles)). The CLI docs
  at docs.protomaps.com were blocked; port/flags need checking there. Could
  also serve `.pmtiles` straight from the existing MinIO with range requests.
- `qdrant/` — `qdrant/qdrant`, Apache-2.0, REST 6333 / gRPC 6334
  ([qdrant](https://github.com/qdrant/qdrant)). Only worth adding as the RAG
  store for Open WebUI + Ollama, which we already ship.
- `cyberchef/`, `it-tools/`, `excalidraw/` — static, no DB, trivial
  Deployments (CyberChef Apache-2.0 `ghcr.io/gchq/cyberchef` port 8080
  ([CyberChef](https://github.com/gchq/CyberChef)); IT-Tools GPLv3
  `ghcr.io/corentinth/it-tools` port 80 ([it-tools](https://github.com/CorentinTh/it-tools))).
- `flatnotes/` — MIT, `dullage/flatnotes`, port 8080, flat Markdown folder,
  `FLATNOTES_AUTH_TYPE`/`FLATNOTES_SECRET_KEY` env → one ExternalSecret
  ([flatnotes](https://github.com/dullage/flatnotes)). Overlaps Outline
  (manifest-only) and Nextcloud Notes.
- `stirling-pdf/` and `homebox/` — see shortlist.

## 2. What peer homelabs run that we don't

Repos examined: [onedr0p/home-ops](https://github.com/onedr0p/home-ops),
[bjw-s-labs/home-ops](https://github.com/bjw-s-labs/home-ops),
[khuedoan/homelab](https://github.com/khuedoan/homelab),
[billimek/k8s-gitops](https://github.com/billimek/k8s-gitops). kubesearch.dev
was blocked by the egress proxy; its source repo says it indexes "Flux
HelmReleases through awesome k8s-at-home projects" from repos tagged
`k8s-at-home`/`kubesearch` ([k8s-at-home-search](https://github.com/whazor/k8s-at-home-search)),
so popularity counts could not be pulled. awesome-selfhosted.net was blocked;
the raw README was fetched but truncated by the fetcher after the "Document
Management" category ([awesome-selfhosted README](https://raw.githubusercontent.com/awesome-selfhosted/awesome-selfhosted/master/README.md)).

### 2a. Platform layer

| Area | What peers do | This repo | Gap / note |
|---|---|---|---|
| Cluster OS | Talos (onedr0p, bjw-s, billimek); Fedora + K3s (khuedoan) | K3s on any host | Fine; khuedoan proves K3s is a normal choice ([khuedoan README](https://github.com/khuedoan/homelab)) |
| GitOps | Flux (onedr0p "Flux watches the clusters in my kubernetes folder", bjw-s, billimek); ArgoCD (khuedoan) | ArgoCD opt-in, imperative installer default | Flux is CNCF-graduated with native SOPS ([flux2](https://github.com/fluxcd/flux2)); ArgoCD+KSOPS is a legitimate alternative, keep it |
| Dependency updates | Renovate in all four ("opening pull requests when it detects a new container image update or a new helm chart" — [billimek](https://raw.githubusercontent.com/billimek/k8s-gitops/master/README.md)); khuedoan runs it in-cluster (`platform/renovate`) | Dependabot for Actions only | **Biggest process gap**: 43 pinned image tags + `tools/versions.env` with no automation. docs.renovatebot.com was blocked; use the [renovate repo](https://github.com/renovatebot/renovate). CI-minutes cap means self-hosted Renovate CronJob (khuedoan pattern) beats the GitHub App |
| CNI | Cilium in onedr0p, bjw-s, khuedoan ("eBPF-based Networking … CNI, LB, Network Policy") | K3s default Flannel + MetalLB | Cilium replaces kube-proxy, has L2 announcements and LB-IPAM (replaces MetalLB), Hubble ([cilium](https://github.com/cilium/cilium)). docs.k3s.io was blocked; the `--flannel-backend=none` recipe needs verifying there |
| Multi-NIC | Multus in onedr0p and bjw-s `kube-system` | none | Needed for Home Assistant/Zigbee mDNS, macvlan ([multus-cni](https://github.com/k8snetworkplumbingwg/multus-cni)) |
| Image mirror | Spegel (onedr0p: "stateless, cluster-local OCI image mirror") | none | MIT, chart in repo ([spegel](https://github.com/spegel-org/spegel)). Only useful multi-node |
| Storage | Rook-Ceph (onedr0p, khuedoan, billimek `rook-ceph/`); bjw-s uses none of Longhorn/Rook (snapshot-controller only) | local-path + MinIO | Single node → Rook is overkill. Longhorn (Apache-2.0, CNCF incubating, `helm repo add longhorn https://charts.longhorn.io`, snapshots + backup to NFSv4/S3) is the K3s-native step up ([longhorn](https://github.com/longhorn/longhorn)); longhorn.io requirements page was blocked. democratic-csi covers TrueNAS/ZFS/NFS/SMB/local-hostpath ([democratic-csi](https://github.com/democratic-csi/democratic-csi)) |
| CSI snapshots | `snapshot-controller` in onedr0p and bjw-s kube-system | none | Prerequisite for VolSync/Velero CSI snapshots |
| Secrets | external-secrets + 1Password Connect (onedr0p, ~$65/yr); bjw-s `external-secrets/`; khuedoan `platform/external-secrets` + `global-secrets` | ESO over an in-cluster `secrets` namespace | Same operator, so a 1Password/Bitwarden Secrets Manager `ClusterSecretStore` is a config change, not a rewrite. external-secrets.io provider docs were blocked |
| Ingress | Envoy Gateway (Gateway API) in onedr0p `network/envoy-gateway` and bjw-s; ingress-nginx (khuedoan) | Traefik | Gateway API migration is optional; Traefik implements it too. Envoy Gateway is Apache-2.0 ([gateway](https://github.com/envoyproxy/gateway)) |
| Public exposure | Cloudflare Tunnel: onedr0p `cloudflare-tunnel`, khuedoan `system/cloudflared` ("Expose services to the internet securely with Cloudflare Tunnel") | port-forward assumed; WireGuard | `cloudflare/cloudflared`, Apache-2.0 ([cloudflared](https://github.com/cloudflare/cloudflared)). No inbound ports, pairs with existing ExternalDNS-Cloudflare |
| Remote access | Tailscale (khuedoan `apps/tailscale`, "VPN without port forwarding") | WireGuard | Tailscale k8s operator lives in `cmd/k8s-operator` with `deploy/` ([tailscale](https://github.com/tailscale/tailscale/tree/main/cmd/k8s-operator)); tailscale.com KB was blocked |
| Identity | Kanidm (khuedoan, bjw-s `security/kanidm-operator`); Dex (khuedoan) | Authelia; Keycloak manifest-only | Kanidm MPL-2.0: OIDC, LDAP gateway, RADIUS, passkeys ([kanidm](https://github.com/kanidm/kanidm)). Authentik MIT core + EE licence, needs Postgres+Redis ([authentik](https://github.com/goauthentik/authentik)). Pocket ID BSD-2, passkey-only OIDC ([pocket-id](https://github.com/pocket-id/pocket-id)). Authelia already covers ForwardAuth; only add an IdP if you need OIDC for many apps |
| Databases | CloudNativePG-style operators; bjw-s `database/dragonfly-operator` | one Postgres/MySQL Deployment per app | CNPG (Apache-2.0, CNCF sandbox, failover + `ScheduledBackup` to S3) would replace N hand-rolled Postgres Deployments ([cloudnative-pg](https://github.com/cloudnative-pg/cloudnative-pg)); Dragonfly = Redis-compatible with S3 snapshots ([dragonfly-operator](https://github.com/dragonflydb/dragonfly-operator)) |
| Backups | kopiur (onedr0p, bjw-s `system/kopiur` + `kopia`); VolSync (khuedoan `system/volsync-system`) | Velero → MinIO | kopiur: "Kopia-native Kubernetes backup operator written in Rust", AGPL-3.0, CRDs `Repository`/`SnapshotPolicy`/`SnapshotSchedule`/`Restore`, `helm install kopiur oci://ghcr.io/home-operations/charts/kopiur` ([kopiur](https://github.com/home-operations/kopiur)). VolSync AGPL-3.0, restic/rclone/rsync movers, expects CSI snapshots ([volsync](https://github.com/backube/volsync)). Kopia itself: Apache-2.0, dedupe+encryption+compression, S3 backend ([kopia](https://github.com/kopia/kopia)) |
| Config reload | Reloader in onedr0p and bjw-s | none | "watch changes in ConfigMap and Secrets and do rolling upgrades", Apache-2.0, `stakater/reloader` ([Reloader](https://github.com/stakater/Reloader)). Directly fixes the ESO-rotates-secret-but-pod-keeps-old-value problem |
| Scheduling | Descheduler (onedr0p, bjw-s) | none | Apache-2.0, official chart since v0.18.0 ([descheduler](https://github.com/kubernetes-sigs/descheduler)). Multi-node only |
| Node upgrades | system-upgrade-controller (onedr0p, billimek `system-upgrade/`); kured (khuedoan `system/kured`); tuppr (billimek, Talos) | none | SUC: "Kubernetes-native upgrade controller (for nodes)", `Plan` CRD, `kubectl apply -k github.com/rancher/system-upgrade-controller` ([SUC](https://github.com/rancher/system-upgrade-controller)). kured: reboots when `/var/run/reboot-required` appears, CNCF sandbox ([kured](https://github.com/kubereboot/kured)); pairs with the Ansible unattended-upgrades |
| Hardware | intel-gpu-resource-driver (onedr0p, bjw-s); NFD; NVIDIA plugin | none | Intel plugin exposes `gpu.intel.com/i915`/`xe` ([intel](https://github.com/intel/intel-device-plugins-for-kubernetes)); NVIDIA `nvidia.com/gpu`, needs nvidia-container-toolkit ([nvidia](https://github.com/NVIDIA/k8s-device-plugin)); NFD labels `feature.node.kubernetes.io/*` ([NFD](https://github.com/kubernetes-sigs/node-feature-discovery)). Needed for Jellyfin transcoding, Immich ML, Ollama, Frigate |
| Observability | kube-prometheus-stack + blackbox (all); Gatus + gatus-sidecar (onedr0p, bjw-s); VictoriaLogs (onedr0p, bjw-s) instead of Loki; smartctl-exporter; snmp-exporter; kromgo; grafana-operator; silence-operator; prometheus-adapter | kube-prometheus-stack, blackbox, Uptime Kuma, Loki opt-in, Gatus manifest-only | gatus-sidecar "turns Ingress, Service, Gateway API HTTPRoute, and Traefik IngressRoute resources into Gatus endpoint configuration, automatically" ([gatus-sidecar](https://github.com/home-operations/gatus-sidecar)). smartctl-exporter needs root/privileged ([smartctl_exporter](https://github.com/prometheus-community/smartctl_exporter)). VictoriaLogs Apache-2.0 "zero-config, schema-free" ([VictoriaLogs](https://github.com/VictoriaMetrics/VictoriaLogs)). Grafana Alloy = OTel collector distribution, Apache-2.0 ([alloy](https://github.com/grafana/alloy)) — the modern replacement for the Promtail we ship |
| Cluster UI | — (none of the four) | — | Headlamp Apache-2.0, now under Kubernetes SIG UI, chart in `charts/headlamp` ([headlamp](https://github.com/headlamp-k8s/headlamp)). Nice-to-have |
| CI | Woodpecker (khuedoan); Forgejo (bjw-s `dev/forgejo`, billimek self-hosts on Forgejo with GitHub mirror); actions-runner-controller (onedr0p) | Gitea + Drone | Woodpecker Apache-2.0, ~100 MB RAM server, SQLite default ([woodpecker](https://github.com/woodpecker-ci/woodpecker)); Drone is the less-maintained ancestor. Forgejo on codeberg.org was blocked |
| Images | `ghcr.io/home-operations/*` (rootless 65534, semver, digest-pinned) | mix of lscr.io/official | Matches this repo's non-root rule for the *arr apps ([containers](https://github.com/home-operations/containers)) |
| Registry | Zot (khuedoan) | Harbor opt-in | Harbor is heavy for one node; note only |

### 2b. Applications

Directory names taken from the peers' trees
([onedr0p default](https://github.com/onedr0p/home-ops/tree/main/kubernetes/apps/default),
[bjw-s selfhosted](https://github.com/bjw-s-labs/home-ops/tree/main/kubernetes/apps/selfhosted),
[bjw-s media](https://github.com/bjw-s-labs/home-ops/tree/main/kubernetes/apps/media),
[bjw-s downloads](https://github.com/bjw-s-labs/home-ops/tree/main/kubernetes/apps/downloads),
[bjw-s home-automation](https://github.com/bjw-s-labs/home-ops/tree/main/kubernetes/apps/home-automation),
[bjw-s ai](https://github.com/bjw-s-labs/home-ops/tree/main/kubernetes/apps/ai),
[khuedoan apps](https://github.com/khuedoan/homelab/tree/master/apps)).

| App | Who runs it | Image / license / deps (from upstream) | Overlaps here |
|---|---|---|---|
| Home Assistant + go2rtc, zwave | onedr0p, bjw-s | `ghcr.io/home-assistant/home-assistant`, Apache-2.0, :8123 ([core](https://github.com/home-assistant/core)) | manifest-only `home-assistant/` — wire it in |
| Frigate | bjw-s | MIT, "local NVR … AI object detection", "GPU or AI accelerator is highly recommended", MQTT ([frigate](https://github.com/blakeblackshear/frigate)) | none; needs Mosquitto (present, unwired) and a device plugin |
| Plex / Jellyfin | onedr0p Plex; bjw-s, khuedoan Jellyfin | — | Jellyfin present |
| sabnzbd, autobrr, recyclarr, qui, seerr, slskd | onedr0p, bjw-s | Recyclarr MIT, `ghcr.io/recyclarr/recyclarr`, syncs TRaSH quality profiles/custom formats to Sonarr/Radarr, no `latest` tag ([recyclarr](https://github.com/recyclarr/recyclarr)) | arr-stack present; jellyseerr manifest-only |
| Immich | none of the four examined | AGPL-3.0, PostgreSQL + Redis/Valkey ([immich](https://raw.githubusercontent.com/immich-app/immich/main/README.md)) | present, opt-in |
| Paperless | bjw-s, khuedoan | GPL-3.0, `ghcr.io/paperless-ngx/paperless-ngx` ([paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)) | present |
| FreshRSS | bjw-s | AGPL-3, Postgres/SQLite/MySQL ([FreshRSS](https://github.com/FreshRSS/FreshRSS)) | yarr present |
| Karakeep | bjw-s | AGPL-3.0, `ghcr.io/karakeep-app/karakeep`, needs Meilisearch + headless Chrome, "LLM-based automatic tagging … with supports for local models using ollama" ([karakeep](https://github.com/karakeep-app/karakeep)) | Linkwarden present (same niche) |
| IT-Tools | bjw-s | above | none |
| Actual | bjw-s, khuedoan | — | manifest-only `actual-budget/` |
| Atuin sync | onedr0p, bjw-s | MIT, "encrypted synchronisation of your history … via an Atuin server" ([atuin](https://github.com/atuinsh/atuin)) | none |
| Navidrome, Audiobookshelf | bjw-s | Navidrome GPL-3.0 `deluan/navidrome` ([navidrome](https://github.com/navidrome/navidrome)) | both present (Navidrome manifest-only) |
| Nextcloud, SearXNG | bjw-s | — | present |
| Matrix, Excalidraw, PairDrop, speedtest, blog | khuedoan | — | Matrix manifest-only |
| ntfy | khuedoan ("send notifications to your phone or desktop") | Apache-2.0/GPLv2 dual, SQLite cache, FCM + web push + email ([ntfy](https://github.com/binwiederhier/ntfy)) | none; Alertmanager has no push target today |
| Open WebUI, LiteLLM, MCP servers | bjw-s `ai/` | — | Open WebUI present |
| Homepage | khuedoan | — | present |
| Forgejo / Woodpecker / Gitea | bjw-s, khuedoan | — | Gitea + Drone present |
| smtp-relay, thelounge, manyfold, mailkeep, bambuddy, dispatcharr, bonob | onedr0p, bjw-s | niche | none |

Popular apps from the awesome-selfhosted space that no examined peer runs but
are frequently requested, with upstream facts:

- **Miniflux** — Apache-2.0, "Works only with PostgreSQL", "a couple of MB of
  memory", `miniflux/miniflux` on :8080 ([miniflux](https://github.com/miniflux/v2),
  [compose](https://github.com/miniflux/v2/blob/main/contrib/docker-compose/basic.yml)). Overlaps yarr.
- **Homebox** — `ghcr.io/sysadminsmedia/homebox` (+rootless/hardened
  variants), SQLite, :7745 ([homebox](https://github.com/sysadminsmedia/homebox)); licence not stated on the page.
- **Stirling-PDF** — "open-core", `docker.stirlingpdf.com/stirlingtools/stirling-pdf`,
  :8080, no DB in the quick start ([Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF)). Complements Paperless.
- **Homarr** — Apache-2.0, `ghcr.io/homarr-labs/homarr`, :7575, "40+
  integrations", Helm chart ([homarr](https://github.com/homarr-labs/homarr)). Overlaps Homepage/Heimdall.
- **Glance** — AGPL-3.0, `glanceapp/glance`, :8080, YAML `glance.yml`
  ([glance](https://github.com/glanceapp/glance)). Feed dashboard, not a service launcher.
- **Dashy** — MIT, `lissy93/dashy`, :8080 ([dashy](https://github.com/Lissy93/dashy)). Overlaps Homepage.
- **Gotify** — MIT, `gotify/server` ([gotify](https://github.com/gotify/server)). ntfy is the more common pick.
- **Syncthing** — MPLv2 ([syncthing](https://github.com/syncthing/syncthing)); VolSync has a syncthing mover.
- **Vikunja** — AGPL-3.0, `vikunja/vikunja` ([vikunja](https://github.com/go-vikunja/vikunja)). **Planka** is fair-code, not OSI ([planka](https://github.com/plankanban/planka)).
- **Grocy** — MIT, SQLite, linuxserver image ([grocy](https://github.com/grocy/grocy)).
- **Firefly III** — AGPL-3 ([firefly-iii](https://github.com/firefly-iii/firefly-iii)); Actual already in repo.
- **Wakapi** — MIT, `ghcr.io/muety/wakapi`, SQLite default, :3000 ([wakapi](https://github.com/muety/wakapi)).
- **Radicale** — GPLv3, filesystem storage ([Radicale](https://github.com/Kozea/Radicale)); Nextcloud already does CalDAV/CardDAV.
- **Tube Archivist** — GPL-3.0, needs Elasticsearch + Redis, ~4 GB RAM ([tubearchivist](https://github.com/tubearchivist/tubearchivist)); **Pinchflat** — AGPL-3.0, "one Docker container with no external dependencies", :8945 ([pinchflat](https://github.com/kieraneglin/pinchflat)) is the lighter choice.
- **Kavita** — GPLv3, `jvmilazz0/kavita`, cbz/epub/pdf ([Kavita](https://github.com/Kareadita/Kavita)); **Komga** — MIT, `gotson/komga` ([komga](https://github.com/gotson/komga)). Overlap Calibre-web.
- **Speedtest Tracker** — MIT, LinuxServer image ([speedtest-tracker](https://github.com/alexjustesen/speedtest-tracker)).
- **Scrutiny** — MIT, `ghcr.io/analogj/scrutiny:*-omnibus|web|collector`, needs InfluxDB 2.x, collector needs `SYS_RAWIO`/`SYS_ADMIN` + `/dev` ([scrutiny](https://github.com/AnalogJ/scrutiny)). smartctl-exporter + Grafana is the lighter, Prometheus-native equivalent.
- **UnPoller** — MIT, `ghcr.io/unpoller/unpoller`, Prometheus/InfluxDB/Loki outputs ([unpoller](https://github.com/unpoller/unpoller)). Only if you own UniFi gear.
- **Semaphore** — MIT, `semaphoreui/semaphore`, :3000, SQLite ok, runs Ansible/Terraform/OpenTofu ([semaphore](https://github.com/semaphoreui/semaphore)). Natural UI for the `ansible/` tree.
- **Kestra** — Apache-2.0, `kestra/kestra`, :8080, Postgres in prod, Helm chart ([kestra](https://github.com/kestra-io/kestra)); **Windmill** — AGPLv3 + proprietary bits in images, Postgres ([windmill](https://github.com/windmill-labs/windmill)). n8n already present.
- **Coder** — AGPL-3.0 + EE, Postgres 13+, Kubernetes workspaces via Terraform ([coder](https://github.com/coder/coder)). code-server manifest-only is the lightweight cousin.
- **Tandoor** — AGPL-3 with commons clause, Postgres ([recipes](https://github.com/TandoorRecipes/recipes)); Mealie present. **Wallabag** MIT ([wallabag](https://github.com/wallabag/wallabag)); Linkwarden present. **BookStack** MIT ([BookStack](https://github.com/BookStackApp/BookStack)); Outline manifest-only.
- **OpenCloud** — Apache-2.0, Go, "does not use a database … stores all data in the filesystem", OIDC via embedded IdP or Keycloak ([opencloud](https://github.com/opencloud-eu/opencloud)). Lighter than the Nextcloud+MySQL stack if you only need files.

## 3. Prioritised shortlist

| # | Name | Category | Why | Deps | Overlaps with | Source |
|---|---|---|---|---|---|---|
| 1 | Renovate (self-hosted CronJob) | platform/process | 43 pinned images and a versions.env with no bump automation; every peer runs it | Gitea/GitHub token | Dependabot (Actions only) | [renovate](https://github.com/renovatebot/renovate), [khuedoan platform/renovate](https://github.com/khuedoan/homelab/tree/master/platform) |
| 2 | Reloader | platform | ESO-rotated secrets never reach running pods without it | none | — | [Reloader](https://github.com/stakater/Reloader) |
| 3 | Kiwix | knowledge (NOMAD) | The single most distinctive NOMAD feature; one image, one PVC | ZIM PVC | — | [kiwix-tools](https://github.com/kiwix/kiwix-tools) |
| 4 | Gatus + gatus-sidecar (wire in) | observability | Already in repo; sidecar auto-generates endpoints from Ingress/IngressRoute | SQLite/Postgres | Uptime Kuma, blackbox | [gatus](https://github.com/TwiN/gatus), [gatus-sidecar](https://github.com/home-operations/gatus-sidecar) |
| 5 | ntfy | notifications | Alertmanager/Gatus/Home Assistant need a push target | none | — | [ntfy](https://github.com/binwiederhier/ntfy) |
| 6 | Cloudflare Tunnel | ingress | Public exposure without port-forwarding; pairs with existing ExternalDNS-Cloudflare | CF account, token | WireGuard | [cloudflared](https://github.com/cloudflare/cloudflared) |
| 7 | system-upgrade-controller | platform | Automated K3s upgrades via `Plan`; `kured` for OS reboots | none | Ansible | [SUC](https://github.com/rancher/system-upgrade-controller), [kured](https://github.com/kubereboot/kured) |
| 8 | Longhorn | storage | Snapshots + S3 backup to MinIO on K3s; the step before Rook | open-iscsi on host | local-path | [longhorn](https://github.com/longhorn/longhorn) |
| 9 | VolSync (or kopiur) | backup | PVC-level restic/kopia backups to MinIO; Velero covers objects, not file deltas | snapshot-controller | Velero | [volsync](https://github.com/backube/volsync), [kopiur](https://github.com/home-operations/kopiur) |
| 10 | Home Assistant (wire in) + Frigate | home automation | Manifests exist; Frigate is the peer-standard NVR | Mosquitto, GPU/TPU, Multus for mDNS | — | [frigate](https://github.com/blakeblackshear/frigate) |
| 11 | Intel/NVIDIA device plugin + NFD | hardware | Unlocks Jellyfin transcode, Immich ML, Ollama, Frigate | host driver | — | [intel](https://github.com/intel/intel-device-plugins-for-kubernetes), [nvidia](https://github.com/NVIDIA/k8s-device-plugin) |
| 12 | Stirling-PDF + IT-Tools + CyberChef | tools (NOMAD) | Stateless, zero-dep, high daily utility | none | — | [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF), [it-tools](https://github.com/CorentinTh/it-tools), [CyberChef](https://github.com/gchq/CyberChef) |
| 13 | Homebox | inventory (NOMAD) | SQLite, single container, rootless image variant | none | — | [homebox](https://github.com/sysadminsmedia/homebox) |
| 14 | Miniflux | content | Postgres-only, MB-scale footprint; mature vs yarr | Postgres | yarr | [miniflux](https://github.com/miniflux/v2) |
| 15 | Kolibri + PMTiles | education/maps (NOMAD) | Completes the offline-knowledge story | PVCs | — | [kolibri](https://github.com/learningequality/kolibri), [go-pmtiles](https://github.com/protomaps/go-pmtiles) |

Honourable mentions: Karakeep (if Ollama tagging is wanted; else keep
Linkwarden), Homarr (only if Homepage's YAML-only config chafes), Semaphore (UI
for `ansible/`), CloudNativePG (consolidate the per-app Postgres Deployments),
smartctl-exporter (disk health without Scrutiny's InfluxDB), Woodpecker
(replace Drone), Cilium (only when going multi-node or wanting Hubble).

## Sources

Blocked by the egress proxy (could not be fetched): kubesearch.dev,
awesome-selfhosted.net, projectnomad.us, tailscale.com, longhorn.io,
docs.k3s.io, docs.renovatebot.com, external-secrets.io, codeberg.org,
docs.protomaps.com. GitHub API (`api.github.com`) returned 403; repo trees
were read from github.com HTML and raw.githubusercontent.com, plus GitHub
code search for project-nomad internals.

- https://github.com/Crosstalk-Solutions/project-nomad (README, FAQ, `install/`, `collections/`, `admin/database/seeders/service_seeder.ts`, `Dockerfile`)
- https://github.com/Crosstalk-Solutions/project-nomad-maps
- https://github.com/onedr0p/home-ops (README; `kubernetes/apps/{default,o11y,network,kube-system,kopiur-system}`)
- https://github.com/bjw-s-labs/home-ops (`kubernetes/apps/*`)
- https://github.com/khuedoan/homelab (README; `apps/`, `platform/`, `system/`)
- https://github.com/billimek/k8s-gitops (README; `kubernetes/`)
- https://github.com/whazor/k8s-at-home-search
- https://raw.githubusercontent.com/awesome-selfhosted/awesome-selfhosted/master/README.md
- Platform: fluxcd/flux2, renovatebot/renovate, cilium/cilium, k8snetworkplumbingwg/multus-cni, spegel-org/spegel, longhorn/longhorn, rook/rook, democratic-csi/democratic-csi, cloudflare/cloudflared, tailscale/tailscale, envoyproxy/gateway, goauthentik/authentik, pocket-id/pocket-id, kanidm/kanidm, cloudnative-pg/cloudnative-pg, dragonflydb/dragonfly-operator, backube/volsync, home-operations/kopiur, kopia/kopia, stakater/Reloader, kubernetes-sigs/descheduler, rancher/system-upgrade-controller, kubereboot/kured, intel/intel-device-plugins-for-kubernetes, NVIDIA/k8s-device-plugin, kubernetes-sigs/node-feature-discovery, headlamp-k8s/headlamp, grafana/alloy, VictoriaMetrics/VictoriaLogs, prometheus-community/smartctl_exporter, kashalls/kromgo, TwiN/gatus, home-operations/gatus-sidecar, home-operations/containers, woodpecker-ci/woodpecker
- Apps: kiwix/kiwix-tools, learningequality/kolibri, protomaps/go-pmtiles, qdrant/qdrant, gchq/CyberChef, dullage/flatnotes, blakeblackshear/frigate, home-assistant/core, miniflux/v2, FreshRSS/FreshRSS, sysadminsmedia/homebox, karakeep-app/karakeep, Stirling-Tools/Stirling-PDF, CorentinTh/it-tools, Kareadita/Kavita, gotson/komga, kieraneglin/pinchflat, alexjustesen/speedtest-tracker, homarr-labs/homarr, glanceapp/glance, Lissy93/dashy, binwiederhier/ntfy, gotify/server, syncthing/syncthing, go-vikunja/vikunja, plankanban/planka, grocy/grocy, firefly-iii/firefly-iii, muety/wakapi, Kozea/Radicale, tubearchivist/tubearchivist, unpoller/unpoller, AnalogJ/scrutiny, semaphoreui/semaphore, kestra-io/kestra, windmill-labs/windmill, coder/coder, TandoorRecipes/recipes, wallabag/wallabag, BookStackApp/BookStack, opencloud-eu/opencloud, atuinsh/atuin, recyclarr/recyclarr, immich-app/immich, navidrome/navidrome, paperless-ngx/paperless-ngx, louislam/uptime-kuma
