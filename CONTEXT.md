# Homelab

A single-node K3s homelab: an installer, a catalogue of self-hosted
applications, and the platform pieces they share. This glossary fixes the
words the scripts, manifests and docs use.

## Language

**Service**:
One self-hosted application as a directory under `kubernetes/services/<name>/`, deployed as a unit. Its databases and caches belong to it.
_Avoid_: app, component, workload

**Descriptor**:
The `service.yaml` in a service directory: the only thing the installer needs to know to install that service.
_Avoid_: manifest (a descriptor is not applied to the cluster), config

**Group**:
The category a service belongs to (core, media, network, content, productivity, ai, dev, home, communication, monitoring, logging). Each group has one toggle.
_Avoid_: category, stack, tier

**Toggle**:
An environment variable (`ENABLE_*_SERVICES`, `INSTALL_*`) read at install time that switches a group or an infrastructure piece on or off.
_Avoid_: flag, feature flag, option

**Opt-in service**:
A service whose descriptor says `optin: true`; it installs only when named in `OPTIN_SERVICES`, even if its group is on.
_Avoid_: extra, unwired, manifest-only

**Step**:
One ordered entry in a descriptor: a file to apply, optionally a pod label to wait on and a toggle that must be true.
_Avoid_: phase, stage

**Placeholder**:
A literal that manifests carry in git and that is replaced at install time: `homelab.local`, `admin@homelab.local`, `value: "UTC"`, the `homelab-ca` issuer, the example GitOps repo URL.
_Avoid_: template variable, default

**Render**:
Replacing every placeholder in a manifest stream with the effective settings. Nothing from the repo reaches a cluster unrendered.
_Avoid_: template, substitute

**Installer**:
`setup-v2.sh`: the one script that takes an empty K3s cluster to a running homelab, idempotently.
_Avoid_: bootstrap script, deploy script

**Infrastructure**:
The pieces every service relies on and that are not services themselves: MetalLB, Traefik, cert-manager, External Secrets, MinIO, Velero, the monitoring stack, network policies.
_Avoid_: platform, system services

**Generated secret**:
A credential created by `scripts/generate-secrets.sh` in the central `secrets` namespace and copied into a service's namespace by an ExternalSecret.
_Avoid_: password, hardcoded secret
