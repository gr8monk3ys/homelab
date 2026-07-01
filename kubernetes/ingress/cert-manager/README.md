# cert-manager Issuers

This directory contains `ClusterIssuer` resources for two common homelab setups:

- `homelab-ca`: Local CA (recommended default for `*.local` / RFC1918-only labs). You must trust the generated root CA on your devices.
- `letsencrypt-staging` / `letsencrypt-prod`: ACME HTTP-01 issuers for publicly reachable domains.

Notes:
- Let's Encrypt will not issue certificates for `.local` domains.
- If you're using the local CA: export the root CA from the `cert-manager` namespace:
  - `kubectl get secret -n cert-manager homelab-root-ca -o jsonpath='{.data.tls\\.crt}' | base64 -d > homelab-root-ca.crt`
