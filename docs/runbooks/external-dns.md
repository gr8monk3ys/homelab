# ExternalDNS (Cloudflare)

ExternalDNS can automatically create and update DNS records for your Ingress/Service hostnames.

This is **optional** and requires a real DNS zone. It will not work for `.local` domains.

## Enable

1. Create a Cloudflare API token with DNS edit permissions for your zone.

2. Store it in the central `secrets` namespace:

```bash
kubectl -n secrets create secret generic cloudflare-api-token \
  --from-literal=token='CF_API_TOKEN_VALUE' \
  --dry-run=client -o yaml | kubectl apply -f -
```

3. Re-run setup with ExternalDNS enabled:

```bash
INSTALL_EXTERNAL_DNS=true ./setup-v2.sh
```

## Verify

```bash
kubectl -n external-dns get deploy,pods
kubectl -n external-dns logs deploy/external-dns --tail=200
```

## Notes

- Configuration: `kubernetes/dns/external-dns/values.yaml`
- Safety default: `policy: upsert-only` (won't delete unmanaged records)
