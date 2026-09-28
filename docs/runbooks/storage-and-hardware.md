# Storage, remote access and hardware

These opt-in services need something on the host, or a credential you create
yourself, before they do anything useful. Each is installed like any other
service:

```bash
OPTIN_SERVICES="longhorn snapshot-controller volsync" ./setup-v2.sh
./scripts/services.sh install longhorn        # or one at a time
```

## Bulk storage (media, photos, object data on big disks)

`local-path` puts every volume on the node's root disk, usually an SSD.
Big, sequentially written files go on a separate *bulk* disk instead:

| What | Where | Claim |
|---|---|---|
| downloads + media library (arr-stack, qBittorrent) | `/mnt/bulk/data` | `media-data` in each namespace |
| Immich upload location (originals, video, DB dumps) | `/mnt/bulk/immich` | `immich-uploads-pvc` |
| Garage data blocks, with `GARAGE_DATA_STORAGE=bulk` | `/mnt/bulk/garage` | `garage-data` |

Databases never go there: Postgres, SQLite (every *arr app's `/config`),
Redis, Garage metadata and Immich thumbnails stay on `local-path`.

**Host prerequisite:** on one node, mount the bulk disk at `/mnt/bulk`,
create the directories the PVs name (they use hostPath `type: Directory`, so
a missing mount fails instead of silently filling the root disk), and label
the node:

```bash
sudo mkdir -p /mnt/bulk/data/{torrents,media}/{movies,tv} /mnt/bulk/immich /mnt/bulk/garage
kubectl label node <node> homelab.io/bulk=true
```

The `bulk` StorageClass (`kubernetes/storage/bulk-storageclass.yaml`) has no
provisioner. Each bulk volume is a static PV next to the service that uses it
(`shared-storage.yaml`, `bulk-storage.yaml`, `storage.yaml`,
`kubernetes/storage/garage/data/bulk.yaml`): pre-bound to its claim, pinned to
the labelled node, `Retain` on delete. A pod that mounts one is scheduled to
the bulk node, and its `local-path` claims are provisioned there too.

The media tree is one directory mounted at `/data` in Sonarr, Radarr, Bazarr
and qBittorrent (two PVs, one per namespace, same path), so an import is a
hardlink, not a copy. Point qBittorrent's categories at `/data/torrents/tv`
and `/data/torrents/movies`, the *arr root folders at `/data/media/tv` and
`/data/media/movies`, and your media server's libraries at the same folders
on the host.

**Reinstalling after a delete.** A `Retain` PV keeps its data and goes
`Released` when its claim is deleted; it will not bind the new claim until
the old claim's UID is cleared:

```bash
kubectl patch pv bulk-arr-stack-data --type json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'
```

**Moving Garage's data to bulk on a running cluster.** The claim's class
cannot change in place, and the metadata claim is pinned to the node it was
provisioned on, so both are recreated. Scale Garage to zero, copy both
volumes' contents out if the buckets matter (otherwise the bootstrap Job
recreates the layout, key and buckets), delete the `garage-meta` and
`garage-data` claims, then re-run `setup-v2.sh` with `GARAGE_DATA_STORAGE=bulk`
and copy the contents back.

**k3d on Docker Desktop (Windows).** Give the cluster a second node, a K3s
agent container with the Windows folder bind-mounted at `/mnt/bulk` and
`--node-label homelab.io/bulk=true`. From the WSL docker CLI, bind the
distro's view of the drive (`/mnt/d/...`): `/run/desktop/mnt/host/d/...` is
not the drive under the WSL 2 backend, but an empty tmpfs directory. Through
that mount (9p/drvfs), every file shows as UID/GID 1000 with mode 0777,
`chown` and `chmod` succeed but change nothing, any UID can write, hardlinks
and symlinks work, and FIFOs do not. That is fine for media and
object blocks, but not for a database.

## Longhorn (distributed block storage)

**Host prerequisite:** `open-iscsi` must be installed and running on every
node, and `nfs-common` if you use an NFS backup target.

```bash
sudo apt install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

Longhorn installs with `defaultClass: false`, so `local-path` stays the
default StorageClass and nothing moves until you ask. To make a specific
PVC use Longhorn, set `storageClassName: longhorn` on it. To switch the
whole cluster over later:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass longhorn \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Replica count is 1 because this is a single node; raise it when you add
nodes. The backup target points at the in-cluster Garage (bucket
`longhorn-backups`, created by Garage's bootstrap Job), which means a
Longhorn backup survives a volume loss but not the loss of the node that
holds Garage. Velero and `scripts/backup-secrets.sh` remain the off-node
path.

The UI is at `longhorn.<domain>`, behind the same ingress as everything else.

## snapshot-controller and VolSync

`snapshot-controller` provides the `VolumeSnapshot` CRDs that Kubernetes
itself does not ship. Install it before VolSync if you want snapshot-based
copies; VolSync's `Direct` clone method works without it.

VolSync replicates a PVC on a schedule, with restic as the mover, into
Garage's `volsync-backups` bucket. One `ReplicationSource` per PVC you care
about, in that PVC's namespace. The repository Secret it names holds
`RESTIC_REPOSITORY=s3:http://garage.garage-system.svc.cluster.local:3900/volsync-backups/<pvc>`,
a `RESTIC_PASSWORD` of your choosing, `AWS_DEFAULT_REGION=garage`, and the
shared backup key (`backup-s3-credentials`: `access-key` as
`AWS_ACCESS_KEY_ID`, `secret-key` as `AWS_SECRET_ACCESS_KEY`), best built
with an ExternalSecret like Longhorn's in
`kubernetes/services/longhorn/namespace.yaml`:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: paperless-data
  namespace: paperless-ngx
spec:
  sourcePVC: paperless-data-pvc
  trigger:
    schedule: "0 4 * * *"
  restic:
    repository: paperless-restic-config   # Secret with RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS keys
    retain:
      daily: 7
      weekly: 4
    copyMethod: Snapshot                  # or Direct without snapshot-controller
```

The mover pod runs in the application's namespace, so that namespace needs
egress to Garage (namespace `garage-system`, TCP 3900). Add that egress rule to the service's own
`kubernetes/services/<name>/networkpolicies.yaml` (ADR-0009) rather than
opening the namespace.

Velero backs up Kubernetes objects and, with its own plugins, volumes;
VolSync backs up file contents with deduplication and retention. Running
both is the usual homelab answer.

## Tailscale operator (remote access)

**Credential:** create an OAuth client in the Tailscale admin console with
the `Devices` write scope and the tag your devices will use, then:

```bash
kubectl -n secrets create secret generic tailscale-oauth \
  --from-literal=client-id=<client-id> \
  --from-literal=client-secret=<client-secret>
```

The operator's `ExternalSecret` copies that into `operator-oauth` in the
`tailscale` namespace. Expose a Service on your tailnet by setting its
ingress class to `tailscale`, or annotate an existing Service:

```bash
kubectl annotate service grafana -n monitoring tailscale.com/expose=true
```

This is an alternative to the Cloudflare Tunnel: Tailscale keeps traffic
inside your tailnet, cloudflared publishes to the public internet.

## node-feature-discovery and the device plugins

`node-feature-discovery` labels nodes with what they actually have
(`feature.node.kubernetes.io/pci-0300_8086.present=true` for an Intel GPU,
for instance). The device plugins then advertise a schedulable resource:

| Plugin | Resource | Host prerequisite |
|---|---|---|
| Intel | `gpu.intel.com/i915` | kernel i915 driver, `/dev/dri` present |
| NVIDIA | `nvidia.com/gpu` | NVIDIA driver + container toolkit; K3s creates the `nvidia` RuntimeClass |

Once a resource is advertised, request it in the workload that needs it:

```yaml
resources:
  limits:
    gpu.intel.com/i915: 1
```

The commented blocks in Jellyfin, Immich, Ollama and Frigate are the places
this matters. Check what was detected with:

```bash
kubectl get nodes -o json | jq '.items[].status.allocatable' # or -o yaml
kubectl describe node <name> | grep -A5 Allocatable
```

## Frigate

Frigate needs three things beyond the manifests: cameras it can reach over
RTSP, Mosquitto (installed with `ENABLE_HOME_SERVICES=true`), and a
detector. The shipped config uses the CPU detector and a disabled example
camera, so the pod starts but detects nothing useful. Edit the
`frigate-config` ConfigMap with your cameras, then swap the detector for a
Coral or OpenVINO block and add the matching device resource.

Recordings live on `frigate-media-pvc` (200Gi by default). That PVC is the
one to point Longhorn or VolSync at if you care about keeping footage.
