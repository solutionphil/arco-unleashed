#!/bin/bash
# setup-fluidd-theme.sh — install / remove the Arco Unleashed theme for Fluidd.
#
# Usage:  bash setup-fluidd-theme.sh [apply|remove|status]     (default: apply)
#
# Fluidd reads its theme from ~/printer_data/config/.fluidd-theme/ -- a DIFFERENT folder from
# Mainsail's .theme/, so the two live side by side and neither disturbs the other.
#
# Verified against the installed fluidd bundle rather than the docs: v1.37.2 has exactly two hooks,
#   getCustomThemeFile(`custom`,[`.css`])                          -> .fluidd-theme/custom.css
#   getCustomThemeFile(`background`,[`.png`,`.jpg`,`.jpeg`,`.gif`]) -> .fluidd-theme/background.*
# There is NO logo and NO favicon hook (the docs claim a logo.svg; no such call exists), and the
# background list has no .svg -- so our main-background.svg cannot be used as-is.
#
# Nothing is restarted: Fluidd fetches the file through moonraker's file API. Reload the browser
# (Ctrl+F5) to see the change. Safe to run during a print.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# Under sudo $HOME is ROOT'S home. This one fails silently rather than loudly: it would happily create
# /root/printer_data/config/.fluidd-theme, print "installed", and leave Fluidd showing nothing at all.
ARCO_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  _h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$_h" ] && ARCO_HOME="$_h"
fi
CFG="$ARCO_HOME/printer_data/config"
DEST="$CFG/.fluidd-theme"
ACT="${1:-apply}"

status(){
  if [ -f "$DEST/custom.css" ]; then
    printf "Fluidd theme: installed -> %s\n" "$DEST/custom.css"
    [ -f "$DEST/background.png" ] && echo "  background.png present" || echo "  no background.png (optional)"
  else
    echo "Fluidd theme: not installed"
  fi
  [ -d "$ARCO_HOME/fluidd" ] || echo "  note: Fluidd itself is not installed -- see scripts/install-fluidd.sh"
}

case "$ACT" in
  status) status; exit 0;;
  remove)
    rm -rf "$DEST" && echo "Fluidd theme removed -> reload the browser (Ctrl+F5) for stock Fluidd."
    exit 0;;
  apply) ;;
  *) echo "Usage: bash setup-fluidd-theme.sh [apply|remove|status]"; exit 1;;
esac

[ -d "$CFG" ] || { echo "no config dir at $CFG"; exit 1; }
[ -f "$DIR/custom.css" ] || { echo "missing $DIR/custom.css"; exit 1; }

mkdir -p "$DEST" || { echo "cannot create $DEST"; exit 1; }
install -m644 "$DIR/custom.css" "$DEST/custom.css" || { echo "cannot write $DEST/custom.css"; exit 1; }
[ -f "$DIR/background.png" ] && install -m644 "$DIR/background.png" "$DEST/background.png"
# root-owned files in the config dir would break moonraker's file API (it runs as mks).
[ "$(id -u)" = 0 ] && chown -R 1000:1000 "$DEST" 2>/dev/null || true

echo "Fluidd theme installed -> $DEST"
echo "  Reload Fluidd in the browser (Ctrl+F5)."
echo "  For the cleanest accent: Settings -> Theme -> Primary Color = #2E74F2, and pick the dark theme."
