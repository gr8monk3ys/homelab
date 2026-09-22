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
#   HARDCODED  a manifest carries a credential inline (CLAUDE.md rule one)
#
# It is also the one manifest credential scanner. That scan needs no cluster,
# so it lives here (CI runs this script) and scripts/validate-setup.sh sources
# this file to reuse the same two functions for its operator-facing report.
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

# --- manifest credential scan (cluster-free; two callers) -------------------
#
# CLAUDE.md rule one: "Never commit a credential, not even as an example."
# Both functions print one filename per line (never file content) and are the
# only copy of this scan; scripts/validate-setup.sh sources this file and
# reports them as an operator-facing check.

# hardcoded_password_files: password-like keys that carry a non-empty inline
# value. Skips SOPS-encrypted secrets and files that reference a secret
# indirectly (secretKeyRef/remoteRef/existingSecret).
hardcoded_password_files() {
    local f
    while IFS= read -r -d '' f; do
        if grep -qE "secretKeyRef|remoteRef|existingSecret" "$f" 2>/dev/null; then
            continue
        fi
        if grep -E "^[[:space:]-]*[\"']?[A-Za-z0-9_.-]*[Pp]assword[\"']?:" "$f" 2>/dev/null | \
            grep -vE ":[[:space:]]*(\"\"|'')?[[:space:]]*(#.*)?$" | grep -q .; then
            echo "$f"
        fi
    done < <(find "$HOMELAB_DIR/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) -not -path "*/secrets/sops/*" -print0 2>/dev/null)
}

# inline_secret_data_files: `kind: Secret` manifests with a `data:` block that
# do not defer to an external store. A warning, not a failure: a Secret with
# inline data is not necessarily a committed credential.
inline_secret_data_files() {
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *external-secret*) continue ;;
            */secrets/sops/*) continue ;;
        esac
        if grep -qE "secretKeyRef|remoteRef|existingSecret" "$f" 2>/dev/null; then
            continue
        fi
        if grep -qE "^kind:[[:space:]]*Secret[[:space:]]*$" "$f" 2>/dev/null && grep -qE "^[[:space:]]*data:" "$f" 2>/dev/null; then
            echo "$f"
        fi
    done < <(find "$HOMELAB_DIR/kubernetes" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
}

print_set() { # <label> <newline-separated names>
    echo "== $1"
    [[ -n "$2" ]] && sed 's/^/  /' <<<"$2"
}

secrets_check_main() {
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

    local pw_files inline_files
    pw_files="$(hardcoded_password_files)"
    if [[ -n "$pw_files" ]]; then
        rc=1
        echo "HARDCODED: a password-like key carries an inline value in these manifests (CLAUDE.md: never commit a credential; use an ExternalSecret):"
        sed 's/^/  /' <<<"$pw_files"
    fi
    inline_files="$(inline_secret_data_files)"
    if [[ -n "$inline_files" ]]; then
        echo "WARNING: these manifests declare a Secret with an inline data: block; check that none of it is a credential:"
        sed 's/^/  /' <<<"$inline_files"
    fi

    if [[ $rc -eq 0 ]]; then
        echo "OK: $(wc -l <<<"$generated" | tr -d ' ') generated secrets, $(wc -l <<<"$consumed" | tr -d ' ') consumed names, ${#USER_SUPPLIED[@]} user-supplied; no drift, no credential in a manifest."
    fi
    return $rc
}

# Sourced (scripts/validate-setup.sh) this file is just the two scanners.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    secrets_check_main "$@"
fi
