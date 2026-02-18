# Common homelab workflows.
#
# Install `just`: https://github.com/casey/just

set shell := ["bash", "-cu"]

default:
  @just --list

ci:
  ./scripts/ci.sh

trivy *ARGS:
  docker run --rm -v "$PWD:/repo" -w /repo aquasec/trivy:0.58.2 config --skip-check-update --ignorefile /repo/.trivyignore {{ARGS}} /repo/kubernetes
  # On macOS + Docker Desktop, scanning the entire extras tree can intermittently fail due to FS walk errors.
  # Scanning the services subtree is equivalent for this repo and is more reliable.
  docker run --rm -v "$PWD:/repo" -w /repo aquasec/trivy:0.58.2 config --skip-check-update --ignorefile /repo/.trivyignore {{ARGS}} /repo/extras/kubernetes/services

dev-tools:
  ./scripts/install-dev-tools.sh

sops-bootstrap:
  ./scripts/sops-bootstrap.sh

argocd-ksops:
  ./scripts/configure-argocd-ksops.sh

setup *ARGS:
  ./setup-v2.sh {{ARGS}}

validate:
  ./scripts/validate-setup.sh

dns:
  ./scripts/configure-wildcard-dns.sh

backup-secrets:
  ./scripts/backup-secrets.sh

restore-secrets FILE:
  ./scripts/restore-secrets.sh {{FILE}}

rotate-secrets:
  ROTATE_SECRETS=true ./scripts/generate-secrets.sh

verify-backups:
  ./scripts/verify-backups.sh

kustomize-apply OVERLAY:
  ./scripts/kustomize-apply.sh {{OVERLAY}}

kind-up:
  ./test/setup-kind.sh

kind-validate:
  ./test/validate.sh

kind-smoke:
  KIND_CONFIG=test/kind-config-smoke.yaml KIND_ENABLE_STORAGE=false KIND_ENABLE_MONITORING=false KIND_ENABLE_NEXTCLOUD=false KIND_SERVICES="homepage" ./test/setup-kind.sh setup
  ./test/validate.sh k8s
