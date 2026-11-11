# Cluster Hardening

This repo supports two layers of hardening:

1. **Pod Security Admission (PSA)** via namespace labels (built-in Kubernetes feature).
2. **Policy-as-code** via Kyverno (optional install).

## Pod Security Admission (PSA)

`setup-v2.sh` supports three modes via `POD_SECURITY_MODE`, and the mode
applies to every namespace the installer creates, infrastructure and services
alike:

- `off`: remove the `pod-security.kubernetes.io/*` labels; nothing is
  enforced, audited or warned.
- `audit` (default): safe migration mode. `enforce` is set to `privileged`
  (nothing is blocked) and `audit`/`warn` stay at each namespace's target
  level, so violations are reported.
- `enforce`: apply the target levels as written (may block non-compliant
  pods).

Examples:

```bash
POD_SECURITY_MODE=audit ./setup-v2.sh
POD_SECURITY_MODE=enforce ./setup-v2.sh
```

Where the target levels live (ADR-0009):
- A service's levels are in its own `kubernetes/services/<name>/namespace.yaml`,
  written at their enforce-mode values. `install_service` applies the mode as a
  transform on that Namespace when the service installs, so a switched-off
  service gets no namespace at all.
- Infrastructure namespaces are in `kubernetes/security/pod-security-standards.yaml`;
  the Pod Security phase applies the same transform to it and skips any
  namespace that does not exist.
- The GitOps path (ArgoCD applies directories as committed, unrendered) gets
  the enforce-mode labels as written.

### Promote from audit to enforce

None of the target levels has been verified, not even on the live k3d
cluster.
Stay on `audit` until its warnings are clean, then switch to `enforce`.

See what `audit` reports:

```bash
# warn: printed by kubectl whenever an apply or a pod creation would violate
# the namespace's level, e.g. when re-running the installer
./setup-v2.sh 2>&1 | grep -i 'would violate PodSecurity'

# dry-run a level against the pods already running in one namespace
kubectl label --dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=<level>

# audit: recorded in the API server audit log (K3s: enable it with
# --kube-apiserver-arg=audit-log-path=... and an audit policy) as the
# pod-security.kubernetes.io/audit-violations annotation
```

When nothing is reported, re-run with `POD_SECURITY_MODE=enforce ./setup-v2.sh`.
If a workload is then rejected, fix its security context or lower that
namespace's level in its `namespace.yaml`, with a comment saying why (see the
`loki` namespace).

## Kyverno (Policy-As-Code)

Kyverno is optional and disabled by default.

Enable it:

```bash
INSTALL_KYVERNO=true KYVERNO_POLICY_MODE=audit ./setup-v2.sh
```

Kyverno's Helm chart version is pinned in `tools/versions.env` (`KYVERNO_CHART_VERSION`).

Two policy modes are supported:
- `KYVERNO_POLICY_MODE=audit`: report violations, do not block.
- `KYVERNO_POLICY_MODE=enforce`: block violations in opted-in namespaces.

### Namespace Opt-In (Recommended)

Policies only apply to namespaces labeled `homelab-kyverno=enabled`.

Enable for a single namespace:

```bash
kubectl label namespace homepage homelab-kyverno=enabled
```

View policy reports (Kyverno creates PolicyReport resources):

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport -A
```

### Promote From Audit To Enforce

1. Run Kyverno in audit mode and fix violations in one namespace at a time.
2. Switch to enforce mode:

```bash
INSTALL_KYVERNO=true KYVERNO_POLICY_MODE=enforce ./setup-v2.sh
```

If a workload gets blocked, remove the label to stop enforcing in that namespace:

```bash
kubectl label namespace <ns> homelab-kyverno-
```

## CrowdSec bouncer

The bouncer is a Traefik plugin (`maxlerebourg/crowdsec-bouncer-traefik-plugin`),
loaded in `kubernetes/ingress/traefik/values.yaml` and configured by the
`crowdsec-bouncer` Middleware in `kubernetes/security/crowdsec/deployment.yaml`.
The `websecure` entrypoint applies it to every HTTPS request. It runs in stream
mode: Traefik pulls the decision list from the agent's Local API every 60
seconds.

It fails closed. When a pull fails, every request gets 403 until a pull
succeeds again. If the plugin itself cannot load (no outbound HTTPS from
Traefik at start), Traefik cannot build the middleware and serves no HTTPS
routes. A run of 403s for everyone is the sign to look at:

```bash
# the plugin logs failed pulls in Traefik's log
kubectl logs -n traefik-system deploy/traefik | grep -i -E 'crowdsec|handleStreamTicker|plugin'
# the agent, its Local API and the registered bouncer
kubectl get pods -n crowdsec
kubectl exec -n crowdsec deploy/crowdsec-agent -- cscli bouncers list
```

The bouncer key is `bouncer-api-key` in the `crowdsec-config` Secret. The agent
registers it as bouncer `traefik` only when that name is not registered yet, so
after rotating the key run `cscli bouncers delete traefik` in the agent and
restart it.
