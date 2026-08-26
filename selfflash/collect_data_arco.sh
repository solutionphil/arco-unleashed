#!/bin/bash
# collect_data_arco.sh — collect the irreplaceable Phrozen Arco files BEFORE you reflash the eMMC.
# Gathers the AMS-server files (phrozen_master + phrozen_slave_ota + device_table + ~/hdlDat) that live
# ONLY in the original Arco base OS — they are NOT inside any downloadable Arco_FW_V*.zip, so once the
# eMMC is reflashed they are gone for good. Run this on the RUNNING original Phrozen Arco first.
#
# Writes a tarball onto YOUR USB stick. This is YOUR own licensed copy: it stays with you and is
# re-installed on your new system by fetch-phrozen-fw.sh / arco-firstrun. It is NOT part of the
# shareable kit — nothing proprietary is ever shared. (A tarball preserves the executable bit, which
# a FAT32 stick would otherwise drop, so phrozen_master stays runnable.)
#
# If the given output dir is NOT actually a mounted USB stick (e.g. the auto-mount didn't fire and it
# would write to internal eMMC), the script finds your stick, mounts it, writes, syncs and unmounts it.
#
# Usage:  bash collect_data_arco.sh ~/printer_data/gcodes/USB      # or any path on your stick
set -e
OUT="${1:?Usage: bash collect_data_arco.sh /path/to/usb-or-output-dir}"
FRP="$HOME/klipper/klippy/extras/phrozen_dev/frp-oms"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/frp-oms" "$STAGE/hdlDat"

echo "=== Collecting the Phrozen AMS-server files (not in Arco_FW_V*.zip) ==="
miss=0
for f in phrozen_master phrozen_slave_ota; do
  if [ -f "$FRP/$f" ]; then cp -v "$FRP/$f" "$STAGE/frp-oms/"
  else echo "  MISSING: $FRP/$f"; [ "$f" = phrozen_master ] && miss=1; fi
done
[ -d "$FRP/device_table" ] && cp -rv "$FRP/device_table" "$STAGE/frp-oms/" || echo "  (device_table absent — ok)"
if [ -d "$HOME/hdlDat" ] && [ -n "$(ls -A "$HOME/hdlDat" 2>/dev/null)" ]; then
  cp -av "$HOME/hdlDat/." "$STAGE/hdlDat/"
else echo "  MISSING: ~/hdlDat"; miss=1; fi

if [ "$miss" = 1 ]; then
  echo ""
  echo "ERROR: phrozen_master and/or ~/hdlDat not found. Run this on the"
  echo "ORIGINAL Arco — these files are not on the new base image."; exit 1
fi

# --- Make sure we write to a REAL USB stick, not the internal eMMC. If $OUT isn't backed by a USB
# device, auto-find the stick (sdX on this board; the eMMC is mmcblk) and mount it. ---
MOUNTED_HERE=""
backing="$(findmnt -no SOURCE --target "$OUT" 2>/dev/null || true)"
if [ -z "$backing" ] || echo "$backing" | grep -qE 'mmcblk|zram|/dev/root|overlay'; then
  echo ""
  echo ">> $OUT is on the eMMC, not a USB stick — looking for your stick..."
  cand="$(lsblk -rno NAME,TYPE,MOUNTPOINT 2>/dev/null | awk '$2=="part" && $1 ~ /^sd/ {print $1"|"$3}' | head -1)"
  if [ -z "$cand" ]; then
    echo "ERROR: no USB stick found. Plug a FAT32 stick in and re-run, or"
    echo "       name a mounted path: bash collect_data_arco.sh /path/to/stick"
    exit 1
  fi
  dev="/dev/${cand%%|*}"; mp="${cand#*|}"
  if [ -n "$mp" ]; then
    echo "   $dev is already mounted at $mp — writing there."
    OUT="$mp"
  else
    echo "   $dev found (not mounted) — mounting it (sudo)..."
    sudo mkdir -p "$OUT"
    if sudo mount "$dev" "$OUT"; then MOUNTED_HERE="$OUT"; echo "   mounted $dev at $OUT"
    else echo "ERROR: could not mount $dev. Mount it yourself:  sudo mount $dev $OUT"; exit 1; fi
  fi
fi

mkdir -p "$OUT"
TARBALL="$OUT/arco-phrozen-ams.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" frp-oms hdlDat
sync   # flush the write cache so the tarball is physically on the stick (don't lose it on unplug)
echo ""
echo "=== Done: $TARBALL ==="
tar -tzf "$TARBALL" | sed 's/^/  /'
echo ""
[ -n "$MOUNTED_HERE" ] && sudo umount "$MOUNTED_HERE" 2>/dev/null || true   # if we mounted it, unmount it
if [ -n "${ARCO_COLLECT_EMBEDDED:-}" ]; then
  # Called from install-unleashed.sh, which is about to flash this printer. The standalone advice below
  # -- take the stick to your PC and check the file is really on it -- is wrong here: the stick stays
  # in, and the caller verifies this tarball itself before it arms anything.
  echo ">> Synced. The installer verifies this file before it arms the flash."
else
  echo ">> Synced. Now plug the stick into your PC and CHECK that"
  echo "   arco-phrozen-ams.tar.gz is really on it."
  echo "   If it is missing, re-insert it here and run this again."
fi
echo "Keep this stick. The Unleashed image re-installs the files on first boot."
echo "This file is PRIVATE — your own licensed copy, not part of the kit."
echo ""
# A tester read "collect data" + "backup" as "my printer is backed up" and only found out otherwise
# after the flash, when there was nothing left to go back to. Say it here, where it cannot be missed.
echo "!! This is NOT a backup of your printer. It saved the files listed"
echo "   above, and nothing else."
echo "   Your calibration, your G-code and Phrozen's own system are ERASED"
echo "   by the flash and cannot be recovered. For a way back, image the"
echo "   whole eMMC first: install-unleashed.sh --backup, BEFORE you flash."
