#!/bin/bash
set -euo pipefail

# Enhanced Homelab Setup Script v2.0
# Features: Secret management, Helm charts, Kustomize, health checks

HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="$HOMELAB_DIR/setup.log"
CONFIG_FILE="${CONFIG_FILE:-$HOMELAB_DIR/config/homelab.yaml}"

# If repo-local tools are installed (see scripts/install-dev-tools.sh), prefer them.
TOOLS_DIR="${TOOLS_DIR:-$HOMELAB_DIR/.tools}"
if [[ -d "$TOOLS_DIR/bin" ]]; then
    PATH="$TOOLS_DIR/bin:$PATH"
fi
if [[ -d "$TOOLS_DIR/venv/bin" ]]; then
    PATH="$TOOLS_DIR/venv/bin:$PATH"
fi
export PATH

VERSIONS_FILE="${VERSIONS_FILE:-$HOMELAB_DIR/tools/versions.env}"
if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "ERROR: Missing versions file: $VERSIONS_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

# Capture explicit env overrides (if any). Config file fills defaults; env overrides win.
ENVIRONMENT_OVERRIDE="${ENVIRONMENT-}"
DOMAIN_OVERRIDE="${DOMAIN-}"
TIMEZONE_OVERRIDE="${TIMEZONE-}"
ADMIN_EMAIL_OVERRIDE="${ADMIN_EMAIL-}"
CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE="${CERT_MANAGER_CLUSTER_ISSUER-}"
GITOPS_REPO_URL_OVERRIDE="${GITOPS_REPO_URL-}"

# Defaults (may be overridden by config)
ENVIRONMENT="production"
DOMAIN="homelab.local"
TIMEZONE="UTC"
ADMIN_EMAIL="admin@homelab.local"
CERT_MANAGER_CLUSTER_ISSUER="homelab-ca"
GITOPS_REPO_URL="https://github.com/your-username/homelab.git"

# Feature toggles (set env vars to "true"/"false")
ENABLE_GITOPS="${ENABLE_GITOPS:-false}"
# When true, apply `kubernetes/gitops/argocd/` after ArgoCD install. Those manifests contain placeholders by default.
APPLY_GITOPS_MANIFESTS="${APPLY_GITOPS_MANIFESTS:-false}"
ENABLE_DEV_SERVICES="${ENABLE_DEV_SERVICES:-false}"
ENABLE_AI_SERVICES="${ENABLE_AI_SERVICES:-false}"

ENABLE_NETWORK_SERVICES="${ENABLE_NETWORK_SERVICES:-true}"
ENABLE_CONTENT_SERVICES="${ENABLE_CONTENT_SERVICES:-true}"
ENABLE_MEDIA_SERVICES="${ENABLE_MEDIA_SERVICES:-true}"
ENABLE_PRODUCTIVITY_SERVICES="${ENABLE_PRODUCTIVITY_SERVICES:-true}"

INSTALL_METALLB="${INSTALL_METALLB:-true}"
INSTALL_TRAEFIK="${INSTALL_TRAEFIK:-true}"
INSTALL_CERT_MANAGER="${INSTALL_CERT_MANAGER:-true}"
INSTALL_EXTERNAL_SECRETS="${INSTALL_EXTERNAL_SECRETS:-true}"
INSTALL_EXTERNAL_DNS="${INSTALL_EXTERNAL_DNS:-false}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
INSTALL_BLACKBOX_EXPORTER="${INSTALL_BLACKBOX_EXPORTER:-true}"
CONFIGURE_ALERTING="${CONFIGURE_ALERTING:-false}"
INSTALL_LOGGING="${INSTALL_LOGGING:-false}"
INSTALL_PROMTAIL="${INSTALL_PROMTAIL:-false}"
INSTALL_VELERO="${INSTALL_VELERO:-true}"

# Optional: include an encrypted backup of secret values in backup_configuration()
BACKUP_SECRETS="${BACKUP_SECRETS:-false}"

# Pod Security Admission labeling mode:
# - off: skip applying PSA labels
# - audit: enforce=privileged, audit/warn set to desired target levels (safe migration)
# - enforce: enforce desired levels (may block non-compliant pods)
POD_SECURITY_MODE="${POD_SECURITY_MODE:-audit}"

# Optional policy-as-code engine (Kyverno) + policy mode.
INSTALL_KYVERNO="${INSTALL_KYVERNO:-false}"
KYVERNO_POLICY_MODE="${KYVERNO_POLICY_MODE:-audit}" # audit|enforce

# When true and Pi-hole is enabled, configure wildcard DNS for *.$DOMAIN to Traefik's LoadBalancer.
CONFIGURE_WILDCARD_DNS="${CONFIGURE_WILDCARD_DNS:-true}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    exit 1
}

success() {
    log "✅ $*"
}

info() {
    log "ℹ️  $*"
}

warning() {
    log "⚠️  $*"
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)             error "Unsupported architecture: $arch" ;;
    esac
}

detect_os() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux)  echo "linux" ;;
        darwin) echo "darwin" ;;
        *)      error "Unsupported OS: $os" ;;
    esac
}

check_requirements() {
    log "Checking system requirements..."

    local missing_tools=()

    # Helm is optional here; we can install it below.
    for tool in kubectl curl; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
    fi

    # Check Kubernetes cluster
    if ! kubectl cluster-info &> /dev/null; then
        error "Kubernetes cluster is not accessible"
    fi

    success "Requirements check completed"
}

install_tools() {
    log "Installing/updating tools..."
    # Pinned versions are sourced from tools/versions.env.

    # Install/update Helm with version pinning
    if ! command -v helm &> /dev/null; then
        log "Installing Helm ${HELM_VERSION}..."
        local helm_script="/tmp/get-helm-3.sh"
        curl -fsSL -o "$helm_script" "https://raw.githubusercontent.com/helm/helm/${HELM_VERSION}/scripts/get-helm-3"
        chmod +x "$helm_script"
        DESIRED_VERSION="${HELM_VERSION}" bash "$helm_script"
        rm -f "$helm_script"
    fi

    # Install/update Kustomize with version pinning
    if ! command -v kustomize &> /dev/null; then
        log "Installing Kustomize ${KUSTOMIZE_VERSION}..."
        local kustomize_script="/tmp/install_kustomize.sh"
        curl -fsSL -o "$kustomize_script" "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/kustomize/${KUSTOMIZE_VERSION}/hack/install_kustomize.sh"
        chmod +x "$kustomize_script"
        bash "$kustomize_script" "${KUSTOMIZE_VERSION#v}" /tmp
        sudo mv /tmp/kustomize /usr/local/bin/
        rm -f "$kustomize_script"
    fi

    # Install yq (YAML CLI) for config parsing and rendering
    if ! command -v yq &> /dev/null; then
        log "Installing yq ${YQ_VERSION}..."
        local OS ARCH
        OS=$(detect_os)
        ARCH=$(detect_arch)
        local yq_tmp="/tmp/yq"
        curl -fsSL -o "$yq_tmp" "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}"
        chmod +x "$yq_tmp"
        sudo mv "$yq_tmp" /usr/local/bin/yq
    fi

    # Install age (encrypted backups for secrets)
    if ! command -v age &> /dev/null || ! command -v age-keygen &> /dev/null; then
        log "Installing age ${AGE_VERSION}..."
        local OS ARCH
        OS=$(detect_os)
        ARCH=$(detect_arch)

        local tmpdir
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/age.XXXXXX")"
        local tarball="${tmpdir}/age.tar.gz"

        curl -fsSL -o "$tarball" "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-${OS}-${ARCH}.tar.gz"
        tar -xzf "$tarball" -C "$tmpdir"

        local age_bin age_keygen_bin
        age_bin="$(find "$tmpdir" -type f -name age -perm -111 2>/dev/null | head -n 1 || true)"
        age_keygen_bin="$(find "$tmpdir" -type f -name age-keygen -perm -111 2>/dev/null | head -n 1 || true)"

        if [[ -z "${age_bin:-}" || -z "${age_keygen_bin:-}" ]]; then
            error "Failed to locate age binaries after extraction"
        fi

        sudo mv "$age_bin" /usr/local/bin/age
        sudo mv "$age_keygen_bin" /usr/local/bin/age-keygen
        rm -rf "$tmpdir"
    fi

    # Add Helm repositories
    log "Adding Helm repositories..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || log "WARNING: prometheus-community repo may already exist"
    helm repo add bitnami https://charts.bitnami.com/bitnami || log "WARNING: bitnami repo may already exist"
    helm repo add jetstack https://charts.jetstack.io || log "WARNING: jetstack repo may already exist"
    helm repo add traefik https://traefik.github.io/charts || log "WARNING: traefik repo may already exist"
    helm repo add external-secrets https://charts.external-secrets.io || log "WARNING: external-secrets repo may already exist"
    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ || log "WARNING: external-dns repo may already exist"
    helm repo add metallb https://metallb.github.io/metallb || log "WARNING: metallb repo may already exist"
    helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || log "WARNING: vmware-tanzu repo may already exist"

    if ! helm repo update; then
        error "Failed to update Helm repositories"
    fi

    success "Tools installation completed"
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warning "Config file not found at $CONFIG_FILE; using defaults and env overrides."
        return 0
    fi

    if ! command -v yq &> /dev/null; then
        warning "yq is not installed; skipping config parsing. (setup-v2.sh installs yq in install_tools)"
        return 0
    fi

    local cfg_domain cfg_timezone cfg_email cfg_issuer cfg_environment cfg_gitops_repo_url
    cfg_domain="$(yq -r '.homelab.domain // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    cfg_timezone="$(yq -r '.homelab.timezone // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    cfg_email="$(yq -r '.homelab.email // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    cfg_environment="$(yq -r '.homelab.environment // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    cfg_issuer="$(yq -r '.ingress.cert_manager.cluster_issuer // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    cfg_gitops_repo_url="$(yq -r '.gitops.repo_url // empty' "$CONFIG_FILE" 2>/dev/null || true)"

    [[ -n "${cfg_domain:-}" ]] && DOMAIN="$cfg_domain"
    [[ -n "${cfg_timezone:-}" ]] && TIMEZONE="$cfg_timezone"
    [[ -n "${cfg_email:-}" ]] && ADMIN_EMAIL="$cfg_email"
    [[ -n "${cfg_environment:-}" ]] && ENVIRONMENT="$cfg_environment"
    [[ -n "${cfg_issuer:-}" ]] && CERT_MANAGER_CLUSTER_ISSUER="$cfg_issuer"
    [[ -n "${cfg_gitops_repo_url:-}" ]] && GITOPS_REPO_URL="$cfg_gitops_repo_url"
}

apply_env_overrides() {
    [[ -n "${DOMAIN_OVERRIDE:-}" ]] && DOMAIN="$DOMAIN_OVERRIDE"
    [[ -n "${TIMEZONE_OVERRIDE:-}" ]] && TIMEZONE="$TIMEZONE_OVERRIDE"
    [[ -n "${ADMIN_EMAIL_OVERRIDE:-}" ]] && ADMIN_EMAIL="$ADMIN_EMAIL_OVERRIDE"
    [[ -n "${ENVIRONMENT_OVERRIDE:-}" ]] && ENVIRONMENT="$ENVIRONMENT_OVERRIDE"
    [[ -n "${CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE:-}" ]] && CERT_MANAGER_CLUSTER_ISSUER="$CERT_MANAGER_CLUSTER_ISSUER_OVERRIDE"
    [[ -n "${GITOPS_REPO_URL_OVERRIDE:-}" ]] && GITOPS_REPO_URL="$GITOPS_REPO_URL_OVERRIDE"
}

escape_sed_replacement() {
    # Escape replacement strings for sed (/, \, &).
    printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

render_stream() {
    local admin_email_esc domain_esc timezone_esc issuer_esc gitops_repo_url_esc
    admin_email_esc="$(escape_sed_replacement "$ADMIN_EMAIL")"
    domain_esc="$(escape_sed_replacement "$DOMAIN")"
    timezone_esc="$(escape_sed_replacement "$TIMEZONE")"
    issuer_esc="$(escape_sed_replacement "$CERT_MANAGER_CLUSTER_ISSUER")"
    gitops_repo_url_esc="$(escape_sed_replacement "$GITOPS_REPO_URL")"

    # 1) Email replacement first (domain replacement would otherwise partially change it).
    # 2) GitOps repo URL placeholder replacement.
    # 3) Domain replacement across the repo defaults.
    # 4) TZ defaults (most manifests use value: "UTC" for TZ).
    # 5) cert-manager issuer selection for Ingress annotations.
    sed \
        -e "s/admin@homelab\\.local/${admin_email_esc}/g" \
        -e "s/https:\\/\\/github\\.com\\/your-username\\/homelab\\.git/${gitops_repo_url_esc}/g" \
        -e "s/homelab\\.local/${domain_esc}/g" \
        -e "s/value: \\\"UTC\\\"/value: \\\"${timezone_esc}\\\"/g" \
        -e "s/cert-manager\\.io\\/cluster-issuer: \\\"homelab-ca\\\"/cert-manager.io\\/cluster-issuer: \\\"${issuer_esc}\\\"/g"
}

render_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        error "render_file: file not found: $file"
    fi
    render_stream < "$file"
}

crd_exists() {
    local crd="$1"
    kubectl get crd "$crd" >/dev/null 2>&1
}

kubectl_apply_rendered_file() {
    local file="$1"
    render_file "$file" | kubectl apply -f -
}

kubectl_apply_rendered_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "kubectl_apply_rendered_dir: directory not found: $dir"
    fi

    local files=()
    local has_servicemonitor_crd="false"
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        has_servicemonitor_crd="true"
    fi

    while IFS= read -r file; do
        local base
        base="$(basename "$file")"
        if [[ "$base" == "servicemonitor.yaml" || "$base" == "servicemonitor.yml" ]]; then
            if [[ "$has_servicemonitor_crd" != "true" ]]; then
                continue
            fi
        fi
        files+=("$file")
    done < <(find "$dir" -type f \( -name "*.yaml" -o -name "*.yml" \) -print | sort)

    if [ ${#files[@]} -eq 0 ]; then
        warning "No YAML files found under: $dir"
        return 0
    fi

    # Apply all YAML in a deterministic order, ensuring namespaces are created first.
    {
        local f
        for f in "${files[@]}"; do
            if [[ "$(basename "$f")" == "namespace.yaml" ]]; then
                render_file "$f"
                echo ""
            fi
        done
        for f in "${files[@]}"; do
            if [[ "$(basename "$f")" != "namespace.yaml" ]]; then
                render_file "$f"
                echo ""
            fi
        done
    } | kubectl apply -f -
}

render_to_tmpfile() {
    local file="$1"
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/homelab-render.XXXXXX.yaml")"
    render_file "$file" > "$tmp"
    echo "$tmp"
}

setup_secrets() {
    log "Setting up secret management..."

    # Create the central secrets namespace first.
    kubectl_apply_rendered_file kubernetes/secrets/secrets-namespace.yaml

    # Ensure kube-root-ca ConfigMap exists (used by ClusterSecretStore caProvider).
    for _ in $(seq 1 30); do
        if kubectl get configmap -n secrets kube-root-ca.crt &> /dev/null; then
            break
        fi
        sleep 1
    done

    if [[ "$INSTALL_EXTERNAL_SECRETS" == "true" ]]; then
        if [[ -z "${EXTERNAL_SECRETS_CHART_VERSION:-}" ]]; then
            error "Missing EXTERNAL_SECRETS_CHART_VERSION (set in tools/versions.env)"
        fi
        log "Installing External Secrets Operator (Helm)..."
        helm upgrade --install external-secrets external-secrets/external-secrets \
            --namespace external-secrets \
            --create-namespace \
            --version "$EXTERNAL_SECRETS_CHART_VERSION" \
            --set installCRDs=true \
            --wait

        # Wait for External Secrets Operator to be ready
        kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=external-secrets -n external-secrets --timeout=300s || \
            warning "External Secrets pods not ready yet (continuing)"

        # Deploy SecretStore RBAC + ClusterSecretStore (requires ESO CRDs)
        kubectl_apply_rendered_file kubernetes/secrets/secret-store-rbac.yaml
        kubectl_apply_rendered_file kubernetes/secrets/secret-store.yaml

        kubectl wait --for=condition=Ready clustersecretstore/homelab-secret-store --timeout=120s || \
            warning "ClusterSecretStore not Ready yet (continuing)"
    else
        warning "INSTALL_EXTERNAL_SECRETS=false; skipping External Secrets Operator + ClusterSecretStore."
        warning "ExternalSecret resources will not apply until you install External Secrets Operator."
    fi

    # Generate all secrets
    log "Generating secure secrets..."
    bash scripts/generate-secrets.sh

    success "Secret management setup completed"
}

setup_storage() {
    log "Setting up persistent storage..."

    # Apply storage manifests via Kustomize
    kubectl apply -k kubernetes/storage/

    # Wait for storage to be ready
    if kubectl get namespace local-path-storage &> /dev/null; then
        kubectl wait --for=condition=Ready pods -l app=local-path-provisioner -n local-path-storage --timeout=300s || \
            warning "local-path-provisioner pods not ready yet (continuing)"
    else
        warning "Namespace local-path-storage not found. If you're not using K3s/Kind, install a storage provisioner."
    fi

    success "Storage setup completed"
}

setup_ingress() {
    log "Setting up ingress controller and certificates..."

    if [[ "$INSTALL_TRAEFIK" == "true" ]]; then
        if [[ -z "${TRAEFIK_CHART_VERSION:-}" ]]; then
            error "Missing TRAEFIK_CHART_VERSION (set in tools/versions.env)"
        fi
        log "Installing Traefik (Helm)..."
        helm upgrade --install traefik traefik/traefik \
            --namespace traefik-system \
            --create-namespace \
            --version "$TRAEFIK_CHART_VERSION" \
            --values kubernetes/ingress/traefik/values.yaml \
            --wait
    else
        warning "INSTALL_TRAEFIK=false; skipping Traefik install."
    fi

    if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
        if [[ -z "${CERT_MANAGER_CHART_VERSION:-}" ]]; then
            error "Missing CERT_MANAGER_CHART_VERSION (set in tools/versions.env)"
        fi
        # Install cert-manager with Helm
        helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --version "$CERT_MANAGER_CHART_VERSION" \
            --set installCRDs=true \
            --wait

        # Apply certificate issuers (local CA + optional Let's Encrypt)
        kubectl_apply_rendered_dir kubernetes/ingress/cert-manager
    else
        warning "INSTALL_CERT_MANAGER=false; skipping cert-manager install + issuers."
    fi

    success "Ingress setup completed"
}

setup_external_dns() {
    log "Setting up ExternalDNS (Cloudflare)..."

    if [[ "$INSTALL_EXTERNAL_DNS" != "true" ]]; then
        warning "INSTALL_EXTERNAL_DNS=false; skipping ExternalDNS."
        return 0
    fi
    if [[ -z "${EXTERNAL_DNS_CHART_VERSION:-}" ]]; then
        error "Missing EXTERNAL_DNS_CHART_VERSION (set in tools/versions.env)"
    fi

    # Namespace must exist for ExternalSecret resources.
    kubectl_apply_rendered_file kubernetes/dns/external-dns/namespace.yaml

    if [[ "$INSTALL_EXTERNAL_SECRETS" == "true" ]]; then
        if ! kubectl get secret -n secrets cloudflare-api-token >/dev/null 2>&1; then
            warning "Missing source secret secrets/cloudflare-api-token (key: token); skipping ExternalDNS."
            warning "Create it in the central secrets namespace, then re-run:"
            warning "  INSTALL_EXTERNAL_DNS=true ./setup-v2.sh"
            return 0
        fi

        kubectl_apply_rendered_file kubernetes/dns/external-dns/external-secrets.yaml

        # Wait for External Secrets Operator to sync the token into the runtime namespace.
        for _ in $(seq 1 60); do
            if kubectl get secret -n external-dns cloudflare-api-token >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
    else
        warning "INSTALL_EXTERNAL_SECRETS=false; expected a Secret external-dns/cloudflare-api-token (key: token)."
        if ! kubectl get secret -n external-dns cloudflare-api-token >/dev/null 2>&1; then
            warning "Missing Secret external-dns/cloudflare-api-token; skipping ExternalDNS."
            return 0
        fi
    fi

    local values_tmp
    values_tmp="$(render_to_tmpfile kubernetes/dns/external-dns/values.yaml)"
    helm upgrade --install external-dns external-dns/external-dns \
        --namespace external-dns \
        --create-namespace \
        --version "$EXTERNAL_DNS_CHART_VERSION" \
        --values "$values_tmp" \
        --wait
    rm -f "$values_tmp"

    success "ExternalDNS setup completed"
}

setup_blackbox_exporter() {
    log "Setting up Prometheus blackbox exporter (ingress probes)..."

    if [[ "$INSTALL_BLACKBOX_EXPORTER" != "true" ]]; then
        warning "INSTALL_BLACKBOX_EXPORTER=false; skipping blackbox exporter."
        return 0
    fi
    if [[ "$INSTALL_TRAEFIK" != "true" ]]; then
        warning "INSTALL_TRAEFIK=false; skipping blackbox exporter probes (Traefik is not installed)."
        return 0
    fi
    if [[ -z "${PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION:-}" ]]; then
        error "Missing PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION (set in tools/versions.env)"
    fi

    local values_tmp
    values_tmp="$(render_to_tmpfile kubernetes/monitoring/blackbox-exporter/values.yaml)"
    helm upgrade --install blackbox-exporter prometheus-community/prometheus-blackbox-exporter \
        --namespace monitoring \
        --version "$PROMETHEUS_BLACKBOX_EXPORTER_CHART_VERSION" \
        --values "$values_tmp" \
        --wait
    rm -f "$values_tmp"

    success "Blackbox exporter setup completed"
}

setup_alerting() {
    log "Configuring Alertmanager notification routing..."

    if [[ "$CONFIGURE_ALERTING" != "true" ]]; then
        warning "CONFIGURE_ALERTING=false; skipping AlertmanagerConfig routing."
        return 0
    fi
    if ! crd_exists "alertmanagerconfigs.monitoring.coreos.com"; then
        warning "AlertmanagerConfig CRD not found; ensure monitoring is installed before configuring alerting."
        return 0
    fi

    if [[ "$INSTALL_EXTERNAL_SECRETS" == "true" ]]; then
        if ! kubectl get secret -n secrets alertmanager-webhook >/dev/null 2>&1; then
            warning "Missing source secret secrets/alertmanager-webhook (key: url); skipping alert routing."
            warning "Create it in the central secrets namespace, then re-run:"
            warning "  CONFIGURE_ALERTING=true ./setup-v2.sh"
            return 0
        fi

        kubectl_apply_rendered_file kubernetes/monitoring/alertmanager/external-secrets.yaml

        # Wait for External Secrets Operator to sync the webhook URL into the runtime namespace.
        for _ in $(seq 1 60); do
            if kubectl get secret -n monitoring alertmanager-webhook >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
    else
        warning "INSTALL_EXTERNAL_SECRETS=false; expected a Secret monitoring/alertmanager-webhook (key: url)."
        if ! kubectl get secret -n monitoring alertmanager-webhook >/dev/null 2>&1; then
            warning "Missing Secret monitoring/alertmanager-webhook; skipping alert routing."
            return 0
        fi
    fi

    kubectl_apply_rendered_file kubernetes/monitoring/alertmanager/alertmanagerconfig.yaml

    success "Alertmanager routing configured"
}

setup_monitoring() {
    log "Setting up monitoring stack with Helm..."

    if [[ "$INSTALL_MONITORING" != "true" ]]; then
        warning "INSTALL_MONITORING=false; skipping monitoring stack."
        return 0
    fi

    # Namespace must exist for ExternalSecret resources.
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

    # Grafana admin creds are sourced from the central `secrets` namespace via ESO.
    kubectl_apply_rendered_file kubernetes/monitoring/prometheus/external-secrets.yaml

    # Install Prometheus stack
    if [[ -z "${KUBE_PROMETHEUS_STACK_CHART_VERSION:-}" ]]; then
        error "Missing KUBE_PROMETHEUS_STACK_CHART_VERSION (set in tools/versions.env)"
    fi
    local prom_values_tmp
    prom_values_tmp="$(render_to_tmpfile kubernetes/monitoring/prometheus/values.yaml)"
    helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --version "$KUBE_PROMETHEUS_STACK_CHART_VERSION" \
        --values "$prom_values_tmp" \
        --wait
    rm -f "$prom_values_tmp"

    # Apply additional PrometheusRules (custom alerts) after the chart CRDs are installed.
    kubectl_apply_rendered_dir kubernetes/monitoring/alerts

    # Apply ServiceMonitors defined by this repo (requires Prometheus Operator CRDs).
    kubectl_apply_rendered_dir kubernetes/monitoring/servicemonitors

    # Deploy additional monitoring components
    kubectl_apply_rendered_dir kubernetes/monitoring/uptime-kuma

    # Optional: ingress probes + notification routing.
    setup_blackbox_exporter
    setup_alerting

    success "Monitoring setup completed"
}

setup_logging() {
    log "Setting up logging (Loki)..."

    if [[ "$INSTALL_LOGGING" != "true" ]]; then
        warning "INSTALL_LOGGING=false; skipping Loki."
        return 0
    fi

    kubectl_apply_rendered_dir kubernetes/services/loki

    # Provision a Loki datasource for Grafana (picked up by kube-prometheus-stack Grafana sidecar).
    if kubectl get namespace monitoring &>/dev/null; then
        kubectl_apply_rendered_file kubernetes/monitoring/grafana/datasources/loki.yaml
    else
        warning "Monitoring namespace not found; skipping Grafana Loki datasource."
    fi

    if [[ "$INSTALL_PROMTAIL" == "true" ]]; then
        if [[ -f "extras/kubernetes/services/loki/promtail-deployment.yaml" ]]; then
            kubectl_apply_rendered_file extras/kubernetes/services/loki/promtail-deployment.yaml
        else
            warning "Promtail manifest not found: extras/kubernetes/services/loki/promtail-deployment.yaml (skipping)."
        fi
    else
        warning "INSTALL_PROMTAIL=false; skipping Promtail (no default log shipper will be installed)."
        warning "To enable later: INSTALL_LOGGING=true INSTALL_PROMTAIL=true ./setup-v2.sh"
    fi

    success "Logging setup completed"
}

setup_core_services() {
    log "Setting up core services with Helm..."

    # Install NextCloud using our custom Helm chart
    local nextcloud_values_tmp
    nextcloud_values_tmp="$(render_to_tmpfile helm/nextcloud/values.yaml)"
    helm upgrade --install nextcloud helm/nextcloud \
        --namespace nextcloud \
        --create-namespace \
        --dependency-update \
        --values "$nextcloud_values_tmp" \
        --wait
    rm -f "$nextcloud_values_tmp"

    # Install other services
    kubectl_apply_rendered_dir kubernetes/services/vaultwarden
    kubectl_apply_rendered_dir kubernetes/services/gitea

    success "Core services setup completed"
}

setup_network_services() {
    log "Setting up network services..."

    if [[ "$ENABLE_NETWORK_SERVICES" != "true" ]]; then
        warning "ENABLE_NETWORK_SERVICES=false; skipping network services."
        return 0
    fi

    kubectl_apply_rendered_dir kubernetes/services/pihole
    kubectl_apply_rendered_dir kubernetes/services/wireguard
    kubectl_apply_rendered_dir kubernetes/services/dnsmasq-dhcp

    if [[ "$CONFIGURE_WILDCARD_DNS" == "true" ]]; then
        bash scripts/configure-wildcard-dns.sh || warning "Wildcard DNS configuration failed (continuing)."
    else
        warning "CONFIGURE_WILDCARD_DNS=false; leaving DNS configuration unchanged."
        warning "To enable later: ./scripts/configure-wildcard-dns.sh"
    fi

    success "Network services setup completed"
}

setup_development_services() {
    log "Setting up development services..."

    if [[ "$ENABLE_DEV_SERVICES" != "true" ]]; then
        warning "ENABLE_DEV_SERVICES=false; skipping development services (Harbor, Drone, etc)."
        return 0
    fi

    # Do not `kubectl apply -f` the whole directory: it contains Helm values files.
    kubectl_apply_rendered_file kubernetes/services/harbor/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/harbor/install.yaml
    kubectl_apply_rendered_dir kubernetes/services/drone
    warning "Drone was installed without a runner (secure default)."
    warning "If you accept the Docker socket risk, apply: extras/kubernetes/services/drone/drone-runner-docker.yaml"

    success "Development services setup completed"
}

setup_content_services() {
    log "Setting up content services..."

    if [[ "$ENABLE_CONTENT_SERVICES" != "true" ]]; then
        warning "ENABLE_CONTENT_SERVICES=false; skipping content services."
        return 0
    fi

    kubectl_apply_rendered_dir kubernetes/services/searxng
    kubectl_apply_rendered_dir kubernetes/services/calibre-web
    kubectl_apply_rendered_dir kubernetes/services/yarr

    success "Content services setup completed"
}

setup_loadbalancer() {
    log "Setting up MetalLB load balancer..."

    if [[ "$INSTALL_METALLB" != "true" ]]; then
        warning "INSTALL_METALLB=false; skipping MetalLB install."
        return 0
    fi
    if [[ -z "${METALLB_CHART_VERSION:-}" ]]; then
        error "Missing METALLB_CHART_VERSION (set in tools/versions.env)"
    fi

    if grep -q "192\\.168\\.1\\.200-192\\.168\\.1\\.250" kubernetes/loadbalancing/metallb/ipaddresspool.yaml 2>/dev/null; then
        warning "MetalLB IP pool appears to be using the default example range (192.168.1.200-192.168.1.250)."
        warning "Review kubernetes/loadbalancing/metallb/ipaddresspool.yaml before exposing services on your LAN."
    fi

    # Add MetalLB Helm repo
    helm repo add metallb https://metallb.github.io/metallb || log "WARNING: metallb repo may already exist"
    helm repo update

    # Install MetalLB
    helm upgrade --install metallb metallb/metallb \
        --namespace metallb-system \
        --create-namespace \
        --version "$METALLB_CHART_VERSION" \
        --wait

    # Wait for MetalLB to be ready
    kubectl wait --for=condition=Ready pods -l app.kubernetes.io/name=metallb -n metallb-system --timeout=300s

    # Apply IP address pool and L2 advertisement
    kubectl_apply_rendered_file kubernetes/loadbalancing/metallb/ipaddresspool.yaml
    kubectl_apply_rendered_file kubernetes/loadbalancing/metallb/l2advertisement.yaml

    success "MetalLB setup completed"
}

setup_backup() {
    log "Setting up Velero backup..."

    if [[ "$INSTALL_VELERO" != "true" ]]; then
        warning "INSTALL_VELERO=false; skipping Velero."
        return 0
    fi
    if [[ -z "${VELERO_CHART_VERSION:-}" ]]; then
        error "Missing VELERO_CHART_VERSION (set in tools/versions.env)"
    fi

    # Add Velero Helm repo
    helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || log "WARNING: vmware-tanzu repo may already exist"
    helm repo update

    # Create namespace
    kubectl_apply_rendered_file kubernetes/backup/velero/namespace.yaml

    # Credentials are sourced from the central `secrets` namespace via ESO.
    kubectl_apply_rendered_file kubernetes/backup/velero/external-secrets.yaml

    # Install Velero with Helm
    local velero_values_tmp
    velero_values_tmp="$(render_to_tmpfile kubernetes/backup/velero/values.yaml)"
    helm upgrade --install velero vmware-tanzu/velero \
        --namespace velero \
        --version "$VELERO_CHART_VERSION" \
        --values "$velero_values_tmp" \
        --wait
    rm -f "$velero_values_tmp"

    # Apply backup schedules
    kubectl_apply_rendered_file kubernetes/backup/velero/schedules.yaml

    success "Velero backup setup completed"
}

setup_security() {
    log "Setting up CrowdSec security..."

    kubectl_apply_rendered_file kubernetes/security/crowdsec/namespace.yaml
    kubectl_apply_rendered_file kubernetes/security/crowdsec/configmap.yaml
    kubectl_apply_rendered_file kubernetes/security/crowdsec/deployment.yaml
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        kubectl_apply_rendered_file kubernetes/security/crowdsec/servicemonitor.yaml
    fi

    # Wait for CrowdSec to be ready
    kubectl wait --for=condition=Ready pods -l app=crowdsec -n crowdsec --timeout=300s || log "WARNING: CrowdSec may take longer to start"

    success "CrowdSec security setup completed"
}

setup_network_policies() {
    log "Setting up network policies for service isolation..."

    # Apply all network policies
    kubectl_apply_rendered_file kubernetes/security/network-policies/namespace.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/default-deny-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/egress-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/database-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/sensitive-services-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/infrastructure-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/media-services-policies.yaml

    success "Network policies setup completed"
}

setup_pod_disruption_budgets() {
    log "Setting up PodDisruptionBudgets for critical services..."

    kubectl_apply_rendered_file kubernetes/security/pod-disruption-budgets.yaml

    success "PodDisruptionBudgets setup completed"
}

setup_resource_quotas() {
    log "Setting up ResourceQuotas for namespace resource limits..."

    kubectl_apply_rendered_file kubernetes/security/resource-quotas.yaml

    success "ResourceQuotas setup completed"
}

setup_pod_security_standards() {
    log "Setting up Pod Security Standards for namespaces..."

    case "$POD_SECURITY_MODE" in
        off)
            warning "POD_SECURITY_MODE=off; skipping Pod Security Admission labels."
            return 0
            ;;
        audit)
            kubectl_apply_rendered_file kubernetes/security/pod-security-standards-audit.yaml
            ;;
        enforce)
            kubectl_apply_rendered_file kubernetes/security/pod-security-standards-enforce.yaml
            ;;
        *)
            error "Invalid POD_SECURITY_MODE: $POD_SECURITY_MODE (expected: off|audit|enforce)"
            ;;
    esac

    success "Pod Security Standards setup completed"
}

setup_policy_as_code() {
    log "Setting up policy-as-code (Kyverno)..."

    if [[ "$INSTALL_KYVERNO" != "true" ]]; then
        warning "INSTALL_KYVERNO=false; skipping Kyverno."
        return 0
    fi

    # Add Kyverno Helm repo
    helm repo add kyverno https://kyverno.github.io/kyverno/ || log "WARNING: kyverno repo may already exist"
    helm repo update

    local kyverno_values_tmp
    kyverno_values_tmp="$(render_to_tmpfile kubernetes/policy/kyverno/values.yaml)"
    helm upgrade --install kyverno kyverno/kyverno \
        --namespace kyverno \
        --create-namespace \
        --version "$KYVERNO_CHART_VERSION" \
        --values "$kyverno_values_tmp" \
        --wait
    rm -f "$kyverno_values_tmp"

    case "$KYVERNO_POLICY_MODE" in
        audit)
            kubectl_apply_rendered_dir kubernetes/policy/kyverno/policies-audit
            ;;
        enforce)
            kubectl_apply_rendered_dir kubernetes/policy/kyverno/policies-enforce
            ;;
        *)
            error "Invalid KYVERNO_POLICY_MODE: $KYVERNO_POLICY_MODE (expected: audit|enforce)"
            ;;
    esac

    success "Kyverno policy engine setup completed"
}

setup_authentication() {
    log "Setting up Authelia SSO/2FA..."

    # Apply all Authelia manifests (includes PDB + ServiceMonitor).
    kubectl_apply_rendered_dir kubernetes/services/authelia

    # Wait for Redis
    kubectl wait --for=condition=Ready pods -l app=authelia-redis -n authelia --timeout=300s

    success "Authelia SSO setup completed"
}

setup_media_services() {
    log "Setting up media services..."

    if [[ "$ENABLE_MEDIA_SERVICES" != "true" ]]; then
        warning "ENABLE_MEDIA_SERVICES=false; skipping media services."
        return 0
    fi

    # Jellyfin
    kubectl_apply_rendered_dir kubernetes/services/jellyfin

    # Arr Stack
    kubectl_apply_rendered_file kubernetes/services/arr-stack/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/arr-stack/shared-storage.yaml
    kubectl_apply_rendered_file kubernetes/services/arr-stack/sonarr-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/arr-stack/radarr-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/arr-stack/prowlarr-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/arr-stack/bazarr-deployment.yaml

    # Audiobookshelf
    kubectl_apply_rendered_file kubernetes/services/audiobookshelf/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/audiobookshelf/deployment.yaml

    success "Media services setup completed"
}

setup_ai_services() {
    log "Setting up AI services..."

    if [[ "$ENABLE_AI_SERVICES" != "true" ]]; then
        warning "ENABLE_AI_SERVICES=false; skipping AI services (Immich ML, Ollama, etc)."
        return 0
    fi

    # Immich (photos with ML)
    kubectl_apply_rendered_file kubernetes/services/immich/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/immich/postgres-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/immich/redis-deployment.yaml

    # Wait for Immich dependencies
    kubectl wait --for=condition=Ready pods -l app=immich-postgres -n immich --timeout=300s || log "WARNING: Immich postgres may take longer"
    kubectl wait --for=condition=Ready pods -l app=immich-redis -n immich --timeout=300s || log "WARNING: Immich redis may take longer"

    kubectl_apply_rendered_file kubernetes/services/immich/server-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/immich/microservices-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/immich/machine-learning-deployment.yaml
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        kubectl_apply_rendered_file kubernetes/services/immich/servicemonitor.yaml
    fi

    # Ollama (local LLM)
    kubectl_apply_rendered_dir kubernetes/services/ollama

    # Open WebUI (chat UI for Ollama)
    kubectl_apply_rendered_dir kubernetes/services/open-webui

    success "AI services setup completed"
}

setup_productivity_services() {
    log "Setting up productivity services..."

    if [[ "$ENABLE_PRODUCTIVITY_SERVICES" != "true" ]]; then
        warning "ENABLE_PRODUCTIVITY_SERVICES=false; skipping productivity services."
        return 0
    fi

    # Paperless-ngx
    kubectl_apply_rendered_file kubernetes/services/paperless-ngx/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/paperless-ngx/postgres-deployment.yaml
    kubectl_apply_rendered_file kubernetes/services/paperless-ngx/redis-deployment.yaml

    # Wait for Paperless dependencies
    kubectl wait --for=condition=Ready pods -l app=paperless-postgres -n paperless-ngx --timeout=300s || log "WARNING: Paperless postgres may take longer"

    kubectl_apply_rendered_file kubernetes/services/paperless-ngx/deployment.yaml

    # n8n
    kubectl_apply_rendered_file kubernetes/services/n8n/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/n8n/postgres-deployment.yaml

    kubectl wait --for=condition=Ready pods -l app=n8n-postgres -n n8n --timeout=300s || log "WARNING: n8n postgres may take longer"

    kubectl_apply_rendered_file kubernetes/services/n8n/deployment.yaml
    if crd_exists "servicemonitors.monitoring.coreos.com"; then
        kubectl_apply_rendered_file kubernetes/services/n8n/servicemonitor.yaml
    fi

    # Mealie
    kubectl_apply_rendered_file kubernetes/services/mealie/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/mealie/deployment.yaml

    # Linkwarden
    kubectl_apply_rendered_file kubernetes/services/linkwarden/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/linkwarden/postgres-deployment.yaml

    kubectl wait --for=condition=Ready pods -l app=linkwarden-postgres -n linkwarden --timeout=300s || log "WARNING: Linkwarden postgres may take longer"

    kubectl_apply_rendered_file kubernetes/services/linkwarden/deployment.yaml

    success "Productivity services setup completed"
}

setup_dashboard() {
    log "Setting up Homepage dashboard..."

    kubectl_apply_rendered_file kubernetes/services/homepage/namespace.yaml
    kubectl_apply_rendered_file kubernetes/services/homepage/rbac.yaml
    kubectl_apply_rendered_file kubernetes/services/homepage/configmap.yaml
    kubectl_apply_rendered_file kubernetes/services/homepage/deployment.yaml

    success "Homepage dashboard setup completed"
}

setup_gitops() {
    log "Setting up GitOps with ArgoCD..."

    if [[ "$ENABLE_GITOPS" != "true" ]]; then
        warning "ENABLE_GITOPS=false; skipping ArgoCD install."
        return 0
    fi
    if [[ -z "${ARGOCD_VERSION:-}" ]]; then
        error "Missing ARGOCD_VERSION (set in tools/versions.env)"
    fi

    # Install ArgoCD with pinned version
    kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
    log "Installing ArgoCD ${ARGOCD_VERSION}..."
    kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

    # Wait for ArgoCD to be ready
    kubectl wait --for=condition=Ready pods --all -n argocd --timeout=600s

    # Apply ArgoCD projects (safe defaults), and only apply apps/repos if explicitly enabled.
    kubectl_apply_rendered_file kubernetes/gitops/argocd/projects.yaml

    if [[ "$APPLY_GITOPS_MANIFESTS" == "true" ]]; then
        kubectl_apply_rendered_file kubernetes/gitops/argocd/repositories.yaml
        kubectl_apply_rendered_file kubernetes/gitops/argocd/root-app.yaml
    else
        warning "APPLY_GITOPS_MANIFESTS=false; skipping GitOps bootstrap manifests."
        warning "Edit placeholders (repo URL, enabled apps), then apply:"
        warning "  kubectl apply -f kubernetes/gitops/argocd/repositories.yaml"
        warning "  kubectl apply -f kubernetes/gitops/argocd/root-app.yaml"
        warning "  (optional full stack): kubectl apply -f kubernetes/gitops/argocd/root-app-full.yaml"
    fi

    success "GitOps setup completed"
}

run_health_checks() {
    log "Running health checks..."

    local failed_checks=()

    # Check core platform components (best-effort)
    if [[ "$INSTALL_TRAEFIK" == "true" ]]; then
        if ! kubectl get pods -n traefik-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
            failed_checks+=("traefik")
        fi
    fi

    if [[ "$INSTALL_EXTERNAL_SECRETS" == "true" ]]; then
        if ! kubectl get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
            failed_checks+=("external-secrets")
        fi
    fi

    if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
        if ! kubectl get pods -n cert-manager -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -q Running; then
            failed_checks+=("cert-manager")
        fi
    fi

    # Check namespaces
    local namespaces_to_check=("nextcloud")
    if [[ "$INSTALL_MONITORING" == "true" ]]; then
        namespaces_to_check+=("monitoring")
    fi
    if [[ "$ENABLE_GITOPS" == "true" ]]; then
        namespaces_to_check+=("argocd")
    fi

    for ns in "${namespaces_to_check[@]}"; do
        if ! kubectl get ns "$ns" &> /dev/null; then
            failed_checks+=("namespace-$ns")
        fi
    done

    if [ ${#failed_checks[@]} -ne 0 ]; then
        warning "Failed health checks: ${failed_checks[*]}"
        warning "Some services may not be ready yet. Check logs with: kubectl logs -f deployment/<service>"
    else
        success "All health checks passed"
    fi
}

get_access_info() {
    log "Retrieving access information..."

    echo ""
    echo "🎉 Homelab setup completed successfully!"
    echo ""
    echo "🔗 Service URLs:"
    echo ""
    if [[ "$CONFIGURE_WILDCARD_DNS" == "true" ]]; then
        echo "   DNS: Wildcard DNS via Pi-hole is enabled (no /etc/hosts)."
        echo "   Pi-hole DNS service: kubectl -n pihole get svc pihole-dns"
    else
        echo "   DNS: Add /etc/hosts entries, or enable wildcard DNS via Pi-hole:"
        echo "     CONFIGURE_WILDCARD_DNS=true ./setup-v2.sh"
        echo "     or run: ./scripts/configure-wildcard-dns.sh"
    fi
    echo ""
    echo "   Infrastructure:"
    echo "   📊 Grafana: https://grafana.$DOMAIN"
    echo "   ⚙️  ArgoCD: https://argocd.$DOMAIN"
    echo "   🏠 Homepage: https://home.$DOMAIN"
    echo ""
    echo "   Media:"
    echo "   🎬 Jellyfin: https://jellyfin.$DOMAIN"
    echo "   📺 Sonarr: https://sonarr.$DOMAIN"
    echo "   🎥 Radarr: https://radarr.$DOMAIN"
    echo "   🔍 Prowlarr: https://prowlarr.$DOMAIN"
    echo "   💬 Bazarr: https://bazarr.$DOMAIN"
    echo "   🎧 Audiobookshelf: https://audiobooks.$DOMAIN"
    echo ""
    echo "   Productivity:"
    echo "   📁 Nextcloud: https://nextcloud.$DOMAIN"
    echo "   📄 Paperless: https://docs.$DOMAIN"
    echo "   📸 Immich: https://photos.$DOMAIN"
    echo "   🍲 Mealie: https://recipes.$DOMAIN"
    echo "   🔖 Linkwarden: https://bookmarks.$DOMAIN"
    echo "   🔄 n8n: https://automation.$DOMAIN"
    echo ""
    echo "   AI:"
    echo "   🤖 Ollama API: https://ai.$DOMAIN"
    echo "   💬 Open WebUI: https://chat.$DOMAIN"
    echo ""
    echo "   Security:"
    echo "   🔐 Vaultwarden: https://vault.$DOMAIN"
    echo "   🔒 Authelia: https://auth.$DOMAIN"
    echo "   🛡️  Gitea: https://git.$DOMAIN"
    echo ""
    echo "🔐 Retrieve credentials securely (not logged):"
    echo "   Grafana:     kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   ArgoCD:      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   Nextcloud:   kubectl get secret nextcloud-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo "   Paperless:   kubectl get secret paperless-admin -n secrets -o jsonpath='{.data.password}' | base64 -d && echo"
    echo ""
    echo "🔧 Management commands:"
    echo "   View logs: kubectl logs -f deployment/<service> -n <namespace>"
    echo "   Scale service: kubectl scale deployment <service> --replicas=<count> -n <namespace>"
    echo "   Update config: helm upgrade <release> <chart> --values <values-file>"
    echo "   Backup status: velero schedule get && velero backup get"
    echo "   CrowdSec decisions: kubectl exec -n crowdsec deploy/crowdsec-agent -- cscli decisions list"
    echo ""
    echo "📚 Documentation: $HOMELAB_DIR/docs/"
    echo "🐛 Troubleshooting: kubectl get events --sort-by='.lastTimestamp' -A"
}

backup_configuration() {
    log "Creating configuration backup..."

    local backup_dir
    backup_dir="$HOMELAB_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    # Backup Kubernetes resources (excluding secrets to avoid plaintext credential exposure)
    kubectl get all,configmaps,pv,pvc -A -o yaml > "$backup_dir/kubernetes-resources.yaml"

    # Backup secret names only (not values) for reference
    kubectl get secrets -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name > "$backup_dir/secrets-inventory.txt"
    log "Note: Secret values are not backed up in plaintext."

    if [[ "$BACKUP_SECRETS" == "true" ]]; then
        log "Creating encrypted secret backup (age)..."
        BACKUP_DIR="$backup_dir" bash scripts/backup-secrets.sh || warning "Encrypted secrets backup failed (continuing)"
    fi

    # Backup Helm releases
    helm list -A -o yaml > "$backup_dir/helm-releases.yaml"

    # Backup important configs
    cp -r "$HOMELAB_DIR/config" "$backup_dir/"
    cp -r "$HOMELAB_DIR/helm" "$backup_dir/"
    cp -r "$HOMELAB_DIR/kustomize" "$backup_dir/"

    # Secure backup directory permissions
    chmod -R 600 "$backup_dir"/*
    chmod 700 "$backup_dir"

    log "Configuration backup created: $backup_dir"
}

main() {
    log "Starting enhanced homelab setup (v2.0)..."
    cd "$HOMELAB_DIR"

    check_requirements
    install_tools

    load_config
    apply_env_overrides

    export ENVIRONMENT DOMAIN TIMEZONE ADMIN_EMAIL CERT_MANAGER_CLUSTER_ISSUER GITOPS_REPO_URL

    log "Effective configuration:"
    log "  Environment: $ENVIRONMENT"
    log "  Domain: $DOMAIN"
    log "  Timezone: $TIMEZONE"
    log "  Admin Email: $ADMIN_EMAIL"
    log "  cert-manager ClusterIssuer: $CERT_MANAGER_CLUSTER_ISSUER"
    log "  GitOps repo URL: $GITOPS_REPO_URL"
    log "  Wildcard DNS (Pi-hole): $CONFIGURE_WILDCARD_DNS"
    log "  ExternalDNS: $INSTALL_EXTERNAL_DNS"
    log "  Pod Security Mode: $POD_SECURITY_MODE"
    log "  Kyverno (policy-as-code): $INSTALL_KYVERNO (mode: $KYVERNO_POLICY_MODE)"
    log "  Blackbox Exporter: $INSTALL_BLACKBOX_EXPORTER"
    log "  Alerting (AlertmanagerConfig): $CONFIGURE_ALERTING"
    log "  Logging (Loki): $INSTALL_LOGGING (Promtail: $INSTALL_PROMTAIL)"

    # Base infrastructure (LB, ingress, secrets, storage)
    setup_loadbalancer
    setup_ingress
    setup_secrets
    setup_external_dns
    setup_storage

    # Platform services
    setup_backup
    setup_security
    setup_pod_security_standards
    setup_network_policies
    setup_pod_disruption_budgets
    setup_resource_quotas
    setup_policy_as_code
    setup_monitoring
    setup_logging

    # Core apps
    setup_core_services
    setup_authentication
    setup_media_services
    setup_network_services
    setup_development_services
    setup_content_services
    setup_ai_services
    setup_productivity_services
    setup_dashboard

    setup_gitops
    run_health_checks
    backup_configuration
    get_access_info

    success "Enhanced homelab setup completed successfully!"
    log "Total setup time: $SECONDS seconds"
}

# Cleanup function
cleanup() {
    if [[ -n "${cleanup_needed:-}" ]]; then
        log "Performing cleanup..."
        # Add any cleanup tasks here
    fi
}
trap cleanup EXIT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
