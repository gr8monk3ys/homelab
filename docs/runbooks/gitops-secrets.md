# GitOps Secrets (SOPS + age + ArgoCD)

This repo can store the homelab's Kubernetes `Secret` resources **encrypted** using **SOPS + age**, then have **ArgoCD** decrypt them at sync time using **KSOPS**.

## Files

- Encrypted secrets live in: `kubernetes/secrets/sops/secrets/*.sops.yaml`
- Kustomize entrypoint: `kubernetes/secrets/sops/kustomization.yaml`
- SOPS config: `.sops.yaml`
- Local age private key (gitignored): `local/sops/age.key`

## Bootstrap

1. Install dev tools (includes `sops`):

```bash
./scripts/install-dev-tools.sh
```

2. Generate an age keypair (gitignored) and generate encrypted secrets:

```bash
./scripts/sops-bootstrap.sh
```

3. Configure ArgoCD to decrypt with KSOPS (creates `argocd/sops-age`, patches repo-server, updates `argocd-cm`):

```bash
./scripts/configure-argocd-ksops.sh
```

4. Sync the ArgoCD Application `homelab-secrets` (defined in `kubernetes/gitops/argocd/apps/core/applications.yaml`).

## Rotating Secrets

Re-run `./scripts/sops-bootstrap.sh` with rotation enabled, then sync ArgoCD again:

```bash
ROTATE_SOPS_SECRETS=true ./scripts/sops-bootstrap.sh
```

If you rotate the **age key**, you must:

1. Re-encrypt the repo secrets with the new **public** key (update `.sops.yaml`)
2. Update the **cluster** secret `argocd/sops-age` with the new private key
