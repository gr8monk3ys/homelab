# Storage, remote access and hardware

These opt-in services need something on the host, or a credential you create
yourself, before they do anything useful. Each is installed like any other
service:

```bash
OPTIN_SERVICES="longhorn snapshot-controller volsync" ./setup-v2.sh
./scripts/services.sh install longhorn        # or one at a time
```

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
nodes. The backup target points at the in-cluster MinIO, which means a
Longhorn backup survives a volume loss but not the loss of the node that
holds MinIO. Velero and `scripts/backup-secrets.sh` remain the off-node
path.

The UI is at `longhorn.<domain>`, behind the same ingress as everything else.

## snapshot-controller and VolSync

`snapshot-controller` provides the `VolumeSnapshot` CRDs that Kubernetes
itself does not ship. Install it before VolSync if you want snapshot-based
copies; VolSync's `Direct` clone method works without it.

VolSync replicates a PVC on a schedule, with restic as the mover, into
MinIO. One `ReplicationSource` per PVC you care about, in that PVC's
namespace:

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
egress to MinIO. Add it to
`kubernetes/security/network-policies/cross-namespace-policies.yaml` rather
than opening the namespace.

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
