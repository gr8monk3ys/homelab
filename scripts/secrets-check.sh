#!/bin/bash
# Static drift check between the secret producer and its consumers.
#
# The secret table (`secrets_catalogue` in scripts/lib/secrets.sh, printed by
# `scripts/generate-secrets.sh --list`) is the one producer of generated
# secrets; ExternalSecrets (remoteRef.key), scripts and docs read them back by
# name. Nothing ties the two sides together except the string, so this script
# derives both sets from the tree and fails CI when they disagree:
#
#   MISSING  consumed, but neither in the table nor listed in USER_SUPPLIED
#   ORPHAN   in the table, but consumed nowhere
#   SOPS     the committed kubernetes/secrets/sops/secrets/*.sops.yaml files
#            (what sops-bootstrap.sh last wrote from the same table) do not
#            match the table one-to-one
#
# Usage: scripts/secrets-check.sh [--list]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

GENERATOR="$HOMELAB_DIR/scripts/generate-secrets.sh"
SOPS_DIR="$HOMELAB_DIR/kubernetes/secrets/sops/secrets"
MANIFEST_DIRS=("$HOMELAB_DIR/kubernetes" "$HOMELAB_DIR/helm")
# Places that read a secret by name: `kubectl get secret[ -n secrets] <name>`
# or the shorthand `secrets/<name>`.
SCRIPT_DOC_PATHS=("$HOMELAB_DIR/scripts" "$HOMELAB_DIR/docs" "$HOMELAB_DIR/test"
                  "$HOMELAB_DIR/setup-v2.sh" "$HOMELAB_DIR/README.md")

# Secrets the operator creates by hand in the `secrets` namespace. Each one
# must be documented in docs/credentials.md under "User-supplied".
USER_SUPPLIED=(
    alertmanager-webhook     # docs/runbooks/alerting.md
    cloudflare-api-token     # docs/runbooks/external-dns.md
    cloudflare-tunnel-token  # docs/credentials.md (cloudflared)
    renovate-token           # docs/credentials.md (renovate)
    tailscale-oauth          # docs/credentials.md (Tailscale operator)
)

NAME='[A-Za-z0-9._-]+'

generated_secrets() {
    "$GENERATOR" --list | awk '{print $1}' | sort -u
}

# Names the committed SOPS/age files carry (one file per table entry).
sops_file_secrets() {
    local f
    for f in "$SOPS_DIR"/*.sops.yaml; do
        [[ -f "$f" ]] || continue
        basename "$f" .sops.yaml
    done | sort -u
}

# remoteRef.key of every ExternalSecret data/dataFrom entry, block or inline form.
remote_keys() {
    find "${MANIFEST_DIRS[@]}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.tpl' \) \
        -not -path '*/charts/*' -print0 \
    | xargs -0 awk '
        /remoteRef:[[:space:]]*\{/ { if (match($0, /key:[[:space:]]*"?[A-Za-z0-9._-]+/)) print substr($0, RSTART, RLENGTH); next }
        /remoteRef:/ { pending = 1; next }
        pending && /^[[:space:]]*key:/ { print; pending = 0 }
        pending && !/^[[:space:]]*(property|version|key):/ { pending = 0 }
    ' | sed -E 's/.*key:[[:space:]]*"?([A-Za-z0-9._-]+).*/\1/' | sort -u
}

# Names scripts/docs read back: `kubectl get secret -n secrets <name>`,
# `kubectl get secret <name> -n secrets`, or `secrets/<name>`.
script_doc_refs() {
    {
        grep -rhoE "get secret -n secrets ${NAME}" "${SCRIPT_DOC_PATHS[@]}" \
            | sed -E 's/.* //'
        grep -rhoE "get secret ${NAME} -n secrets" "${SCRIPT_DOC_PATHS[@]}" \
            | awk '{print $3}'
        grep -rhoE "(^|[^./A-Za-z0-9_-])secrets/${NAME}" "${SCRIPT_DOC_PATHS[@]}" \
            | sed -E 's#.*secrets/##'
    } 2>/dev/null | sort -u
}

print_set() { # <label> <newline-separated names>
    echo "== $1"
    [[ -n "$2" ]] && sed 's/^/  /' <<<"$2"
}

main() {
    local generated remote scriptdoc user consumed missing orphan overlap sops_files sops_drift
    generated="$(generated_secrets)"
    sops_files="$(sops_file_secrets)"
    remote="$(remote_keys)"
    scriptdoc="$(script_doc_refs)"
    user="$(printf '%s\n' "${USER_SUPPLIED[@]}" | sort -u)"
    consumed="$(sort -u <<<"$remote"$'\n'"$scriptdoc" | sed '/^$/d')"

    if [[ "${1:-}" == "--list" ]]; then
        print_set "generated ($(wc -l <<<"$generated" | tr -d ' '))" "$generated"
        print_set "consumed by ExternalSecret remoteRef.key ($(wc -l <<<"$remote" | tr -d ' '))" "$remote"
        print_set "consumed by scripts/docs ($(wc -l <<<"$scriptdoc" | tr -d ' '))" "$scriptdoc"
        print_set "user-supplied (${#USER_SUPPLIED[@]})" "$user"
        print_set "kubernetes/secrets/sops/secrets/*.sops.yaml ($(wc -l <<<"$sops_files" | tr -d ' '))" "$sops_files"
        return 0
    fi

    # consumed − generated − user-supplied
    missing="$(comm -23 <(echo "$consumed") <(sort -u <<<"$generated"$'\n'"$user"))"
    # generated − consumed
    orphan="$(comm -23 <(echo "$generated") <(echo "$consumed"))"
    # user-supplied ∩ generated: the list and the generator disagree
    overlap="$(comm -12 <(echo "$user") <(echo "$generated"))"

    local rc=0
    if [[ -n "$missing" ]]; then
        rc=1
        echo "MISSING: consumed but not in the secret table (add a \`secret\` line to scripts/lib/secrets.sh, or list it in USER_SUPPLIED and docs/credentials.md):"
        sed 's/^/  /' <<<"$missing"
    fi
    if [[ -n "$orphan" ]]; then
        rc=1
        echo "ORPHAN: in the secret table but no ExternalSecret, script or doc reads it (wire a consumer or drop the \`secret\` line and its docs/credentials.md entry):"
        sed 's/^/  /' <<<"$orphan"
    fi
    if [[ -n "$overlap" ]]; then
        rc=1
        echo "CONFLICT: listed in USER_SUPPLIED but also generated:"
        sed 's/^/  /' <<<"$overlap"
    fi
    sops_drift="$(comm -3 <(echo "$generated") <(echo "$sops_files") | tr -d '\t' | sort -u)"
    if [[ -n "$sops_drift" ]]; then
        rc=1
        echo "SOPS: the secret table and kubernetes/secrets/sops/secrets/*.sops.yaml do not match (present on one side only; re-run ROTATE_SOPS_SECRETS=true ./scripts/sops-bootstrap.sh):"
        sed 's/^/  /' <<<"$sops_drift"
    fi
    if [[ $rc -eq 0 ]]; then
        echo "OK: $(wc -l <<<"$generated" | tr -d ' ') generated secrets, $(wc -l <<<"$consumed" | tr -d ' ') consumed names, ${#USER_SUPPLIED[@]} user-supplied; no drift."
    fi
    return $rc
}

main "$@"
