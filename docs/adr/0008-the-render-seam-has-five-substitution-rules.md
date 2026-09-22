---
status: rejected
date: 2026-09-22
---

# The render seam has five substitution rules, and no per-service values

A review pass proposed extending `scripts/lib/render.sh` with per-service
values or overrides — a descriptor key that could declare its own
substitutions, so a service could parameterise something the five rules do
not reach. We rejected it.

Two separate review passes went looking for the motivating case: a descriptor
somewhere in the catalogue forced to hardcode a value the seam could not
express. Neither found one. The five rules cover every placeholder
`CONTEXT.md` names — the domain, the admin email, the timezone, the
cert-manager ClusterIssuer, the GitOps repo URL — and those are the only
things that vary between one homelab and another (ADR-0003: variation is
placeholders and toggles, not overlays). The one place a descriptor does
reach past the rules is `values:` on the six `kind: helm` services, and that
file is itself rendered as a manifest before Helm sees it, so it inherits the
same five rules rather than escaping them.

The rules are under pressure from zero users, not from 64 services. Adding an
override key now would add a second way to express variation, with no case to
justify it and every descriptor free to diverge.

## Consequences

- `scripts/lib/render.sh` stays the one seam, with one substitution table
  that every applier shares; a descriptor cannot introduce a private
  placeholder.
- A new cluster-wide variable is a sixth rule in the seam plus a key in
  `config/homelab.yaml` (which `homelab_load_config` reads), not a
  per-service escape.
- Revisit when a real descriptor needs a value the seam cannot express and
  the alternative is hardcoding it. Point at that descriptor in the revision.
