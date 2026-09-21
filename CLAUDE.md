# CLAUDE.md

Self-hosted Kubernetes homelab on K3s. `setup-v2.sh` installs the
infrastructure layer plus the service catalogue: every directory under
`kubernetes/services/` has a `service.yaml` descriptor (group, opt-in,
ordered steps) and `scripts/lib/services.sh` is the one code path that
installs one. 23 install by default, 20 are opt-in. Not yet proven
end-to-end on a live cluster — see the README status line.

## Run / test

```bash
./setup-v2.sh                    # idempotent installer; generates secrets first
./scripts/validate-setup.sh      # cluster health + hardcoded-password check
./scripts/install-dev-tools.sh   # pinned toolchain into .tools/ (no sudo)
./scripts/ci.sh                  # what CI runs: bash -n, shellcheck, yamllint, kubeconform, services check+render, helm lint, kustomize build
./scripts/services.sh list       # the catalogue; `check` validates descriptors, `render <dir>` renders without a cluster
./test/setup-kind.sh             # throwaway KinD cluster; test/validate.sh k8s
cd test && docker compose up -d  # Compose stack; needs test/.env (copy .env.example)
```

## Where things live

- `kubernetes/{ingress,storage,backup,monitoring,dns,secrets,security}/` — infrastructure
- `kubernetes/services/<name>/` — one directory per app with a `service.yaml` descriptor (see `scripts/lib/services.sh` header); the descriptor's `group` maps to an `ENABLE_*`/`INSTALL_*` toggle and `optin: true` needs `OPTIN_SERVICES`
- `scripts/lib/{common,render,services}.sh` — shared preamble, the placeholder-rendering seam every applier uses, and `install_service`
- `kubernetes/security/network-policies/` — applied by the installer; `kubernetes/network-policies/` is a manual toolkit, not installed
- `kubernetes/secrets/sops/` — SOPS/age-encrypted Secrets for ArgoCD + KSOPS (opt-in GitOps)
- `kustomize/overlays/production/` — the only overlay (single node)
- `helm/nextcloud/` — the one Helm-chart-managed app
- `scripts/` — secrets, backup/restore, validation, DR; `tools/versions.env` pins every tool and chart version
- `CONTEXT.md` — the glossary (service, descriptor, group, opt-in, placeholder, render); `docs/adr/` — decisions; `docs/research/` — research notes
- `docs/credentials.md` lists every generated secret; `docs/runbooks/` are day-2 docs
- `archive/legacy` branch — the removed `legacy/` and `extras/` trees

## Rules

- Never commit a credential, not even as an example. Apps read `ExternalSecret`s; new ones need an entry in `scripts/generate-secrets.sh`.
- A new service is `kubernetes/services/<name>/` plus its `service.yaml`; CI fails on a directory without one. Never add a per-service block to `setup-v2.sh`.
- Every script sources `scripts/lib/common.sh`; anything that applies repo manifests goes through `scripts/lib/render.sh` (never raw `kubectl apply -f` on a repo path).
- Containers: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `runAsNonRoot` where the image allows.
- Databases are separate StatefulSets, never sidecars.
- `ENVIRONMENT` is parsed by `setup-v2.sh` but unused; only `DOMAIN` (or `config/homelab.yaml`) has effect.
- Repo is private: Actions minutes are capped. Keep CI to the one `ci.yml`; nothing scheduled.

## Agent skills

### Issue tracker

GitHub Issues on `gr8monk3ys/homelab`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, label string equal to role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
