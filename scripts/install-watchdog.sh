#!/bin/bash
# install-watchdog.sh — install the voronFDM moonraker-websocket watchdog (systemd timer + oneshot).
# Why: after the auto-calibration's SAVE_CONFIG → klippy restart, voronFDM freezes its own read loop
# (hard-coded sleep(2) + cache-clear + sleep(2)), Moonraker drops voronFDM's websocket, and voronFDM
# never reconnects (its reconnect only fires on a clean WS CLOSE frame, never on the abrupt drop) →
# the display stays on the calibration page instead of returning to the home screen. This watchdog
# notices voronFDM has no :7125 connection and restarts it. Update-safe (no Moonraker/voronFDM mods).
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/voronfdm-watchdog"
SUDO="sudo"; [ "$(id -u)" = 0 ] && SUDO=""

[ -d "$SRC" ] || { echo "ERROR: $SRC not found."; exit 1; }
$SUDO install -m 755 "$SRC/arco-voronfdm-watchdog.sh" /home/mks/arco-voronfdm-watchdog.sh
$SUDO install -m 644 "$SRC/arco-voronfdm-watchdog.service" /etc/systemd/system/arco-voronfdm-watchdog.service
$SUDO install -m 644 "$SRC/arco-voronfdm-watchdog.timer"   /etc/systemd/system/arco-voronfdm-watchdog.timer
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now arco-voronfdm-watchdog.timer
echo "voronFDM watchdog installed + enabled — timer every 15s, restarts voronFDM if its moonraker"
echo "websocket stays dead >20s (ignores brief normal restarts)."
$SUDO systemctl is-active arco-voronfdm-watchdog.timer
