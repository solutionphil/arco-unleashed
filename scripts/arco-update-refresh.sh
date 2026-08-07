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
# Runs ONCE per printer, not once per boot: it stamps itself done and returns instantly ever after. The
# stale state it clears is made by the FIRST boot after a flash, so once that is behind a machine there
# is nothing left to watch for -- and a unit that keeps waking up to reach GitHub is noise. A boot in
# which it could NOT finish leaves no stamp and is retried on the next one.
set -uo pipefail

API="${ARCO_MOONRAKER:-http://localhost:7125}"
STAMP="${ARCO_REFRESH_STAMP:-/var/lib/arco-unleashed/update-refresh.done}"
say(){ echo "[update-refresh] $*"; }

# ONCE, not once per boot. The stale state this clears is created by the FIRST boot after a flash, so a
# printer that has been through it does not need checking again -- and a unit that keeps waking up to
# talk to GitHub is the kind of background noise nobody asked for. The stamp is written only after the
# job has actually succeeded, so a boot where it could not finish is retried on the next one.
# To run it again by hand (e.g. after a restore): sudo rm /var/lib/arco-unleashed/update-refresh.done
if [ -f "$STAMP" ]; then exit 0; fi
mark_done(){ mkdir -p "$(dirname "$STAMP")" 2>/dev/null; date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP" 2>/dev/null || true; }

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
if [ "${n:-0}" -eq 0 ]; then say "nothing invalid — no refresh needed"; mark_done; exit 0; fi
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

# 4. Refresh -- with retries, because the first attempt is expected to be refused.
# Moonraker runs its OWN update check while it starts, and answers this endpoint with an error for as
# long as that is in flight. The first version of this script fired once, got exactly that refusal and
# gave up until the next boot: observed on hardware 2026-08-07, all three log lines inside the same
# second ("resolution works" -> "refresh call failed"), which is far too fast to be anything but a
# rejected request. So: try again, and say what came back instead of just "failed" -- a bare "failed"
# is what made this cost a whole reboot cycle to diagnose.
say "resolution works — asking moonraker to re-check"
# mktemp, not a fixed path under /run: as a systemd unit this is root and /run is writable, but the
# script must also be runnable by hand as the printer user for diagnosis -- and there it failed on the
# output file, which then made curl report a doubled "000000" and hid the real HTTP status.
OUT=$(mktemp 2>/dev/null) || OUT=/tmp/arco-update-refresh.$$
done_ok=0
for attempt in 1 2 3 4 5 6 7 8; do
  # Re-check first: Moonraker's own startup refresh may have finished and fixed this without us.
  if [ "$(invalid_count)" = "0" ]; then say "already valid (moonraker's own check finished)"; done_ok=1; break; fi
  code=$(curl -sS -o "$OUT" -w '%{http_code}' --max-time 60 -X POST "$API/machine/update/refresh" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then say "refresh accepted (attempt $attempt)"; done_ok=1; break; fi
  say "attempt $attempt: HTTP $code — $(tr -d '\n' < "$OUT" 2>/dev/null | cut -c1-140)"
  sleep 30
done
rm -f "$OUT"
[ "$done_ok" = 1 ] || { say "moonraker refused every attempt — leaving it; a manual refresh still works"; exit 0; }

# The refresh runs asynchronously; give it room before judging the result.
for _ in $(seq 1 12); do
  m=$(invalid_count)
  [ "${m:-1}" -eq 0 ] && { say "all components valid now"; mark_done; exit 0; }
  sleep 10
done
say "$m still invalid two minutes after the refresh — that is a real finding, not the first-boot race"
mark_done   # the race is over either way; anything left is not what this unit is for
exit 0
