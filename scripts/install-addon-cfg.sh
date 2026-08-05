#!/bin/bash
# install-addon-cfg.sh — seed AddOn.cfg from the kit template.
# Usage:  bash install-addon-cfg.sh [target]     (default: ~/printer_data/config/AddOn.cfg)
#
# AddOn.cfg holds the user's own tweaks, so an existing file is NEVER overwritten -- this
# only ever creates a missing one. Until this existed the template was dead weight: nothing
# in the kit ever deployed it, and AddOn.cfg reached recipients solely because the image is
# cloned from a printer that happened to have one. A base-image or manual install got the
# include from addon-toggle.sh pointing at a file that was never there -> klipper refuses to
# start with "Unable to open include file".
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/../config-templates/AddOn.cfg.template"
DST="${1:-$HOME/printer_data/config/AddOn.cfg}"

[ -f "$SRC" ] || { echo "ERROR: template missing: $SRC"; exit 1; }

if [ -f "$DST" ]; then
  echo "AddOn.cfg: already present, kept as-is -> $DST"
  exit 0
fi

mkdir -p "$(dirname "$DST")" || { echo "ERROR: cannot create $(dirname "$DST")"; exit 1; }
cp "$SRC" "$DST" || { echo "ERROR: cannot write $DST"; exit 1; }
# running as root (image build / sudo) must not leave a root-owned config behind: klipper
# and moonraker both write here as mks.
[ "$(id -u)" = 0 ] && chown 1000:1000 "$DST" 2>/dev/null || true
echo "AddOn.cfg: installed from template -> $DST"
echo "  enable it with:  bash addon-toggle.sh on"
