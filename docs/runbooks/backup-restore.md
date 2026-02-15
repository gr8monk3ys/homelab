# Backup And Restore

This repo supports two complementary backup/restore paths:

1. **Secrets backup (age-encrypted)**: portable, fast, and recommended before rebuilds.
2. **Cluster backups (Velero)**: PVs + Kubernetes resources, for full restores.

## Prerequisites

- `kubectl` configured and pointing at the cluster.
- Tools installed (recommended): `./scripts/install-dev-tools.sh`

## 1) Secrets Backup (Recommended)

Creates an encrypted backup of Secrets (and optionally cert-manager CA material).

### Create a Backup

```bash
./scripts/backup-secrets.sh
ls -la backups/secrets-*.yaml.age
```

By default this creates (or reuses) an age identity at `.secrets/agekey.txt`.

### Restore Secrets

```bash
./scripts/restore-secrets.sh backups/secrets-secrets-<timestamp>.yaml.age
```

Notes:
- Restoring secrets overwrites resources in the cluster. Use on a fresh/rebuilt cluster unless you know what you are doing.
- If you lose `.secrets/agekey.txt`, you cannot decrypt old backups. Store it safely offline.

## 2) Velero Backups (Cluster + PVs)

Velero is installed when `INSTALL_VELERO=true` (default) in `./setup-v2.sh`.

### Check Velero Status

```bash
kubectl -n velero get pods
kubectl -n velero get schedule
kubectl -n velero get backup
```

### Verify Backups

This repo includes a verification script:

```bash
./scripts/verify-backups.sh
```

It checks Velero resources and runs a small restore test (when possible).

### Create an On-Demand Backup (kubectl)

If you do not have the `velero` CLI, you can still create a backup via CRs:

```bash
backup_name="manual-backup-$(date +%Y%m%d-%H%M%S)"
cat <<YAML | kubectl apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${backup_name}
  namespace: velero
spec:
  includedNamespaces:
  - '*'
  snapshotVolumes: true
  ttl: 720h0m0s
YAML
```

Watch it:

```bash
kubectl -n velero get backup -w
```

## 3) Disaster Recovery (Guided Restore)

Use the interactive helper when you need to restore from Velero backups:

```bash
./scripts/disaster-recovery.sh
```

To include a secrets restore as part of the run (optional):

```bash
SECRETS_BACKUP_FILE=backups/secrets-secrets-<timestamp>.yaml.age ./scripts/disaster-recovery.sh
```
