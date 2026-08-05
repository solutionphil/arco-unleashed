#!/bin/sh
# prepare_unleashed_self_flash.sh — bootstrap the eMMC self-flash tool on a printer that has NO kit yet
# (e.g. a stock Buster Arco). Finds unleashed-selfflash.tar.gz (next to this script or on the USB stick),
# unpacks it to ~/selfflash, normalizes line endings + exec bits, and prints the next command. No git
# clone, no kit required — everything comes from the USB stick.
#
#   Usage:  sh prepare_unleashed_self_flash.sh
set -u
TARBALL=unleashed-selfflash.tar.gz
DEST="$HOME/selfflash"
SELFDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

find_tarball() {
  for d in "$SELFDIR" . "$HOME/printer_data/gcodes/USB" /home/*/printer_data/gcodes/USB /media/* /mnt/* /run/media/*/*; do
    [ -f "$d/$TARBALL" ] && { echo "$d/$TARBALL"; return 0; }
  done
  return 1
}

TB=$(find_tarball) || {
  echo "ERROR: $TARBALL not found."
  echo "       Put it next to this script (or on the USB stick) and re-run."
  exit 1
}
echo "Found self-flash package: $TB"

rm -rf "$DEST"; mkdir -p "$DEST"
tar xzf "$TB" -C "$DEST" || { echo "ERROR: could not extract $TB"; exit 1; }

# The target is Linux — guard against CRLF if the stick round-tripped through Windows, and restore +x.
find "$DEST" -type f \( -name '*.sh' -o -name 'arco-emmc-flash' -o -name '*.hook' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$DEST/install-unleashed.sh" "$DEST/initramfs/arco-emmc-flash" "$DEST/initramfs/arco-emmc-flash.hook" 2>/dev/null || true

[ -f "$DEST/install-unleashed.sh" ] || { echo "ERROR: install-unleashed.sh missing after extract — bad package?"; exit 1; }

echo ""
echo "Ready. The self-flash tool is unpacked to: $DEST"
echo ""
echo "  Next — inspect first (no changes):"
echo "    sudo bash $DEST/install-unleashed.sh"
echo ""
echo "  Then, when you're ready to flash:"
echo "    sudo bash $DEST/install-unleashed.sh --arm"
echo ""
echo "  (The image and arco-phrozen-ams.tar.gz must be on the same USB stick. Phrozen's"
echo "   Arco_FW_V*.zip is optional — add it only if the printer will have no internet"
echo "   during setup, or you want PhrozenGo.)"
