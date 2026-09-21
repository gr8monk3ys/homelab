# Ansible host prep

Prepares a Debian/Ubuntu host to run K3s. Run it once against a fresh
machine, before `./setup-v2.sh`; re-running is safe.

```bash
just ansible-prep                                   # all three playbooks
just ansible-prep -e nas_ip=192.168.1.50 -e nas_user=you -e nas_ssh_key=~/.ssh/id_ed25519
just ansible-prep --tags firewall                   # one part only
```

`inventory/hosts.yaml` has a single host, `nas`; override its address,
SSH user, key and Python path with `-e nas_ip=...`, `nas_user`, `nas_ssh_key`,
`python_path`. `-e homelab_timezone=...` sets the host timezone (defaults
to UTC; keep it equal to `homelab.timezone` in `config/homelab.yaml`).

| Playbook | Does |
|---|---|
| `playbooks/base-system.yaml` | Base packages, Docker + Compose (for the `test/` Compose stack), `/opt/homelab/{data,backups}`, timezone, sysctl limits |
| `playbooks/security.yaml` | unattended-upgrades, SSH hardening (key-only, no root), UFW (22, 80, 443, 6443, 10250), fail2ban. `-e full_upgrade=true` upgrades every package |
| `playbooks/backup.yaml` | `backup` user, rsync/rclone/restic, a nightly tar of `/etc/rancher` and `/opt/homelab/config` into `/opt/homelab/backups` with 14-day retention, plus a restore script |

It does not install K3s or anything in the cluster; that is
`setup-v2.sh`. Cluster-level backups (Velero, `scripts/backup-secrets.sh`)
are separate from the host tarball this creates.

Requires `ansible-playbook` on the machine you run it from and key-based
SSH to the host. Note the SSH hardening disables password login: make sure
your key works before running `playbooks/security.yaml`.
