#!/bin/bash
# arco-wifi-rearm.sh — put the Wi-Fi setup portal back within reach when a printer has lost its network.
#
# WHY THIS EXISTS. The captive portal lives inside arco-firstrun.sh and nowhere else, and
# arco-firstrun.service disables itself once it has run. Nothing ever enabled it again. The USB
# wifi-seed.txt recovery hangs off the same script, and the display's own network page cannot list
# networks at all. So a printer that lost its Wi-Fi configuration -- a factory reset from the display is
# the way people hit this -- had no way back in at all: no portal, no seed file, no display, no SSH. The
# only cure left was opening the machine and pulling the eMMC. Found 2026-08-06 with a tester in exactly
# that position.
#
# WHAT IT DELIBERATELY DOES NOT DO. It only fires when there is NO usable Wi-Fi configuration -- the
# config is missing, or holds no ssid. It does NOT fire merely because the printer failed to associate:
# a router that is slow or briefly down at boot would then raise a setup AP, take wlan0 away from the
# normal connection, and sit there until somebody walks over and submits the form. Being unreachable for
# two minutes is a nuisance; being unreachable until someone notices the AP is worse than the problem.
# A printer carried to a new house therefore still needs the eMMC route, and that is a conscious trade,
# not an oversight.
#
# Runs once at boot from arco-wifi-rearm.service, as root. Idempotent, and silent on a healthy printer.
set -uo pipefail

WPA="${ARCO_WPA_CONF:-/etc/wpa_supplicant/wpa_supplicant-wlan0.conf}"

# A readable log beside Klipper's own, not only the journal. journald is volatile on this image (it
# lives under /run), so anything a first boot logs is gone at the next reboot -- and while it is there,
# only root can read it. This unit runs at exactly the moment that matters and for a printer whose
# owner may have no network at all, so its record has to outlive the boot and be fetchable without a
# shell. Same reasoning as arco-update-refresh.sh.
_KITDIR="$(cd "$(dirname "$0")/.." && pwd)"
_AHOME="$(dirname "$_KITDIR")"
LOGF="${ARCO_REARM_LOG:-$_AHOME/printer_data/logs/arco-wifi-rearm.log}"
mkdir -p "$(dirname "$LOGF")" 2>/dev/null || true
say(){
  echo "[wifi-rearm] $*"
  printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*" >> "$LOGF" 2>/dev/null || true
  chown --reference="$_AHOME" "$LOGF" 2>/dev/null || true
}

# No wireless interface at all -> nothing this script can help with (and never on a wired-only box).
[ -d /sys/class/net/wlan0 ] || { say "no wlan0 — nothing to do"; exit 0; }

# NetworkManager, if it is the one in charge, keeps its own connections; leave it alone entirely.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  say "NetworkManager is in charge — not our stack, nothing to do"; exit 0
fi

# 🔴 UNREADABLE IS NOT THE SAME AS EMPTY, and getting that wrong costs the printer its network.
# wpa_supplicant-wlan0.conf is 0600 root, so any run that is not root cannot read it -- and the old
# test could not tell "the file says there is no network" from "I was not allowed to look". It read the
# second as the first. Caught on hardware 2026-08-07 by running this as the printer user on a machine
# that was online at the time: it announced no network configured and went on to raise the setup AP,
# which would have taken wlan0 away from a perfectly good connection. Only the lack of root privileges
# stopped it. So: when in doubt, do nothing.
if [ ! -r "$WPA" ]; then
  say "cannot read $WPA (needs root) — refusing to guess; nothing changed"; exit 0
fi

# A configuration counts only if it names a network. An empty credential-less file is exactly what the
# image ships and what a reset leaves behind, and that is the case we are here for.
if grep -qE '^[[:space:]]*ssid=' "$WPA" 2>/dev/null; then
  say "a Wi-Fi network is configured — leaving the portal alone"; exit 0
fi

say "no Wi-Fi network configured in $WPA"

# Nothing to re-arm if the portal was never installed (a kit that predates it, or a partial install).
if [ ! -f /etc/systemd/system/arco-firstrun.service ] && [ ! -f /lib/systemd/system/arco-firstrun.service ]; then
  say "arco-firstrun.service is not installed — cannot open the setup portal"; exit 0
fi

if systemctl is-enabled --quiet arco-firstrun.service 2>/dev/null; then
  say "arco-firstrun is already armed — it will open the portal itself"; exit 0
fi

say "re-arming arco-firstrun so the setup portal comes up"
systemctl enable arco-firstrun.service 2>/dev/null || true
# start, not restart: firstrun is a oneshot that reboots on a successful portal submit. Failing to start
# must not fail this unit -- a printer that cannot open its portal should still finish booting.
systemctl start arco-firstrun.service 2>/dev/null || say "WARN: could not start arco-firstrun.service"
exit 0
