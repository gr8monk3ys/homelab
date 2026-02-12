# Network Policies

This directory contains Kubernetes NetworkPolicies for securing pod-to-pod communication.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Internet                                │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│               Traefik Ingress (kube-system)                  │
└─────────────────────────┬───────────────────────────────────┘
                          │ (allowed by ingress-allow policy)
┌─────────────────────────▼───────────────────────────────────┐
│                    Service Namespaces                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │ vaultwarden │  │  nextcloud  │  │   gitea     │   ...    │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘          │
│         │                │                │                  │
│         └────────────────┼────────────────┘                  │
│                          │ (allowed by database policies)    │
│                    ┌─────▼─────┐                             │
│                    │ Databases │                             │
│                    └───────────┘                             │
└─────────────────────────────────────────────────────────────┘
```

## Policies

### Base Policies (apply to all namespaces)

- `default-deny.yaml` - Denies all ingress/egress by default
- `allow-dns.yaml` - Allows DNS resolution (kube-dns)
- `allow-ingress.yaml` - Allows traffic from Traefik ingress
- `allow-monitoring.yaml` - Allows Prometheus scraping

### Service-Specific Policies

- `allow-database.yaml` - Allows apps to connect to their databases
- `allow-redis.yaml` - Allows apps to connect to Redis instances

## Usage

### Apply base policies to a namespace

```bash
# Apply default deny
kubectl apply -f default-deny.yaml -n <namespace>

# Apply common allows
kubectl apply -f allow-dns.yaml -n <namespace>
kubectl apply -f allow-ingress.yaml -n <namespace>
kubectl apply -f allow-monitoring.yaml -n <namespace>
```

### Apply to all service namespaces

```bash
./apply-network-policies.sh
```

## Testing

Verify policies are working:

```bash
# Test DNS resolution works
kubectl run test --rm -it --image=busybox -n <namespace> -- nslookup kubernetes

# Test ingress works
curl https://<service>.homelab.local

# Test database access (should work from app, fail from other namespaces)
kubectl run test --rm -it --image=postgres:15 -n <other-namespace> -- \
  psql -h <db-service>.<db-namespace> -U postgres
```

## Important Notes

1. **Order matters**: Apply default-deny first, then allow policies
2. **DNS is critical**: Always apply allow-dns or pods can't resolve services
3. **Monitoring**: Apply allow-monitoring or Prometheus can't scrape metrics
4. **Debugging**: Use `kubectl describe networkpolicy -n <namespace>` to verify
