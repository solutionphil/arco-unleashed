#!/bin/sh
# One-time installer: wire the Voron theme macros into printer.cfg,
# restart Klipper, verify, and self-test both directions.
set -e
cd "$HOME/printer_data/config"

cp printer.cfg "printer.cfg.bak-theme-$(date +%s)"
if ! grep -q "unleashed-theme-macros" printer.cfg; then
    sed -i '5a [include unleashed-theme-macros.cfg]' printer.cfg
fi
echo "include:"; grep -n "unleashed-theme-macros" printer.cfg

echo "=== Klipper restart ==="
curl -s -X POST http://localhost:7125/printer/restart >/dev/null || true

st=""; i=0
while [ $i -lt 30 ]; do
    sleep 2
    resp="$(curl -s http://localhost:7125/printer/info)"
    st="$(printf '%s' "$resp" | grep -oE '"state":[ ]*"[a-z]+' | head -1 | grep -oE '[a-z]+$')"
    case "$st" in ready|error|shutdown) break ;; esac
    i=$((i+1))
done
echo "klipper state: $st"
printf '%s' "$resp" | grep -oE '"state_message":[ ]*"[^"]{0,90}' | head -1

echo "=== Macro registered ==="
curl -s http://localhost:7125/printer/objects/list | grep -oiE "gcode_macro switch_theme" | sort -u

if [ "$st" = "ready" ]; then
    echo "=== TEST: SWITCH_THEME (1x) ==="
    curl -s -X POST "http://localhost:7125/printer/gcode/script?script=SWITCH_THEME" >/dev/null
    sleep 4; echo "state=$(cat .theme-state 2>/dev/null)"
    sh unleashed-theme.sh light >/dev/null; echo "restored: state=$(cat .theme-state 2>/dev/null)"
fi
