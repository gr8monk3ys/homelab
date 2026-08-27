# Logging (Loki + Promtail)

This repo can optionally install a simple Loki setup for log aggregation.

Promtail is optional and disabled by default because it requires host access (hostPath mounts) to read node logs.

## Install Loki (Optional)

`setup-v2.sh` installs Loki when:

```bash
INSTALL_LOGGING=true ./setup-v2.sh
```

This applies the manifests under `kubernetes/services/loki/`.

## Install Promtail (Optional, Higher Risk)

Promtail ships node logs to Loki, but requires host mounts and elevated access.

Enable it explicitly:

```bash
INSTALL_LOGGING=true INSTALL_PROMTAIL=true ./setup-v2.sh
```

This applies `kubernetes/services/loki/promtail-deployment.yaml`.

## Grafana Datasource (Optional)

If monitoring/Grafana is installed, `setup-v2.sh` will also apply `kubernetes/monitoring/grafana/datasources/loki.yaml` to provision a Loki datasource.

The datasource points to:

- `http://loki.loki.svc.cluster.local:3100`

You can do this via the Grafana UI, or by adding a datasource manifest to the repo and applying it in your setup flow.
