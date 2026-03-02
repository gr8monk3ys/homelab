# Extras

This directory contains **optional** manifests that are not installed by `setup-v2.sh` by default.

Common reasons a component lives under `extras/`:
- It requires elevated privileges (for example `hostNetwork`, host mounts, or extra Linux capabilities).
- It requires broad RBAC.
- It is intentionally opt-in so the base homelab stays secure-by-default and clean in automated scans.

## Use

Apply an extra component explicitly, for example:

```bash
kubectl apply -f extras/kubernetes/services/<component>/
```

If you enable extras, consider running Trivy against them separately.

## Current Extras

- `extras/kubernetes/monitoring/uptime-kuma/`: Optional ServiceMonitor for Uptime Kuma metrics (requires enabling metrics in Uptime Kuma).
- `extras/kubernetes/services/drone/`: Drone runner that mounts Docker socket from the host.
- `extras/kubernetes/services/flaresolverr/`: FlareSolverr (requires `SYS_ADMIN`).
- `extras/kubernetes/services/jellyfin/`: Optional ServiceMonitor (requires Jellyfin Prometheus plugin or another metrics exporter).
- `extras/kubernetes/services/netdata/`: Netdata node monitoring (host mounts/ports).
- `extras/kubernetes/services/reloader/`: Stakater Reloader (cluster-wide RBAC to patch workloads).
- `extras/kubernetes/services/trivy/`: Trivy Operator (broad RBAC + creates Jobs/CronJobs).
- `extras/kubernetes/services/loki/promtail-deployment.yaml`: Promtail (hostPath log collector for Loki).
