# Homelab Testing Environment

This directory contains testing configurations for the homelab setup.

## Docker Compose Testing

Test individual services without the complexity of Kubernetes.

### Prerequisites

- Docker and Docker Compose installed
- At least 8GB RAM available
- 50GB free disk space

### Quick Start

1. **Start the testing stack:**
   ```bash
   cd test/
   docker-compose up -d
   ```

2. **Add entries to your `/etc/hosts` file:**
   ```
   127.0.0.1 homelab.local
   127.0.0.1 nextcloud.homelab.local
   127.0.0.1 vault.homelab.local
   127.0.0.1 jellyfin.homelab.local
   127.0.0.1 grafana.homelab.local
   127.0.0.1 pihole.homelab.local
   127.0.0.1 git.homelab.local
   127.0.0.1 registry.homelab.local
   127.0.0.1 minio.homelab.local
   127.0.0.1 dashboard.homelab.local
   127.0.0.1 search.homelab.local
   127.0.0.1 books.homelab.local
   127.0.0.1 rss.homelab.local
   ```

3. **Access services:**
   - Traefik Dashboard: http://localhost:8080
   - Pi-hole: http://pihole.homelab.local (password: admin123)
   - Nextcloud: http://nextcloud.homelab.local (admin/nextcloud123)
   - Vaultwarden: http://vault.homelab.local
   - Jellyfin: http://jellyfin.homelab.local
   - Grafana: http://grafana.homelab.local (admin/admin123)
   - Gitea: http://git.homelab.local
   - MinIO: http://minio.homelab.local (minioadmin/minioadmin123)
   - Dashboard: http://dashboard.homelab.local
   - SearXNG: http://search.homelab.local (private search)
   - Calibre-web: http://books.homelab.local (digital library)
   - Yarr: http://rss.homelab.local (admin/yarrPass123)

### Service Status

Check service status:
```bash
docker-compose ps
```

View logs:
```bash
docker-compose logs -f [service-name]
```

Stop services:
```bash
docker-compose down
```

Remove all data:
```bash
docker-compose down -v
```

### Limitations

**What works:**
- Individual service functionality
- Basic inter-service communication
- Web interface access
- Basic monitoring

**What doesn't work:**
- Advanced Kubernetes features
- Automatic SSL certificates (Let's Encrypt)
- Full network isolation
- Some advanced integrations

### Media Testing

Create a `media` directory for Jellyfin:
```bash
mkdir -p test/media/{movies,tv,music}
# Add some sample media files for testing
```

### Development Workflow

1. Test individual services with Docker Compose
2. Validate configurations and connectivity
3. Debug issues in isolated environment
4. Apply fixes to Kubernetes manifests
5. Deploy to full homelab environment

## Network Configuration

The Docker Compose stack uses:
- Network: 172.20.0.0/16
- Pi-hole IP: 172.20.0.10
- All other services use dynamic IPs

## Resource Usage

Approximate resource consumption:
- CPU: 2-4 cores
- RAM: 6-8GB
- Storage: 20-50GB (depending on data)

Monitor resource usage:
```bash
docker stats
```