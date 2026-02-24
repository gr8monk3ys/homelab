# Homelab Testing Environment

This directory contains testing configurations for the homelab setup.

## Docker Compose Testing

Test individual services without the complexity of Kubernetes.

⚠️ **Security note**: this Compose stack is for local testing only. It uses simple, static credentials in `test/docker-compose.yml`. Do not expose it to the internet.

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
   - Pi-hole: http://pihole.homelab.local
   - Nextcloud: http://nextcloud.homelab.local
   - Vaultwarden: http://vault.homelab.local
   - Jellyfin: http://jellyfin.homelab.local
   - Grafana: http://grafana.homelab.local
   - Gitea: http://git.homelab.local
   - MinIO: http://minio.homelab.local
   - Dashboard: http://dashboard.homelab.local
   - SearXNG: http://search.homelab.local (private search)
   - Calibre-web: http://books.homelab.local (digital library)
   - Yarr: http://rss.homelab.local

   Credentials for the Compose stack are defined in `test/docker-compose.yml`.

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

## Kind (Kubernetes-In-Docker) Testing

This exercises the Kubernetes manifests against a real Kubernetes cluster running in Docker.

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
