# Cluster Hardening

This repo supports two layers of hardening:

1. **Pod Security Admission (PSA)** via namespace labels (built-in Kubernetes feature).
2. **Policy-as-code** via Kyverno (optional install).

## Pod Security Admission (PSA)

`setup-v2.sh` supports three modes via `POD_SECURITY_MODE`:

- `off`: do not apply PSA labels.
- `audit` (default): safe migration mode (no blocking, but sets audit/warn levels).
- `enforce`: enforce target levels (may block non-compliant pods).

Examples:

```bash
POD_SECURITY_MODE=audit ./setup-v2.sh
POD_SECURITY_MODE=enforce ./setup-v2.sh
```

Files:
- Audit mode: `kubernetes/security/pod-security-standards-audit.yaml`
- Enforce mode: `kubernetes/security/pod-security-standards-enforce.yaml`

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
