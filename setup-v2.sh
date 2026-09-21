#!/bin/bash
set -euo pipefail

# Enhanced Homelab Setup Script v2.0
# Features: Secret management, Helm charts, Kustomize, health checks

HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# DR (scripts/disaster-recovery.sh) sources this file and points LOGFILE at its own log.
LOGFILE="${LOGFILE:-$HOMELAB_DIR/setup.log}"

# Shared preamble (tools PATH, versions.env, log family), the rendering seam,
# and the service catalogue. See scripts/lib/*.sh.
source "$HOMELAB_DIR/scripts/lib/common.sh"
source "$HOMELAB_DIR/scripts/lib/render.sh"
source "$HOMELAB_DIR/scripts/lib/helm.sh"
source "$HOMELAB_DIR/scripts/lib/services.sh"
source "$HOMELAB_DIR/scripts/lib/netpol.sh"
source "$HOMELAB_DIR/scripts/lib/health.sh"

# DOMAIN, TIMEZONE, ADMIN_EMAIL, CERT_MANAGER_CLUSTER_ISSUER, GITOPS_REPO_URL:
# defaults <- config/homelab.yaml <- environment (see homelab_load_config).

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
ENABLE_HOME_SERVICES="${ENABLE_HOME_SERVICES:-false}"
ENABLE_COMMUNICATION_SERVICES="${ENABLE_COMMUNICATION_SERVICES:-false}"
# Services marked `optin: true` in their service.yaml install only when named here
# (space/comma separated) or when set to "all". `./scripts/services.sh list` shows them.
OPTIN_SERVICES="${OPTIN_SERVICES:-}"

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

    add_helm_repos

    success "Tools installation completed"
}

# Chart repos are not fetched up front: helm_release (scripts/lib/helm.sh)
# adds and updates the one repo a chart needs, so an unreachable repo fails
# only that release and a run with every INSTALL_* Helm toggle off needs no
# repo at all. Kept as a phase name for install_tools and disaster recovery.
add_helm_repos() {
    log "Helm repositories are added per chart at install time (HELM_REPOS in scripts/lib/helm.sh)."
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
        helm_infra_release external-secrets

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
        helm_infra_release traefik
    else
        warning "INSTALL_TRAEFIK=false; skipping Traefik install."
    fi

    if [[ "$INSTALL_CERT_MANAGER" == "true" ]]; then
        helm_infra_release cert-manager

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

    helm_infra_release external-dns

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

    helm_infra_release blackbox-exporter

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

    helm_infra_release kube-prometheus-stack

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

    # Loki, and Promtail when INSTALL_PROMTAIL=true (see kubernetes/services/loki/service.yaml).
    install_service loki
    if [[ "$INSTALL_PROMTAIL" != "true" ]]; then
        warning "INSTALL_PROMTAIL=false; no default log shipper was installed."
        warning "To enable later: INSTALL_LOGGING=true INSTALL_PROMTAIL=true ./setup-v2.sh"
    fi

    # Provision a Loki datasource for Grafana (picked up by kube-prometheus-stack Grafana sidecar).
    if kubectl get namespace monitoring &>/dev/null; then
        kubectl_apply_rendered_file kubernetes/monitoring/grafana/datasources/loki.yaml
    else
        warning "Monitoring namespace not found; skipping Grafana Loki datasource."
    fi

    success "Logging setup completed"
}

setup_core_services() {
    log "Setting up core services..."

    # Authelia (first), Nextcloud (kind: helm), Vaultwarden, Gitea, Homepage
    # (last), plus opt-ins such as Keycloak: all from their descriptors.
    install_service_group core

    success "Core services setup completed"
}

setup_network_services() {
    log "Setting up network services..."

    install_service_group network
    if [[ "$ENABLE_NETWORK_SERVICES" != "true" ]]; then
        return 0
    fi

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

    install_service_group dev
    if [[ "$ENABLE_DEV_SERVICES" == "true" ]]; then
        warning "Drone was installed without a runner (secure default)."
        warning "A Docker-socket runner manifest is preserved on the archive/legacy branch."
    fi

    success "Development services setup completed"
}

setup_content_services() {
    log "Setting up content services..."
    install_service_group content
    success "Content services setup completed"
}

setup_loadbalancer() {
    log "Setting up MetalLB load balancer..."

    if [[ "$INSTALL_METALLB" != "true" ]]; then
        warning "INSTALL_METALLB=false; skipping MetalLB install."
        return 0
    fi

    if grep -q "192\\.168\\.1\\.200-192\\.168\\.1\\.250" kubernetes/loadbalancing/metallb/ipaddresspool.yaml 2>/dev/null; then
        warning "MetalLB IP pool appears to be using the default example range (192.168.1.200-192.168.1.250)."
        warning "Review kubernetes/loadbalancing/metallb/ipaddresspool.yaml before exposing services on your LAN."
    fi

    helm_infra_release metallb

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

    # Create namespace
    kubectl_apply_rendered_file kubernetes/backup/velero/namespace.yaml

    # Credentials are sourced from the central `secrets` namespace via ESO.
    kubectl_apply_rendered_file kubernetes/backup/velero/external-secrets.yaml

    helm_infra_release velero

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
    kubectl_apply_rendered_file kubernetes/security/network-policies/egress-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/database-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/sensitive-services-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/infrastructure-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/media-services-policies.yaml
    kubectl_apply_rendered_file kubernetes/security/network-policies/cross-namespace-policies.yaml

    success "Network policies setup completed"
}

# kubectl_apply_rendered_file_existing_ns <file>: like kubectl_apply_rendered_file,
# but documents whose namespace does not exist yet are skipped with a warning
# (a disabled Helm release or service group never created it). Render mode
# applies everything.
kubectl_apply_rendered_file_existing_ns() {
    local file="$1"
    if [[ "$HOMELAB_APPLY_MODE" == "render" ]]; then
        kubectl_apply_rendered_file "$file"
        return 0
    fi
    local existing ns present="" missing=()
    existing=" $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}') "
    for ns in $(render_file "$file" | yq -r '.metadata.namespace // ""' | sort -u); do
        [[ "$ns" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || continue   # drops yq's --- separators
        if [[ "$existing" == *" $ns "* ]]; then
            present+="${present:+|}$ns"
        else
            missing+=("$ns")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warning "$file: skipping documents for namespaces that do not exist: ${missing[*]}"
        warning "Re-run ./setup-v2.sh after enabling the toggles that create them."
    fi
    if [[ -z "$present" ]]; then
        warning "$file: nothing to apply yet"
        return 0
    fi
    render_file "$file" | yq "select(.metadata.namespace | test(\"^($present)\$\"))" | \
        apply_stream "$(_render_label "$file")"
}

setup_pod_disruption_budgets() {
    log "Setting up PodDisruptionBudgets for critical services..."

    # Targets infrastructure and service namespaces; those a disabled toggle
    # never created are skipped (see kubectl_apply_rendered_file_existing_ns).
    kubectl_apply_rendered_file_existing_ns kubernetes/security/pod-disruption-budgets.yaml

    success "PodDisruptionBudgets setup completed"
}

setup_resource_quotas() {
    log "Setting up ResourceQuotas for namespace resource limits..."

    kubectl_apply_rendered_file_existing_ns kubernetes/security/resource-quotas.yaml

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

    helm_infra_release kyverno

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

setup_media_services() {
    log "Setting up media services..."
    install_service_group media
    success "Media services setup completed"
}

setup_ai_services() {
    log "Setting up AI services..."
    install_service_group ai
    success "AI services setup completed"
}

setup_productivity_services() {
    log "Setting up productivity services..."
    install_service_group productivity
    success "Productivity services setup completed"
}

setup_home_services() {
    log "Setting up home automation services..."
    install_service_group home
    success "Home automation services setup completed"
}

setup_communication_services() {
    log "Setting up communication services..."
    install_service_group communication
    success "Communication services setup completed"
}

setup_monitoring_apps() {
    # Opt-in services that live next to the monitoring stack (e.g. Gatus).
    install_service_group monitoring
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
    # One health interface for every caller (scripts/lib/health.sh): every
    # enabled infrastructure piece and catalogue service, from the same lists
    # the installer used.
    log "Running health checks..."
    services_report_failures || true
    health_report --all --enabled-only || \
        warning "Some pieces are not ready yet (see the table above); re-run ./scripts/validate-setup.sh later."
}

get_access_info() {
    log "Retrieving access information..."
    echo ""
    echo "🎉 Homelab setup completed successfully!"
    echo ""
    access_summary
    echo ""
    echo "🔧 Management commands:"
    echo "   Health:  ./scripts/validate-setup.sh"
    echo "   Logs:    kubectl logs -f deployment/<service> -n <namespace>"
    echo "   Backups: velero schedule get && velero backup get"
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

    # Secure backup directory permissions (dirs must stay traversable)
    find "$backup_dir" -mindepth 1 -type d -exec chmod 700 {} +
    find "$backup_dir" -type f -exec chmod 600 {} +
    chmod 700 "$backup_dir"

    log "Configuration backup created: $backup_dir"
}

main() {
    log "Starting enhanced homelab setup (v2.0)..."
    cd "$HOMELAB_DIR"

    check_requirements
    install_tools

    homelab_load_config

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
    log "  Service groups: media=$ENABLE_MEDIA_SERVICES network=$ENABLE_NETWORK_SERVICES dev=$ENABLE_DEV_SERVICES content=$ENABLE_CONTENT_SERVICES ai=$ENABLE_AI_SERVICES productivity=$ENABLE_PRODUCTIVITY_SERVICES home=$ENABLE_HOME_SERVICES communication=$ENABLE_COMMUNICATION_SERVICES"
    log "  Opt-in services: ${OPTIN_SERVICES:-none}"

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
    setup_pod_disruption_budgets
    setup_resource_quotas
    setup_policy_as_code
    setup_monitoring
    setup_logging

    # Applications: every kubernetes/services/<name>/service.yaml, by group.
    setup_core_services
    setup_media_services
    setup_network_services
    setup_development_services
    setup_content_services
    setup_ai_services
    setup_productivity_services
    setup_home_services
    setup_communication_services
    setup_monitoring_apps

    # Static NetworkPolicies target service namespaces, so they come after the
    # services that create those namespaces. Per-namespace isolation was
    # already applied by install_service from each descriptor.
    setup_network_policies

    setup_gitops
    run_health_checks
    backup_configuration
    get_access_info

    success "Enhanced homelab setup completed successfully!"
    log "Total setup time: $SECONDS seconds"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
