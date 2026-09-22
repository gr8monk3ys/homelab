#!/bin/bash
# shellcheck shell=bash
#
# Manifest credential scan: the CI gate for CLAUDE.md rule one ("Never commit
# a credential, not even as an example"). Cluster-free; two callers:
# scripts/secrets-check.sh (CI) fails on a finding, scripts/validate-setup.sh
# reports it as a critical operator-facing check. test/credentials.sh proves
# the coverage with fixtures it generates at runtime.
#
# Requires scripts/lib/common.sh to be sourced first, and yq on PATH.
#
#   credential_findings [dir...]
#       One line per inline credential, "<file>: document <n>: <yaml path>";
#       never the value. Default dirs: kubernetes/ and helm/. rc 0 always;
#       an empty output is a clean tree.
#   inline_secret_data_files [dir...]
#       One filename per line: `kind: Secret` manifests with a data: block
#       that do not defer to an external store. A warning, not a failure: a
#       Secret with inline data is not necessarily a committed credential.
#
# What counts as a credential (judged per YAML document, structurally, with
# yq; no file is skipped because some other part of it is clean):
#   the PASSWORD FAMILY: a key containing "password"/"passwd" anywhere, or
#   "pass" as a whole key component (DB_PASS, pass, dbPass), any case, in
#     (a) a mapping key with a non-empty string or number value, or
#     (b) an env-style item {name: <family>, value: <non-empty literal>}.
#   Not a credential:
#     keys shaped like a reference: ending in Key, Name, File, Ref, Secret or
#       Path, any case (passwordKey, existingSecret, DB_PASSWORD_FILE, ...);
#     values that are paths (start with /) or templated (${...}, {{ ... }});
#     empty, null and boolean values.
# Scanned: *.yaml/*.yml, except the SOPS-encrypted store (*/secrets/sops/*)
# and vendored CRDs (crd.yaml, crds.yaml). A Helm template that is not YAML
# until rendered is scanned with its {{ }} actions neutralised; a file that
# still does not parse is itself a finding ("unparseable"), never skipped.

if [[ -n "${HOMELAB_CREDENTIALS_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_CREDENTIALS_SOURCED=1

if [[ -z "${HOMELAB_COMMON_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/common.sh before scripts/lib/credentials.sh" >&2
    exit 1
fi

# The password family, and the reference shape that exempts a key (RE2, as yq
# evaluates them).
_CRED_FAMILY_RE='(?i:passw(or)?d)|(?i:(^|[^a-z])pass([^a-z]|$))|[a-z0-9]Pass([^a-z]|$)|^pass[A-Z]'
_CRED_REFERENCE_RE='(?i)(key|name|file|ref|secret|path)$'

# The yq program, evaluated on every document: prints
# "<document index> <yaml path>" per finding (credential_findings prefixes
# the filename when it scans a batch).
_cred_yq_program() {
    cat <<EOF
.. | select(tag == "!!str" or tag == "!!int" or tag == "!!float")
   | select((tostring) != "" and ((tostring) | test("^/|\\\$\\{|\\{\\{") | not))
   | select(
       ((path | .[-1] | tag) == "!!str"
          and ((path | .[-1]) | test("$_CRED_FAMILY_RE"))
          and ((path | .[-1]) | test("$_CRED_REFERENCE_RE") | not))
       or
       ((path | .[-1]) == "value"
          and (parent | .name | tag) == "!!str"
          and ((parent | .name) | test("$_CRED_FAMILY_RE"))
          and ((parent | .name) | test("$_CRED_REFERENCE_RE") | not))
     )
   | (document_index | tostring) + " " + (path | map(tostring) | join("."))
EOF
}

# _cred_label <file>: repo-relative when inside the repo.
_cred_label() {
    case "$1" in
        "$HOMELAB_DIR"/*) echo "${1#"$HOMELAB_DIR"/}" ;;
        *) echo "$1" ;;
    esac
}

# _cred_scan_files [dir...]: NUL-separated files the scan covers.
_cred_scan_files() {
    local dirs=("$@")
    [[ ${#dirs[@]} -gt 0 ]] || dirs=("$HOMELAB_DIR/kubernetes" "$HOMELAB_DIR/helm")
    find "${dirs[@]}" -type f \( -name '*.yaml' -o -name '*.yml' \) \
        -not -path '*/secrets/sops/*' -not -name 'crd.yaml' -not -name 'crds.yaml' \
        -print0 2>/dev/null
}

credential_findings() {
    require_cmd yq "the credential scan reads manifests structurally"
    local program f out
    local plain=() templated=()
    program="$(_cred_yq_program)"
    while IFS= read -r -d '' f; do
        if grep -q '{{' "$f"; then templated+=("$f"); else plain+=("$f"); fi
    done < <(_cred_scan_files "$@")

    # Plain YAML in one yq run (every document of every file); if any file in
    # the batch does not parse, fall back to one run per file so that file is
    # named instead of hiding the rest.
    if [[ ${#plain[@]} -gt 0 ]]; then
        if out="$(yq -r "filename + \" \" + ($program)" "${plain[@]}" 2>/dev/null)"; then
            while read -r f rest; do
                [[ -n "$f" && "$f" != "---" ]] || continue
                _cred_report "$f" "$rest"
            done <<<"$out"
        else
            templated+=("${plain[@]}")
        fi
    fi

    for f in "${templated[@]}"; do
        if ! out="$(yq -r "$program" "$f" 2>/dev/null)"; then
            # A Helm template: drop lines that are only a {{ }} action, and turn
            # inline actions into a plain scalar that still reads as templated.
            if ! out="$(sed -E '/^[[:space:]]*\{\{.*\}\}[[:space:]]*$/d; s/\{\{[^}]*\}\}/x{{tpl}}/g' "$f" \
                        | yq -r "$program" 2>/dev/null)"; then
                echo "$(_cred_label "$f"): unparseable (not scanned; fix the YAML)"
                continue
            fi
        fi
        while IFS= read -r rest; do
            [[ -n "$rest" && "$rest" != "---" ]] || continue
            _cred_report "$f" "$rest"
        done <<<"$out"
    done
}

# _cred_report <file> "<document index> <yaml path>"
_cred_report() {
    local doc="${2%% *}" path="${2#* }"
    echo "$(_cred_label "$1"): document $doc: $path"
}

inline_secret_data_files() {
    local f dirs=("$@")
    [[ ${#dirs[@]} -gt 0 ]] || dirs=("$HOMELAB_DIR/kubernetes")
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
    done < <(find "${dirs[@]}" -type f \( -name "*.yaml" -o -name "*.yml" \) -print0 2>/dev/null)
}
