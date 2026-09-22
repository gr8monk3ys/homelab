---
status: rejected
date: 2026-09-22
---

# Installer phases are not a table

A review pass proposed collapsing `main()` in `setup-v2.sh` into a table of
phases — one row per phase (name, toggle, function or group), driven by a
loop — the way `HELM_INFRA_RELEASES` collapsed the Helm installs (ADR-0005).
We rejected it: this is ADR-0005's own argument, applied to phases, coming
out the other way.

`main()` runs 28 phases. Exactly 8 of them fit a table row: the pure group
wrappers (`media`, `content`, `ai`, `productivity`, `home`, `communication`,
`monitoring` apps, and `core` bar a comment), whose whole body is a `log`,
one `install_service_group <g>` and a `success`. Two more are group phases
with residue a row cannot carry: `network` branches on
`CONFIGURE_WILDCARD_DNS` and shells out to
`scripts/configure-wildcard-dns.sh`, and `dev` emits the Drone-without-a-
runner warning. The other 18 do not fit at all, because each carries a
precondition or a dispatch that is not a column: the `kube-root-ca.crt`
ConfigMap poll before the ClusterSecretStore, the
`secrets/cloudflare-api-token` source-secret gate before ExternalDNS, the
AlertmanagerConfig CRD gate before alert routing, the MetalLB
default-example-range check, and two `case` dispatches, on
`POD_SECURITY_MODE` (`off|audit|enforce`) and `KYVERNO_POLICY_MODE`
(`audit|enforce`). Those 18 bodies run 7 to 40 lines.

A phase table would therefore describe under a third of the phases and leave
the rest as functions called from the loop anyway — two mechanisms where
there is now one, and no special case removed. ADR-0005 accepted the table
for Helm releases because the rows there differ only in values; here the
phases differ in their preconditions, which is precisely what a row cannot
hold.

## Consequences

- `main()` stays a readable list of named phase calls. Each phase is still a
  function so `scripts/disaster-recovery.sh` can re-run one by name.
- A narrower move stays open and is not rejected here: the ten
  `setup_*_services` wrappers are 8 pure ones plus 2 with residue, so
  `main()` could loop `SERVICE_GROUPS` (already the ordered table of groups)
  instead of calling ten wrappers, leaving the two residues as the phases
  that keep a body. That is a change to one-third of the phases, not to the
  shape of `main()`.
- Revisit the whole question only if the preconditions move out of
  `setup-v2.sh` — if a phase's gate becomes a declaration rather than code,
  the row becomes expressible.
