# Common homelab workflows.
#
# Install `just`: https://github.com/casey/just

set shell := ["bash", "-cu"]

default:
  @just --list

ci:
  ./scripts/ci.sh

dev-tools:
  ./scripts/install-dev-tools.sh

sops-bootstrap:
  ./scripts/sops-bootstrap.sh

argocd-ksops:
  ./scripts/configure-argocd-ksops.sh

# The k3d cluster on a Linux Docker host (docs/runbooks/native-linux-host.md).
# BULK_HOST_PATH is the host directory bound at /mnt/bulk in the node.
k3d-render:
  ./scripts/k3d-cluster.sh render

k3d-check:
  ./scripts/k3d-cluster.sh check

k3d-up:
  ./scripts/k3d-cluster.sh create

setup *ARGS:
  ./setup-v2.sh {{ARGS}}

validate:
  ./scripts/validate-setup.sh

services:
  ./scripts/services.sh list

services-check:
  ./scripts/services.sh check

services-render DIR:
  ./scripts/services.sh render {{DIR}}

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

# Host prep for K3s nodes (run before setup-v2.sh); see ansible/README.md.
ansible-prep *ARGS:
  cd ansible && ansible-playbook -i inventory/hosts.yaml playbooks/base-system.yaml playbooks/security.yaml playbooks/backup.yaml {{ARGS}}

kind-up:
  ./test/setup-kind.sh

kind-validate:
  ./test/validate.sh

kind-smoke:
  KIND_CONFIG=test/kind-config-smoke.yaml KIND_ENABLE_STORAGE=false KIND_ENABLE_MONITORING=false KIND_ENABLE_NEXTCLOUD=false KIND_SERVICES="homepage" ./test/setup-kind.sh setup
  ./test/validate.sh k8s
