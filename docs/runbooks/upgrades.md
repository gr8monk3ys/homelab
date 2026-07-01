# Upgrades

This repo is designed so that upgrades are mostly "re-apply desired state":

- If you use GitOps (ArgoCD): commit changes, let ArgoCD sync, and roll back via Git.
- If you do not use GitOps: re-run `./setup-v2.sh` (it is intended to be idempotent).

## Preflight Checklist

1. Ensure you have a secrets backup:

```bash
./scripts/backup-secrets.sh
```

2. Ensure Velero has recent successful backups (if enabled):

```bash
kubectl -n velero get schedule,backup
```

3. Validate manifests locally:

```bash
./scripts/install-dev-tools.sh
CI=true ./scripts/ci.sh
just kind-smoke
```

## Upgrade The Repo Toolchain

Tool versions are pinned in `tools/versions.env`.

After editing it:

```bash
./scripts/install-dev-tools.sh
```

## Upgrade Cluster Components (Non-GitOps)

Re-run the setup script to apply updates:

```bash
./setup-v2.sh
./scripts/validate-setup.sh
```

If you want to limit what gets applied, use the `ENABLE_*` / `INSTALL_*` toggles in `setup-v2.sh`.

## Upgrade With ArgoCD (GitOps)

1. Commit changes to the repo (manifests/values/overlays).
2. Let ArgoCD sync (or trigger a manual sync).
3. If something breaks, roll back by reverting the Git commit.

ArgoCD bootstrap docs: `kubernetes/gitops/argocd/README.md`

## Rollback Basics

- Deployments:

```bash
kubectl rollout history deployment/<name> -n <namespace>
kubectl rollout undo deployment/<name> -n <namespace>
```

- Helm releases:

```bash
helm history <release> -n <namespace>
helm rollback <release> <revision> -n <namespace>
```
