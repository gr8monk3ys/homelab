#!/bin/bash
# shellcheck shell=bash
#
# Pinned CLI tool installer, table driven. Source it, don't run it:
#
#   source "$SCRIPT_DIR/lib/tools.sh"     # pulls in lib/common.sh if needed
#   BIN_DIR=/some/bin tools_install       # every tool in the table
#   BIN_DIR=/some/bin tools_install helm kustomize yq age
#   tools_list                            # one name per line
#
# Interface:
#   BIN_DIR     required; binaries land here as $BIN_DIR/<name> (mode 0755)
#   TMP_DIR     optional scratch dir (default: a mktemp dir, removed on return)
#   FORCE       "true" reinstalls even when the binary is already present
#   Versions come from tools/versions.env (sourced by lib/common.sh).
#
# tools_install never exits the caller's shell: a tool that fails to download
# or unpack is logged and skipped, the rest still install, and the return
# status is 1 with a final line naming every failure.
#
# Table columns (whitespace separated, "-" for none):
#   name        installed binary name and lookup key
#   version     name of the variable in tools/versions.env
#   url         download URL; {version} {os} {arch} are substituted
#   layout      bare                    the download is the binary
#               tar:<path>[,<path>...]  gzipped tarball; each path (same
#                                       placeholders) is installed under its
#                                       basename, so age also yields age-keygen
#   checksum    URL of a sha256 for the download (bare layout only), or -
#
# helm stays on get.helm.sh (no binaries on GitHub releases); everything else
# uses GitHub release assets or dl.k8s.io.

if [[ -n "${HOMELAB_TOOLS_SOURCED:-}" ]]; then
    return 0
fi
HOMELAB_TOOLS_SOURCED=1

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

tools__table() {
    cat <<'TABLE'
helm         HELM_VERSION         https://get.helm.sh/helm-{version}-{os}-{arch}.tar.gz                                                            tar:{os}-{arch}/helm                    -
kind         KIND_VERSION         https://github.com/kubernetes-sigs/kind/releases/download/{version}/kind-{os}-{arch}                              bare                                    -
kubectl      KUBECTL_VERSION      https://dl.k8s.io/release/{version}/bin/{os}/{arch}/kubectl                                                       bare                                    https://dl.k8s.io/release/{version}/bin/{os}/{arch}/kubectl.sha256
kustomize    KUSTOMIZE_VERSION    https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F{version}/kustomize_{version}_{os}_{arch}.tar.gz  tar:kustomize                -
kubeconform  KUBECONFORM_VERSION  https://github.com/yannh/kubeconform/releases/download/v{version}/kubeconform-{os}-{arch}.tar.gz                  tar:kubeconform                         -
velero       VELERO_CLI_VERSION   https://github.com/vmware-tanzu/velero/releases/download/{version}/velero-{version}-{os}-{arch}.tar.gz            tar:velero-{version}-{os}-{arch}/velero -
yq           YQ_VERSION           https://github.com/mikefarah/yq/releases/download/{version}/yq_{os}_{arch}                                        bare                                    -
age          AGE_VERSION          https://github.com/FiloSottile/age/releases/download/{version}/age-{version}-{os}-{arch}.tar.gz                  tar:age/age,age/age-keygen              -
sops         SOPS_VERSION         https://github.com/getsops/sops/releases/download/{version}/sops-{version}.{os}.{arch}                            bare                                    -
TABLE
}

tools_list() {
    tools__table | awk '{print $1}'
}

# tools__row <name>  -> the table row, or failure when unknown
tools__row() {
    local row
    row="$(tools__table | awk -v n="$1" '$1 == n')"
    [[ -n "$row" ]] || return 1
    echo "$row"
}

# tools__expand <template> <version> <os> <arch>
tools__expand() {
    local s="$1"
    s="${s//\{version\}/$2}"
    s="${s//\{os\}/$3}"
    s="${s//\{arch\}/$4}"
    echo "$s"
}

tools__download() {
    curl -fsSL -o "$2" "$1"
}

# tools__verify_sha256 <file> <sha256-file>
tools__verify_sha256() {
    local expected actual
    expected="$(awk '{print $1; exit}' <"$2")"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$1" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$1" | awk '{print $1}')"
    fi
    [[ -n "$expected" && "$expected" == "$actual" ]]
}

# tools__targets <name> <layout>  -> the binary names a row installs
tools__targets() {
    local p
    case "$2" in
        bare) echo "$1" ;;
        tar:*)
            for p in $(echo "${2#tar:}" | tr ',' ' '); do
                basename "$p"
            done ;;
    esac
}

tools__installed() {
    local t
    for t in "$@"; do
        [[ -x "$BIN_DIR/$t" ]] || return 1
    done
}

# tools__install_one <name> <version-var> <url-template> <layout> <checksum-template>
# Returns 1 (after logging why) instead of exiting, so the loop can go on.
tools__install_one() {
    local name="$1" version_var="$2" url_tmpl="$3" layout="$4" sum_tmpl="$5"
    local version os arch url work p src targets

    version="${!version_var:-}"
    if [[ -z "$version" ]]; then
        log "ERROR: $version_var is not set (tools/versions.env); skipping $name"
        return 1
    fi

    # shellcheck disable=SC2207
    targets=($(tools__targets "$name" "$layout"))
    if [[ "${FORCE:-false}" != "true" ]] && tools__installed "${targets[@]}"; then
        return 0
    fi

    os="$(detect_os)" && arch="$(detect_arch)" || return 1
    url="$(tools__expand "$url_tmpl" "$version" "$os" "$arch")"
    work="$(mktemp -d "$TMP_DIR/$name.XXXXXX")" || return 1

    log "Installing $name $version ..."
    if ! tools__download "$url" "$work/download"; then
        log "ERROR: $name: download failed: $url"
        rm -rf "$work"; return 1
    fi

    case "$layout" in
        bare)
            if [[ "$sum_tmpl" != "-" ]]; then
                url="$(tools__expand "$sum_tmpl" "$version" "$os" "$arch")"
                if ! tools__download "$url" "$work/sha256"; then
                    log "ERROR: $name: checksum download failed: $url"
                    rm -rf "$work"; return 1
                fi
                if ! tools__verify_sha256 "$work/download" "$work/sha256"; then
                    log "ERROR: $name: sha256 verification failed"
                    rm -rf "$work"; return 1
                fi
            fi
            install -m 0755 "$work/download" "$BIN_DIR/$name" || { rm -rf "$work"; return 1; }
            ;;
        tar:*)
            if ! tar -xzf "$work/download" -C "$work"; then
                log "ERROR: $name: could not unpack $url"
                rm -rf "$work"; return 1
            fi
            for p in $(echo "${layout#tar:}" | tr ',' ' '); do
                src="$work/$(tools__expand "$p" "$version" "$os" "$arch")"
                if [[ ! -f "$src" ]]; then
                    log "ERROR: $name: $(basename "$p") not found in archive"
                    rm -rf "$work"; return 1
                fi
                install -m 0755 "$src" "$BIN_DIR/$(basename "$p")" || { rm -rf "$work"; return 1; }
            done
            ;;
        *)
            log "ERROR: $name: unknown layout '$layout'"
            rm -rf "$work"; return 1
            ;;
    esac
    rm -rf "$work"
}

# tools_install [name...]   default: every tool in the table
tools_install() {
    local names name row failed="" own_tmp=""
    local f1 f2 f3 f4 f5

    [[ -n "${BIN_DIR:-}" ]] || { log "ERROR: BIN_DIR is not set"; return 1; }
    mkdir -p "$BIN_DIR" || return 1
    if [[ -z "${TMP_DIR:-}" ]]; then
        own_tmp="$(mktemp -d "${TMPDIR:-/tmp}/homelab-tools.XXXXXX")" || return 1
        TMP_DIR="$own_tmp"
    fi
    mkdir -p "$TMP_DIR" || return 1

    if [[ $# -gt 0 ]]; then names="$*"; else names="$(tools_list)"; fi

    for name in $names; do
        if ! row="$(tools__row "$name")"; then
            log "ERROR: unknown tool '$name' (see tools_list)"
            failed="$failed $name"
            continue
        fi
        read -r f1 f2 f3 f4 f5 <<<"$row"
        tools__install_one "$f1" "$f2" "$f3" "$f4" "$f5" || failed="$failed $name"
    done

    [[ -n "$own_tmp" ]] && rm -rf "$own_tmp"
    if [[ -n "$failed" ]]; then
        log "ERROR: failed to install:$failed"
        return 1
    fi
    return 0
}
