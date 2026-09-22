#!/usr/bin/env bash
# Guards disaster recovery's copy of the installer's phase order.
#
# scripts/disaster-recovery.sh re-runs the installer's phases by name (each
# run_step re-sources setup-v2.sh and calls one phase), so it restates two
# facts about setup-v2.sh that nothing else ties together:
#
#   (a) every phase it passes to run_step exists: `^<name>() {` in setup-v2.sh
#       (install_service and the env/bash commands it runs are not phases);
#   (b) it runs them in the installer's order: the phases full_recovery runs
#       (its reinstall_* stages in the order it calls them, each stage's
#       run_step phases in order) are a subsequence of the setup_* phases in
#       setup-v2.sh's main() (first occurrence of each, comments ignored).
#       DR may skip phases; it may not reorder them.
#
# Both files are parsed, not sourced: no cluster, no framework, no tools
# beyond awk. Run it directly or through scripts/ci.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"

INSTALLER="$HOMELAB_DIR/setup-v2.sh"
DR="$HOMELAB_DIR/scripts/disaster-recovery.sh"

FAILURES=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

# function_body <file> <name>: the lines between `<name>() {` and its closing
# `}` at column 0, full-line comments and trailing ` # ...` comments removed,
# backslash-continued lines joined.
function_body() {
    awk -v fn="$2" '
        $0 ~ "^" fn "\\(\\) *\\{" { inside = 1; next }
        inside && /^}/ { exit }
        inside {
            line = $0
            if (line ~ /^[[:space:]]*#/) next
            sub(/[[:space:]]+#[^"'\'']*$/, "", line)
            if (held != "") { line = held " " line; held = "" }
            if (line ~ /\\$/) { sub(/\\$/, "", line); held = line; next }
            print line
        }
    ' "$1"
}

# run_step_phases <body on stdin>: the function-name argument of each run_step,
# in order; install_service, env and bash are commands, not phases.
run_step_phases() {
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*run_step[[:space:]]+\"[^\"]*\"[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; then
            case "${BASH_REMATCH[1]}" in
                install_service|env|bash) ;;
                *) echo "${BASH_REMATCH[1]}" ;;
            esac
        fi
    done
}

echo "disaster recovery phases:"

# --- (a) every run_step phase is an installer function -----------------------

dr_all_phases="$(run_step_phases < <(awk '
    /^[[:space:]]*#/ { next }
    { line = $0 }
    held != "" { line = held " " line; held = "" }
    line ~ /\\$/ { sub(/\\$/, "", line); held = line; next }
    { print line }' "$DR") | sort -u)"
if [[ -z "$dr_all_phases" ]]; then
    fail "found no run_step phase in scripts/disaster-recovery.sh (parser out of date?)"
fi
for phase in $dr_all_phases; do
    if grep -qE "^${phase}\(\) *\{" "$INSTALLER"; then
        ok "defined in setup-v2.sh: $phase"
    else
        fail "scripts/disaster-recovery.sh runs '$phase', which setup-v2.sh does not define"
    fi
done

# --- (b) full_recovery's phases are a subsequence of main()'s ---------------

mapfile -t main_phases < <(function_body "$INSTALLER" main \
    | grep -oE 'setup_[a-z_]+' | awk '!seen[$0]++')
mapfile -t stages < <(function_body "$DR" full_recovery \
    | grep -oE '^[[:space:]]*reinstall_[a-z_]+' | sed 's/^[[:space:]]*//')

if [[ ${#main_phases[@]} -eq 0 ]]; then
    fail "found no setup_* phase in setup-v2.sh main() (parser out of date?)"
fi
if [[ ${#stages[@]} -eq 0 ]]; then
    fail "found no reinstall_* stage in full_recovery (parser out of date?)"
fi

dr_sequence=()   # "<phase> <stage>"
for stage in "${stages[@]}"; do
    mapfile -t stage_phases < <(function_body "$DR" "$stage" | run_step_phases)
    [[ ${#stage_phases[@]} -gt 0 ]] || fail "stage $stage runs no installer phase (parser out of date?)"
    for phase in "${stage_phases[@]}"; do
        dr_sequence+=("$phase $stage")
    done
done

# index_of <phase> [from]: first index >= from of <phase> in main_phases, or -1.
index_of() {
    local i
    for ((i = ${2:-0}; i < ${#main_phases[@]}; i++)); do
        [[ "${main_phases[$i]}" == "$1" ]] && { echo "$i"; return; }
    done
    echo -1
}

pos=0 prev="" order_ok=true
for entry in "${dr_sequence[@]}"; do
    phase="${entry% *}" stage="${entry#* }"
    at="$(index_of "$phase" "$pos")"
    if [[ "$at" -ge 0 ]]; then
        pos=$((at + 1)) prev="$phase"
        continue
    fi
    order_ok=false
    if [[ -n "$prev" && "$(index_of "$phase")" -ge 0 ]]; then
        fail "order: disaster recovery runs $phase ($stage) after $prev, but setup-v2.sh main() runs $phase before $prev"
    else
        fail "order: disaster recovery runs $phase ($stage), which setup-v2.sh main() never runs"
    fi
    break
done
if [[ "$order_ok" == "true" ]]; then
    ok "full_recovery's ${#dr_sequence[@]} phases run in main()'s order"
else
    echo "        main():        ${main_phases[*]}"
    echo "        full_recovery: $(for e in "${dr_sequence[@]}"; do printf '%s ' "${e% *}"; done)"
fi

if [[ $FAILURES -ne 0 ]]; then
    echo "disaster recovery phases: $FAILURES assertion(s) failed"
    exit 1
fi
echo "disaster recovery phases: all assertions passed"
