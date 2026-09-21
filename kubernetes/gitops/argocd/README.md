# ArgoCD (GitOps)

This repo can install ArgoCD, but GitOps bootstrapping is intentionally **opt-in**.

## Install ArgoCD

`setup-v2.sh` installs ArgoCD when:

```bash
ENABLE_GITOPS=true ./setup-v2.sh
```

By default, the setup script applies only `projects.yaml` (safe defaults).

## Apply Repo + App-of-Apps (Opt-In)

The files in this directory contain placeholders (for example `your-username`). Before applying them, edit:

- `kubernetes/gitops/argocd/repositories.yaml`
- `kubernetes/gitops/argocd/root-app.yaml` (core apps)
- `kubernetes/gitops/argocd/root-app-full.yaml` (core + optional apps)
- `kubernetes/gitops/argocd/apps/core/kustomization.yaml` (single source of truth for child app `repoURL`)
- `kubernetes/gitops/argocd/apps/full/kustomization.yaml` (same, for the full stack)

Tip: `setup-v2.sh` can render `gitops.repo_url` into the bootstrap manifests it applies (`repositories.yaml`, `root-app.yaml`, `root-app-full.yaml`). For the child Applications, update the repo URL once in `apps/core/kustomization.yaml` (and `apps/full/kustomization.yaml` if you use the full stack) and Kustomize will replace it across all Application resources.

Then apply them:

```bash
kubectl apply -f kubernetes/gitops/argocd/repositories.yaml
kubectl apply -f kubernetes/gitops/argocd/root-app.yaml
```

To install the full stack (core + optional apps), apply:

```bash
kubectl apply -f kubernetes/gitops/argocd/root-app-full.yaml
```

Or have `setup-v2.sh` apply them automatically after ArgoCD is installed:

```bash
ENABLE_GITOPS=true APPLY_GITOPS_MANIFESTS=true ./setup-v2.sh
```

## Service Applications are generated

`apps/services/default.yaml` (what the installer deploys by default),
`apps/services/optional.yaml` (opt-in and toggled-off services) and
`projects.yaml` (AppProject destinations) are generated from the service
catalogue (`kubernetes/services/*/service.yaml`):

```bash
./scripts/services.sh argocd          # regenerate
./scripts/services.sh argocd --check  # what CI runs; fails when stale
```

`apps/core/applications.yaml` keeps only the hand-written infrastructure
Applications (secrets, MetalLB, CrowdSec). Each generated Application excludes
`service.yaml` and values files from its directory source. ArgoCD applies the
manifests exactly as committed, so for the GitOps path the placeholder domain
(`homelab.local`) must be rendered into git first, for example with
`./scripts/services.sh render <dir>` and a commit of the output, or a
Kustomize replacement in your fork.

## Notes

- Some parts of this homelab are installed via Helm directly in `setup-v2.sh` (for example Traefik, cert-manager, External Secrets Operator, and kube-prometheus-stack). If you want "full GitOps", migrate those installs into ArgoCD-managed Helm Applications.
- For GitOps-managed Secrets (SOPS + age), see `docs/runbooks/gitops-secrets.md` and `kubernetes/gitops/argocd/ksops/`.
