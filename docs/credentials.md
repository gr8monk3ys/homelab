# 🔐 Accessing Credentials (No Defaults)

This repo does **not** ship default passwords for Kubernetes deployments.

This repo supports two patterns:

1. **Generated secrets (default)**: `setup-v2.sh` runs `scripts/generate-secrets.sh`, which generates random credentials and stores them as **Kubernetes Secrets** in a central `secrets` namespace. **External Secrets Operator (ESO)** then copies those values into the namespaces where each app runs.
2. **GitOps secrets (SOPS/age)**: encrypted `Secret` manifests live in `kubernetes/secrets/sops/` and are decrypted at sync time by ArgoCD (KSOPS). See `docs/runbooks/gitops-secrets.md`.

Both patterns produce the same secrets from one table. `secrets_catalogue` in
`scripts/lib/secrets.sh` lists every generated secret as one line, `secret
<name> <key>=<policy> ...`, where the policy says how the value is made
(`password`, `hex:<bytes>`, `literal:<value>`, `empty`, `email`,
`template:<text with {key}>`, `argon2:<name>/<key>`, `users-db:...`).
`scripts/generate-secrets.sh` runs the table through the `kubectl` adapter
(upsert into `secrets`); `scripts/sops-bootstrap.sh` runs it through the
`sops` adapter (one encrypted file per secret). `scripts/generate-secrets.sh
--list` prints the table without a cluster. To add a secret, add one line to
the table and an ExternalSecret that reads it (see ADR 0004).

## Where Credentials Live

- **Source of truth**:
  - Generated secrets: `secrets` namespace (created by `scripts/generate-secrets.sh`)
  - GitOps secrets: `kubernetes/secrets/sops/` (encrypted at rest in git)
- **Runtime copies**: per-namespace Secrets created from `ExternalSecret` resources (for example `grafana-admin` in `monitoring`)

If ESO is not installed (or not running), the runtime copies will not exist yet, but the source-of-truth secrets in `secrets` still will.

## Common Commands

List generated secrets:

```bash
kubectl get secrets -n secrets
```

Read a secret field (example: Grafana admin password):

```bash
kubectl get secret -n secrets grafana-admin -o jsonpath='{.data.password}' | base64 -d && echo
```

Read the in-namespace copy (only after ESO has synced it):

```bash
kubectl get secret -n monitoring grafana-admin -o jsonpath='{.data.password}' | base64 -d && echo
```

## The full list

```bash
scripts/generate-secrets.sh --list
```

That is the authoritative answer, and it needs no cluster: it prints all 53
generated secrets with their keys and policies, straight from the table this
doc describes. **This page does not list them all** — it never will, because
a hand-copied list drifts the day someone adds a `secret` line. What follows
is the handful you actually reach for, with the notes that are not obvious
from the table.

## Service Cheat Sheet (the ones you reach for)

Thirteen of the 53, in the `secrets` namespace:

- Grafana admin: `grafana-admin` (`username`, `password`)
- Nextcloud admin: `nextcloud-admin` (`username`, `password`)
- Nextcloud DB password: `nextcloud-db-password` (`password`)
- MySQL root password: `mysql-root-password` (`password`)
- Vaultwarden admin token: `vaultwarden-admin` (`admin-token`)
- Pi-hole web password: `pihole-config` (`web-password`)
- Gitea admin: `gitea-admin` (`username`, `password`) — generated as a bootstrap credential only; no ExternalSecret copies it and nothing auto-provisions this account (Gitea runs with `INSTALL_LOCK=true` and registration disabled). Read it with `kubectl get secret -n secrets gitea-admin -o jsonpath='{.data.password}' | base64 -d`, then create the first admin manually: `kubectl -n gitea exec deploy/gitea -- gitea admin user create --admin --username <u> --password <p> --email <e>`
- MinIO root creds: `minio-config` (`root-user`, `root-password`)
- Authelia admin (plaintext for recovery): `authelia-admin` (`username`, `password`) — only the Argon2 hash in `authelia-users` reaches the cluster; read the plaintext with `kubectl get secret -n secrets authelia-admin -o jsonpath='{.data.password}' | base64 -d`
- Authelia users database: `authelia-users` (`users_database.yml`)
- Open WebUI: `open-webui-config` (`secret-key`)
- Miniflux admin: `miniflux-admin` (`username`, `password`) — created on first start via `CREATE_ADMIN=1`
- Miniflux DB password: `miniflux-db-password` (`password`)

## User-supplied (not generated)

These are **not** in the secret table. You create them
by hand in the `secrets` namespace before (or after) running `setup-v2.sh`;
the installer skips the integration with a warning when the secret is absent.
They are listed in `USER_SUPPLIED` in `scripts/secrets-check.sh`, which is
what lets CI tell an intentionally hand-made secret from a missing one.

- Alertmanager webhook (for notifications): `alertmanager-webhook` (`url`) — see `docs/runbooks/alerting.md`
- Cloudflare API token (for ExternalDNS): `cloudflare-api-token` (`token`) — see `docs/runbooks/external-dns.md`
- Cloudflare Tunnel token (for the opt-in `cloudflared` service): `cloudflare-tunnel-token` (`token`). In the Cloudflare dashboard open Zero Trust → Networks → Tunnels → Create a tunnel, pick the Cloudflared connector, name it, and on the "Install and run a connector" step copy the token from the shown `cloudflared ... --token <token>` command (nothing else on that page needs running); under Public Hostname add one entry per service you want published (hostname → `http://<service>.<namespace>.svc.cluster.local:<port>`, or `https://traefik.traefik-system.svc.cluster.local` with "No TLS verify" to go through Traefik). Then `kubectl -n secrets create secret generic cloudflare-tunnel-token --from-literal=token=<token>`. The tunnel shows Healthy in the dashboard once the pod's `/ready` probe passes.
- Tailscale OAuth client (for the opt-in `tailscale-operator` service): `tailscale-oauth` (`client-id`, `client-secret`). In the Tailscale admin console open Settings → OAuth clients → Generate OAuth client, give it the `Devices: write` scope and the tag your cluster's devices will carry (for example `tag:k8s`), then `kubectl -n secrets create secret generic tailscale-oauth --from-literal=client-id=<id> --from-literal=client-secret=<secret>`. An ExternalSecret copies it into `operator-oauth` in the `tailscale` namespace, which is where the chart looks. See `docs/runbooks/storage-and-hardware.md`.
- Renovate GitHub token (for the opt-in `renovate` CronJob): `renovate-token` (`token`). A fine-grained personal access token scoped to the homelab repository with Contents, Pull requests, Workflows and Metadata read/write (or a classic token with `repo`), created under GitHub → Settings → Developer settings; then `kubectl -n secrets create secret generic renovate-token --from-literal=token=<token>`. The repository to run against is set in the `renovate-config` ConfigMap (`kubectl -n renovate edit configmap renovate-config`), not here.

One optional secret lives outside the `secrets` namespace entirely: the
Home Assistant ServiceMonitor reads a long-lived access token from
`home-assistant-token` (`token`) in the `home-assistant` namespace
(`bearerTokenSecret`, `optional: true`). Home Assistant issues that token
from its UI (Profile → Long-lived access tokens); create the Secret yourself
with `kubectl -n home-assistant create secret generic home-assistant-token --from-literal=token=<token>`.

## Drift check

`scripts/secrets-check.sh` compares the secret table
(`scripts/generate-secrets.sh --list`) with every ExternalSecret
`remoteRef.key` under `kubernetes/` and `helm/`, plus the `kubectl get secret
-n secrets <name>` recipes in scripts and docs. A generated secret nothing
reads, or a consumed name nothing generates, fails the check, as does a
committed `kubernetes/secrets/sops/secrets/*.sops.yaml` that has no table
entry (or vice versa). `--list` prints the sets.

**The doc recipe is an escape hatch, not a consumer.** Because
`script_doc_refs` in that script scans `docs/` alongside `scripts/`, a plain
`kubectl get secret -n secrets <name>` line *in a Markdown file* counts as a
consumer and clears the ORPHAN side of the check. So if a secret ever loses
its real `ExternalSecret`, adding a line to this page would silence the
check instead of fixing the cluster. Use it only for secrets whose consumer
genuinely is a human at a terminal (the Gitea bootstrap admin and the
Authelia plaintext recovery credential above are the real cases). A secret
an app needs gets an `ExternalSecret`, not a paragraph.

## Notes

- If you enable publicly trusted TLS (Let’s Encrypt), make sure your domain is publicly reachable. Let’s Encrypt will not issue certificates for `.local` domains.
- For local domains, the default is a **local CA** via cert-manager (`ClusterIssuer: homelab-ca`). See `kubernetes/ingress/cert-manager/README.md` for how to export and trust the root CA certificate on your devices.
