#!/bin/bash
# usb-fw.sh — locate Phrozen's official Arco_FW_V*.zip on a user-provided USB stick (FAT32).
#
# Arco Unleashed NEVER downloads Phrozen's software. The user obtains Phrozen's official firmware
# package themselves and copies it onto a FAT32 USB stick; we only read that local file.
#
# Sourced by arco-firstrun (runs as root) and fetch-phrozen-fw (manual runs, uses sudo).
# Provides:  find_fw_zip   -> echoes the zip path (leaving the stick mounted at $USB_MNT), or returns 1
#            cleanup_fw_mount -> unmounts $USB_MNT
USB_MNT="${USB_MNT:-/mnt/arco-usb}"
# Where OUR OWN udev automount puts sticks (Moonraker's gcodes dir, so the display can browse them).
GCODE_USB="${GCODE_USB:-/home/mks/printer_data/gcodes/USB}"

_usb_sudo(){ if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

find_fw_zip(){
  local z d dev mp
  # 1) Already-mounted media. $GCODE_USB comes FIRST because our own automount claims the stick there
  # before firstrun ever looks; leaving it out made firstrun poll forever for a stick that was mounted
  # all along, right under its nose.
  for d in "$GCODE_USB" "$GCODE_USB"* /media/*/* /media/* /run/media/*/* /mnt/usb "$USB_MNT"; do
    [ -d "$d" ] || continue
    z=$(ls "$d"/Arco_FW_V*.zip 2>/dev/null | head -1) || true
    [ -n "$z" ] && { echo "$z"; return 0; }
  done
  # 2) Mount candidate USB partitions ourselves (read-only). Skip the eMMC (mmcblk*).
  _usb_sudo mkdir -p "$USB_MNT"
  _usb_sudo umount "$USB_MNT" 2>/dev/null || true
  for dev in $(lsblk -rno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}' | grep -vE '^mmcblk'); do
    # A partition that is already mounted somewhere cannot simply be mounted again here ("already mounted
    # on ..."), so search wherever it actually lives instead of failing on it.
    mp=$(findmnt -nro TARGET --source "/dev/$dev" 2>/dev/null | head -1)
    if [ -n "$mp" ]; then
      z=$(ls "$mp"/Arco_FW_V*.zip 2>/dev/null | head -1) || true
      [ -n "$z" ] && { echo "$z"; return 0; }
      continue
    fi
    _usb_sudo mount -o ro "/dev/$dev" "$USB_MNT" 2>/dev/null || continue
    z=$(ls "$USB_MNT"/Arco_FW_V*.zip 2>/dev/null | head -1) || true
    if [ -n "$z" ]; then echo "$z"; return 0; fi
    _usb_sudo umount "$USB_MNT" 2>/dev/null || true
  done
  return 1
}

# Only ever unmounts OUR temporary mount — never the automount's, which the user's display relies on.
cleanup_fw_mount(){ _usb_sudo umount "$USB_MNT" 2>/dev/null || true; }
