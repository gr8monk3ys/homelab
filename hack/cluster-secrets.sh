#!/usr/bin/env bash
# Create infrastructure/secrets/cluster-secrets.sops.yaml: every secret value
# the cluster substitutes (${B2_KEY_ID} and so on), SOPS-encrypted to the
# age key in .sops.yaml.
#
#   ./hack/cluster-secrets.sh          # prompts for what it cannot generate
#   ./hack/cluster-secrets.sh --keys   # print the key names (hack/validate.sh)
#
# Refuses to overwrite an existing file: a new VOLSYNC_RESTIC_PASSWORD would
# lock every existing backup. Change one value with
#   sops edit infrastructure/secrets/cluster-secrets.sops.yaml
#
# Any key already set in the environment is used as is (non-interactive runs).
set -euo pipefail
cd "$(dirname "$0")/.."

# Generated when not set: random passwords, and a random ntfy.sh topic.
GENERATED=(VOLSYNC_RESTIC_PASSWORD GRAFANA_ADMIN_PASSWORD OPENCLOUD_ADMIN_PASSWORD NTFY_URL)
# Asked for: Backblaze B2 (an application key limited to one bucket) and the
# WireGuard VPN that qBittorrent's traffic leaves through (gluetun settings).
ASKED=(B2_ENDPOINT B2_BUCKET B2_KEY_ID B2_APP_KEY VPN_SERVICE_PROVIDER WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES SERVER_COUNTRIES)

if [[ ${1:-} == --keys ]]; then
  printf '%s\n' "${GENERATED[@]}" "${ASKED[@]}"
  exit 0
fi

out=infrastructure/secrets/cluster-secrets.sops.yaml
[[ -e $out ]] && { echo "$out exists; use: sops edit $out" >&2; exit 1; }
for tool in sops kubectl openssl; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed" >&2; exit 1; }
done

declare -A hint=(
  [B2_ENDPOINT]="B2 S3 endpoint with scheme, e.g. https://s3.us-west-004.backblazeb2.com"
  [B2_BUCKET]="B2 bucket name (private, no lifecycle rule that deletes files)"
  [B2_KEY_ID]="B2 application keyID"
  [B2_APP_KEY]="B2 applicationKey"
  [VPN_SERVICE_PROVIDER]="gluetun provider name, e.g. mullvad, protonvpn, airvpn"
  [WIREGUARD_PRIVATE_KEY]="WireGuard private key from the provider"
  [WIREGUARD_ADDRESSES]="WireGuard interface address, e.g. 10.64.1.2/32"
  [SERVER_COUNTRIES]="gluetun SERVER_COUNTRIES, e.g. Netherlands"
)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
env_file=$tmp/env
: >"$env_file"
chmod 600 "$env_file"

for key in "${GENERATED[@]}"; do
  value=${!key:-}
  if [[ -z $value ]]; then
    case $key in
      NTFY_URL) value="https://ntfy.sh/homelab-$(openssl rand -hex 12)" ;;
      *) value=$(openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-40) ;;
    esac
  fi
  printf '%s=%s\n' "$key" "$value" >>"$env_file"
done
for key in "${ASKED[@]}"; do
  value=${!key:-}
  while [[ -z $value ]]; do
    read -rsp "$key (${hint[$key]}): " value
    echo
  done
  printf '%s=%s\n' "$key" "$value" >>"$env_file"
done

kubectl create secret generic cluster-secrets --namespace flux-system \
  --from-env-file="$env_file" --dry-run=client -o yaml >"$tmp/secret.yaml"
sops --encrypt --filename-override "$out" "$tmp/secret.yaml" >"$out"
echo "wrote $out"
echo "Alerts go to $(grep '^NTFY_URL=' "$env_file" | cut -d= -f2-): subscribe to that topic in the ntfy app."
echo "Grafana: admin / sops -d $out | yq .data.GRAFANA_ADMIN_PASSWORD | base64 -d"
