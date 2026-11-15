# Bring-up on the Arch host

From a wiped or new host to every app running. Order matters. Steps marked
**(owner)** need an account or a decision; the rest are commands.

## 0. Before anything touches the RAID

- `cat /proc/mdstat` shows `[UUU]` and no resync.
- Nothing from before is deleted: the old Garage blocks in
  `/mnt/raid/50 Dev/52 homelab/garage` have no metadata (it was on the wiped
  drive) and are unreadable; move them aside once B2 holds a backup, never before.

## 1. Accounts (owner)

1. **Backblaze B2**: a private bucket (keep all versions, no lifecycle rule
   that deletes), and an application key limited to that bucket. Note the S3
   endpoint shown on the bucket page.
2. **VPN** for qBittorrent: a WireGuard config from a provider gluetun
   supports (private key, interface address).
3. **Renovate**: install the Mend Renovate GitHub app on `gr8monk3ys/homelab`
   (https://github.com/apps/renovate). It opens a Dependency Dashboard issue and
   PRs; patch and digest bumps merge themselves after CI.
4. **ntfy**: install the app on your phone; `hack/cluster-secrets.sh` prints
   the topic to subscribe to.

## 2. Host

```bash
sudo ./host/setup.sh
```

nvidia-container-toolkit, the RAID at `/mnt/raid` via fstab, the Immich
library at `/var/lib/homelab/immich` on the SSD (copied once from the RAID),
the ufw rules K3s needs (pods to host, servicelb forwarding from private
networks), K3s (pinned in the script), and `~/.kube/config`. It ends by checking the node is Ready and
that K3s found the nvidia runtime.

## 3. Secrets (owner)

The age key is `~/.config/sops/age/keys.txt`. **Copy it into the password
manager now.** Without it the secrets in Git are unreadable and a rebuild
cannot decrypt them.

```bash
./hack/cluster-secrets.sh        # asks for B2 and VPN values, generates the rest
git add infrastructure/secrets/cluster-secrets.sops.yaml && git commit -m "chore: cluster secrets"
git push
```

## 4. Flux

```bash
GITHUB_TOKEN=<fine-grained PAT: this repo, Contents + Administration rw> ./hack/bootstrap.sh
```

Watch until `cluster-secrets`, `infrastructure-controllers`,
`infrastructure-configs`, `apps` and every app are Ready.

## 5. DNS and the LAN CA

k8s-gateway answers `*.home.arpa` on the host's port 53 (UDP). Point clients at
it for that domain only:

- **Router**: a conditional forward of `home.arpa` to the host (172.16.0.43),
  if the router supports it; or
- **Tailscale** (also gives remote access): `sudo pacman -S tailscale`,
  `sudo systemctl enable --now tailscaled`, `sudo tailscale up
  --advertise-routes=172.16.0.43/32`, approve the route in the admin console,
  then Admin → DNS → add a split-DNS nameserver 172.16.0.43 for `home.arpa`.

Check: `dig @172.16.0.43 photos.home.arpa` returns the host's address.

Trust the CA once per device:

```bash
kubectl -n cert-manager get secret homelab-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
sudo trust anchor homelab-ca.crt        # Arch; phones: install as a CA profile
```

## 6. Data back in

- **Media** is already at `/mnt/raid/50 Dev/52 homelab/data` and appears in
  Sonarr/Radarr/Jellyfin at `/data`.
- **Immich**: the library is at `/var/lib/homelab/immich` (setup.sh copied it
  from `.../52 homelab/immich`, which stays as a fallback until B2 holds a
  backup). The database was lost
  with the old host; the newest nightly dump is in `.../immich/backups/`.
  With the `immich` Deployment scaled to 0:

  ```bash
  flux suspend kustomization immich
  kubectl -n photos scale deploy immich --replicas=0
  # Immich's dumps are pg_dumpall output; this is Immich's documented restore
  # (https://immich.app/docs/administration/backup-and-restore).
  gunzip -c "/var/lib/homelab/immich/backups/<newest>.sql.gz" \
    | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | kubectl -n photos exec -i immich-db-1 -- psql -U postgres -d postgres
  flux resume kustomization immich
  ```

  Check the dump's Immich version against the running one first (the file
  name carries it); Immich migrates forward, not back. The old dump's tables
  are owned by the old setup's role; if Immich then logs permission errors,
  give the `immich` role ownership of the restored tables before going further.

## 7. Verify

```bash
flux get kustomizations -A          # all Ready
kubectl get pods -A | grep -v Running | grep -v Completed
kubectl -n media get replicationsource   # every app: a lastSyncTime after the first night
./hack/restore.sh media prowlarr --test  # a backup that restores
```

Grafana: `https://grafana.home.arpa`, admin and the password printed by
`hack/cluster-secrets.sh`. Fire a test alert to be sure ntfy works:

```bash
kubectl -n monitoring exec sts/alertmanager-kube-prometheus-stack-alertmanager -- \
  amtool alert add test severity=warning --annotation=summary="ntfy test" --alertmanager.url=http://localhost:9093
```
