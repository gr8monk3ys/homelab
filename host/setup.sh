#!/usr/bin/env bash
# Prepare the Arch host and install K3s. Idempotent; run as root:
#   sudo ./host/setup.sh
#
#   1. nvidia-container-toolkit (K3s detects it and adds the nvidia runtime).
#   2. The RAID at /mnt/raid through /etc/fstab (by UUID), instead of the
#      desktop's automount under /run/media, which only exists after login.
#   3. K3s pinned to K3S_VERSION, config from host/k3s-config.yaml, and a
#      systemd drop-in so K3s never starts before the RAID is mounted.
#   4. The kubeconfig copied to the invoking user's ~/.kube/config.
set -euo pipefail

# renovate: datasource=github-releases depName=k3s-io/k3s
K3S_VERSION=v1.37.2+k3s1
RAID_UUID=22A4AE26A4ADFD03
RAID_MOUNT=/mnt/raid

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
owner=${SUDO_USER:?run through sudo, not as root directly}
here=$(cd "$(dirname "$0")" && pwd)

echo "== nvidia-container-toolkit"
pacman -S --needed --noconfirm nvidia-container-toolkit

echo "== RAID at $RAID_MOUNT"
if ! grep -q "UUID=$RAID_UUID" /etc/fstab; then
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  # ntfs3 has no Unix owners: every file is 1000:1000, which is what the pods
  # run as. nofail keeps the desktop booting if the array is missing; K3s
  # then refuses to start (RequiresMountsFor below), which is the point.
  echo "UUID=$RAID_UUID $RAID_MOUNT ntfs3 uid=1000,gid=1000,umask=002,iocharset=utf8,prealloc,nofail,x-systemd.device-timeout=60s 0 0" >>/etc/fstab
  systemctl daemon-reload
fi
mkdir -p "$RAID_MOUNT"
if ! mountpoint -q "$RAID_MOUNT"; then
  # The desktop may have it mounted under /run/media; one mount at a time.
  if auto=$(findmnt -rno TARGET -S "UUID=$RAID_UUID"); then
    echo "unmounting the desktop automount at $auto"
    umount "$auto"
  fi
  mount "$RAID_MOUNT"
fi

echo "== K3s $K3S_VERSION"
install -D -m 0644 "$here/k3s-config.yaml" /etc/rancher/k3s/config.yaml
install -d -m 0755 /etc/systemd/system/k3s.service.d
cat >/etc/systemd/system/k3s.service.d/10-raid.conf <<EOF
[Unit]
RequiresMountsFor=$RAID_MOUNT
EOF
install -d -m 0700 /var/lib/homelab/volumes
if [[ "$(k3s --version 2>/dev/null | head -1)" != *"$K3S_VERSION"* ]]; then
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl -fsSL https://get.k3s.io -o "$installer"
  # The installer checks the binary's sha256 against the release's checksums.
  INSTALL_K3S_VERSION="$K3S_VERSION" sh "$installer"
fi
systemctl daemon-reload
systemctl enable --now k3s

echo "== kubeconfig for $owner"
home=$(getent passwd "$owner" | cut -d: -f6)
install -d -o "$owner" -m 0700 "$home/.kube"
if [[ -f "$home/.kube/config" ]] && ! cmp -s /etc/rancher/k3s/k3s.yaml "$home/.kube/config"; then
  cp -p "$home/.kube/config" "$home/.kube/config.bak.$(date +%Y%m%d%H%M%S)"
fi
install -o "$owner" -m 0600 /etc/rancher/k3s/k3s.yaml "$home/.kube/config"

echo "== checks"
k3s kubectl wait --for=condition=Ready node/homelab --timeout=120s
if grep -q nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml; then
  echo "nvidia runtime: found"
else
  echo "nvidia runtime: NOT found; is nvidia-container-toolkit installed? restart k3s after installing it" >&2
fi
echo "done. Next: ./hack/bootstrap.sh (as $owner, not root)"
