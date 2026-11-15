# Homelab

A small single-node K3s homelab on one Arch Linux PC, managed by Flux. This
glossary fixes the words the manifests and docs use.

## Language

**Cluster**:
The K3s node `homelab`, running natively under systemd on the Arch host (`host/setup.sh`). `clusters/homelab/` is what Flux reconciles on it.
_Avoid_: environment, stage

**Layer**:
One of the Flux Kustomizations in `clusters/homelab/`, applied in order: `cluster-secrets`, `infrastructure-controllers` (CRDs and operators), `infrastructure-configs` (objects that need them), `apps`. Each waits for the one before it to be Ready.
_Avoid_: phase, tier

**Flux Kustomization**:
A `kustomize.toolkit.fluxcd.io` object: a path in a source that Flux builds and applies. Not the same as a `kustomization.yaml`, which lists the files in one directory.
_Avoid_: app, sync

**App group**:
A directory under `apps/` (`media`, `photos`, `files`) holding related apps that share one namespace. The group's `kustomization.yaml` lists the namespace, shared volumes and each app's `ks.yaml`.
_Avoid_: category, stack

**App**:
One self-hosted application in its own directory under an app group, applied by its own Flux Kustomization (`ks.yaml`), with its own volumes, `HTTPRoute` and NetworkPolicy. Its database (a CloudNativePG `Cluster`) belongs to it.
_Avoid_: service (a Kubernetes Service is something else)

**Gateway**:
`gateway/homelab`, the one Gateway API Gateway, served by the K3s-bundled Traefik. Every app attaches an `HTTPRoute` to its `https` listener.
_Avoid_: ingress

**LAN CA**:
The private certificate authority `homelab-ca` (a cert-manager `ClusterIssuer`). It signs the wildcard certificate for `*.${DOMAIN}`. Devices trust it by importing its certificate.
_Avoid_: self-signed cert

**Cluster settings**:
The `cluster-settings` ConfigMap in `clusters/homelab/`. Flux substitutes its keys (`${DOMAIN}`, `${TIMEZONE}`, `${BULK_PATH}`) into every layer.
_Avoid_: config, placeholder

**Cluster secrets**:
The SOPS-encrypted `cluster-secrets` Secret (`infrastructure/secrets/`), substituted like cluster settings: every credential the cluster uses. Made once by `hack/cluster-secrets.sh`.
_Avoid_: secret table, vault

**Backup**:
A VolSync `ReplicationSource` sending PVC `${APP}` to its own restic repository in Backblaze B2 nightly (`components/volsync`). Only something restored by `hack/restore.sh --test` counts as known-good.
_Avoid_: snapshot, Velero

**Bulk storage**:
`${BULK_PATH}` (`/mnt/raid/50 Dev/52 homelab`) on the NTFS RAID 5: media, downloads, the photo library, through static hostPath volumes. Everything else goes on `local-path` volumes on the SSD.
_Avoid_: NAS, shared storage

**Sealed file**:
A `*.sops.yaml` file whose `data`/`stringData` values are encrypted with SOPS and age. The only form a Secret takes in Git.
_Avoid_: encrypted secret, vault
