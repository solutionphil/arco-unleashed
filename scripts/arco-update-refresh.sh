#!/bin/bash
# arco-update-refresh.sh — clear the "INVALID" the update manager shows after a fresh flash.
#
# WHAT ACTUALLY HAPPENS. On a first boot Moonraker starts before Wi-Fi is associated and before DNS
# answers, runs its first update check, and that check fails:
#     "fatal: unable to access 'https://github.com/...': Could not resolve host: github.com"
# Moonraker then CACHES that result. It does not retry on its own, so klipper and moonraker keep showing
# INVALID with version "?" long after the network is perfectly fine -- measured on 2026-08-07: DNS
# resolving github.com correctly while the panel still said INVALID, and a single refresh flipping both
# to is_valid=true with real versions. Two testers reported it as a fault; it never was one, and the
# printer works throughout. What it does cost is the update button, and it tempts the owner towards the
# one button they must never press -- "Hard Recover" deletes phrozen_dev and gcode_shell_command.py.
#
# WHY NOT ORDER MOONRAKER AFTER THE NETWORK INSTEAD. Because this image deliberately does not have a
# reliable "the network is up" signal: systemd-networkd-wait-online ships disabled (it would block every
# boot on the phantom wired link), and ordering the web stack behind it would delay Mainsail and the
# webcam on every boot without a cable. Waiting HERE costs one idle background task and nothing else.
#
# Runs at every boot -- the race repeats at every boot -- but only actually calls out when something is
# invalid, so a healthy printer makes no network request at all.
set -uo pipefail

API="${ARCO_MOONRAKER:-http://localhost:7125}"
say(){ echo "[update-refresh] $*"; }

# 1. Moonraker itself. No point asking anything before it answers.
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 && break
  sleep 5
done || true
curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 || { say "moonraker not answering — nothing to do"; exit 0; }

# 2. Is anything actually invalid? A printer that came up cleanly must not generate traffic.
status(){ curl -fsS --max-time 10 "$API/machine/update/status?refresh=false" 2>/dev/null; }
invalid_count(){ status | grep -o '"is_valid":false' | wc -l; }

n=$(invalid_count)
if [ "${n:-0}" -eq 0 ]; then say "nothing invalid — no refresh needed"; exit 0; fi
say "$n component(s) reported invalid — waiting for name resolution"

# 3. Wait for DNS. Up to ~4 minutes: a printer set up through the captive portal reboots into this with
# Wi-Fi still associating, and giving up early would leave exactly the state we came to fix.
ok=0
for _ in $(seq 1 48); do
  getent hosts github.com >/dev/null 2>&1 && { ok=1; break; }
  sleep 5
done
if [ "$ok" != 1 ]; then
  say "no name resolution after ~4 min — leaving the cached state alone (an offline printer is fine)"
  exit 0
fi

# 4. One refresh. Moonraker re-checks every component; unauthenticated GitHub allows far more than this.
say "resolution works — asking moonraker to re-check"
curl -fsS --max-time 60 -X POST "$API/machine/update/refresh" >/dev/null 2>&1 || {
  say "refresh call failed — will try again next boot"; exit 0; }

sleep 10
m=$(invalid_count)
if [ "${m:-0}" -eq 0 ]; then say "all components valid now"
else say "$m still invalid after the refresh — that is a real finding, not the first-boot race"; fi
exit 0
