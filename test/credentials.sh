#!/usr/bin/env bash
# Coverage of the manifest credential scan (scripts/lib/credentials.sh), the
# CI gate for CLAUDE.md rule one: each shape of committed password it must
# catch, and each reference shape it must let through.
#
# CLAUDE.md forbids committing a credential "not even as an example", so this
# file holds no credential-shaped literal: every fixture is written at run
# time into a mktemp directory, with a random value, and removed on exit.
#
# Drives the library's interface only: credential_findings <dir>. No cluster,
# no framework, no tools beyond yq. Run it directly or through scripts/ci.sh.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/credentials.sh
source "$TEST_DIR/../scripts/lib/credentials.sh"

FAILURES=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; FAILURES=$((FAILURES + 1)); }

FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/homelab-credentials.XXXXXX")"
trap 'rm -rf "$FIXTURES"' EXIT

# A fresh random value per fixture: nothing here is a real or reusable secret.
v() { echo "fixture-$RANDOM$RANDOM"; }

# fixture <name> : stdin -> $FIXTURES/<name>
fixture() {
    mkdir -p "$(dirname "$FIXTURES/$1")"
    cat > "$FIXTURES/$1"
}

# --- must be caught ----------------------------------------------------------

fixture bad/lowercase-key.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: app-config}
data:
  password: $(v)
EOF

fixture bad/uppercase-key.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: app-env}
data:
  DB_PASSWORD: $(v)
EOF

fixture bad/short-pass-key.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: app-env}
data:
  DB_PASS: "$(v)"
  smtpPasswd: $(v)
EOF

fixture bad/env-item.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: db}
spec:
  template:
    spec:
      containers:
        - name: db
          env:
            - name: POSTGRES_PASSWORD
              value: "$(v)"
EOF

# The old file-level scan skipped any file mentioning secretKeyRef.
fixture bad/same-document-as-secretkeyref.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: app}
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: {name: app-admin, key: password}
            - name: SMTP_PASSWORD
              value: $(v)
EOF

fixture bad/next-document-to-secretkeyref.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: app}
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: ADMIN_PASSWORD
              valueFrom:
                secretKeyRef: {name: app-admin, key: password}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: app-settings}
data:
  adminPassword: $(v)
EOF

fixture bad/configmap-camelcase.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: redis}
data:
  redisPassword: $(v)
EOF

fixture bad/values.yaml <<EOF
mysql:
  auth:
    database: nextcloud
    rootPassword: $(v)
EOF

fixture bad/numeric-value.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: pin}
data:
  password: $RANDOM$RANDOM
EOF

fixture bad/secret-stringdata.yaml <<EOF
apiVersion: v1
kind: Secret
metadata: {name: app}
stringData:
  password: $(v)
EOF

# --- must pass ---------------------------------------------------------------

fixture good/secretkeyref.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: db}
spec:
  template:
    spec:
      containers:
        - name: db
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: {name: db-credentials, key: password}
EOF

fixture good/reference-keys.yaml <<EOF
auth:
  existingSecret: app-credentials
  passwordKey: password
  secretPasswordName: app-credentials
  passwordSecretRef: {name: app-credentials, key: password}
EOF

fixture good/password-file.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: db}
spec:
  template:
    spec:
      containers:
        - name: db
          env:
            - name: POSTGRES_PASSWORD_FILE
              value: /run/secrets/postgres-password
            - name: DB_PASSWORD
              value: /var/run/secrets/db/password
---
apiVersion: v1
kind: ConfigMap
metadata: {name: settings}
data:
  MYSQL_PASSWORD_FILE: /run/secrets/mysql
EOF

fixture good/templated.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: settings}
data:
  DB_PASSWORD: "\${DB_PASSWORD}"
  REDIS_PASSWORD: "{{ .Values.redis.password }}"
EOF

fixture good/empty-values.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: settings}
data:
  password: ""
  passwd:
  DB_PASSWORD: ''
spec:
  env:
    - name: SMTP_PASSWORD
      value: ""
EOF

fixture good/not-the-family.yaml <<EOF
traefik:
  passHostHeader: true
  tls:
    passthrough: "yes"
  bypass: "on"
  compass: north
EOF

# A Helm template that is only YAML once rendered.
fixture good/helm/templates/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "app.fullname" . }}
  labels:
    {{- include "app.labels" . | nindent 4 }}
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: APP_PASSWORD
              value: {{ .Values.password | quote }}
EOF

# The two exclusions: the SOPS-encrypted store and vendored CRDs.
fixture good/secrets/sops/secrets/app.sops.yaml <<EOF
stringData:
  password: $(v)
EOF
fixture good/crds.yaml <<EOF
spec:
  default:
    password: $(v)
EOF

# --- assertions --------------------------------------------------------------

echo "credential scan:"

findings="$(credential_findings "$FIXTURES")"

for f in "$FIXTURES"/bad/*.yaml; do
    name="bad/$(basename "$f")"
    if grep -qF "$f: document " <<<"$findings"; then
        ok "caught   $name ($(grep -F "$f: document " <<<"$findings" | sed "s|^$f: ||" | paste -sd ';' -))"
    else
        fail "missed   $name"
    fi
done

while IFS= read -r f; do
    name="${f#"$FIXTURES"/}"
    if grep -qF "$f:" <<<"$findings"; then
        fail "flagged  $name: $(grep -F "$f:" <<<"$findings" | sed "s|^$f: ||" | paste -sd ';' -)"
    else
        ok "passes   $name"
    fi
done < <(find "$FIXTURES/good" -type f -name '*.yaml' | sort)

# Judged per document: the next-document case flags document 1 only.
assert_doc() { # <fixture> <expected findings, ;-joined>
    local got
    got="$(grep -F "$FIXTURES/$1: " <<<"$findings" | sed "s|^$FIXTURES/$1: ||" | paste -sd ';' -)"
    if [[ "$got" == "$2" ]]; then ok "$1 -> $2"; else fail "$1: expected '$2', got '$got'"; fi
}
assert_doc bad/next-document-to-secretkeyref.yaml "document 1: data.adminPassword"
assert_doc bad/same-document-as-secretkeyref.yaml "document 0: spec.template.spec.containers.0.env.1.value"
assert_doc bad/short-pass-key.yaml "document 0: data.DB_PASS;document 0: data.smtpPasswd"

# Findings name a file and a YAML path, never the value.
if grep -q 'fixture-' <<<"$findings"; then
    fail "a finding printed a credential value"
else
    ok "no finding prints a value"
fi

if [[ $FAILURES -ne 0 ]]; then
    echo "credential scan: $FAILURES assertion(s) failed"
    exit 1
fi
echo "credential scan: all assertions passed"
