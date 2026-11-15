# Disaster recovery

What survives what, and how to get back.

| Lost | Still have | Recovery |
|---|---|---|
| A bad commit | Git history | `git revert`, push; Flux reconciles. |
| One app's config | B2 restic repo | `./hack/restore.sh <namespace> <app>` |
| The K3s install | `/var/lib/homelab/volumes`, Git | `sudo ./host/setup.sh`, `./hack/bootstrap.sh`: volumes are reattached by path. |
| The SSD (OS, volumes, Immich library) | RAID, B2, Git, age key in password manager | Reinstall Arch, then the whole of [bring-up](bring-up.md), then `./hack/restore.sh` for every app, `photos immich` included. |
| The RAID | SSD (Immich library and DB dumps, app config), B2, Git | New array, then bring-up. Media is gone unless re-downloaded. |
| The age key | — | **Nothing in Git decrypts.** Make a new key and `hack/cluster-secrets.sh` again; the B2 restic repositories need the old `VOLSYNC_RESTIC_PASSWORD`, so also keep that value in the password manager. |

## Keep these outside the house

1. `~/.config/sops/age/keys.txt` — in the password manager.
2. `VOLSYNC_RESTIC_PASSWORD` — in the password manager
   (`sops -d infrastructure/secrets/cluster-secrets.sops.yaml`).
3. The B2 account login.

With those three and GitHub, everything except media comes back.

## Restore drill (monthly)

```bash
./hack/restore.sh media sonarr --test
./hack/restore.sh photos immich --test   # large: the whole library
```

A `--test` restore goes into a scratch PVC, lists it and deletes it; the app
keeps running.

## Restore all apps after a rebuild

Bootstrap first (the apps start empty), then for each app with state:

```bash
for app in prowlarr sonarr radarr bazarr qbittorrent seerr jellyfin; do ./hack/restore.sh media "$app"; done
./hack/restore.sh files opencloud
./hack/restore.sh photos immich   # only if the SSD copy is gone
```
