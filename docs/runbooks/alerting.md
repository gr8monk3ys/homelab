# Alerting (AlertmanagerConfig)

This repo supports opt-in alert notifications via `AlertmanagerConfig` resources managed by the Prometheus Operator (kube-prometheus-stack).

## Enable

1. Create a webhook URL for wherever you want notifications to go (Slack, Discord, a custom endpoint, etc).

2. Store it in the central `secrets` namespace:

```bash
kubectl -n secrets create secret generic alertmanager-webhook \
  --from-literal=url='https://example.com/webhook' \
  --dry-run=client -o yaml | kubectl apply -f -
```

3. Re-run setup with alert routing enabled:

```bash
CONFIGURE_ALERTING=true ./setup-v2.sh
```

## What It Does

- Applies `kubernetes/monitoring/alertmanager/external-secrets.yaml` (ESO sync into `monitoring`)
- Applies `kubernetes/monitoring/alertmanager/alertmanagerconfig.yaml`
- Drops noisy alerts:
  - `Watchdog`
  - `severity=info`

## Verify

```bash
kubectl get alertmanagerconfig -n monitoring
kubectl get secret -n monitoring alertmanager-webhook
kubectl -n monitoring get pods | rg alertmanager
```

## Troubleshooting

- If `AlertmanagerConfig` isn't recognized:

```bash
kubectl get crd alertmanagerconfigs.monitoring.coreos.com
```

- If the webhook Secret isn't present in `monitoring`, check ESO:

```bash
kubectl get externalsecret -n monitoring alertmanager-webhook
kubectl describe externalsecret -n monitoring alertmanager-webhook
```
