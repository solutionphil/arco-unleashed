#!/bin/bash
# apply-test-print.sh — keep the printer's built-in test prints OURS, and keep them that way.
#
# WHY. Phrozen ship two demo prints, and neither is cut for the machine it ends up on:
#   FDM_TEST.gcode        a 3DBenchy on their own demo profile
#   Chroma_Kit_TEST.gcode the same boat in four colour bands, sliced with an *Anycubic Kobra S1*
#                         print profile -- a foreign printer entirely
# So the first thing a new owner prints tells them nothing about their own printer. Ours are the same
# models sliced for the profile this kit actually ships, and the four-colour one keeps Phrozen's band
# layers (26 / 82 / 170) so it still demonstrates exactly what it was meant to demonstrate.
#
# WHY A GUARD AND NOT A ONE-OFF COPY. Each file has two homes and Phrozen own both of them:
#   phrozen_dev/serial-screen/<name>   the SOURCE, replaced by every Phrozen firmware update
#   printer_data/gcodes/<name>         the copy the display and Mainsail actually list
# arco-firstrun seeds the second from the first. So a Phrozen update puts their file back in the source
# and their own update flow re-seeds it -- and a one-time copy at install would be gone with the first
# update, silently. Replacing BOTH means even their re-seed copies ours.
#
# State-based on purpose, not event-based: it asks "is the deployed file ours?" rather than trying to
# hook every path that could have changed it. That covers the initial install, Phrozen updates, a manual
# re-install, and whatever route nobody has thought of yet. Runs from klipper's ExecStartPre, so it heals
# before the display can list a stale file.
#
# Driven by the CONTENTS of assets/test-print/, not by a hard-coded list: adding a third test print is
# then a matter of dropping the file in, with no second place to remember.
#
# Quiet when there is nothing to do -- this runs before every single Klipper start.
set -uo pipefail

KITDIR="$(cd "$(dirname "$0")/.." && pwd)"
AHOME="$(dirname "$KITDIR")"
AUSER="$(stat -c%U "$KITDIR" 2>/dev/null || echo mks)"

SRCDIR="$KITDIR/assets/test-print"
GD="$AHOME/printer_data/gcodes"
SS="$AHOME/klipper/klippy/extras/phrozen_dev/serial-screen"

installed=""
for src in "$SRCDIR"/*.gcode; do
  [ -f "$src" ] || continue                  # kit without the assets: nothing to enforce, not an error
  name="$(basename "$src")"
  changed=0
  for dst in "$GD/$name" "$SS/$name"; do
    d="$(dirname "$dst")"
    [ -d "$d" ] || continue                  # phrozen_dev absent (pre-USB-install printer) -> skip that home
    cmp -s "$src" "$dst" && continue         # already ours
    install -o "$AUSER" -g "$AUSER" -m 644 "$src" "$dst" 2>/dev/null || continue
    changed=1
  done
  # Moonraker caches a rendered preview per file under .thumbs and keys it by NAME, not by content -- so a
  # replaced test print would keep showing Phrozen's boat on the panel and in Mainsail. Dropping the cached
  # images makes Moonraker re-extract the one embedded in our file (240x224) on the next scan.
  if [ "$changed" = 1 ]; then
    rm -f "$GD/.thumbs/${name%.gcode}"-*.png 2>/dev/null || true
    installed="$installed $name"
  fi
done

[ -n "$installed" ] && echo "[test-print] installed the kit's:$installed (Phrozen's were in place)"
exit 0
