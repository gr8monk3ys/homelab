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
- If you already have an ingress controller installed, you can skip Traefik and set `ingressClassName` / annotations accordingly.
