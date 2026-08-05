#!/bin/bash
# apt-hold.sh — protect critical packages from being overwritten by upgrades (DTB/kernel/firmware).
# Otherwise an apt upgrade kills the custom DTB / WiFi firmware.
# On the printer:  sudo bash scripts/apt-hold.sh
set -e
[ "$EUID" -eq 0 ] || { echo "Please run with sudo."; exit 1; }

HOLD=$(dpkg -l 2>/dev/null | awk '/^ii/{print $2}' | grep -E \
  'linux-image|linux-dtb|linux-u-boot|armbian-firmware|armbian-bsp|^firmware-' || true)

if [ -z "$HOLD" ]; then
  echo "No matching packages found — check manually with 'dpkg -l | grep -E linux-'."
  exit 0
fi
echo "Putting the following packages on hold:"; echo "$HOLD"
echo "$HOLD" | xargs apt-mark hold

# Also stop apt's background auto-update timers — they could upgrade a non-held package, wake the eMMC,
# or (worst case) pull a kernel/DTB that breaks WiFi/display before you notice. Idempotent.
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
echo "Masked apt-daily auto-update timers (no background auto-updates)."

# Also mask unattended-upgrades (auto apt upgrades) + the man-db rebuild timer — each can fire a heavy
# CPU/eMMC burst at a random time, and landing inside an Auto-Cal that triggers an MCU "Timer too close".
# And disable a few never-needed daemons: NFS rpcbind, network-stats vnstat, the disconnected-HDMI
# console getty@tty1. Idempotent.
systemctl mask --now unattended-upgrades.service 2>/dev/null || true
systemctl disable --now man-db.timer rpcbind.service rpcbind.socket vnstat.service getty@tty1.service 2>/dev/null || true
echo "Masked unattended-upgrades + man-db.timer; disabled rpcbind/vnstat/getty@tty1."

echo ""
echo "Status:"; apt-mark showhold
echo "To release later:  sudo apt-mark unhold <package>"
