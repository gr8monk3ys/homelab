# Runbooks (Day-2 Ops)

This folder is for operational procedures: backup/restore, upgrades, and common break/fix workflows.

## Quick Triage

Start here when "something is broken":

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
kubectl get events -A --sort-by=.lastTimestamp | tail -n 100
```

Repo-provided health checks:

```bash
./scripts/validate-setup.sh
```

## When X Breaks, Do Y

| Symptom | First Checks | Likely Area | Next |
|---|---|---|---|
| `https://*.${DOMAIN}` not reachable | `kubectl -n traefik-system get svc,pods` | Ingress / LoadBalancer | See "Ingress/DNS" below |
| DNS works but TLS is broken | `kubectl get certificates -A` | cert-manager / issuer | Check certificate + issuer events |
| Services stuck in `ImagePullBackOff` | `kubectl get pods -A | rg ImagePullBackOff` | Registry / DNS / network | Check node DNS + registry creds |
| Many pods failing with secret errors | `kubectl get externalsecret -A` | External Secrets Operator | Reconcile ESO + SecretStore |
| Storage/PVC issues | `kubectl get pvc -A` | StorageClass / PVs | Inspect PV binding + node disk |
| Backups failing | `kubectl -n velero get schedule,backup` | Velero / MinIO | Run `./scripts/verify-backups.sh` |
| Need to rebuild cluster | Ensure secrets backup exists | Disaster recovery | See backup/restore runbook |

### Ingress/DNS Checklist

```bash
kubectl -n traefik-system get svc traefik
kubectl -n traefik-system get pods
kubectl get ingress -A
```

If you use Pi-hole wildcard DNS:

```bash
./scripts/configure-wildcard-dns.sh
kubectl -n pihole get svc pihole-dns
```

### Certificates Checklist

```bash
kubectl -n cert-manager get pods
kubectl get clusterissuer,issuer -A
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>
```

### External Secrets Checklist

```bash
kubectl -n external-secrets get pods
kubectl get secretstore,clustersecretstore -A
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>
```

## Runbooks

- Backup/restore: `docs/runbooks/backup-restore.md`
- Upgrades: `docs/runbooks/upgrades.md`
- Hardening: `docs/runbooks/hardening.md`
- Logging: `docs/runbooks/logging.md`
- Alerting: `docs/runbooks/alerting.md`
- ExternalDNS: `docs/runbooks/external-dns.md`
- GitOps secrets (SOPS): `docs/runbooks/gitops-secrets.md`
