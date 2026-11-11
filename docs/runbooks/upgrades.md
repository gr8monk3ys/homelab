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

### Helm 4 (since 2026-11)

`HELM_VERSION` is on Helm 4. What changed for this repo:

- A bare `--wait` (what `helm_release` passes) now means the kstatus `watcher`
  strategy; without `--wait` Helm 4 waits for hooks only (`hookOnly`), as Helm 3 did.
- New releases install with server-side apply. A release first installed by
  Helm 3 keeps client-side apply on upgrade, so existing releases behave as before.
  If a first Helm 4 upgrade reports a field-manager conflict, run it once with
  `--dry-run` to see which field, and fix the owner rather than forcing.
- `--atomic` and `--force` are now `--rollback-on-failure` and `--force-replace`;
  the scripts here use neither.

### Argo CD 3

`ARGOCD_VERSION` is on Argo CD 3. `setup-v2.sh` applies the install manifest with
`kubectl apply --server-side --force-conflicts`, as the Argo CD upgrade guide
requires. Things to know when upgrading a cluster that ran 2.x:

- Resource tracking is now annotation-based. Applications that synced with label
  tracking need one manual sync after the upgrade.
- `update`/`delete` on an Application no longer cover its managed resources, and
  log access is enforced by RBAC. This repo ships no custom `argocd-rbac-cm`
  policy, so only hand-added policies need review.
- Repositories in `argocd-cm` are no longer read; this repo already declares
  them as Secrets (`kubernetes/gitops/argocd/repositories.yaml`).
- Read each minor's guide from the version you run up to the target:
  https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/

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
