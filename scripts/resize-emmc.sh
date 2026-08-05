#!/bin/bash
# resize-emmc.sh — grow the root filesystem to fill the whole eMMC.
# Needed after writing a SHRUNK image to a larger/different card (the rootfs stays small
# otherwise). Safe to run anytime: if it's already at full size, it just reports "nothing to do".
set -e

# detect root device + partition automatically
ROOTPART=$(findmnt -no SOURCE /)               # e.g. /dev/mmcblk1p2
DISK="/dev/$(lsblk -no PKNAME "$ROOTPART")"    # e.g. /dev/mmcblk1
PARTNUM=$(echo "$ROOTPART" | grep -oE '[0-9]+$')

echo "root fs:   $ROOTPART"
echo "disk:      $DISK   (partition $PARTNUM)"
echo "before:"; df -h / | tail -1
echo

# growpart comes from cloud-guest-utils
command -v growpart >/dev/null 2>&1 || sudo apt install -y cloud-guest-utils

echo ">> growing partition..."
sudo growpart "$DISK" "$PARTNUM" || echo "  (growpart: already at max / nothing to do)"
echo ">> resizing filesystem..."
sudo resize2fs "$ROOTPART"

echo
echo "after:"; df -h / | tail -1
echo "Done."
