# 🏠 Automated Homelab Setup v2.0

A **production-ready, secure** homelab deployment using Kubernetes with proper secret management, health checks, and multi-environment support. Features Helm charts, Kustomize overlays, and comprehensive automation.

## 🔐 Security First
- **No hardcoded passwords** - All secrets properly managed
- **External Secrets Operator** for centralized secret management
- **Separated databases** - No more sidecar anti-patterns
- **Health checks & resource limits** on all services
- **Multi-environment support** (dev/staging/production)

## ✨ Features

### 🔐 Security & Secret Management
- **External Secrets Operator** - Centralized secret management
- **Kubernetes Secrets** - No hardcoded passwords anywhere
- **Automated secret generation** - 32+ character random passwords
- **Secret rotation capability** - Update without service downtime

### 🔧 Core Infrastructure
- **K3s Kubernetes** - Lightweight, production-ready Kubernetes
- **Traefik Ingress** - Automatic service discovery and SSL certificates
- **MinIO** - S3-compatible object storage
- **Local Path Provisioner** - Dynamic persistent volume provisioning
- **Separated Databases** - StatefulSets instead of sidecars

### 📊 Monitoring & Observability
- **Prometheus + Grafana** - Comprehensive metrics and visualization
- **Uptime Kuma** - Service uptime monitoring
- **AlertManager** - Alert management and notifications

### 🛠️ Self-Hosted Services
- **Nextcloud** - File synchronization and collaboration
- **Vaultwarden** - Password manager (Bitwarden-compatible)
- **Jellyfin** - Media server for streaming content
- **Heimdall** - Application dashboard
- **Authelia** - Authentication and authorization

### 🔄 GitOps & Automation
- **Helm Charts** - Templated, configurable deployments
- **Kustomize Overlays** - Environment-specific configurations
- **ArgoCD** - GitOps continuous delivery
- **Ansible** - System configuration management
- **Automated backups** - Scheduled data protection
- **Health Checks** - Liveness and readiness probes

## 🚀 Quick Start

### Prerequisites
- Linux server (Ubuntu/Debian recommended)
- 4GB+ RAM, 50GB+ storage
- Root or sudo access
- Internet connection

### 🚀 Quick Start (Secure)
```bash
git clone https://github.com/yourusername/homelab.git
cd homelab

# Generate secure secrets first
./scripts/generate-secrets.sh

# Deploy with new secure architecture
./setup-v2.sh

# Validate deployment
./scripts/validate-setup.sh
```

### 🔧 Custom Environment
```bash
ENVIRONMENT=production DOMAIN=yourdomain.com ./setup-v2.sh
```

### For Synology NAS Integration
```bash
# First, setup your Synology NAS
./scripts/synology-setup.sh 192.168.1.100 admin ~/.ssh/id_rsa

# Then run the main setup
./setup.sh
```

## 📁 Project Structure

```
homelab/
├── setup-v2.sh             # 🆕 Enhanced secure setup script
├── setup.sh                 # 🚫 Legacy (insecure)
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
├── kubernetes/
│   ├── secrets/             # 🆕 Secret management
│   ├── storage/             # Storage configurations
│   ├── ingress/             # Traefik and cert-manager
│   ├── monitoring/          # Prometheus, Grafana, Uptime Kuma
│   ├── services/            # All self-hosted services (updated)
│   └── gitops/              # ArgoCD configurations
├── scripts/
│   ├── generate-secrets.sh  # 🆕 Secure secret generation
│   ├── validate-setup.sh    # 🆕 Comprehensive validation
│   └── synology-setup.sh    # Synology NAS configuration
├── ansible/                 # System configuration
├── docs/                    # Documentation
└── SECURITY_NOTICE.md       # 🆕 Security upgrade guide
```

## ⚙️ Configuration

Edit `config/homelab.yaml` to customize your setup:

```yaml
homelab:
  domain: "homelab.local"
  timezone: "America/New_York"
  email: "your-email@example.com"

services:
  nextcloud:
    admin_user: "admin"
    admin_password: "secure-password"
    storage_size: "100Gi"
  # ... more services
```

## 🌐 Service Access

After setup, access your services at:

| Service | URL | Description |
|---------|-----|-------------|
| Dashboard | https://dashboard.homelab.local | Heimdall dashboard |
| Grafana | https://grafana.homelab.local | Monitoring dashboard |
| Nextcloud | https://nextcloud.homelab.local | File sync & sharing |
| Vaultwarden | https://vault.homelab.local | Password manager |
| Jellyfin | https://jellyfin.homelab.local | Media server |
| Uptime Kuma | https://uptime.homelab.local | Uptime monitoring |
| ArgoCD | https://argocd.homelab.local | GitOps dashboard |

## 🔒 Security Features

- **Automated SSL certificates** via Let's Encrypt
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

- [K3s](https://k3s.io/) - Lightweight Kubernetes
- [Traefik](https://traefik.io/) - Cloud Native Networking Stack
- [Helm](https://helm.sh/) - Package Manager for Kubernetes
- All the amazing open-source projects that make this possible

---

⭐ **Star this repo if you found it helpful!** ⭐