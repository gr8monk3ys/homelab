---
status: accepted
date: 2026-11-14
amends: 0012
---

# The Immich library on the SSD; ufw rules for K3s

## Context

ADR 0012 put the Immich library on the RAID next to the media. The RAID is
Intel firmware RAID 5 (IMSM through mdadm) on three ST2000DM006 disks with
12–13k hours, formatted NTFS and mounted with ntfs3: no POSIX owners, no
Linux fsck, and a ~4 TB rebuild on consumer disks if one fails. Media can be
downloaded again; photos cannot. The existing library is 108 MB, and the SSD
(btrfs inside LUKS, snapshotted by snapper) has 299 GB free.

Omarchy enables ufw with INPUT and FORWARD policies of DROP. K3s pods reach
the API server and CoreDNS through the host, and servicelb DNATs host ports
80/443/53 to pods; ufw drops both, so the cluster cannot come up as written.

## Decision

- `PHOTOS_PATH=/var/lib/homelab/immich` on the SSD holds the Immich library
  (`apps/photos/immich-library.yaml`). `host/setup.sh` creates it (1000:1000)
  and copies the RAID library into it once; the RAID copy stays until B2
  holds a backup of the new one. VolSync to B2 is unchanged.
- `host/setup.sh` adds the ufw rules from the K3s docs (allow from
  10.42.0.0/16 and 10.43.0.0/16) and routed rules: pod egress, and forwarding
  into pods only from private networks (RFC 1918 and Tailscale's 100.64/10).
- The RAID keeps media and downloads, and stays NTFS. Reformatting it means
  moving 2.7 TB of personal files off first; that is the owner's decision.

## Consequences

- Photos outgrowing ~250 GB means a bigger SSD or a new disk, not the RAID.
- Losing the SSD now also loses the local photo library: restore it from B2
  (`./hack/restore.sh photos immich`).
