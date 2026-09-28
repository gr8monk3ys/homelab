---
status: accepted
date: 2026-09-27
---

# Garage is the in-cluster S3 store

MinIO was the S3 target for Velero, Longhorn and VolSync until its public
images were withdrawn: quay.io answers 401 and Docker Hub denies the pull, for
the pinned release, newer ones and `latest` alike (issue #44). On the first
real deployment it never started, so backups had no target.

We replaced it with Garage (`dxflrs/garage`, deuxfleurs), pinned to a v2.x
release in `kubernetes/storage/garage/garage.yaml`. The alternatives in the
issue:

- **SeaweedFS**: an S3 gateway over a filer and volume servers. More moving
  parts and more memory than a backup target on one node needs.
- **A community rebuild of MinIO**: the smallest diff, but it trades an
  upstream that stopped publishing for a third party that might.
- **An external bucket only**: the right place for a backup to end up
  (docs/runbooks/backup-restore.md), but it needs an account and a network
  path the default install cannot assume. The in-cluster store stays the
  default; pointing Velero elsewhere is still one values change.

Garage is a single static binary built for self-hosting, publishes its own
images, and idles at a few MiB of memory here (limit 512 MiB).

## How it is wired

- One Deployment in `garage-system` (`strategy: Recreate`, two
  ReadWriteOnce PVCs: metadata and data), `replication_factor = 1`, SQLite
  metadata. Garage's docs recommend SQLite over LMDB when there is no second
  replica to rebuild metadata from after an unclean shutdown.
- One stable endpoint, `http://garage.garage-system.svc.cluster.local:3900`,
  region `garage`, path-style. Every consumer names it.
- The secret table generates Garage's RPC secret, admin and metrics tokens
  (`garage-config`) and one shared backup key (`backup-s3-credentials`). The
  key ID is generated in Garage's own shape (`GK` + 24 hex) by the
  `garage-key-id` policy, so the key exists before Garage does and every
  consumer's ExternalSecret can read it on the first install.
- Garage needs a layout, keys and buckets before it serves anything. A Job
  (`garage-bootstrap`) does that through the admin API, checking before
  every step, and runs on every install. The Garage image has no shell, so
  the Job runs curl in its own image.

## Consequences

- The secret rows were renamed (`minio-config`, `velero-minio-credentials` →
  `garage-config`, `backup-s3-credentials`). A cluster that already has the
  old rows keeps them until removed by hand; nothing reads them.
- The committed SOPS files follow the table: the two MinIO files are gone and
  the two new ones were encrypted to the existing age recipient in
  `.sops.yaml` with freshly generated values, as `sops-bootstrap.sh` would.
- Garage has no web console, so there is no `minio.<domain>`-style URL.
  Inspect it with `kubectl -n garage-system exec deploy/garage -- /garage …`.
- The backups still sit on the node's own disk. That was true of MinIO and is
  true of any in-cluster store; `verify-backups.sh` keeps saying so.
