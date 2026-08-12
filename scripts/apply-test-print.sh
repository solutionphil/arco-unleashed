#!/bin/bash
# apply-test-print.sh — keep the printer's built-in test print OURS, and keep it that way.
#
# WHY. Phrozen ship FDM_TEST.gcode, a 3DBenchy sliced for their own demo profile: 0.25 mm layers at up to
# 300 mm/s with 0.5-0.58 mm extrusion widths. On a printer running this kit it is the wrong yardstick --
# it was cut for a machine configuration that is not the one it now runs on, so the first thing a new
# owner prints tells them nothing useful about their printer. Ours is the same model sliced for the
# profile this kit actually ships.
#
# WHY A GUARD AND NOT A ONE-OFF COPY. The file has two homes and Phrozen own both of them:
#   phrozen_dev/serial-screen/FDM_TEST.gcode   the SOURCE, replaced by every Phrozen firmware update
#   printer_data/gcodes/FDM_TEST.gcode         the copy the display and Mainsail actually list
# arco-firstrun seeds the second from the first. So a Phrozen update puts their file back in the source
# and their own update flow re-seeds it -- and a one-time copy at install would be gone with the first
# update, silently. Replacing BOTH means even their re-seed copies ours.
#
# State-based on purpose, not event-based: it asks "is the deployed file ours?" rather than trying to
# hook every path that could have changed it. That covers the initial install, Phrozen updates, a manual
# re-install, and whatever route nobody has thought of yet. Runs from klipper's ExecStartPre, so it heals
# before the display can list a stale file.
#
# Quiet when there is nothing to do -- this runs before every single Klipper start.
set -uo pipefail

KITDIR="$(cd "$(dirname "$0")/.." && pwd)"
AHOME="$(dirname "$KITDIR")"
AUSER="$(stat -c%U "$KITDIR" 2>/dev/null || echo mks)"

SRC="$KITDIR/assets/test-print/FDM_TEST.gcode"
[ -f "$SRC" ] || exit 0                      # kit without the asset: nothing to enforce, not an error

GD="$AHOME/printer_data/gcodes"
SS="$AHOME/klipper/klippy/extras/phrozen_dev/serial-screen"

changed=0
for dst in "$GD/FDM_TEST.gcode" "$SS/FDM_TEST.gcode"; do
  d="$(dirname "$dst")"
  [ -d "$d" ] || continue                    # phrozen_dev absent (AMS-less / pre-fetch printer) -> skip
  cmp -s "$SRC" "$dst" && continue           # already ours
  install -o "$AUSER" -g "$AUSER" -m 644 "$SRC" "$dst" 2>/dev/null || continue
  changed=1
done

# Moonraker caches a rendered preview per file under .thumbs and keys it by NAME, not by content -- so a
# replaced FDM_TEST.gcode would keep showing Phrozen's boat on the panel and in Mainsail. Dropping the
# cached images makes Moonraker re-extract the one embedded in our file (240x224) on the next scan.
if [ "$changed" = 1 ]; then
  rm -f "$GD/.thumbs/FDM_TEST"-*.png 2>/dev/null || true
  echo "[test-print] installed the kit's FDM_TEST.gcode (Phrozen's was in place)"
fi
exit 0
