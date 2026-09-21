# Logging (Loki + Grafana Alloy)

This repo can optionally install a simple Loki setup for log aggregation, plus
Grafana Alloy as the log shipper that feeds it.

Alloy replaced Promtail here because Grafana declared Promtail end-of-life on
2 March 2026; it receives no further updates or security fixes, and Alloy (an
OpenTelemetry Collector distribution) is Grafana's supported successor.

The shipper is optional and disabled by default because it requires host
access (hostPath mounts) to read node logs.

## Install Loki (Optional)

`setup-v2.sh` installs Loki when:

```bash
INSTALL_LOGGING=true ./setup-v2.sh
```

This applies the manifests under `kubernetes/services/loki/`.

## Install Grafana Alloy (Optional, Higher Risk)

Alloy ships node logs to Loki, but requires host mounts and elevated access.

Enable it explicitly:

```bash
INSTALL_LOGGING=true INSTALL_ALLOY=true ./setup-v2.sh
```

This applies `kubernetes/services/loki/alloy-daemonset.yaml`: a DaemonSet, its
ServiceAccount, a ClusterRole/ClusterRoleBinding granting `get`/`list`/`watch`
on pods, nodes and namespaces, and the `alloy-config` ConfigMap.

### Where the configuration lives

The Alloy pipeline is the `config.alloy` key of the `alloy-config` ConfigMap in
`kubernetes/services/loki/alloy-daemonset.yaml`. It uses Alloy's own syntax:

- `discovery.kubernetes "pods"` — discovers the pods scheduled on this node
- `discovery.relabel "pod_logs"` — sets the `namespace`, `pod`, `container`,
  `node`, `app` and `job` labels and builds the `/var/log/pods/...` path
- `local.file_match` + `loki.source.file` — tail the matching log files
- `loki.process` (`stage.cri {}`) — parse the CRI log format
- `loki.write "default"` — push to
  `http://loki.loki.svc.cluster.local:3100/loki/api/v1/push`

Read it back from a running cluster with:

```bash
kubectl -n loki get configmap alloy-config -o jsonpath='{.data.config\.alloy}'
```

Editing the ConfigMap is not enough on its own — restart the DaemonSet so the
pods pick the new config up:

```bash
kubectl -n loki rollout restart daemonset/alloy
```

### Security context

Alloy runs as root (`runAsNonRoot: false`, `runAsUser: 0`). The container log
files under `/var/log/pods` are root-owned and mode 0600 on K3s, and the
`grafana/alloy` image ships no default user. Every capability is dropped,
`allowPrivilegeEscalation` is false, the root filesystem is read-only, the
seccomp profile is `RuntimeDefault`, and `/var/log` is mounted read-only.

Note that the `loki` namespace is labelled
`pod-security.kubernetes.io/enforce: baseline`, and the baseline Pod Security
Standard forbids hostPath volumes. On a cluster where that label is enforced,
the Alloy pods are not admitted; relabel the namespace to `privileged` (the
convention this repo uses for the other hostPath services, see
`kubernetes/services/kured/namespace.yaml`) before enabling `INSTALL_ALLOY`.

## Check that Alloy is shipping

```bash
kubectl -n loki get daemonset alloy
kubectl -n loki get pods -l app=alloy
kubectl -n loki logs ds/alloy
```

A healthy pod logs component start-up lines and nothing about
`loki.write` retries. Alloy's own UI and metrics are on port 12345:

```bash
kubectl -n loki port-forward ds/alloy 12345:12345
# then open http://localhost:12345/ for the component graph,
# or curl http://localhost:12345/-/ready
```

Then confirm the logs landed, in Grafana → Explore, with the Loki datasource
selected:

```logql
{namespace="loki"}
```

or, for one workload:

```logql
{namespace="monitoring", container="grafana"}
```

If Explore returns no streams, check `kubectl -n loki logs ds/alloy` for push
errors and confirm the NetworkPolicies allow same-namespace traffic
(`allow-same-namespace` is in the descriptor's `networkPolicies:` list).

## Grafana Datasource (Optional)

If monitoring/Grafana is installed, `setup-v2.sh` will also apply `kubernetes/monitoring/grafana/datasources/loki.yaml` to provision a Loki datasource.

The datasource points to:

- `http://loki.loki.svc.cluster.local:3100`

You can do this via the Grafana UI, or by adding a datasource manifest to the repo and applying it in your setup flow.
