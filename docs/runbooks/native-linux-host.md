# Bring-up on a native Linux Docker host

The cluster ran as k3d on Docker Desktop (Windows 11, WSL2) from 2026-09-27
until that install was wiped on 2026-10-29. The same PC now runs Arch Linux
(Omarchy) with Docker Engine as a systemd service, an RTX 3090 and the same
RAID-5 volume. This runbook takes that machine from nothing to a validated
cluster without losing what is on the RAID.

What the old cluster left behind, checked 2026-11-11 (names and sizes only):

| On the RAID, under `50 Dev/52 homelab/` | Size | What it is now |
|---|---|---|
| `data/` (`media/`, `torrents/`, each `movies/`, `tv/`) | 0 | the empty media tree; nothing to save |
| `immich/` (`library`, `upload`, `thumbs`, `encoded-video`, `profile`, `backups`) | ~108 MB | Immich's upload location: originals plus its own nightly database dumps in `backups/` |
| `garage/` (`00/` ... `ff/`) | ~11 GB | Garage data blocks **without** their metadata (that was on `local-path`, on the wiped C: drive). Garage cannot read them back; treat it as an orphan |

The Postgres databases, every `local-path` volume, the generated secrets and
the Garage metadata were on the wiped disk. No `backup-secrets.sh` export
exists in the checkout. So this is a fresh install that re-attaches files,
not a restore.

## Decisions to make first

1. **Mount point.** The RAID is mounted by udisks at
   `/run/media/<user>/Raid Storage`, which exists only after a desktop login.
   A k3d node started at boot would bind an empty directory. Mount it from
   `/etc/fstab` at `/mnt/raid` (below). `BULK_HOST_PATH` is then
   `/mnt/raid/50 Dev/52 homelab`; the space is fine.
2. **Immich.** Restore the last database dump from `immich/backups/` (keeps
   albums, faces, users) or start empty and re-import the originals.
3. **Garage.** Recommended: keep `GARAGE_DATA_STORAGE=local-path` (default)
   and move the orphaned `garage/` aside. `bulk` puts new blocks on the RAID,
   which is where the old orphan lives, so move it aside in either case.
4. **Which services.** Start small (below); `ENABLE_AI_SERVICES` pulls in
   Ollama and Open WebUI with Immich.
5. **NTFS.** The RAID stays NTFS (`ntfs3`): one owner for every file (UID
   1000, which every bulk pod runs as), `chown`/`chmod` do not persist,
   hardlinks work. Fine for media and photos, never for a database. A
   reformat to ext4/XFS is a later, separate decision with a full copy first.

## Host prerequisites (needs sudo; the owner runs these)

**RAID state.** `/proc/mdstat` shows `md126` (Intel RST/IMSM RAID-5, external
metadata on `md127`) **resyncing at 86.6 %, about 19 h left at 3.7 MB/s** on
2026-11-11. Let it finish before the backup copy or any heavy writes, and
make sure the array assembles at boot (`mdadm` installed, `mdmon` running for
IMSM):

```bash
cat /proc/mdstat                          # wait for [UUU] with no resync line
sudo mdadm --detail --scan                # the ARRAY lines
sudo mdadm --detail --scan | sudo tee -a /etc/mdadm.conf   # once, if not there
```

**fstab entry at a stable path.**

```bash
sudo blkid /dev/md126p1                   # note UUID=...
sudo umount "/run/media/$USER/Raid Storage"
sudo mkdir -p /mnt/raid
echo 'UUID=<uuid>  /mnt/raid  ntfs3  uid=1000,gid=1000,umask=022,iocharset=utf8,prealloc,nofail,x-systemd.device-timeout=60s  0 0' \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/raid
ls "/mnt/raid/50 Dev/52 homelab"          # data  garage  immich
```

**Docker waits for the mount.** k3d's node containers restart with Docker at
boot; without this they can start before `/mnt/raid` is mounted and bind an
empty directory:

```bash
sudo systemctl edit docker.service
#   [Unit]
#   RequiresMountsFor=/mnt/raid
sudo systemctl daemon-reload
```

**NVIDIA container toolkit** (only for GPU containers; nothing else needs it):

```bash
sudo pacman -S --needed nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker run --rm --gpus all ubuntu nvidia-smi   # the 3090 should be listed
```

The `nvidia-device-plugin` service (GPU *inside* the cluster) needs more than
that: the k3d node must be created with `--gpus all` (`options.runtime.gpuRequest`
in `k3d/homelab.yaml`) **and** run a K3s image that carries the NVIDIA
container runtime, which `rancher/k3s` does not (k3d's CUDA guide builds one).
Until someone builds and pins that image, run GPU work next to the cluster
("GPU" below) and leave `nvidia-device-plugin` out of `OPTIN_SERVICES`.

**Already fine on this host** (checked 2026-11-11): Docker 29.9 on cgroup v2
with the systemd driver (no `fail-cgroupv1` workaround needed),
`fs.inotify.max_user_instances=1024` and `max_user_watches=524288`.
`ufw` is active, but Docker's published ports bypass it: 80/443 are reachable
from the LAN as soon as the cluster runs, the API (6550) only on 127.0.0.1.

## Tools (no sudo)

The repo's pins are in `tools/versions.env`; mise installs the same versions:

```bash
mise use -g kubectl@1.34.0 helm@3.21.2 kustomize@5.3.0 kubeconform@0.6.4 \
  yq@4.44.3 age@1.1.1 sops@3.10.2 kind@0.30.0 k3d@latest just@latest pipx:yamllint@1.35.1
# or, repo-local: ./scripts/install-dev-tools.sh   (puts them in .tools/)
```

## 1. Back up the bulk tree first

Nothing below deletes bulk data, but the next steps are the first writes to
it since the wipe. Copy it off the array (about 12 GB; the SSD has room) and
keep a checksum list. Run this after the resync has finished.

```bash
BULK="/mnt/raid/50 Dev/52 homelab"
DEST="$HOME/homelab-bulk-backup-$(date +%F)"
mkdir -p "$DEST"
rsync -aH --info=progress2 "$BULK/" "$DEST/"
(cd "$BULK" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$DEST.sha256"
(cd "$DEST" && sha256sum --quiet -c "$DEST.sha256") && echo "backup verified"
```

Keep that copy until Immich has been checked in step 6.

## 2. Prepare the bulk directories

The PVs use `hostPath` `type: Directory`, so the three directories must exist
(they do). Move the orphaned Garage blocks aside rather than deleting them:

```bash
BULK="/mnt/raid/50 Dev/52 homelab"
mv "$BULK/garage" "$BULK/garage.orphaned-2026-10-29"
mkdir "$BULK/garage"
mkdir -p "$BULK"/data/{torrents,media}/{movies,tv}
```

## 3. Configure

Edit `config/homelab.yaml` (domain, email, timezone). Then check the host and
look at the cluster config that will be used; neither touches Docker:

```bash
export BULK_HOST_PATH="/mnt/raid/50 Dev/52 homelab"
just k3d-render          # the rendered k3d/homelab.yaml
just k3d-check           # Docker, cgroup v2, data/ immich/ garage/ present
```

## 4. Create the cluster

```bash
just k3d-up              # k3d cluster create; context k3d-homelab
kubectl get nodes -L homelab.io/bulk          # one node, bulk=true
docker exec k3d-homelab-server-0 ls /mnt/bulk # data  garage  garage.orphaned-...  immich
```

One node, K3s pinned by `K3S_IMAGE_TAG` in `tools/versions.env`, the K3s
Traefik disabled (the installer brings its own), servicelb kept, ports 80 and
443 published on every host address, the API on `127.0.0.1:6550`, the
kubeconfig merged into `~/.kube/config`.

## 5. Install

MetalLB must be off on k3d (the installer refuses otherwise): servicelb gives
LoadBalancer Services the node's Docker address and k3d publishes the ports.
A first pass with the infrastructure and a small service set:

```bash
INSTALL_METALLB=false \
ENABLE_MEDIA_SERVICES=false ENABLE_NETWORK_SERVICES=false \
ENABLE_CONTENT_SERVICES=false ENABLE_PRODUCTIVITY_SERVICES=false \
./setup-v2.sh
./scripts/backup-secrets.sh      # the new generated secrets; keep the age key off this machine
```

Then grow, one group or service at a time, e.g.
`INSTALL_METALLB=false ENABLE_MEDIA_SERVICES=true ./setup-v2.sh` or
`./scripts/services.sh install immich`.

## 6. Re-attach Immich

Immich's upload location is the static PV `bulk-immich-uploads` on
`/mnt/bulk/immich`, so the originals are there as soon as Immich installs. The
database is new and empty. To bring back albums, people and users, restore
the newest dump from `immich/backups/` into the new database before anyone
uses the web UI, following Immich's "Backup and Restore" docs for the
installed version (scale `immich-server` to 0, load the dump into the
`immich-postgres` pod with `psql`, scale back). The dump must come from the
same or an older Immich version than the one installed. If you choose to
start empty instead, add the originals as an external library or re-upload
them.

## 7. Verify

```bash
./scripts/validate-setup.sh
kubectl get pv -l homelab.io/bulk-path        # Bound
kubectl get pods -A | grep -v -E 'Running|Completed'
curl -kI https://grafana.<domain> --resolve grafana.<domain>:443:127.0.0.1
```

Reboot once and check that the node comes back with `/mnt/bulk` populated
(`docker exec k3d-homelab-server-0 ls /mnt/bulk`) before trusting it.

## Ports and DNS

LAN clients reach Traefik on the host's LAN address (172.16.0.43 on wifi on
2026-11-11; give it a DHCP reservation). Wildcard DNS through Pi-hole must
point there, not at the LoadBalancer IP (a Docker bridge address):

```bash
TRAEFIK_IP=172.16.0.43 ./scripts/configure-wildcard-dns.sh
```

Other LoadBalancer Services (Pi-hole 53, WireGuard 51820/udp, Gitea SSH,
Jellyfin discovery) are reachable from the LAN only once k3d publishes their
port: add it to `ports:` in `k3d/homelab.yaml` before creating the cluster,
or later with `k3d cluster edit homelab --port-add '<host>:<port>@loadbalancer'`.
Port 53 on all addresses collides with systemd-resolved, which listens on
127.0.0.53, 127.0.0.54 and 172.17.0.1 here: publish DNS on the LAN address
only (`172.16.0.43:53:53/udp`).

## GPU

Immich machine learning and Ollama can use the 3090 as plain containers next
to the cluster (`docs/runbooks/storage-and-hardware.md`, "A GPU outside the
cluster"). On Linux, pods reach the host at `host.k3d.internal` (k3d adds it to
CoreDNS); a port published on `127.0.0.1` is **not** reachable that way, so
publish on the k3d network's gateway address:

```bash
GW="$(docker network inspect k3d-homelab -f '{{(index .IPAM.Config 0).Gateway}}')"
docker run -d --name immich-machine-learning-gpu --restart unless-stopped \
  --gpus all -p "$GW:3003:3003" -v immich-ml-model-cache:/cache \
  ghcr.io/immich-app/immich-machine-learning:<immich-server tag>-cuda
IMMICH_ML_URL=http://host.k3d.internal:3003 ./scripts/services.sh install immich
kubectl -n immich scale deployment immich-machine-learning --replicas=0
```

## Rolling back

`k3d cluster delete homelab` removes the node containers and the
`local-path` volumes inside them (databases, app config). It does not touch
the RAID: the bulk PVs are `hostPath` with `Retain`. The backup from step 1
and `garage.orphaned-2026-10-29` stay until you delete them.
