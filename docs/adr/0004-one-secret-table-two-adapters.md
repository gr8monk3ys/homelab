---
status: accepted
date: 2026-09-21
---

# One secret table, two adapters

Every generated secret is one line of `secrets_catalogue` in
`scripts/lib/secrets.sh`: `secret <name> <key>=<policy> ...`, where the
policy (`password`, `hex:<n>`, `literal:<v>`, `empty`, `email`,
`template:<text>`, `argon2:<name>/<key>`, `users-db:...`) says how a value
is made. `secret` dispatches on `SECRETS_ADAPTER`: `kubectl` upserts into
the `secrets` namespace (`scripts/generate-secrets.sh`), `sops` writes an
encrypted manifest per secret (`scripts/sops-bootstrap.sh`), `list` prints
the table (`generate-secrets.sh --list`, what `secrets-check.sh` reads).
We chose this over the previous shape, two scripts each carrying 51
near-identical blocks that only a grep-based drift check kept in step, and
over a YAML data file (a bash function needs no parser and lets a policy
call another, as `users-db` calls `argon2`).

## Consequences

- Adding a secret is one table line plus its ExternalSecret; the sops path
  and `--list` follow for free. `secrets-check.sh` no longer diffs the two
  scripts; it still diffs the table against the committed
  `kubernetes/secrets/sops/secrets/*.sops.yaml`, which are artefacts.
- A value that depends on another (Drone's `database-url`, Yarr's
  `auth-credentials`, the Authelia users DB) is a policy, not inline code;
  a new special case must become a named policy or it cannot be tabulated.
- A skipped (existing) secret in `kubectl` mode has its values read back,
  so `authelia-users` hashes the stored admin password rather than a fresh
  one, which the old script got wrong when only the users DB was missing.
- The Argon2 hash is produced in-cluster or by `docker`. In `kubectl` mode
  a failure still falls back to the placeholder hash with a warning; in
  `sops` mode it is an error, because the placeholder would be committed.
