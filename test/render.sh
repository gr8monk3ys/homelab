#!/usr/bin/env bash
# Assertions on the rendering seam's substitution rules: render_stream in
# scripts/lib/render.sh, which every applier (installer, disaster recovery,
# KinD harness, CI render) pushes repo manifests through.
#
# Drives the interface only: set DOMAIN / ADMIN_EMAIL / TIMEZONE /
# CERT_MANAGER_CLUSTER_ISSUER / GITOPS_REPO_URL, feed render_stream a line,
# compare. Covers the five placeholder rules, replacement values carrying sed
# metacharacters (& and /), and the rule order (the email placeholder
# contains the domain placeholder, so the email rule must run first; the repo
# URL placeholder does not, so its place in the order is not observable).
#
# In-process: no cluster, no framework, no tools beyond sed. Run it directly
# or through scripts/ci.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# render.sh captures these as env overrides when sourced; none may leak in.
unset DOMAIN ADMIN_EMAIL TIMEZONE CERT_MANAGER_CLUSTER_ISSUER GITOPS_REPO_URL ENVIRONMENT
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/render.sh
source "$TEST_DIR/../scripts/lib/render.sh"

FAILURES=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

# expect_render <input> <expected output> <what>
expect_render() {
    local got
    got="$(render_stream <<<"$1")"
    if [[ "$got" == "$2" ]]; then
        ok "$3: '$1' -> '$got'"
    else
        fail "$3: '$1' rendered to '$got', expected '$2'"
    fi
}

# The effective values render_stream reads (what homelab_load_config exports).
set_config() { # <domain> <email> <timezone> <issuer> <repo url>
    DOMAIN="$1" ADMIN_EMAIL="$2" TIMEZONE="$3" CERT_MANAGER_CLUSTER_ISSUER="$4" GITOPS_REPO_URL="$5"
}

echo "render rules:"

set_config "lab.example.test" "ops@mail.example.test" "Europe/Amsterdam" \
    "letsencrypt-prod" "https://git.example.test/me/infra.git"

# 1. the domain, wherever it appears
expect_render "  host: jellyfin.homelab.local" "  host: jellyfin.lab.example.test" "domain"
expect_render "- homelab.local, *.homelab.local" "- lab.example.test, *.lab.example.test" "domain (every occurrence)"
# 2. the admin email
expect_render "  email: admin@homelab.local" "  email: ops@mail.example.test" "admin email"
# 3. the timezone, only in its value: "UTC" form
expect_render '  value: "UTC"' '  value: "Europe/Amsterdam"' "timezone"
expect_render '  TZ: UTC' '  TZ: UTC' "timezone (only the quoted value: form)"
# 4. the cluster issuer, only on the cert-manager annotation
expect_render '    cert-manager.io/cluster-issuer: "homelab-ca"' \
              '    cert-manager.io/cluster-issuer: "letsencrypt-prod"' "cluster issuer"
expect_render '  issuerRef: {name: homelab-ca}' '  issuerRef: {name: homelab-ca}' "cluster issuer (only the annotation)"
# 5. the GitOps repository URL
expect_render "  repoURL: https://github.com/your-username/homelab.git" \
              "  repoURL: https://git.example.test/me/infra.git" "GitOps repo URL"

# Nothing else changes.
expect_render "  image: nginx:1.27" "  image: nginx:1.27" "untouched line"

echo "sed metacharacters in values:"

set_config "a&b/c.example.test" "x&y/z@example.test" "America/Argentina/Buenos_Aires" \
    "issuer&/one" "https://git.example.test/a&b/c.git"
expect_render "host: app.homelab.local" "host: app.a&b/c.example.test" "DOMAIN with & and /"
expect_render "email: admin@homelab.local" "email: x&y/z@example.test" "ADMIN_EMAIL with & and /"
expect_render 'value: "UTC"' 'value: "America/Argentina/Buenos_Aires"' "TIMEZONE with /"
expect_render 'cert-manager.io/cluster-issuer: "homelab-ca"' \
              'cert-manager.io/cluster-issuer: "issuer&/one"' "issuer with & and /"
expect_render "repoURL: https://github.com/your-username/homelab.git" \
              "repoURL: https://git.example.test/a&b/c.git" "repo URL with & and /"
set_config 'back\slash.example.test' "ops@example.test" "UTC" "homelab-ca" \
    "https://github.com/your-username/homelab.git"
expect_render "host: homelab.local" 'host: back\slash.example.test' "DOMAIN with a backslash"

echo "rule order:"

# The email placeholder contains the domain placeholder: were the domain rule
# first, admin@homelab.local would become admin@<DOMAIN> and ADMIN_EMAIL
# would never apply.
set_config "lab.example.test" "ops@mail.example.test" "UTC" "homelab-ca" \
    "https://git.example.test/me/infra.git"
expect_render "admin@homelab.local, https://homelab.local" \
              "ops@mail.example.test, https://lab.example.test" "email before domain, on one line"

# Defaults render to themselves.
set_config "homelab.local" "admin@homelab.local" "UTC" "homelab-ca" \
    "https://github.com/your-username/homelab.git"
expect_render 'host: homelab.local; value: "UTC"' 'host: homelab.local; value: "UTC"' "defaults are a no-op"

if [[ $FAILURES -ne 0 ]]; then
    echo "render rules: $FAILURES assertion(s) failed"
    exit 1
fi
echo "render rules: all assertions passed"
