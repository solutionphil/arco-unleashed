#!/bin/bash
# apply-reprint-redirect.sh — self-heal the TFT-reprint bridge's plumbing.
#
# The bridge (arco-reprint-bridge.py) reads voronFDM's stdout to recover the filename it never puts
# on the moonraker websocket. Two things must be true, both of which a Phrozen firmware update can
# undo (KlipperScreen-start.sh is Phrozen's), so this runs as a per-boot ExecStartPre guard:
#   1) voronFDM's launch line in phrozen_dev/KlipperScreen-start.sh redirects stdout to the capture
#      log (stock sends it to /dev/null).
#   2) the bridge is running. If the systemd service (installed at flash time, root) is active it
#      owns it; otherwise (e.g. a live/no-root setup) we install-if-missing + nohup-launch it as mks.
#
# Idempotent + no-sudo: only edits an mks-owned file and launches an mks process. No Phrozen code.
set -u
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
KS="$HOME/klipper/klippy/extras/phrozen_dev/KlipperScreen-start.sh"
CAP="$HOME/vfdm-capture.log"
HELPER="$HOME/wsrelay/arco-reprint-bridge.py"
PY="$HOME/moonraker-env/bin/python"

# 1) install-if-missing / update the helper next to the relay
if [ -f "$SCRIPTDIR/arco-reprint-bridge.py" ]; then
  if ! cmp -s "$SCRIPTDIR/arco-reprint-bridge.py" "$HELPER" 2>/dev/null; then
    mkdir -p "$(dirname "$HELPER")"
    install -m755 "$SCRIPTDIR/arco-reprint-bridge.py" "$HELPER" && echo "  reprint-bridge helper installed/updated"
  fi
fi

# 2) ensure voronFDM's stdout is redirected to the capture log (only if KlipperScreen-start.sh exists)
if [ -w "$KS" ] && grep -q 'serial-screen/voronFDM >/dev/null' "$KS" 2>/dev/null; then
  sed -i "s#serial-screen/voronFDM >/dev/null 2>&1 #serial-screen/voronFDM >$CAP 2>\&1 #" "$KS" \
    && echo "  voronFDM stdout -> $CAP (reprint bridge source)"
fi

# 3) ensure the bridge is running (service owns it if present+active; else nohup as mks)
if systemctl is-active --quiet arco-reprint-bridge.service 2>/dev/null; then
  :   # the systemd service owns it
elif [ -f "$HELPER" ] && ! pgrep -f "[a]rco-reprint-bridge" >/dev/null 2>&1; then
  setsid "$PY" -u "$HELPER" >>"$HOME/arco-reprint-bridge.out" 2>&1 </dev/null &
  echo "  reprint-bridge launched (no systemd service present)"
fi
exit 0
