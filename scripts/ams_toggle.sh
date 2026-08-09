#!/bin/bash
# ams_toggle.sh — switch the Phrozen Arco AMS ("Chroma Kit") on/off WITHOUT a firmware flash.
#
# AMS levers (AMS mode is file-driven; the P0 gcode is the runtime lever):
#   - hdlDat/Phrozen_Dev.json "mode"          : 1 = MC (multi-color / AMS), 3 = FILA_RUNOUT (single-color)
#   - printer.cfg [phrozen_dev] auto_connect  : true/false (open the AMS serial at startup)
# The RUNTIME mode is set by the P0 gcode (P0 M1 / P0 M3), NOT by the file alone — so the AMS_ON /
# AMS_OFF Mainsail macros (in AddOn.cfg) do the gcode (G28 + P0 M1 + P28 / RESTART); this script only
# edits the state files. P0 M1 with filament in the toolhead moves to the spit area -> the macro homes
# first, and a factory-new AMS additionally needs one-time provisioning (not covered here).
#
# Usage:
#   bash ams_toggle.sh files on|off   # ONLY edit the state files (called by the AMS_ON/AMS_OFF macros)
#   bash ams_toggle.sh on             # SSH/menu: files + G28 + P0 M1 + P28 (connect, multi-color)
#   bash ams_toggle.sh off            # SSH/menu: files + restart Klipper (single-color, AMS off)
#   bash ams_toggle.sh status
set -e
CFG="$HOME/printer_data/config/printer.cfg"
DEVJSON="$HOME/hdlDat/Phrozen_Dev.json"
MR="http://localhost:7125"

set_files(){   # $1 = on|off
  if [ "$1" = on ]; then AC=true; MODE=1; else AC=false; MODE=3; fi
  if [ -f "$CFG" ] && grep -qE '^[[:space:]]*auto_connect:' "$CFG"; then
    cp "$CFG" "$CFG.ams.bak" 2>/dev/null || true
    sed -i -E "s/^([[:space:]]*auto_connect:).*/\1 $AC/" "$CFG"
  else echo "WARN: no 'auto_connect:' line in $CFG"; fi
  if [ -f "$DEVJSON" ]; then
    cp "$DEVJSON" "$DEVJSON.ams.bak" 2>/dev/null || true
    python3 - "$DEVJSON" "$MODE" <<'PY'
import json,sys
p=sys.argv[1]; m=int(sys.argv[2])
d=json.load(open(p)); d['mode']=m; json.dump(d,open(p,'w'))
PY
  else echo "WARN: $DEVJSON not found (AMS server installed?)"; fi
  echo "AMS files set ($1): auto_connect=$AC, Phrozen_Dev.json mode=$MODE"
}

gc(){ curl -s -X POST "$MR/printer/gcode/script?script=$1" >/dev/null 2>&1 || true; }

# A SERVICE restart, not klipper's own RESTART. Switching AMS off rewrites printer.cfg, and phrozen_dev
# holds an open serial port and background threads that klippy's in-process restart does not reliably
# tear down. A service restart also runs the ExecStartPre self-heal guards, which the gcode RESTART
# skips -- see selfupdate.sh for why that distinction keeps mattering.
#
# Through Moonraker, which does it without root: 'klipper' is in its available_services (verified on
# hardware 2026-08-09). What stood here was `echo makerbase | sudo -S systemctl restart klipper
# 2>/dev/null || true` -- a password in clear text, in a public repository, that stops working the
# moment the owner changes it, which the manual recommends. And `|| true` swallowed the failure, so the
# script cheerfully printed "AMS OFF" while klipper had never re-read the config. Silent and wrong.
restart_klipper(){
  if curl -s -m 25 -X POST "$MR/machine/services/restart?service=klipper" 2>/dev/null | grep -q '"result"'; then
    return 0
  fi
  echo "WARNING: could not restart klipper through Moonraker."
  echo "         The files are changed but NOT in effect yet. Finish it with:"
  echo "             sudo systemctl restart klipper"
  return 1
}

case "${1:-}" in
  files)  set_files "${2:?usage: ams_toggle.sh files on|off}";;
  on)     set_files on; echo ">> G28 + P0 M1 + P28 ..."; gc "G28"; gc "P0%20M1"; sleep 2; gc "P28"; gc "SAVE_VARIABLE%20VARIABLE=ams%20VALUE=1"; echo "AMS ON (multi-color, connected).";;
  off)    set_files off; gc "SAVE_VARIABLE%20VARIABLE=ams%20VALUE=0"; echo ">> restarting klipper ..."
          if restart_klipper; then echo "AMS OFF (single-color)."; else echo "AMS files set to single-color, but NOT yet active."; fi;;
  status)
    echo "  auto_connect          : $(grep -E '^[[:space:]]*auto_connect:' "$CFG" 2>/dev/null | awk '{print $2}')"
    echo "  Phrozen_Dev.json mode : $(grep -oE '\"mode\":[[:space:]]*[0-9]+' "$DEVJSON" 2>/dev/null | grep -oE '[0-9]+$') (1=MC/AMS, 3=single-color)"
    echo "  save_variables 'ams'  : $(grep -oE '^ams[[:space:]]*=[[:space:]]*[0-9]+' "$HOME/printer_data/config/variables.cfg" 2>/dev/null | grep -oE '[0-9]+$' || echo '0 (default - not set yet)') (1=on, 0=off; steers the Orca start-gcode)"
    ;;
  *) echo "Usage: bash ams_toggle.sh on|off|status   (macros use: files on|off)"; exit 1;;
esac
