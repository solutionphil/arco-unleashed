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
say(){ echo "[wifi-rearm] $*"; }

# No wireless interface at all -> nothing this script can help with (and never on a wired-only box).
[ -d /sys/class/net/wlan0 ] || { say "no wlan0 — nothing to do"; exit 0; }

# NetworkManager, if it is the one in charge, keeps its own connections; leave it alone entirely.
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  say "NetworkManager is in charge — not our stack, nothing to do"; exit 0
fi

# A configuration counts only if it names a network. An empty credential-less file is exactly what the
# image ships and what a reset leaves behind, and that is the case we are here for.
if [ -f "$WPA" ] && grep -qE '^[[:space:]]*ssid=' "$WPA" 2>/dev/null; then
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
