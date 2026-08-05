#!/bin/bash
# addon-features.sh - whiptail checklist to enable/disable individual AddOn.cfg features.
# Toggles the #@FEAT ... #@ENDFEAT blocks (via addon_features.py) + the board_fan<->printer.cfg
# coupling, then restarts Klipper and verifies it comes back up. Run from the setup menu.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ADDON="${ADDON:-$HOME/printer_data/config/AddOn.cfg}"
PRINTER="${PRINTER:-$HOME/printer_data/config/printer.cfg}"
PY="$DIR/addon_features.py"

[ -f "$ADDON" ] || { echo "AddOn.cfg not found: $ADDON"; exit 1; }
command -v whiptail >/dev/null 2>&1 || { echo "whiptail missing (sudo apt install whiptail)"; exit 1; }

# 1) feature list:  id<TAB>state<TAB>desc
mapfile -t FEATS < <(python3 "$PY" --list "$ADDON")
[ "${#FEATS[@]}" -gt 0 ] || { echo "No #@FEAT blocks found in $ADDON."; exit 1; }

# 2) build whiptail --checklist args (tag item state) + measure widest content
args=()
maxtag=0; maxdesc=0
for f in "${FEATS[@]}"; do
  id="${f%%$'\t'*}"; rest="${f#*$'\t'}"; state="${rest%%$'\t'*}"; desc="${rest#*$'\t'}"
  args+=( "$id" "$desc" "$state" )
  [ "${#id}"   -gt "$maxtag"  ] && maxtag=${#id}
  [ "${#desc}" -gt "$maxdesc" ] && maxdesc=${#desc}
done

# 3) size the box to fit the content, clamped to the terminal (no truncated descriptions)
cols=$(tput cols 2>/dev/null || echo 80); rows=$(tput lines 2>/dev/null || echo 24)
width=$(( maxtag + maxdesc + 16 ))          # [*] prefix + tag/desc gap + borders + scrollbar
[ "$width" -gt $(( cols - 2 )) ] && width=$(( cols - 2 ))
[ "$width" -lt 60 ] && width=60
listh=${#FEATS[@]}
height=$(( listh + 8 ))
if [ "$height" -gt $(( rows - 2 )) ]; then
  height=$(( rows - 2 )); listh=$(( height - 8 )); [ "$listh" -lt 3 ] && listh=3
fi

# 4) the checklist
SEL=$(whiptail --title "Arco Unleashed - AddOn Features" \
  --checklist "Space = toggle, Tab -> <Ok>. Enabled features:" \
  "$height" "$width" "$listh" "${args[@]}" 3>&1 1>&2 2>&3) || { echo "(cancelled - nothing changed)"; exit 0; }
SEL=$(echo "$SEL" | tr -d '"')

# 4) warn before turning G30 off (loses the mesh fix)
if ! printf ' %s ' $SEL | grep -q ' g30 '; then
  if ! whiptail --title "Warning: G30" --yesno \
      "G30 OFF = reverts to Phrozen's original: it calibrates a throwaway 'default'\nand does NOT save -> your mesh fix is gone.\n\nReally disable it?" 12 72; then
    SEL="$SEL g30"
  fi
fi

# 5) change summary (before = FEATS, after = SEL); bail out if nothing changed
echo; echo "=== Changes ==="
nchg=0
for f in "${FEATS[@]}"; do
  id="${f%%$'\t'*}"; rest="${f#*$'\t'}"; old="${rest%%$'\t'*}"
  if printf ' %s ' $SEL | grep -q " $id "; then new=ON; else new=OFF; fi
  if [ "$old" != "$new" ]; then printf "   %-12s %s -> %s\n" "$id" "$old" "$new"; nchg=$((nchg+1)); fi
done
if [ "$nchg" -eq 0 ]; then echo "   (no change - nothing to do)"; exit 0; fi

# 6) apply (writes .addon.bak first; board_fan also (un)comments printer.cfg)
python3 "$PY" --apply "$ADDON" "$PRINTER" "$SEL"
echo "   -> AddOn.cfg written (.addon.bak saved)."

# 7) restart + VERIFY (the "complete & check")
if ! whiptail --title "Klipper restart" --yesno \
    "$nchg change(s) applied.\n\nRestart Klipper now and verify?" 9 64; then
  echo "   Not restarted - changes take effect after a RESTART."
  exit 0
fi
printf "   Restarting, waiting for klippy "
curl -s -m 5 -X POST "http://localhost:7125/printer/gcode/script?script=RESTART" >/dev/null 2>&1 \
  || (echo makerbase | sudo -S systemctl restart klipper >/dev/null 2>&1)
sleep 3
ok=-1; msg=""
for i in $(seq 1 25); do
  R=$(curl -s -m 4 "http://localhost:7125/printer/info" 2>/dev/null)
  if echo "$R" | grep -qE '"state":[ ]*"ready"'; then ok=1; break; fi
  if echo "$R" | grep -qE '"state":[ ]*"(error|shutdown)"'; then
    ok=0; msg=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'].get('state_message','')[:300])" 2>/dev/null); break
  fi
  printf "."; sleep 2
done
echo
if [ "$ok" = 1 ]; then
  active=$(python3 "$PY" --list "$ADDON" | awk -F'\t' '$2=="ON"' | wc -l)
  echo "   [OK] COMPLETE - Klipper ready, $active features active."
elif [ "$ok" = 0 ]; then
  echo "   [FAIL] Klipper reports a config error:"
  echo "$msg" | sed 's/^/        /'
  if whiptail --title "Error - roll back?" --yesno \
      "Config error after toggling.\n\nRestore AddOn.cfg + printer.cfg from backup (.addon.bak) and restart?" 11 68; then
    [ -f "$ADDON.addon.bak" ] && cp "$ADDON.addon.bak" "$ADDON"
    [ -f "$PRINTER.addon.bak" ] && cp "$PRINTER.addon.bak" "$PRINTER"
    curl -s -m 5 -X POST "http://localhost:7125/printer/gcode/script?script=FIRMWARE_RESTART" >/dev/null 2>&1
    echo "   Backup restored, FIRMWARE_RESTART sent."
  fi
else
  echo "   [?] Timeout waiting for klippy - check status in Mainsail."
fi
