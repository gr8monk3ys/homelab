# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Automated Homelab Setup v2.0 - A production-ready Kubernetes homelab deployment using K3s with proper secret management, Helm charts, Kustomize overlays, and multi-environment support.

## Essential Commands

```bash
# Initial deployment (run in order)
./scripts/generate-secrets.sh      # Generate Kubernetes secrets first
./setup-v2.sh                      # Deploy entire stack
./scripts/validate-setup.sh        # Validate deployment health

# Environment-specific deployment
ENVIRONMENT=production DOMAIN=yourdomain.com ./setup-v2.sh

# Testing (Docker Compose-based, no K8s required)
cd test && docker-compose up -d

# KinD testing for CI/CD
./test/setup-kind.sh
./test/test-runner.sh

# Synology NAS integration
./scripts/synology-setup.sh <nas-ip> <admin-user> <ssh-key-path>
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
│  │ Core: MinIO, Local Path Provisioner    │ │
│  │ Monitoring: Prometheus, Grafana        │ │
│  │ Apps: Nextcloud, Vaultwarden, Jellyfin │ │
│  │       Heimdall, ArgoCD, Gitea, etc.    │ │
│  └────────────────────────────────────────┘ │
├─────────────────────────────────────────────┤
│  Ansible (base system, security, backups)   │
└─────────────────────────────────────────────┘
```

## Directory Structure

- `kubernetes/secrets/` - External Secrets Operator setup
- `kubernetes/storage/` - MinIO, local-path provisioner
- `kubernetes/ingress/` - Traefik, cert-manager
- `kubernetes/monitoring/` - Prometheus, Grafana, Uptime Kuma
- `kubernetes/services/<name>/` - Individual service deployments
- `kubernetes/gitops/` - ArgoCD configurations
- `helm/` - Helm charts (e.g., nextcloud)
- `kustomize/overlays/{development,staging,production}/` - Environment configs
- `ansible/playbooks/` - base-system.yaml, security.yaml, backup.yaml
- `config/homelab-secure.yaml` - Main configuration file

## Key Patterns

**Secrets**: All services reference Kubernetes secrets, never hardcoded passwords. Access secrets with:
```bash
kubectl get secret <name> -n <namespace> -o jsonpath='{.data.password}' | base64 -d
```

**Databases**: Use separate StatefulSets, not sidecar containers.

**New services**: Create under `kubernetes/services/<service-name>/` with namespace.yaml, deployment.yaml, service.yaml, ingress.yaml.

**Environment overlays**: Modify `kustomize/overlays/<env>/` for environment-specific patches.

## Validation

After any changes, run:
```bash
./scripts/validate-setup.sh
```

This checks: cluster health, secret management, storage provisioning, ingress, monitoring, core services, and scans for hardcoded passwords.

## Troubleshooting

```bash
kubectl get pods --all-namespaces           # Service status
kubectl logs -f deployment/<name> -n <ns>   # Service logs
kubectl get pv && kubectl get pvc -A        # Storage issues
kubectl get certificates -A                  # SSL problems
kubectl get externalsecrets -A              # Secret sync status
```

Setup logs: `setup.log` in project root.
