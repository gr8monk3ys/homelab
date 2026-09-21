# Homelab Testing Environment

The KinD harness: the repo's manifests and Helm releases against a real
Kubernetes cluster running in Docker, through the same modules the installer
uses (`scripts/lib/{common,render,services,netpol,helm,health}.sh`), so the
harness carries only what is KinD-specific.

## Kind (Kubernetes-In-Docker) Testing

### Prerequisites

- Docker

If you have run `./scripts/install-dev-tools.sh`, the Kind scripts will prefer `.tools/bin` for `kind`, `kubectl`, and `helm` (no sudo required).

### Quick Start

```bash
./test/setup-kind.sh setup
./test/validate.sh k8s
```

Cleanup:

```bash
./test/setup-kind.sh cleanup
```

### Smoke Profile (Fast)

Useful for a quick sanity check (and what the GitHub Actions smoke workflow runs):

```bash
KIND_CONFIG=./test/kind-config-smoke.yaml \
  KIND_ENABLE_STORAGE=false \
  KIND_ENABLE_MONITORING=false \
  KIND_ENABLE_NEXTCLOUD=false \
  KIND_SERVICES="homepage" \
  ./test/setup-kind.sh setup

./test/validate.sh k8s
```

### Toggles

| Variable | Default | Effect |
| --- | --- | --- |
| `CLUSTER_NAME` | `homelab-test` | Kind cluster name |
| `KIND_CONFIG` | `test/kind-config.yaml` | Kind cluster config (port mappings) |
| `KIND_NODE_IMAGE` | unset | pin the Kind node image |
| `KIND_ENABLE_STORAGE` | `true` | apply `kubernetes/storage/` |
| `KIND_ENABLE_MONITORING` | `true` | install kube-prometheus-stack and uptime-kuma |
| `KIND_ENABLE_NEXTCLOUD` | `true` | include the Nextcloud catalogue service |
| `KIND_SERVICES` | unset | explicit service list; overrides the groups |
| `KIND_SERVICE_GROUPS` | `core network content` | groups to deploy when `KIND_SERVICES` is unset |

### Access information

`./test/setup-kind.sh info` prints the cluster's NodePorts plus the access
summary from `scripts/lib/health.sh`, which reads service URLs from the
catalogue rather than a list kept here.

## Validation

```bash
./test/validate.sh            # all checks
./test/validate.sh config     # required files and YAML syntax
./test/validate.sh k8s        # descriptors plus cluster health
./test/validate.sh connectivity
```

`./test/test-runner.sh help` wraps both scripts.
