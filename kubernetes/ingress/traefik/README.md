# Traefik (Ingress Controller)

This repo installs Traefik via the official Helm chart (recommended). The legacy, manifest-based deployment is preserved under `legacy/`.

## Install (Helm)

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update

helm upgrade --install traefik traefik/traefik \
  --namespace traefik-system \
  --create-namespace \
  --values kubernetes/ingress/traefik/values.yaml \
  --wait
```

## Notes

- Traefik CRDs are required for `Middleware` and other `traefik.io/*` resources used by this repo.
- `values.yaml` loads one plugin, the CrowdSec bouncer (`experimental.plugins.bouncer`). Traefik downloads it from plugins.traefik.io at every start, so the pod needs outbound HTTPS. Its settings live in the `crowdsec-bouncer` Middleware (`kubernetes/security/crowdsec/deployment.yaml`), which the `websecure` entrypoint applies to every request. If the plugin cannot load, that middleware cannot be built and HTTPS routes are not served.
- If you already have an ingress controller installed, you can skip Traefik and set `ingressClassName` / annotations accordingly.
