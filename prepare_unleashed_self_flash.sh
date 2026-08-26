#!/bin/sh
# prepare_unleashed_self_flash.sh — bootstrap the eMMC self-flash tool on a printer that has NO kit yet
# (e.g. a stock Buster Arco). Finds unleashed-selfflash.tar.gz (next to this script or on the USB stick),
# unpacks it to ~/selfflash, normalizes line endings + exec bits, and prints the next command. No git
# clone, no kit required — everything comes from the USB stick.
#
#   Usage:  sh prepare_unleashed_self_flash.sh
set -u
TARBALL=unleashed-selfflash.tar.gz
# $HOME under sudo is ROOT'S home. This script is documented to run WITHOUT sudo, but people add it --
# it is a flashing tool, sudo feels right -- and then it unpacks to /root/selfflash while the very next
# command they run is `sudo bash ~/selfflash/install-unleashed.sh`, where ~ is their own home. On a
# printer that already has an OLD ~/selfflash (any machine restored from an image that carried one)
# that silently runs the OLD tool: on 2026-08-10 it armed a backup with a version that had never heard
# of splitting, and the only sign was two missing lines in a config file nobody normally reads.
# So: always the invoking user's home, and say which one, because "unpacked to ~/selfflash" is exactly
# the sentence that gets skimmed.
ARCO_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  _h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$_h" ] && ARCO_HOME="$_h"
fi
DEST="$ARCO_HOME/selfflash"
SELFDIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

find_tarball() {
  for d in "$SELFDIR" . "$ARCO_HOME/printer_data/gcodes/USB" /home/*/printer_data/gcodes/USB /media/* /mnt/* /run/media/*/*; do
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
# Unpacked under sudo, the tree would belong to root inside the owner's home. Harmless for the flash
# itself, awkward for everything afterwards.
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$DEST" 2>/dev/null || true

[ -f "$DEST/install-unleashed.sh" ] || { echo "ERROR: install-unleashed.sh missing after extract — bad package?"; exit 1; }

echo ""
echo "Ready. The self-flash tool is unpacked to: $DEST"
echo ""
echo "  Next:"
echo "    sudo bash $DEST/install-unleashed.sh"
echo ""
echo "  That one command now offers a menu — check, back up, install, or cancel"
echo "  something already armed. The old flags still work."
echo ""
echo "  (The image must be on the USB stick. arco-phrozen-ams.tar.gz is collected"
echo "   for you if it is not there yet. Phrozen's Arco_FW_V*.zip is optional —"
echo "   add it only if the printer will have no internet during setup, or you"
echo "   want PhrozenGo.)"
echo ""

# Offer to go straight on, so the guide is one command instead of two. Chained with the ABSOLUTE path,
# never ~: this script deliberately runs WITHOUT sudo (see the note at the top about $HOME under sudo),
# and "sudo bash ~/selfflash/..." from here would resolve ~ to root's home and could start an OLD tool
# — the failure of 2026-08-10, met from the other direction.
#
# Offered, never assumed, and it defaults to no. A script that starts a flashing tool on its own would
# be the wrong kind of helpful.
if [ -t 0 ] && [ -t 1 ]; then
  printf "Start it now? [y/N] "
  read -r _a || _a=""
  case "$_a" in
    y|Y|yes|YES) echo ""; exec sudo bash "$DEST/install-unleashed.sh" ;;
    *)           echo "Not started — run the command above when you are ready." ;;
  esac
fi
