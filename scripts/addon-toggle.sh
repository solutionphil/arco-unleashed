#!/bin/bash
# addon-toggle.sh — enable/disable your AddOn.cfg (custom optimizations) in printer.cfg.
# Toggles the `[include AddOn.cfg]` line. AddOn.cfg = your own tweaks (github solutionphil).
# Usage:  bash addon-toggle.sh on|off|status
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/printer_data/config/printer.cfg"
ADDON="$HOME/printer_data/config/AddOn.cfg"
[ -f "$CFG" ] || { echo "ERROR: $CFG not found"; exit 1; }

present(){ grep -qE '^[[:space:]]*#?[[:space:]]*\[include AddOn\.cfg\]' "$CFG"; }
state(){
  if grep -qE '^[[:space:]]*\[include AddOn\.cfg\]' "$CFG"; then echo ON
  elif grep -qE '^[[:space:]]*#[[:space:]]*\[include AddOn\.cfg\]' "$CFG"; then echo OFF
  else echo MISSING; fi
}

case "${1:-status}" in
  on)
    # An include is only safe once the file behind it exists -- klipper refuses to start on a
    # missing include, and this is the only place that writes it. Seed it before, not after.
    if [ ! -f "$ADDON" ]; then
      bash "$DIR/install-addon-cfg.sh" "$ADDON" || {
        echo "ERROR: AddOn.cfg is missing and could not be seeded -- refusing to add an include"
        echo "       to a file that does not exist (klipper would not start). printer.cfg untouched."
        exit 1; }
    fi
    if present; then
      sed -i 's|^\([[:space:]]*\)#[[:space:]]*\(\[include AddOn\.cfg\]\)|\1\2|' "$CFG"
    elif grep -qE '^\[include printer_gcode_macro\.cfg\]' "$CFG"; then
      sed -i '/^\[include printer_gcode_macro\.cfg\]/a [include AddOn.cfg]' "$CFG"
      echo "  (AddOn.cfg include was missing -> added after printer_gcode_macro.cfg)"
    else
      sed -i '1a [include AddOn.cfg]' "$CFG"
      echo "  (AddOn.cfg include was missing -> added near top)"
    fi
    echo "AddOn.cfg: ON"
    ;;
  off)
    sed -i 's|^\([[:space:]]*\)\(\[include AddOn\.cfg\]\)|\1# \2|' "$CFG"
    echo "AddOn.cfg: OFF"
    ;;
  status) echo "AddOn.cfg: $(state)";;
  *) echo "Usage: bash addon-toggle.sh on|off|status"; exit 1;;
esac

[ "${1:-}" = status ] || echo "Run RESTART in Mainsail (or: sudo systemctl restart klipper) to apply."
