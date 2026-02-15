# GitOps Secrets (SOPS/age)

This folder contains the **source-of-truth** Kubernetes `Secret` manifests for the homelab, encrypted with **SOPS + age**.

## Layout

- `kustomization.yaml`: Kustomize entrypoint used by ArgoCD
- `ksops-generator.yaml`: KSOPS function config that decrypts the secret manifests
- `secrets/*.sops.yaml`: encrypted `Secret` resources (one file per secret)

## Bootstrap

Generate an age keypair (gitignored) and create/update encrypted secret manifests:

```bash
./scripts/sops-bootstrap.sh
```

Rotate/regenerate (overwrites encrypted files):

```bash
ROTATE_SOPS_SECRETS=true ./scripts/sops-bootstrap.sh
```

Then configure ArgoCD repo-server to decrypt them:

```bash
./scripts/configure-argocd-ksops.sh
```
