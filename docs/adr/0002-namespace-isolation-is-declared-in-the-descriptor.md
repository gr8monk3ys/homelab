---
status: accepted
date: 2026-09-21
---

# Namespace isolation is declared in the service descriptor

A service's NetworkPolicies are a `networkPolicies:` list of template names
in its `service.yaml`, rendered from
`kubernetes/security/network-policies/templates/` into the service's
namespace by the same `install_service` call that applies its manifests.
We chose this over the two previous shapes: a standalone toolkit
(`kubernetes/network-policies/`, deleted) with its own applier and a
hardcoded list of 28 namespaces that nothing ran, and per-namespace
default-deny blocks copied into the static files under
`kubernetes/security/network-policies/`. Static files now hold only what a
template cannot express: infrastructure namespaces, Nextcloud (Helm, no
descriptor), and cross-namespace rules such as one app reaching another's
database.

## Consequences

- Policies are additive: `allow-same-namespace` already permits an app to
  reach its own database, so the finer per-pod DB egress rules that remain
  in the static files are redundant within a namespace and can be retired
  when they are next touched.
- A service that must reach the LAN or the Kubernetes API (Home Assistant,
  Homepage) omits the key and stays open until a template expresses that
  need; adding such a template is the intended extension point.
- ArgoCD applies a service directory as committed, so the GitOps path does
  not render templates. Isolation for GitOps-managed services needs the
  rendered policies committed (see `scripts/services.sh render`).
