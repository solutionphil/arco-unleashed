#!/bin/bash
# optimize-fs.sh — cut eMMC writes/wear: mount the rootfs with 'noatime'.
# atime (the "last read" timestamp) is a write-on-every-read. Nothing on a Klipper host
# needs it — Klipper, Moonraker, Mainsail and voronFDM never read atime. 'relatime' (the
# default) already trims most of it; 'noatime' removes the rest. Pairs with the commit=120
# write-batching that's already on the root mount.
# Idempotent + UUID-agnostic: matches the '/' ext4 entry, never a specific UUID.
set -uo pipefail
FSTAB=/etc/fstab

if awk '$1!~/^#/ && $2=="/" && $3=="ext4" && $4 ~ /(^|,)noatime(,|$)/{f=1} END{exit !f}' "$FSTAB"; then
  echo "  rootfs already mounts noatime (fstab) — nothing to change"
else
  cp "$FSTAB" "$FSTAB.arco-bak"
  awk '$1!~/^#/ && $2=="/" && $3=="ext4" && $4 !~ /(^|,)noatime(,|$)/{$4="noatime," $4} {print}' \
      "$FSTAB" > "$FSTAB.tmp" && mv "$FSTAB.tmp" "$FSTAB"
  echo "  added noatime to the / entry (backup: $FSTAB.arco-bak)"
fi
grep -E '[[:space:]]/[[:space:]]+ext4[[:space:]]' "$FSTAB" | sed 's/^/    /'
mount -o remount,noatime / 2>/dev/null && echo "  applied live (remounted / noatime)" \
  || echo "  (live remount skipped — applies next boot)"
