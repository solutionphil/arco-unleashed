#!/bin/bash
# install-usb-automount.sh — install the Arco Unleashed USB automount.
#
# Drops a udev rule + systemd template unit + mount helper so an inserted USB stick is
# mounted at ~mks/printer_data/gcodes/USB, where the Phrozen display (voronFDM) looks for
# <USB>/phrozen_dev firmware updates. The stock Buster OS provided this automount; the
# armbian-mkspi migration does not, which is why an inserted stick was never detected.
#
# Run as root. Idempotent — safe to re-run.
set -e
src=$(cd "$(dirname "$0")" && pwd)

install -Dm755 "$src/arco-usb-mount"              /usr/local/bin/arco-usb-mount
install -Dm644 "$src/arco-usb-mount@.service"     /etc/systemd/system/arco-usb-mount@.service
install -Dm644 "$src/99-arco-usb-automount.rules" /etc/udev/rules.d/99-arco-usb-automount.rules

systemctl daemon-reload
udevadm control --reload-rules
echo "arco-usb-automount installed."

# Pick up a stick that is already inserted, so the user need not re-plug after install.
dev=$(lsblk -lno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}' | grep -vE 'mmcblk|zram' | head -1)
if [ -n "$dev" ]; then
  umount /home/mks/printer_data/gcodes/USB 2>/dev/null || true
  udevadm trigger --action=add --sysname-match="$dev"
  udevadm settle
  echo "triggered already-inserted /dev/$dev"
fi
