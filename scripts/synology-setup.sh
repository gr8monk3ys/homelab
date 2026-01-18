#!/bin/bash
set -euo pipefail

SYNOLOGY_IP="${1:-}"
SYNOLOGY_USER="${2:-admin}"
SSH_KEY="${3:-$HOME/.ssh/id_rsa}"
# Network range allowed to access NFS (default: common home network)
NFS_ALLOWED_NETWORK="${NFS_ALLOWED_NETWORK:-192.168.1.0/24}"

if [ -z "$SYNOLOGY_IP" ]; then
    echo "Usage: $0 <synology_ip> [username] [ssh_key_path]"
    echo "Example: $0 192.168.1.100 admin ~/.ssh/id_rsa"
    echo ""
    echo "Environment variables:"
    echo "  NFS_ALLOWED_NETWORK - Network CIDR for NFS access (default: 192.168.1.0/24)"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Setting up Synology NAS for Homelab at $SYNOLOGY_IP"

ssh_cmd() {
    # Use 'accept-new' to accept first-time connections but reject changed keys (MITM protection)
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$SYNOLOGY_USER@$SYNOLOGY_IP" "$@"
}

scp_cmd() {
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$@"
}

log "Testing SSH connection..."
if ! ssh_cmd "echo 'SSH connection successful'"; then
    echo "ERROR: Cannot connect to Synology NAS. Please check:"
    echo "1. SSH is enabled in Control Panel > Terminal & SNMP"
    echo "2. Your SSH key is added to the authorized_keys"
    echo "3. The IP address and username are correct"
    exit 1
fi

log "Updating package list..."
ssh_cmd "sudo synopkg update"

log "Installing Docker package..."
ssh_cmd "sudo synopkg install Docker"

log "Starting Docker service..."
ssh_cmd "sudo synoservice --enable pkgctl-Docker"
ssh_cmd "sudo synoservice --start pkgctl-Docker"

log "Creating homelab directory structure..."
ssh_cmd "mkdir -p /volume1/homelab/{data,config,backups}"
ssh_cmd "mkdir -p /volume1/homelab/data/{nextcloud,jellyfin,vaultwarden,prometheus,grafana}"

log "Setting up Docker Compose environment..."
# Use the version-controlled docker-compose file instead of inline heredoc
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_DIR="$(dirname "$SCRIPT_DIR")"
scp_cmd "${HOMELAB_DIR}/config/synology-docker-compose.yml" "$SYNOLOGY_USER@$SYNOLOGY_IP:/volume1/homelab/docker-compose.yml"

log "Starting Portainer for container management..."
ssh_cmd "cd /volume1/homelab && docker-compose up -d"

log "Setting up NFS shares for Kubernetes..."
ssh_cmd "sudo mkdir -p /volume1/k8s-storage"
ssh_cmd "sudo chown -R $SYNOLOGY_USER:users /volume1/k8s-storage"

log "Configuring NFS exports..."
# Secure NFS configuration:
# - Restricted to specific network (not world-accessible)
# - root_squash prevents remote root from having local root privileges
# - sync ensures data integrity (no async data loss)
# - sec=sys uses standard UNIX authentication
ssh_cmd "echo '/volume1/k8s-storage ${NFS_ALLOWED_NETWORK}(rw,sync,root_squash,sec=sys,anonuid=1025,anongid=100)' | sudo tee -a /etc/exports"
ssh_cmd "sudo exportfs -ra"

log "Creating backup scripts..."
cat > backup-script.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/volume1/homelab/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"

# Backup Docker volumes
docker run --rm -v homelab_portainer_data:/data -v "$BACKUP_DIR":/backup alpine tar czf /backup/portainer-backup.tar.gz -C /data .

# Backup configuration files
tar czf "$BACKUP_DIR/config-backup.tar.gz" -C /volume1/homelab config/

# Cleanup old backups (keep 7 days)
find /volume1/homelab/backups -type d -mtime +7 -exec rm -rf {} +

echo "Backup completed: $BACKUP_DIR"
EOF

scp_cmd "backup-script.sh" "$SYNOLOGY_USER@$SYNOLOGY_IP:/volume1/homelab/"
ssh_cmd "chmod +x /volume1/homelab/backup-script.sh"

log "Setting up backup cron job..."
ssh_cmd "(crontab -l 2>/dev/null; echo '0 2 * * * /volume1/homelab/backup-script.sh') | crontab -"

log "Synology setup completed!"
echo ""
echo "🎉 Your Synology NAS is configured for the homelab!"
echo ""
echo "Next steps:"
echo "1. Access Portainer at: http://$SYNOLOGY_IP:9000"
echo "2. Configure your homelab.yaml with the NAS IP"
echo "3. Run the main setup script from your Kubernetes host"
echo ""
echo "NFS storage is available at: $SYNOLOGY_IP:/volume1/k8s-storage"
echo "Backup directory: /volume1/homelab/backups"