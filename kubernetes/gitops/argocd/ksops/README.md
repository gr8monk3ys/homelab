# ArgoCD KSOPS Integration

ArgoCD does not decrypt SOPS secrets by default. This repo uses **KSOPS** (a Kustomize exec plugin) so ArgoCD can sync SOPS-encrypted `Secret` manifests.

## What This Does

- Sets ArgoCD Kustomize build options to allow exec plugins:
  - `kustomize.buildOptions: --enable-alpha-plugins --enable-exec`
- Patches `argocd-repo-server` to:
  - Install `ksops` + `kustomize` from `viaductoss/ksops:v4.4.0`
  - Mount the age private key from `argocd/sops-age` at `/.config/sops/age/keys.txt`

## Apply

Use the repo script:

```bash
./scripts/configure-argocd-ksops.sh
```

