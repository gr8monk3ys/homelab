#!/bin/bash
# shellcheck shell=bash
#
# The secret table and the one way to produce a generated secret.
#
# `secrets_catalogue` is the table: one `secret` line per generated secret,
# naming its keys and how each value is produced (its policy). Callers pick
# an adapter with SECRETS_ADAPTER and call `secrets_catalogue`; nothing else
# in the repo needs to know how a secret is generated, hashed or written.
#
#   secret <name> <key>=<policy> [<key>=<policy> ...]
#
# Policies (the right-hand side of key=policy):
#   password            32-char random password (openssl base64, [A-Za-z0-9])
#   password:<n>        n-char random password
#   hex:<n>             n random bytes, hex encoded (2n characters)
#   literal:<value>     the value as written (admin usernames, fixed config)
#   empty               "" (the operator fills it in later)
#   email               ADMIN_EMAIL (scripts/lib/render.sh, homelab_load_config)
#   template:<text>     text with {key} replaced by that key's value from the
#                       same secret; keys resolve left to right, so put the
#                       referenced key first
#   argon2:<name>/<key> Authelia Argon2id hash of an earlier secret's value
#   users-db:<name>/<user-key>,<name>/<password-key>
#                       Authelia users_database.yml with one admin user,
#                       whose password is the argon2 hash of <password-key>
#
# Adapters (SECRETS_ADAPTER):
#   kubectl   upsert into SECRETS_NAMESPACE; an existing secret is left alone
#             unless ROTATE_SECRETS=true (its values are read back so later
#             table entries that reference it hash the real password)
#   sops      write a client-side dry-run Secret manifest and encrypt it with
#             sops to SECRETS_SOPS_OUT_DIR/<name>.sops.yaml
#   list      print "<name> <key>=<policy> ..." per secret; no cluster,
#             no randomness, no side effects
#
# Requires scripts/lib/common.sh and scripts/lib/render.sh (for ADMIN_EMAIL);
# call homelab_load_config before the kubectl and sops adapters run.

if [[ -n "${HOMELAB_SECRETS_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_SECRETS_SOURCED=1

if [[ -z "${HOMELAB_RENDER_SOURCED:-}" ]]; then
    echo "ERROR: source scripts/lib/render.sh before scripts/lib/secrets.sh" >&2
    exit 1
fi

SECRETS_ADAPTER="${SECRETS_ADAPTER:-kubectl}"
SECRETS_NAMESPACE="${SECRETS_NAMESPACE:-secrets}"
ROTATE_SECRETS="${ROTATE_SECRETS:-false}"
SECRETS_SOPS_OUT_DIR="${SECRETS_SOPS_OUT_DIR:-$HOMELAB_DIR/kubernetes/secrets/sops/secrets}"
SECRETS_SOPS_CONFIG="${SECRETS_SOPS_CONFIG:-$HOMELAB_DIR/.sops.yaml}"
AUTHELIA_IMAGE="${AUTHELIA_IMAGE:-authelia/authelia:4.38.18}"
AUTHELIA_PLACEHOLDER_HASH='$argon2id$v=19$m=65536,t=3,p=4$REPLACE_WITH_PROPER_HASH'

# Every resolved value, as SECRETS_VALUES[<name>/<key>], so a later table
# entry can reference an earlier one (argon2, users-db).
declare -gA SECRETS_VALUES=()

# ---------------------------------------------------------------------------
# The table
# ---------------------------------------------------------------------------

secrets_catalogue() {
    # Core infrastructure. Every secret here must have a consumer:
    # scripts/secrets-check.sh fails CI on generated-but-unused or
    # used-but-ungenerated names.
    secret minio-config             root-user=literal:minioadmin root-password=password
    secret velero-minio-credentials access-key=literal:velero secret-key=hex:32

    # Databases
    secret mysql-root-password      password=password
    secret nextcloud-db-password    password=password
    secret gitea-db-password        password=password
    secret immich-db-password       password=password
    secret paperless-db-password    password=password
    secret n8n-db-password          password=password
    secret linkwarden-db-password   password=password
    secret miniflux-db-password     password=password
    secret synapse-db-password      password=password
    secret mattermost-db-password   password=password
    secret outline-db-password      password=password
    secret hoppscotch-db-password   password=password
    secret umami-db-password        password=password
    secret metabase-db-password     password=password
    secret nocodb-db-password       password=password
    secret keycloak-db-password     password=password
    secret romm-db-password         password=password
    secret romm-db-root-password    password=password

    # Application admin credentials
    secret nextcloud-admin          username=literal:admin password=password
    secret grafana-admin            username=literal:admin password=password
    secret gitea-admin              username=literal:admin password=password
    secret harbor-admin             username=literal:admin password=password
    secret vaultwarden-admin        admin-token=hex:64
    secret paperless-admin          username=literal:admin password=password secret-key=hex:64
    secret miniflux-admin           username=literal:admin password=password
    secret keycloak-admin-password  password=password
    secret code-server-password     password=password
    secret node-red-password        password=password
    secret mosquitto-password       password=password

    # Service configuration
    secret pihole-config            web-password=password 'dns-servers=literal:1.1.1.1;8.8.8.8'
    secret wireguard-config         ui-password=password internal-subnet=literal:10.13.13.0
    secret searxng-config           secret-key=hex:64 'instance-name=literal:Homelab Search'
    secret yarr-config              auth-user=literal:admin auth-password=password \
                                    'auth-credentials=template:admin:{auth-password}'
    secret drone-config             gitea-client-id=hex:16 gitea-client-secret=hex:64 rpc-secret=hex:64 \
                                    db-password=password \
                                    'database-url=template:postgres://drone:{db-password}@drone-db:5432/drone?sslmode=disable'
    secret crowdsec-config          bouncer-api-key=hex:32 enroll-key=empty
    secret n8n-config               encryption-key=hex:32 jwt-secret=hex:32
    secret linkwarden-config        nextauth-secret=hex:32
    secret open-webui-config        secret-key=hex:32
    secret outline-secret-key       key=hex:64
    secret outline-utils-secret     key=hex:64
    secret hoppscotch-jwt-secret    secret=hex:64
    secret hoppscotch-session-secret secret=hex:64
    secret umami-app-secret         secret=hex:64
    secret metabase-encryption-key  key=hex:64
    secret nocodb-jwt-secret        secret=hex:64
    secret romm-auth-secret         secret=hex:64
    # IGDB credentials are optional (game metadata); the operator fills them in.
    secret romm-igdb-client-id      id=empty
    secret romm-igdb-client-secret  secret=empty

    # Authelia: the plaintext admin password is kept for recovery; only the
    # Argon2 hash inside users_database.yml reaches the cluster.
    secret authelia-secrets         jwt-secret=hex:64 session-secret=hex:64 \
                                    storage-encryption-key=hex:64 redis-password=password
    secret authelia-admin           username=literal:admin password=password
    secret authelia-users           users_database.yml=users-db:authelia-admin/username,authelia-admin/password
}

# ---------------------------------------------------------------------------
# The interface
# ---------------------------------------------------------------------------

secret() {
    local name="$1"
    shift
    [[ $# -gt 0 ]] || error "secret $name: no keys"
    case "$SECRETS_ADAPTER" in
        kubectl|sops|list) "secrets_adapter_$SECRETS_ADAPTER" "$name" "$@" ;;
        *) error "Unknown SECRETS_ADAPTER: $SECRETS_ADAPTER (kubectl|sops|list)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Value generation
# ---------------------------------------------------------------------------

generate_password() {
    local length="${1:-32}"
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

generate_secret_key() {
    local bytes="${1:-64}"
    openssl rand -hex "$bytes"
}

# Argon2id hash of $1 via `authelia crypto hash`: in-cluster when kubectl can
# reach one (no Docker needed on the host), else docker. Prints nothing when
# neither works.
generate_authelia_argon2_hash() {
    local password="$1" output=""
    if kubectl cluster-info &> /dev/null; then
        output="$(
            kubectl run "authelia-hashgen-$(date +%s)" \
                --namespace="$SECRETS_NAMESPACE" \
                --image="$AUTHELIA_IMAGE" \
                --restart=Never --rm -i --command -- \
                authelia crypto hash generate argon2 --password "$password" 2>/dev/null || true
        )"
    fi
    if [[ -z "$output" ]] && command -v docker &> /dev/null; then
        output="$(
            docker run --rm "$AUTHELIA_IMAGE" \
                authelia crypto hash generate argon2 --password "$password" 2>/dev/null || true
        )"
    fi
    grep -Eo '\$argon2[^[:space:]]+' <<<"$output" | head -n 1
}

# Value of an earlier table entry, by <name>/<key>.
_secrets_ref() {
    local ref="$1"
    [[ -n "${SECRETS_VALUES[$ref]+x}" ]] \
        || error "secret reference $ref: not produced by an earlier table entry"
    printf '%s' "${SECRETS_VALUES[$ref]}"
}

# Resolve one policy to a value on stdout. $1 is the owning secret's name
# (for template references); diagnostics go to stderr so they are not captured.
# Nested failures are checked explicitly: this runs inside `$(...) || ...` in
# the caller, where bash suspends errexit.
_secrets_resolve() {
    local name="$1" policy="$2"
    case "$policy" in
        password)     generate_password ;;
        password:*)   generate_password "${policy#password:}" ;;
        hex:*)        generate_secret_key "${policy#hex:}" ;;
        literal:*)    printf '%s' "${policy#literal:}" ;;
        empty)        printf '' ;;
        email)        printf '%s' "$ADMIN_EMAIL" ;;
        template:*)
            local text="${policy#template:}" key val
            while [[ "$text" =~ \{([A-Za-z0-9_.-]+)\} ]]; do
                key="${BASH_REMATCH[1]}"
                val="$(_secrets_ref "$name/$key")" || return 1
                text="${text//"{$key}"/$val}"
            done
            printf '%s' "$text"
            ;;
        argon2:*)
            local plaintext hash
            plaintext="$(_secrets_ref "${policy#argon2:}")" || return 1
            hash="$(generate_authelia_argon2_hash "$plaintext")"
            if [[ -z "$hash" ]]; then
                if [[ "$SECRETS_ADAPTER" == "sops" ]]; then
                    error "Cannot hash the Authelia admin password: neither a reachable cluster (kubectl) nor docker is available. Refusing to commit a placeholder hash to kubernetes/secrets/sops/."
                fi
                warning "Failed to generate the Authelia Argon2 hash; using a placeholder. Replace it before exposing Authelia externally." >&2
                hash="$AUTHELIA_PLACEHOLDER_HASH"
            fi
            printf '%s' "$hash"
            ;;
        users-db:*)
            local refs="${policy#users-db:}" username hash email
            username="$(_secrets_ref "${refs%%,*}")" || return 1
            hash="$(_secrets_resolve "$name" "argon2:${refs#*,}")" || return 1
            email="$(_secrets_resolve "$name" email)" || return 1
            cat <<USERS_EOF
---
users:
  ${username}:
    displayname: "Admin User"
    password: "${hash}"
    email: ${email}
    groups:
      - admins
      - users
USERS_EOF
            ;;
        *) error "secret $name: unknown policy '$policy'" ;;
    esac
}

# Resolve every key=policy of a secret into SECRETS_VALUES and SECRETS_KEYS.
_secrets_resolve_all() {
    local name="$1" spec key policy value
    shift
    SECRETS_KEYS=()
    for spec in "$@"; do
        key="${spec%%=*}"
        policy="${spec#*=}"
        [[ "$spec" == *=* && -n "$key" ]] || error "secret $name: expected key=policy, got '$spec'"
        value="$(_secrets_resolve "$name" "$policy")" || error "secret $name/$key: policy '$policy' failed"
        SECRETS_VALUES["$name/$key"]="$value"
        SECRETS_KEYS+=("$key")
    done
}

# Client-side Secret manifest for a resolved secret, on stdout.
_secrets_manifest() {
    local name="$1" key
    local -a literals=()
    for key in "${SECRETS_KEYS[@]}"; do
        literals+=("--from-literal=${key}=${SECRETS_VALUES[$name/$key]}")
    done
    kubectl create secret generic "$name" \
        --namespace="$SECRETS_NAMESPACE" \
        "${literals[@]}" \
        --dry-run=client -o yaml
}

# ---------------------------------------------------------------------------
# Adapters
# ---------------------------------------------------------------------------

secrets_adapter_list() {
    local name="$1"
    shift
    printf '%s' "$name"
    printf ' %s' "$@"
    printf '\n'
}

secrets_adapter_kubectl() {
    local name="$1"
    shift
    if [[ "$ROTATE_SECRETS" != "true" ]] && kubectl get secret -n "$SECRETS_NAMESPACE" "$name" &> /dev/null; then
        log "Secret ${SECRETS_NAMESPACE}/${name} already exists; skipping (set ROTATE_SECRETS=true to rotate)."
        # Keep the stored values so later entries reference what is really there.
        local line key
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            key="${line%%=*}"
            SECRETS_VALUES["$name/$key"]="$(base64 -d <<<"${line#*=}")"
        done < <(kubectl get secret -n "$SECRETS_NAMESPACE" "$name" \
            -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}')
        return 0
    fi
    _secrets_resolve_all "$name" "$@"
    _secrets_manifest "$name" | kubectl apply -f -
}

secrets_adapter_sops() {
    local name="$1"
    shift
    _secrets_resolve_all "$name" "$@"
    local tmp out="$SECRETS_SOPS_OUT_DIR/$name.sops.yaml"
    tmp="$(mktemp "${TMPDIR:-/tmp}/homelab-secret.XXXXXX")"
    _secrets_manifest "$name" > "$tmp"
    # SOPS matches creation_rules against the *target* path, not the temp file.
    if ! sops --encrypt \
        --config "$SECRETS_SOPS_CONFIG" \
        --filename-override "$out" \
        "$tmp" > "$out"; then
        rm -f "$tmp" "$out"
        error "sops failed to encrypt $name"
    fi
    rm -f "$tmp"
    log "Wrote $out"
}
