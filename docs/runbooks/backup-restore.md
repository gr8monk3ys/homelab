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

## Where the backups land (read this first)

Velero's default `BackupStorageLocation` points at the MinIO running inside
this cluster (`http://minio.minio.svc.cluster.local:9000`). MinIO stores its
data on a `local-path` PersistentVolume, which is a directory on the node's
own disk.

On a single-node homelab that means **the backups sit on the same physical
disk as the volumes they back up**. That covers exactly one failure mode, a
bad `kubectl delete`, and none of the ones people actually lose data to: a
dead disk, a dead node, a filesystem that will not mount.

`./scripts/verify-backups.sh` warns about this on every run while the target
is in-cluster and the node count is one.

To fix it, point the BackupStorageLocation somewhere off this machine:

- **A NAS over S3 or NFS.** Point `s3Url` at the NAS's S3 endpoint, or mount
  an NFS export and use Velero's filesystem backup.
- **An external S3 bucket** (Backblaze B2, Wasabi, AWS). Change `s3Url`,
  `region` and `bucket` in `kubernetes/backup/velero/values.yaml`, and put
  the credentials in the secret table (`scripts/lib/secrets.sh`) instead of
  reusing the MinIO ones.
- **A second machine** running MinIO, if you already have one.

Whatever you choose, prove a restore once. A backup nobody has restored from
is a hypothesis.

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

Its reinstall options (`infrastructure`, `monitoring`, `security`,
`services`, and the steps of `full`) run the installer's own phases from
`setup-v2.sh`, so a recovery cannot diverge from a fresh install; the same
`INSTALL_*`/`ENABLE_*`/`POD_SECURITY_MODE` settings apply. A full recovery
runs them in the installer's order:

1. Infrastructure: `setup_ingress`, then the optional secrets restore (below),
   then `setup_secrets`, `setup_storage` and `setup_backup`.
2. Monitoring: `setup_monitoring`, `setup_logging`.
3. Security posture: CrowdSec (`setup_security`), then the Pod Security, PodDisruptionBudget, ResourceQuota,
   Kyverno and static NetworkPolicy phases. These cover infrastructure
   namespaces only and skip any that do not exist; a service's own labels,
   quota, PDB and policies come back with the service (ADR-0009). Also
   available on its own as `./scripts/disaster-recovery.sh security` or the
   menu's "Reapply the security posture" item.
4. Services: `setup_service_group core`, then the services named in
   `CRITICAL_SERVICES` (default `vaultwarden nextcloud gitea home-assistant`).

MetalLB is not reinstalled by DR.

To include a secrets restore as part of the run (optional; it runs before the
installer generates secrets, so restored values are kept):

```bash
SECRETS_BACKUP_FILE=backups/secrets-secrets-<timestamp>.yaml.age ./scripts/disaster-recovery.sh
```
