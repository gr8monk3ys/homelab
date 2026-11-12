# Homelab

A small single-node K3s homelab on one Windows PC, managed by Flux. This
glossary fixes the words the manifests and docs use.

## Language

**Cluster**:
The k3d cluster `homelab` defined by `k3d/homelab.yaml`: one K3s server in Docker Desktop. `clusters/homelab/` is what Flux reconciles on it.
_Avoid_: environment, stage

**Layer**:
One of the three Flux Kustomizations in `clusters/homelab/`, applied in order: `infrastructure-controllers` (CRDs and operators), `infrastructure-configs` (objects that need them), `apps`. Each waits for the one before it to be Ready.
_Avoid_: phase, tier

**Flux Kustomization**:
A `kustomize.toolkit.fluxcd.io` object: a path in a source that Flux builds and applies. Not the same as a `kustomization.yaml`, which lists the files in one directory.
_Avoid_: app, sync

**App group**:
A directory under `apps/` (`media`, `photos`, `files`) holding related apps. The group's `kustomization.yaml` lists its apps.
_Avoid_: category, stack

**App**:
One self-hosted application in its own directory and namespace under an app group, with its own volumes, secrets and `HTTPRoute`. Its database (a CloudNativePG `Cluster`) belongs to it.
_Avoid_: service (a Kubernetes Service is something else)

**Gateway**:
`gateway/homelab`, the one Gateway API Gateway, served by the K3s-bundled Traefik. Every app attaches an `HTTPRoute` to its `https` listener.
_Avoid_: ingress

**LAN CA**:
The private certificate authority `homelab-ca` (a cert-manager `ClusterIssuer`). It signs the wildcard certificate for `*.${DOMAIN}`. Devices trust it by importing its certificate.
_Avoid_: self-signed cert

**Cluster settings**:
The `cluster-settings` ConfigMap in `clusters/homelab/`. Flux substitutes its keys (`${DOMAIN}`, `${TIMEZONE}`) into the configs and apps layers.
_Avoid_: config, placeholder

**Bulk storage**:
`D:\30 Media\homelab` on the RAID 5 HDD, bound at `/mnt/bulk` on the server node: media, downloads, the photo library. Everything else goes on `local-path` volumes on C:.
_Avoid_: NAS, shared storage

**Sealed file**:
A `*.sops.yaml` file whose `data`/`stringData` values are encrypted with SOPS and age. The only form a Secret takes in Git.
_Avoid_: encrypted secret, vault
