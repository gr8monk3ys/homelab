---
status: accepted
date: 2026-09-22
amends: ADR-0002
---

# A service namespace carries everything applied into it

Four central files under `kubernetes/security/` — the Pod Security labels,
the ResourceQuotas, the PodDisruptionBudgets and the static NetworkPolicies —
each hard-coded service namespaces (23, 22, 3 and 16 of them respectively),
and none of them could know which services were switched on. Two bugs
followed, both reproduced against a live kube-apiserver. A default
`./setup-v2.sh` aborted at `setup_network_policies`: static policies
targeted `loki`, `frigate` and `home-assistant`, namespaces a default install
never creates, and under `set -euo pipefail` the failed apply ended the run.
And the Pod Security phase created empty namespaces for 7 switched-off
services, because its file held whole Namespace objects rather than labels.

We decided that everything living in a service's namespace lives in the
service's directory. Its Pod Security labels go in its `namespace.yaml`,
written at their enforce-mode levels; its quota in `resourcequota.yaml`; its
disruption budgets in `pdb.yaml`; its hand-written NetworkPolicies in
`networkpolicies.yaml`. A NetworkPolicy belongs to the service whose
namespace it is in — its selectors may name other namespaces, and that is
fine. `install_service` applies these files exactly when the service
installs, and for a `kind: helm` service too, after the release. The central
files under `kubernetes/security/` keep only infrastructure namespaces, and
their phases skip any namespace that does not exist instead of creating it,
because most infrastructure is switched on and off too (every Helm
release has an `INSTALL_*` toggle; `INSTALL_METALLB=false` leaves
`metallb-system` absent). `./scripts/services.sh check`
fails if any file under `kubernetes/security/` names a service namespace.

`POD_SECURITY_MODE` (`off|audit|enforce`) is now one transform over one
file's worth of labels instead of a choice between two files.
`install_service` applies it to the service's Namespace document: `enforce`
applies the labels as written; `audit` sets `enforce` to `privileged` and
keeps `audit` and `warn` at the file's level; `off` removes the
`pod-security.kubernetes.io/*` labels. The Pod Security phase applies the same
transform to the one infrastructure file,
`kubernetes/security/pod-security-standards.yaml`. The separate
`pod-security-standards-audit.yaml` and `-enforce.yaml` are gone; the audit
file was the enforce file with `enforce` forced to `privileged`, which is
exactly what the transform does. The transform belongs to `install_service`
and touches only Namespace documents. It is not a sixth substitution rule in
`scripts/lib/render.sh`, so ADR-0008 stands.

## Consequences

- Supersedes ADR-0002's sentence that the static files under
  `kubernetes/security/network-policies/` hold cross-namespace and per-pod
  rules. They now hold only rules for infrastructure namespaces; a
  cross-namespace rule whose policy sits in a service namespace lives in that
  service's `networkpolicies.yaml`.
- `POD_SECURITY_MODE` now reaches every namespace. Under the default `audit`,
  the 37 services whose `namespace.yaml` already carried labels move from
  enforced to audited. This is deliberate: no pod has run on a real node, so
  none of those levels is verified; `audit` is the documented safe-migration
  default; and the old split, where those labels were enforced regardless of
  the mode, was accidental. Switch to `enforce` once the audit warnings are
  clean (`docs/runbooks/hardening.md`).
- The GitOps path gets the enforce-mode labels as written, because ArgoCD
  applies a service directory as committed and unrendered, so no transform
  runs there.
- A switched-off service leaves no trace in the cluster: no namespace, no
  quota, no policy aimed at a namespace that is not there.
- The security phases run after the infrastructure and before the services,
  and disaster recovery runs them in the same place. They no longer have to
  run last to find their namespaces, because the service namespaces are not
  theirs.
