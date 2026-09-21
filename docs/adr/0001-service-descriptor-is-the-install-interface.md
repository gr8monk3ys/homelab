---
status: accepted
date: 2026-09-21
---

# The service descriptor is the install interface

Every application directory under `kubernetes/services/` carries a
`service.yaml` descriptor (namespace, group, opt-in key, ordered steps with
waits), and `install_service` in `scripts/lib/services.sh` is the only code
that installs one. We chose this over two alternatives: keeping per-service
blocks in `setup-v2.sh` (which had left 20 of 43 directories uninstallable
and encoded ordering rules four different ways), and moving every service to
Kustomize or Helm (which would replace a working sed-based rendering path and
43 plain-manifest directories in one step). The descriptor keeps manifests
plain `kubectl`-applyable YAML while making a service directory
self-describing, installable by the installer, disaster recovery, the KinD
harness and CI through one interface.

## Consequences

- A directory without a descriptor fails `./scripts/ci.sh`.
- Ordering and wait rules are data; adding a service never touches
  `setup-v2.sh`.
- Group toggles and `OPTIN_SERVICES` decide what installs; the descriptor
  cannot express finer conditions than a step's `when:` toggle. If that
  becomes limiting, extend the descriptor rather than special-casing the
  installer.
- Moving to Kustomize or Helm later means generating from, or replacing,
  the descriptors, not re-discovering the install rules.
