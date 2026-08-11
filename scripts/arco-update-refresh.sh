#!/bin/bash
# arco-update-refresh.sh — clear the "INVALID" the update manager shows after a fresh flash.
#
# WHAT HAPPENS. On a first boot Moonraker starts before Wi-Fi is associated and before DNS answers, runs
# its first update check, and that check fails:
#     "fatal: unable to access 'https://github.com/...': Could not resolve host: github.com"
# Moonraker caches that result. klipper and moonraker then keep showing INVALID with version "?" long
# after the network is fine. Two testers reported it as a fault; it never was one, the printer works
# throughout. What it costs is the update button -- and INVALID is exactly the state in which Moonraker
# offers "Hard Recover", the one button that deletes phrozen_dev and gcode_shell_command.py.
#
# THIS IS A WATCHER, NOT A TRIGGER -- and that is the correction the first real first-boot forced.
# The obvious design is to POST /machine/update/refresh and be done. Measured on hardware 2026-08-07,
# that POST cannot work in this window: Moonraker is running its OWN startup check and answers
#     503 {"error":{"code":503,"message":"Server is busy, cannot perform refresh"}}
# for as long as it lasts -- three attempts over three minutes, all refused. What actually cleared the
# state was Moonraker's own check FINISHING, which this script noticed because it re-read the status
# before each attempt. So the useful part was never the nudge; it was the patience. The loop below is
# therefore built around watching, with an occasional POST for the case where Moonraker is idle and
# simply never going to retry on its own.
#
# The same run exposed a second thing: Moonraker sends the 503 body immediately but does not close the
# connection, so a POST with --max-time 60 burned a full minute per attempt. Hence the short timeout.
#
# WHY NOT ORDER MOONRAKER AFTER THE NETWORK. This image ships systemd-networkd-wait-online disabled on
# purpose -- it would block every boot on the phantom wired link the RK3328 device tree creates -- and
# putting the web stack behind it would delay Mainsail and the webcam on every cable-less boot.
#
# ONCE per printer, not once per boot: it stamps itself done and returns instantly ever after. A run
# that did NOT succeed leaves no stamp and is retried on the next boot.
set -uo pipefail

API="${ARCO_MOONRAKER:-http://localhost:7125}"
STAMP="${ARCO_REFRESH_STAMP:-/var/lib/arco-unleashed/update-refresh.done}"

# A readable log beside Klipper's own, NOT only the journal. journald is volatile on this image (it
# lives under /run), so a first-boot log is gone at the next reboot -- and even while it is there only
# root can read it, which turns "send me the log" into an instruction containing sudo. This file
# survives, sits where Mainsail's file browser can fetch it, and needs no shell at all.
KITDIR="$(cd "$(dirname "$0")/.." && pwd)"
AHOME="$(dirname "$KITDIR")"
LOGF="${ARCO_REFRESH_LOG:-$AHOME/printer_data/logs/arco-update-refresh.log}"
mkdir -p "$(dirname "$LOGF")" 2>/dev/null || true
say(){
  echo "[update-refresh] $*"
  printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$*" >> "$LOGF" 2>/dev/null || true
}

if [ -f "$STAMP" ]; then exit 0; fi
mark_done(){
  mkdir -p "$(dirname "$STAMP")" 2>/dev/null
  date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP" 2>/dev/null || true
  # The log belongs to the owner, not to root, or they cannot delete it from the web UI.
  chown --reference="$AHOME" "$LOGF" 2>/dev/null || true
}

# ── 1. Moonraker must answer before anything else means anything ───────────────────────────────────
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 \
  || { say "moonraker not answering — nothing to do"; exit 0; }

status(){ curl -fsS --max-time 10 "$API/machine/update/status?refresh=false" 2>/dev/null; }
invalid_count(){ status | grep -o '"is_valid":false' | wc -l; }

n=$(invalid_count)
if [ "${n:-0}" -eq 0 ]; then say "nothing invalid — no refresh needed"; mark_done; exit 0; fi
say "$n component(s) invalid — waiting for name resolution"

# ── 2. DNS. Up to ~4 min: a printer set up through the captive portal reboots into this with Wi-Fi
# still associating, and giving up early leaves exactly the state we came to fix. ───────────────────
ok=0
for _ in $(seq 1 48); do
  getent hosts github.com >/dev/null 2>&1 && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || { say "no name resolution after ~4 min — leaving it (an offline printer is fine)"; exit 0; }
say "resolution works — watching for the update manager to come good"

# ── 3. Watch, and nudge now and then ───────────────────────────────────────────────────────────────
# 15 s between looks, up to 15 minutes, and the POST must never hold the loop up. Two facts, both
# measured, decide the shape here:
#   * while Moonraker is busy it sends the 503 body and then keeps the connection open, so a POST with
#     --max-time 60 eats a full minute doing nothing -- that is how the first version spent three
#     minutes on three refusals;
#   * a POST that SUCCEEDS is synchronous and fetches from GitHub for every component, which takes well
#     over ten seconds. So a short timeout does not fix the first problem, it breaks the second.
# Hence: the first nudge is sent synchronously with room to finish, purely so its answer reaches the
# log; every later one is fired and forgotten. Watching is what actually detects success either way.
OUT=$(mktemp 2>/dev/null) || OUT=/tmp/arco-update-refresh.$$
# 60, not 32. The 8-minute window was chosen while this unit still held multi-user.target, where every
# extra minute was a minute of dead printer -- so it was a compromise, not a measurement. On 2026-08-11
# it ran out at 22:03:15 and the state came good on its own a few minutes later: it gave up with the
# finish line in sight, wrote no stamp, and thereby signed itself up to repeat the whole thing on the
# next boot. Now that the unit is Type=simple and off the boot path, waiting longer costs nothing and
# buys the stamp.
for i in $(seq 1 60); do
  m=$(invalid_count)
  if [ "${m:-1}" -eq 0 ]; then
    say "all components valid now (after $(( i * 15 ))s)"
    rm -f "$OUT"; mark_done; exit 0
  fi
  if [ "$i" = 1 ]; then
    code=$(curl -sS -o "$OUT" -w '%{http_code}' --max-time 45 -X POST "$API/machine/update/refresh" 2>/dev/null) || true
    case "$code" in ''|*[!0-9]*) code=000 ;; esac      # one fallback, not two -- the old form printed "000000"
    msg=$(tr -d '\n' < "$OUT" 2>/dev/null | grep -oE '"message":"[^"]*"' | head -1)
    case "$code" in
      200) say "nudge accepted — waiting for it to land" ;;
      000) say "nudge timed out — moonraker is busy with its own check; watching instead" ;;
        *) say "nudge refused: HTTP $code ${msg:-no message} — watching instead" ;;
    esac
  elif [ $(( i % 8 )) -eq 1 ]; then
    # Every two minutes, fire and forget. This one is only for the case where Moonraker is idle and
    # has already given up; if it is still busy the request is refused and nobody has to wait for it.
    ( curl -sS --max-time 45 -X POST "$API/machine/update/refresh" >/dev/null 2>&1 & ) 2>/dev/null
  fi
  sleep 15
done
rm -f "$OUT"
say "still invalid after 15 min — NOT stamping, so the next boot tries again. Press refresh in the"
say "update manager, or run this script by hand, if it stays this way."
exit 0
