---
status: accepted
date: 2026-11-14
amends: 0011
---

# Native K3s on the Linux host, VolSync backups to B2, Jellyfin in the cluster

ADR 0011 was written for the Windows PC: K3s in Docker Desktop through k3d,
the bulk tree at `D:\30 Media\homelab`, Plex native on Windows. That PC was
wiped and now runs Arch Linux (Omarchy) with Docker Engine, the RTX 3090 and
the same RAID 5. The wipe also lost everything that lived only on the PC: the
Immich database, Garage's metadata, every generated credential and the old age
key. The backups the old installer could make sat on the same disks.

## Decision

- **K3s runs natively under systemd**, installed and pinned by
  `host/setup.sh` (`host/k3s-config.yaml`). No k3d: the GPU, the RAID and the
  LAN address need no container plumbing, servicelb binds the host's ports,
  and the kubelet is not inside a container whose deletion takes the volumes
  with it. Volumes live in `/var/lib/homelab/volumes`, outside the tree
  `k3s-uninstall.sh` deletes.
- **The RAID mounts at `/mnt/raid` from `/etc/fstab`**, and K3s's unit has
  `RequiresMountsFor=/mnt/raid`: nothing starts against an empty mount point.
  It stays NTFS (ntfs3, every file 1000:1000) for now; reformatting 2.7 TB is
  a separate decision.
- **Offsite backups with VolSync and restic to Backblaze B2.** Every app PVC
  opts in through `components/volsync` (one restic repository per app,
  nightly, 7 daily/4 weekly/6 monthly). Immich's Postgres is covered by
  Immich's own nightly dump, which lands in the backed-up library; no
  barman-cloud plugin. Media is not backed up offsite. `hack/restore.sh`
  restores in place or into a scratch PVC (`--test`, monthly).
- **One SOPS secret for every credential**, `cluster-secrets`
  (`hack/cluster-secrets.sh`), substituted by Flux like `cluster-settings`.
  Files that need a credential hold only `${VAR}`s. A new age key replaces the
  lost one; it lives in `~/.config/sops/age/keys.txt` and the password manager.
- **Per-app Flux Kustomizations** (`apps/<group>/<app>/ks.yaml`) instead of one
  per group: an app gets its own `dependsOn` (Immich waits for its database)
  and `${APP}` for the VolSync component. A group shares one namespace.
- **Jellyfin replaces Plex**, in the cluster, transcoding on the 3090. The
  device plugin time-slices the card (4 slots) for Jellyfin and Immich ML.
- **Monitoring for one box**: kube-prometheus-stack with alerts for the RAID
  (`node_md_*`), SMART, GPU temperature and stale backups, delivered to ntfy;
  Flux reconcile failures go to the same topic.
- **LAN DNS**: k8s-gateway answers `*.${DOMAIN}` from the HTTPRoutes; clients
  reach it through a router conditional forward or Tailscale split DNS.
  Tailscale runs on the host, not in the cluster.

## Consequences

- `k3d/`, the cgroup-v1 workaround and the Windows paths are gone.
- A rebuild is: `host/setup.sh`, restore the age key, `hack/bootstrap.sh`,
  `hack/restore.sh` per app (docs/runbooks/disaster-recovery.md).
- Still not covered: no UPS, so no NUT exporter; one GPU shared without
  memory isolation; the RAID is NTFS (no POSIX permissions, no reflinks).
