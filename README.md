# 🏠 Automated Homelab Setup v2.0

A **self-hosted** homelab deployment on Kubernetes (K3s) with externalized secret management, health checks, and multi-environment support. Includes Helm charts, Kustomize overlays, and setup automation.

> **Status:** this is a personal homelab, not a hardened product. The manifests are consistent and CI-validated, but the full 43-service stack has not been proven end-to-end on a live cluster. Deploy a subset, verify, then grow.

## 🔐 Security First
- **No hardcoded passwords** - All secrets properly managed
- **External Secrets Operator** for centralized secret management
- **Separated databases** - No more sidecar anti-patterns
- **Health checks & resource limits** on all services
- **Multi-environment support** (dev/staging/production)

## ✨ Features

### 🔐 Security & Secret Management
- **External Secrets Operator** - Centralized secret management
- **Kubernetes Secrets** - No hardcoded passwords in Kubernetes manifests
- **Automated secret generation** - 32+ character random passwords
- **Secret rotation capability** - Update without service downtime
- **SOPS + age (GitOps optional)** - Encrypted secrets at rest in git (ArgoCD via KSOPS)

### 🔧 Core Infrastructure
- **K3s Kubernetes** - Lightweight, production-ready Kubernetes
- **Traefik Ingress** - Ingress controller (routing + TLS termination via cert-manager)
- **MinIO** - S3-compatible object storage
- **Local Path Provisioner** - Dynamic persistent volume provisioning
- **Separated Databases** - StatefulSets instead of sidecars

### 📊 Monitoring & Observability
- **Prometheus + Grafana** - Comprehensive metrics and visualization
- **Uptime Kuma** - Service uptime monitoring
- **AlertManager** - Alert management and notifications
- **Loki (optional)** - Log aggregation (Promtail is opt-in)

### 🛠️ Self-Hosted Services
- **Nextcloud** - File synchronization and collaboration
- **Vaultwarden** - Password manager (Bitwarden-compatible)
- **Jellyfin** - Media server for streaming content
- **Homepage** - Application dashboard
- **Authelia** - Authentication and authorization
- **Ollama (optional)** - Local LLM runtime
- **Open WebUI (optional)** - Chat UI for Ollama

### 🔄 GitOps & Automation
- **Helm Charts** - Templated, configurable deployments
- **Kustomize Overlays** - Environment-specific configurations
- **ArgoCD** - GitOps continuous delivery
- **SOPS secrets (optional)** - Store `Secret` manifests encrypted in git (see `docs/runbooks/gitops-secrets.md`)
- **Ansible** - System configuration management
- **Automated backups** - Scheduled data protection
- **Health Checks** - Liveness and readiness probes

## 🚀 Quick Start

### Prerequisites
- Kubernetes cluster (K3s recommended) and `kubectl` configured
- RAM: ~8GB for a minimal subset; **32GB+ recommended for the full stack** (pod memory *requests* alone total ~25 GiB before monitoring/registry overhead)
- 100GB+ storage (more if you enable media/photo services)
- Root or sudo access (for installing tools)
- Internet connection (image pulls and Helm charts)

### 🚀 Quick Start (Secure)
```bash
git clone https://github.com/<you>/homelab.git
cd homelab

# Deploy (installs core controllers and creates any missing secrets)
./setup-v2.sh

# Validate deployment
./scripts/validate-setup.sh
```

### Optional: GitOps Secrets (SOPS + age)

If you want ArgoCD-managed encrypted Secrets:

```bash
./scripts/sops-bootstrap.sh
./scripts/configure-argocd-ksops.sh
```

### Optional: `just` Shortcuts

If you use [`just`](https://github.com/casey/just), this repo includes a `justfile`:

```bash
just setup
just validate
just ci
just trivy
```

## 🧰 Development

### Pre-commit Hooks (Recommended)

This repo includes a `.pre-commit-config.yaml` with fast local checks.

Install `pre-commit` (pick one):

- `pipx install pre-commit`
- `python3 -m pip install --user pre-commit`
- Or: run `./scripts/install-dev-tools.sh` and use `.tools/venv/bin/pre-commit`

Enable the git hook:

```bash
pre-commit install
```

Optional (recommended): also run the full repo gate before pushing (runs `./scripts/ci.sh` and fails if required tools are missing):

```bash
pre-commit install --hook-type pre-push
```

Run on all files:

```bash
pre-commit run -a
```

### Repo-Local Tooling (No Sudo)

Install pinned versions of the tools used by `./scripts/ci.sh` into `.tools/`:

```bash
./scripts/install-dev-tools.sh
# or
just dev-tools
```

Tool versions are pinned in `tools/versions.env`. Most repo scripts (including `./scripts/ci.sh` and `./setup-v2.sh`) will automatically use `.tools/` if present.

### 🔧 Customize What Gets Installed
```bash
# Examples
ENABLE_AI_SERVICES=true ./setup-v2.sh
ENABLE_DEV_SERVICES=true ./setup-v2.sh
ENABLE_GITOPS=true ./setup-v2.sh

INSTALL_VELERO=false INSTALL_METALLB=false ./setup-v2.sh
INSTALL_LOGGING=true INSTALL_PROMTAIL=true ./setup-v2.sh
```

### For Synology NAS Integration
```bash
# First, setup your Synology NAS
./scripts/synology-setup.sh 192.168.1.100 admin ~/.ssh/id_rsa

# Then run the main setup
./setup-v2.sh
```

## 📁 Project Structure

```
homelab/
├── setup-v2.sh             # Main setup script
├── config/
│   ├── homelab-secure.yaml  # 🆕 Secure configuration
│   └── homelab.yaml         # Symlink to secure config
├── helm/                    # 🆕 Helm charts
│   └── nextcloud/           # Example Helm chart
├── kustomize/               # 🆕 Environment overlays
│   ├── base/                # Base configurations
│   └── overlays/            # Environment-specific
│       ├── development/
│       ├── staging/
│       └── production/
├── extras/                  # Optional (higher-risk) manifests not installed by default
├── legacy/                  # Archived legacy manifests (not used by setup-v2.sh)
├── kubernetes/
│   ├── secrets/             # 🆕 Secret management
│   ├── storage/             # Storage configurations
│   ├── ingress/             # Traefik and cert-manager
│   ├── monitoring/          # Prometheus, Grafana, Uptime Kuma
│   ├── services/            # All self-hosted services (updated)
│   └── gitops/              # ArgoCD configurations
├── scripts/
│   ├── generate-secrets.sh  # 🆕 Secure secret generation
│   ├── backup-secrets.sh    # Encrypted secret backup (age)
│   ├── restore-secrets.sh   # Encrypted secret restore (age)
│   ├── configure-wildcard-dns.sh # Pi-hole wildcard DNS for *.<domain>
│   ├── validate-setup.sh    # 🆕 Comprehensive validation
│   └── synology-setup.sh    # Synology NAS configuration
├── ansible/                 # System configuration
├── docs/                    # Documentation
└── SECURITY_NOTICE.md       # 🆕 Security upgrade guide
```

## ⚙️ Configuration

- Secrets: generated into the `secrets` namespace; see `docs/credentials.md`.
- Helm values: `kubernetes/**/values.yaml` and `helm/**/values.yaml`.
- Feature toggles: see `ENABLE_*` and `INSTALL_*` at the top of `setup-v2.sh`.
- Kustomize overlays: `./scripts/kustomize-apply.sh kustomize/overlays/production`
- `setup-v2.sh` reads `config/homelab.yaml` for defaults like `homelab.domain`, `homelab.timezone`, `homelab.email`, `ingress.cert_manager.cluster_issuer`, and `gitops.repo_url` (env vars override).

## 🌐 Service Access

After setup, access your services at:

| Service | URL | Description |
|---------|-----|-------------|
| Homepage | https://home.<your-domain> | Dashboard |
| Grafana | https://grafana.<your-domain> | Monitoring dashboard |
| Nextcloud | https://nextcloud.<your-domain> | File sync & sharing |
| Vaultwarden | https://vault.<your-domain> | Password manager |
| Jellyfin | https://jellyfin.<your-domain> | Media server |
| Uptime Kuma | https://uptime.<your-domain> | Uptime monitoring |
| Ollama (optional) | https://ai.<your-domain> | Local LLM API |
| Open WebUI (optional) | https://chat.<your-domain> | Chat UI for Ollama |
| ArgoCD (optional) | https://argocd.<your-domain> | GitOps dashboard |

### DNS (Recommended)

If you enable Pi-hole, you can configure wildcard DNS so you do not need per-machine `/etc/hosts` entries:

```bash
./scripts/configure-wildcard-dns.sh

# Then point your clients (or router DHCP) at the Pi-hole DNS service IP:
kubectl -n pihole get svc pihole-dns
```

Disable the automatic DNS step during `setup-v2.sh` with:

```bash
CONFIGURE_WILDCARD_DNS=false ./setup-v2.sh
```

## 🔒 Security Features

- **TLS certificates** via cert-manager (local CA by default; optional Let’s Encrypt for public domains)
- **Pod Security Admission (PSA)** namespace labeling (`POD_SECURITY_MODE=audit|enforce`; see `docs/runbooks/hardening.md`)
- **Policy-as-code (optional)** with Kyverno (`INSTALL_KYVERNO=true`; see `docs/runbooks/hardening.md`)
- **Firewall configuration** with UFW
- **Fail2ban** for intrusion prevention
- **SSH hardening** with key-only authentication
- **Regular security updates** via unattended-upgrades
- **Backup encryption** and rotation

## 🛡️ Backup & Recovery

Automated backups run daily at 2 AM:
- **Configuration files** - Full cluster state
- **Application data** - Persistent volumes
- **Database dumps** - Complete data export
- **Retention policy** - 30 days default

Restore with:
```bash
/usr/local/bin/restore-homelab.sh /path/to/backup
```

Encrypted secret backups (recommended before rebuilds):

```bash
./scripts/backup-secrets.sh
./scripts/restore-secrets.sh backups/secrets-secrets-<timestamp>.yaml.age
```

## 📚 Additional Services

The homelab supports easy addition of more services:

### Media Services
- Radarr, Sonarr, Lidarr (media automation)
- Overseerr (request management)
- Tautulli (Plex/Jellyfin analytics)

### Development Tools
- GitLab CE (Git repository hosting)
- Jenkins (CI/CD)
- Code-server (VS Code in browser)

### Network Services
- Pi-hole (DNS filtering)
- WireGuard VPN
- Nginx Proxy Manager

Add services by placing Kubernetes manifests in `kubernetes/services/<service-name>/`

## 🐛 Troubleshooting

### Common Issues

**Services not accessible:**
```bash
kubectl get pods --all-namespaces
kubectl get ingress --all-namespaces
```

**Storage issues:**
```bash
kubectl get pv
kubectl get pvc --all-namespaces
```

**SSL certificate problems:**
```bash
kubectl get certificates --all-namespaces
kubectl describe certificate <cert-name>
```

### Runbooks

Day-2 operations (backup/restore/upgrades): `docs/runbooks/README.md`

### Logs
All setup logs are saved to `setup.log`

Service logs:
```bash
kubectl logs -f deployment/<service-name> -n <namespace>
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Add your service/improvement
4. Test thoroughly
5. Submit a pull request

## 📄 License

MIT License - see [LICENSE](LICENSE) for details

## 🙏 Acknowledgments

Built on [K3s](https://k3s.io/), [Traefik](https://traefik.io/), [Helm](https://helm.sh/), and the wider self-hosted open-source ecosystem.
