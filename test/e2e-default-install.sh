#!/usr/bin/env bash
# The default install, end to end, against a real Kubernetes API server.
#
# Every other check renders manifests; none applies them. The one time this
# repo's installer was applied to a live API server, every service was switched
# on, so every namespace existed -- and a DEFAULT ./setup-v2.sh aborted halfway
# for two PRs without anyone noticing (static NetworkPolicies aimed at the
# namespaces of switched-off services). This test runs exactly what a new user
# runs, with the defaults, and asserts on what ends up in the cluster.
#
# What it is and is not: etcd + kube-apiserver from the controller-tools envtest
# release, pinned in tools/versions.env. There is no kubelet, scheduler or
# controller-manager, so no pod ever starts: this tests the installer's order,
# preconditions and what it applies where, not whether workloads come up.
# The Helm-installed infrastructure is switched off (chart hooks and --wait
# need running pods); the CRDs it would install are preloaded at their pinned
# versions instead. HELM_WAIT=false lets the one Helm release in the default
# service set (Nextcloud) install without waiting for pods.
#
# Needs network (GitHub releases, raw.githubusercontent.com) the first time;
# downloads are cached under .tools/e2e/. Run directly or from CI.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$TEST_DIR/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/render.sh
source "$TEST_DIR/../scripts/lib/render.sh"
# shellcheck source=scripts/lib/services.sh
source "$TEST_DIR/../scripts/lib/services.sh"

require_cmd curl
require_cmd yq

CACHE="$HOMELAB_DIR/.tools/e2e"
WORK="$(mktemp -d)"
ETCD_PORT="${E2E_ETCD_PORT:-23790}"
API_PORT="${E2E_API_PORT:-26443}"
PIDS=()
cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    # Wait for them to exit, so an immediate re-run finds its ports free.
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

failures=0
pass() { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }

fetch() {   # fetch <url> <dest>: cached download
    [[ -s "$2" ]] && return 0
    mkdir -p "$(dirname "$2")"
    curl -fsSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

# --- 1. API server -----------------------------------------------------------
log "e2e: API server (envtest $ENVTEST_VERSION)..."
envtest_dir="$CACHE/envtest-$ENVTEST_VERSION"
if [[ ! -x "$envtest_dir/kube-apiserver" ]]; then
    fetch "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-$ENVTEST_VERSION/envtest-$ENVTEST_VERSION-linux-amd64.tar.gz" \
        "$CACHE/envtest-$ENVTEST_VERSION.tgz" || error "e2e: cannot download envtest $ENVTEST_VERSION"
    mkdir -p "$envtest_dir"
    tar -xzf "$CACHE/envtest-$ENVTEST_VERSION.tgz" -C "$envtest_dir" --strip-components=2
fi
export PATH="$envtest_dir:$PATH"   # its kubectl matches the server

openssl genrsa -traditional -out "$WORK/sa.key" 2048 2>/dev/null
openssl rsa -in "$WORK/sa.key" -pubout -out "$WORK/sa.pub" 2>/dev/null
echo 'e2etoken,admin,admin,"system:masters"' > "$WORK/tokens.csv"
etcd --data-dir "$WORK/etcd" --listen-client-urls "http://127.0.0.1:$ETCD_PORT" \
    --advertise-client-urls "http://127.0.0.1:$ETCD_PORT" --listen-peer-urls "http://127.0.0.1:$((ETCD_PORT + 10))" \
    > "$WORK/etcd.log" 2>&1 &
PIDS+=("$!")
kube-apiserver --etcd-servers="http://127.0.0.1:$ETCD_PORT" --cert-dir="$WORK/certs" \
    --secure-port="$API_PORT" --bind-address=127.0.0.1 \
    --service-account-key-file="$WORK/sa.pub" --service-account-signing-key-file="$WORK/sa.key" \
    --service-account-issuer=https://kubernetes.default.svc --token-auth-file="$WORK/tokens.csv" \
    --authorization-mode=RBAC --service-cluster-ip-range=10.0.0.0/24 \
    --disable-admission-plugins=ServiceAccount > "$WORK/apiserver.log" 2>&1 &
PIDS+=("$!")
cat > "$WORK/kubeconfig" <<KCFG
apiVersion: v1
kind: Config
clusters: [{name: e2e, cluster: {server: "https://127.0.0.1:$API_PORT", insecure-skip-tls-verify: true}}]
users: [{name: admin, user: {token: e2etoken}}]
contexts: [{name: e2e, context: {cluster: e2e, user: admin}}]
current-context: e2e
KCFG
export KUBECONFIG="$WORK/kubeconfig"
for _ in $(seq 1 60); do kubectl get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
kubectl get --raw /readyz >/dev/null 2>&1 || { tail -20 "$WORK/apiserver.log"; error "e2e: API server did not become ready"; }

# --- 2. The CRDs the switched-off Helm infrastructure would have installed ----
log "e2e: CRDs..."
crds="$CACHE/crds"
fetch "https://raw.githubusercontent.com/external-secrets/external-secrets/v${EXTERNAL_SECRETS_CHART_VERSION#v}/deploy/crds/bundle.yaml" "$crds/external-secrets-$EXTERNAL_SECRETS_CHART_VERSION.yaml"
fetch "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_CHART_VERSION/cert-manager.crds.yaml" "$crds/cert-manager-$CERT_MANAGER_CHART_VERSION.yaml"
fetch "https://github.com/prometheus-operator/prometheus-operator/releases/download/$PROMETHEUS_OPERATOR_VERSION/stripped-down-crds.yaml" "$crds/prometheus-operator-$PROMETHEUS_OPERATOR_VERSION.yaml"
for crd in ingressroutes ingressroutetcps ingressrouteudps middlewares middlewaretcps serverstransports serverstransporttcps tlsoptions tlsstores traefikservices; do
    fetch "https://raw.githubusercontent.com/traefik/traefik-helm-chart/v$TRAEFIK_CHART_VERSION/traefik/crds/traefik.io_$crd.yaml" "$crds/traefik-$TRAEFIK_CHART_VERSION/$crd.yaml" || true
done
[[ -s "$crds/traefik-$TRAEFIK_CHART_VERSION/ingressroutes.yaml" ]] || error "e2e: cannot fetch the Traefik CRDs for chart $TRAEFIK_CHART_VERSION"
for f in "$crds"/*.yaml "$crds/traefik-$TRAEFIK_CHART_VERSION"/*.yaml; do
    kubectl apply --server-side -f "$f" >/dev/null || error "e2e: CRDs in $f were rejected"
done
kubectl wait --for=condition=Established crd --all --timeout=120s >/dev/null

# --- 3. ./setup-v2.sh with the defaults ----------------------------------------
# Every Helm-installed infrastructure piece off, read from the table that
# defines them (scripts/lib/helm.sh); every service toggle left at its default.
helm_off=()
for release in $(helm_infra_release_names); do
    toggle="$(helm_infra_field "$release" toggle)"
    [[ -n "$toggle" ]] && helm_off+=("${toggle%%=*}=false")
done
log "e2e: ./setup-v2.sh with default toggles (${helm_off[*]})..."
start=$SECONDS
env "${helm_off[@]}" HELM_WAIT=false ./setup-v2.sh </dev/null > "$WORK/install.log" 2>&1
rc=$?
log "e2e: installer exited $rc after $((SECONDS - start))s"

echo "e2e assertions:"
not_installed="$(sed 's/\x1b\[[0-9;]*m//g' "$WORK/install.log" | sed -n 's/.*These services did not install: //p' | tail -1)"
helm_kind=" "
for name in $(services_all); do
    [[ "$(service_field "$name" '.kind' manifests)" == "helm" ]] && helm_kind+="$name "
done
unexplained=""
for name in $not_installed; do
    [[ "$helm_kind" == *" $name "* ]] || unexplained+="$name "
done
if [[ $rc -eq 0 ]]; then
    pass "the default install ran to the end (exit 0)"
elif [[ -n "$not_installed" && -z "$unexplained" ]] && grep -q 'did not install' "$WORK/install.log"; then
    pass "the default install ran to the end; only kind: helm services failed ($not_installed), which need a kubelet or chart network this test does not have"
else
    fail "the default install failed (exit $rc)${unexplained:+; services that did not install: $unexplained}"
    sed 's/\x1b\[[0-9;]*m//g' "$WORK/install.log" | grep -E 'ERROR|Error|error:|FAIL' | tail -15 | sed 's/^/        /'
fi

# Every service the defaults enable has its namespace; no service they leave off
# has one -- the Pod Security phase used to create them.
existing=" $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}') "
missing_ns="" phantom=""
service_group_toggles_apply
for name in $(services_all); do
    ns="$(service_field "$name" '.namespace')"
    if service_enabled "$name"; then
        [[ "$existing" == *" $ns "* ]] || missing_ns+="$ns "
    else
        [[ "$existing" == *" $ns "* ]] && phantom+="$ns "
    fi
done
[[ -z "$missing_ns" ]] && pass "every default-enabled service has its namespace" || fail "namespaces missing for enabled services: $missing_ns"
[[ -z "$phantom" ]] && pass "no namespace exists for a switched-off service" || fail "namespaces exist for switched-off services: $phantom"

# What moved into service directories (docs/adr/0009) arrived with its service.
# A service that did not install is skipped: its quota and policies install with
# it (for kind: helm, after the release), so there is nothing to expect.
installed() { service_enabled "$1" && [[ " $not_installed " != *" $1 "* ]]; }
quota_ns="" netpol_ns=""
for name in $(services_all); do
    installed "$name" || continue
    ns="$(service_field "$name" '.namespace')"
    dir="$(service_dir "$name")"
    if [[ -f "$dir/resourcequota.yaml" && -z "$(kubectl get resourcequota -n "$ns" -o name 2>/dev/null)" ]]; then quota_ns+="$ns "; fi
    if [[ -f "$dir/networkpolicies.yaml" ]]; then
        while IFS= read -r pol; do
            [[ -n "$pol" ]] || continue
            kubectl get networkpolicy "$pol" -n "$ns" >/dev/null 2>&1 || netpol_ns+="$ns/$pol "
        done < <(yq -N -r 'select(.kind == "NetworkPolicy") | .metadata.name' "$dir/networkpolicies.yaml")
    fi
done
[[ -z "$quota_ns" ]] && pass "each enabled service's ResourceQuota is in its namespace" || fail "ResourceQuota missing in: $quota_ns"
[[ -z "$netpol_ns" ]] && pass "each enabled service's own NetworkPolicies are in its namespace" || fail "NetworkPolicies missing: $netpol_ns"

# POD_SECURITY_MODE (default audit) reached the service namespaces.
unrelaxed=""
for name in $(services_all); do
    service_enabled "$name" || continue
    ns="$(service_field "$name" '.namespace')"
    [[ -f "$(service_dir "$name")/namespace.yaml" ]] || continue
    [[ -n "$(yq -r '.metadata.labels["pod-security.kubernetes.io/enforce"] // ""' "$(service_dir "$name")/namespace.yaml")" ]] || continue
    level="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')"
    [[ "$level" == "privileged" ]] || unrelaxed+="$ns($level) "
done
[[ -z "$unrelaxed" ]] && pass "POD_SECURITY_MODE=audit relaxed every service namespace's enforce level" || fail "not relaxed to privileged under audit: $unrelaxed"

if [[ $failures -ne 0 ]]; then
    echo "e2e: $failures assertion(s) failed; installer log tail:"
    sed 's/\x1b\[[0-9;]*m//g' "$WORK/install.log" | tail -25 | sed 's/^/        /'
    exit 1
fi
echo "e2e: default install verified against a live API server"
