---
status: accepted
date: 2026-09-21
---

# Infrastructure releases are a table, not per-piece descriptors

The second architecture pass proposed a `component.yaml` descriptor next to
each `kubernetes/<piece>/` directory, mirroring `service.yaml`. We chose the
smaller shape instead: `HELM_INFRA_RELEASES` in `scripts/lib/helm.sh` is one
row per Helm-installed piece (release, chart, namespace, version variable,
values file, optional `--set` and wait label), and each installer phase is a
`helm_infra_release <name>` call plus the lines that are genuinely special
for that piece (ExternalDNS's secret precondition, MetalLB's default-range
warning, Kyverno's policy mode, the ClusterSecretStore wait). The CI chart
smoke iterates the same table.

A descriptor per piece would have moved nine rows into nine files without
removing any special case, because the special cases are the phases'
ordering and preconditions, which a descriptor cannot express without
growing into a script. Revisit only if the table needs a fourth column that
varies per piece.

## Consequences

- A chart bump is one line in `tools/versions.env`; adding a Helm-installed
  piece is one table row and one `helm_infra_release` call.
- Applications that are Helm charts belong in the catalogue as `kind: helm`
  services (ADR-0001), not in this table.
