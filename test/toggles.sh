#!/usr/bin/env bash
# Assertions on the toggle algebra: which services install under which
# ENABLE_*/INSTALL_*/OPTIN_SERVICES settings, and which infrastructure pieces
# the INSTALL_*/ENABLE_GITOPS toggles switch on.
#
# CI's render step calls `services.sh render` with no names, and that branch
# renders every descriptor regardless of toggle, so it proves nothing about
# what would actually install. This file is the gate for that: it drives the
# public interface of scripts/lib/services.sh (services_all, service_field,
# service_enabled, services_in_group, service_group_names,
# service_group_field, service_group_toggle) and of scripts/lib/health.sh
# (infra_enabled), and pins the numbers CLAUDE.md and the README state.
#
# No cluster, no framework, no tools beyond yq (which reads the descriptors).
# Run it directly or through scripts/ci.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/render.sh
source "$TEST_DIR/../scripts/lib/render.sh"
# shellcheck source=scripts/lib/services.sh
source "$TEST_DIR/../scripts/lib/services.sh"
# shellcheck source=scripts/lib/health.sh
source "$TEST_DIR/../scripts/lib/health.sh"

# The toggles are read from the environment at call time, so none may leak in:
# every group toggle SERVICE_GROUPS names, the infrastructure toggles asserted
# below, and the opt-in list (services.sh already copied it when sourced).
for _grp in $(service_group_names); do
    _var="$(service_group_field "$_grp" toggle)"
    [[ "$_var" == "-" ]] || unset "$_var"
done
unset INSTALL_KYVERNO ENABLE_GITOPS _grp _var
OPTIN_SERVICES=""

FAILURES=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

assert_eq() { # <expected> <actual> <what>
    if [[ "$1" == "$2" ]]; then ok "$3 = $1"; else fail "$3: expected '$1', got '$2'"; fi
}

# enabled_count [VAR=VALUE ...]: how many services install under those toggles.
enabled_count() {
    local n=0 name
    for name in $(services_all); do
        service_enabled "$name" && n=$((n + 1))
    done
    echo "$n"
}

echo "toggle algebra:"

catalogue=$(services_all | wc -l | tr -d ' ')
assert_eq 64 "$catalogue" "descriptors in the catalogue"

# The three numbers CLAUDE.md and the README state, derived here from the
# descriptors and SERVICE_GROUPS rather than restated.
default_enabled=$(enabled_count)
optin_total=0
group_gated=0
for svc in $(services_all); do
    svc_group="$(service_field "$svc" '.group')"
    if [[ "$(service_field "$svc" '.optin' false)" == "true" ]]; then
        optin_total=$((optin_total + 1))
    elif [[ "$(service_group_toggle "$svc_group")" != "true" ]]; then
        group_gated=$((group_gated + 1))
    fi
done
assert_eq 18 "$default_enabled" "enabled under the default toggles"
assert_eq 37 "$optin_total"     "opt-in services (need naming in OPTIN_SERVICES)"
assert_eq 9  "$group_gated"     "non-opt-in services waiting on a group toggle"
assert_eq 64 "$((default_enabled + optin_total + group_gated))" "18 + 37 + 9"

# The "-" sentinel: core has no toggle variable and is always on.
assert_eq "-"    "$(service_group_field core toggle)" "core's toggle column"
assert_eq "true" "$(service_group_toggle core)"       "core's effective toggle"

# ${!var:-$default}: the environment overrides the table's default, both ways.
assert_eq "true"  "$(ENABLE_DEV_SERVICES=true service_group_toggle dev)"   "dev with ENABLE_DEV_SERVICES=true"
assert_eq "false" "$(service_group_toggle dev)"                            "dev by default"
assert_eq "false" "$(ENABLE_MEDIA_SERVICES=false service_group_toggle media)" "media with ENABLE_MEDIA_SERVICES=false"
assert_eq "true"  "$(service_group_toggle media)"                          "media by default"

# A group with no row in SERVICE_GROUPS is not a group: nothing installs.
assert_eq "unknown" "$(service_group_toggle nosuchgroup)" "an unknown group's toggle"
assert_eq ""        "$(service_group_field nosuchgroup toggle)" "an unknown group's toggle column"
assert_eq ""        "$(services_in_group nosuchgroup)" "services in an unknown group"

# Every group in the table has at least one service, and every service's group
# is in the table.
for grp in $(service_group_names); do
    [[ -n "$(services_in_group "$grp")" ]] || fail "group '$grp' has no services"
done
for svc in $(services_all); do
    svc_group="$(service_field "$svc" '.group')"
    [[ "$(service_group_toggle "$svc_group")" != "unknown" ]] \
        || fail "service '$svc' names group '$svc_group', which has no SERVICE_GROUPS row"
done
ok "every group has services and every service has a group"

# OPTIN_SERVICES: naming one opt-in service adds exactly that one.
assert_eq 19 "$(OPTIN_SERVICES=heimdall enabled_count)" "default + OPTIN_SERVICES=heimdall"
# ... and the comma-separated form adds exactly two.
assert_eq 20 "$(OPTIN_SERVICES=heimdall,kured enabled_count)" "default + OPTIN_SERVICES=heimdall,kured"
assert_eq 20 "$(OPTIN_SERVICES='heimdall kured' enabled_count)" "default + OPTIN_SERVICES='heimdall kured'"
# Naming an opt-in service whose group is off changes nothing: the group gate
# comes first. code-server is in the (default-off) dev group.
assert_eq 18 "$(OPTIN_SERVICES=code-server enabled_count)" "default + OPTIN_SERVICES=code-server (dev is off)"
# An unknown name is simply not selected.
assert_eq 18 "$(OPTIN_SERVICES=not-a-service enabled_count)" "default + OPTIN_SERVICES=not-a-service"

# OPTIN_SERVICES=all: every opt-in service in an enabled group, and with every
# group toggle on, the whole catalogue.
assert_eq 49 "$(OPTIN_SERVICES=all enabled_count)" "OPTIN_SERVICES=all under the default groups"
assert_eq 64 "$(OPTIN_SERVICES=all ENABLE_DEV_SERVICES=true ENABLE_AI_SERVICES=true \
                ENABLE_HOME_SERVICES=true ENABLE_COMMUNICATION_SERVICES=true \
                INSTALL_LOGGING=true enabled_count)" "OPTIN_SERVICES=all with every group on"

# Turning a group off removes exactly that group's enabled services.
media_enabled=0
for svc in $(services_in_group media); do
    service_enabled "$svc" && media_enabled=$((media_enabled + 1))
done
assert_eq "$((default_enabled - media_enabled))" \
    "$(ENABLE_MEDIA_SERVICES=false enabled_count)" "default with the media group off"

echo "infrastructure toggles:"

# infra_enabled <piece> as a word, for assert_eq.
infra_state() { if infra_enabled "$1"; then echo true; else echo false; fi; }

# Toggles with a default of false in their table row.
assert_eq "false" "$(infra_state kyverno)"                          "kyverno by default"
assert_eq "true"  "$(INSTALL_KYVERNO=true infra_state kyverno)"     "kyverno with INSTALL_KYVERNO=true"
assert_eq "false" "$(infra_state argocd)"                           "argocd by default"
assert_eq "true"  "$(ENABLE_GITOPS=true infra_state argocd)"        "argocd with ENABLE_GITOPS=true"
# No toggle column: the installer always brings these up.
for piece in local-path minio crowdsec; do
    assert_eq "true" "$(infra_state "$piece")"                      "$piece (no toggle)"
    assert_eq "true" "$(INSTALL_KYVERNO=false ENABLE_GITOPS=false infra_state "$piece")" \
        "$piece with unrelated toggles off"
done
# A piece that is not in the table is not infrastructure.
assert_eq "false" "$(infra_state nosuchpiece)"                      "an unknown piece"

if [[ $FAILURES -ne 0 ]]; then
    echo "toggle algebra: $FAILURES assertion(s) failed"
    exit 1
fi
echo "toggle algebra: all assertions passed"
