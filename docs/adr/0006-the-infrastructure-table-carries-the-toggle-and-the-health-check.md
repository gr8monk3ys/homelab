---
status: accepted
date: 2026-09-21
amends: ADR-0005
---

# The infrastructure table carries the toggle and the health check

`HELM_INFRA_RELEASES` in `scripts/lib/helm.sh` now has three more columns per
row -- `--toggle <VAR>[=<default>]`, `--health-label <selector>` and
`--health-in <ns>[,<ns>]` -- and `scripts/lib/health.sh` derives every
Helm-installed piece it checks from that table instead of repeating it.
ADR-0005 said to revisit the table "only if it needs a fourth column that
varies per piece"; this is that trigger, and the answer is still one table.

The duplicate list was doing real damage. `HEALTH_INFRA` and
`_health_infra_spec` restated the namespace of six pieces and left three out
altogether: external-dns, Kyverno and the blackbox exporter were installed by
`setup-v2.sh` and then never checked, so `./scripts/validate-setup.sh --infra`
reported "infrastructure is healthy" without ever looking at them. Deriving
the pieces from the rows makes that class of omission impossible: adding a
row now adds the health check with it.

The three new columns describe the piece, not the `helm upgrade`, so
`helm_infra_release` strips them before calling `helm_release` and
`helm_infra_field <release> <column>` is how health reads them. `--toggle`
carries its default only when the installer's default is off (external-dns,
Kyverno), so "no default written" means "on", as every other toggle in
`setup-v2.sh` means it. `--health-label` falls back to `--wait-label`, because
where the install waits on a piece's pods those are the same pods.

## Considered alternatives

A descriptor per piece was rejected again for ADR-0005's reason: the special
cases are the phases' preconditions and ordering, and a file per piece would
not remove one. A separate health table keyed by piece was what we had, and
is exactly the drift this replaces. Two columns (toggle, selector) would have
been enough for seven of the nine rows; `--health-in` exists because Traefik
is checked where K3s may already run it (`kube-system`) as well as where the
installer puts it, and that is genuinely health's business, not helm's.

## Consequences

- The `monitoring` health row is now named `kube-prometheus-stack`, after its
  release. `health_report` prints that name; nothing keys on it, and it no
  longer collides with the `monitoring` service group in `--all` output.
- A piece with no `--toggle` would be treated as always on. Every row has one,
  and a row without one is a mistake the next reader can see in the table.
- `HEALTH_INFRA` is built at source time: the four pieces that are not Helm
  releases (local-path, MinIO, CrowdSec, ArgoCD) stay in `health.sh`, which is
  the only remaining list of infrastructure and is now short enough to read.
- A wrong `--health-label` turns into a FAIL row, not a silent pass. That is
  the intended failure direction, but it means a chart that relabels its pods
  on a version bump shows up as unhealthy rather than as nothing at all.
