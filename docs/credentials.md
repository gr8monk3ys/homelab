# 🔐 Default Credentials

## Service Access Credentials

### Grafana
- URL: https://grafana.homelab.local
- Username: `admin`
- Password: `admin123`
- First login: Change password immediately

### Nextcloud
- URL: https://nextcloud.homelab.local
- Username: `admin`
- Password: `nextcloud123`
- Database: MySQL (configured automatically)

### Vaultwarden
- URL: https://vault.homelab.local
- Admin Token: `change-me-please`
- Admin Panel: https://vault.homelab.local/admin
- First user: Create during setup

### ArgoCD
- URL: https://argocd.homelab.local
- Username: `admin`
- Password: Get with: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### MinIO Console
- URL: Internal service (kubectl port-forward)
- Access Key: `minioadmin`
- Secret Key: `minioadmin123`
- Console Port: 9001

### Traefik Dashboard
- URL: http://your-server-ip:8080
- No authentication by default (internal access only)

## Database Credentials

### MySQL (Nextcloud)
- Host: `mysql-service.nextcloud.svc.cluster.local`
- Database: `nextcloud`
- Username: `nextcloud`
- Password: `nextcloud123`
- Root Password: `root123`

## System Access

### SSH (After Hardening)
- Port: 22
- Authentication: Key-only (password disabled)
- Root login: Disabled
- Key location: `~/.ssh/id_rsa`

### Backup User
- Username: `backup`
- Home: `/opt/homelab/backups`
- Shell: `/bin/bash`
- Purpose: Automated backups

## Security Notes

⚠️ **IMPORTANT: Change all default passwords immediately after setup!**

### Immediate Actions Required:
1. Change Grafana admin password
2. Update Vaultwarden admin token
3. Create strong passwords for Nextcloud
4. Generate new MinIO access keys
5. Secure ArgoCD with proper authentication

### Password Requirements:
- Minimum 12 characters
- Mix of uppercase, lowercase, numbers, symbols
- Unique for each service
- Store in password manager (use your new Vaultwarden!)

### API Keys & Tokens:
- Rotate regularly (quarterly recommended)
- Use environment-specific keys
- Never commit to version control
- Store securely in Kubernetes secrets

## Advanced Security

### Enable 2FA Where Supported:
- Nextcloud: Enable TOTP app
- Vaultwarden: Built-in 2FA support
- ArgoCD: OIDC integration available

### Network Security:
- All services behind Traefik reverse proxy
- SSL/TLS termination with Let's Encrypt
- Internal service communication
- Firewall rules restrict external access

### Monitoring Access:
- Review Grafana access logs regularly
- Monitor failed login attempts
- Set up alerts for security events
- Regular security audit of permissions

## Credential Rotation Schedule

| Service | Frequency | Method |
|---------|-----------|---------|
| System passwords | Monthly | Manual via service UI |
| Database passwords | Quarterly | Update secrets, restart services |
| SSL certificates | Automatic | Let's Encrypt auto-renewal |
| SSH keys | Yearly | Generate new, update authorized_keys |
| Backup encryption | Quarterly | Update restic repository keys |
| API tokens | Quarterly | Regenerate via service APIs |

## Emergency Access

### Lost Admin Access:
```bash
# Reset Grafana password
kubectl exec -n monitoring deployment/grafana -- grafana-cli admin reset-admin-password newpassword

# Reset ArgoCD password
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" newpassword | tr -d ':\n')'"}}'

# Access Nextcloud via database
kubectl exec -n nextcloud deployment/mysql -- mysql -u root -proot123 nextcloud
```

### Service Recovery:
- All credentials stored in Kubernetes secrets
- Backup includes encrypted credential store
- Recovery procedures in `/usr/local/bin/restore-homelab.sh`

---

**Remember: Security is a process, not a destination. Review and update regularly!** 🔒