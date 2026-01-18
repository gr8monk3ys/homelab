# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Automated Homelab Setup v2.0 - A production-ready Kubernetes homelab deployment using K3s with 51 services, comprehensive monitoring, and enterprise-grade security patterns.

## Essential Commands

```bash
# Initial deployment (run in order)
./scripts/generate-secrets.sh      # Generate Kubernetes secrets first
./setup-v2.sh                      # Deploy entire stack
./scripts/validate-setup.sh        # Validate deployment health

# Environment-specific deployment
ENVIRONMENT=production DOMAIN=yourdomain.com ./setup-v2.sh

# Testing
cd test && docker-compose up -d    # Docker Compose-based (no K8s required)
./test/setup-kind.sh               # KinD cluster for CI/CD
./test/test-runner.sh              # Run test suite

# Backup & Recovery
./scripts/verify-backups.sh        # Verify backup integrity
./scripts/disaster-recovery.sh     # Disaster recovery procedures

# Network policies
./kubernetes/network-policies/apply-network-policies.sh
```

**IMPORTANT**: Never use `setup.sh` (legacy/insecure). Always use `setup-v2.sh`.

## Architecture

```
┌─────────────────────────────────────────────┐
│  Traefik Ingress + Cert-Manager (SSL)       │
├─────────────────────────────────────────────┤
│  Kubernetes Cluster (K3s)                   │
│  ┌────────────────────────────────────────┐ │
│  │ External Secrets Operator              │ │
│  │ (centralized secret management)        │ │
│  └────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────┐ │
│  │ Core: MinIO, Velero, Local Path Prov.  │ │
│  │ Monitoring: Prometheus, Grafana, Alerts│ │
│  │ Auth: Authelia, Keycloak               │ │
│  │ Apps: 51 services (see services dir)   │ │
│  └────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────┐ │
│  │ NetworkPolicies (default deny + allow) │ │
│  └────────────────────────────────────────┘ │
├─────────────────────────────────────────────┤
│  Ansible (base system, security, backups)   │
└─────────────────────────────────────────────┘
```

## Directory Structure

- `kubernetes/secrets/` - External Secrets Operator setup
- `kubernetes/storage/` - MinIO, local-path provisioner
- `kubernetes/ingress/` - Traefik, cert-manager
- `kubernetes/monitoring/` - Prometheus stack + `alerts/` (PrometheusRules)
- `kubernetes/network-policies/` - Default deny + service-specific policies
- `kubernetes/services/<name>/` - Individual service deployments (51 services)
- `kubernetes/gitops/` - ArgoCD configurations
- `helm/` - Helm charts
- `kustomize/overlays/{development,staging,production}/` - Environment configs
- `ansible/playbooks/` - base-system.yaml, security.yaml, backup.yaml

## Key Patterns

**Secrets**: All services use ExternalSecrets referencing ClusterSecretStore. Never hardcode.
```bash
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.password}' | base64 -d
```

**Security Context**: All containers must have:
- `allowPrivilegeEscalation: false`
- `capabilities: drop: [ALL]`
- `runAsNonRoot: true` (where image supports it)

**New Service Checklist**:
1. Create `kubernetes/services/<service-name>/` with:
   - `namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingress.yaml`
   - `pdb.yaml` (PodDisruptionBudget) for critical services
   - `servicemonitor.yaml` for Prometheus scraping
   - `hpa.yaml` for auto-scaling if variable load
2. Add ExternalSecret for credentials
3. Add NetworkPolicy in `kubernetes/network-policies/service-specific/`

**Databases**: Always use separate StatefulSets (e.g., `postgres-deployment.yaml`), never sidecars.

## Validation

After any changes:
```bash
./scripts/validate-setup.sh
```

Checks: cluster health, secrets, storage, ingress, monitoring, hardcoded passwords.

## Troubleshooting

```bash
kubectl get pods -A                         # Service status
kubectl logs -f deployment/<name> -n <ns>   # Service logs
kubectl get pv && kubectl get pvc -A        # Storage issues
kubectl get certificates -A                 # SSL problems
kubectl get externalsecrets -A              # Secret sync status
kubectl get hpa -A                          # Autoscaler status
kubectl get prometheusrules -A              # Alert rules
```

Setup logs: `setup.log` in project root.
