#!/bin/bash
# emergency-repair.sh — one action for "something broke".
#
# The printer normally repairs itself: klipper.service runs seven idempotent ExecStartPre guards, so a
# Klipper update, a Phrozen firmware update or a reboot heals before klippy imports anything. This is
# for the times that was not enough — and for the things no guard covers.
#
# It deliberately does NOT ask what went wrong. Somebody whose printer just stopped working does not
# know whether it was Phrozen's firmware, a Klipper update, a Moonraker update or a "hard recover", and
# making them diagnose before they may repair is the wrong burden at the worst moment. Every step here
# is idempotent and check-first, so running all of them is always safe and a healthy printer is a no-op.
#
# What it covers beyond the guards:
#   * [arco_mcu_timing] missing from AddOn.cfg — without it the MCU timing widening is never applied and
#     homing can fail with "Timer too close", with nothing pointing at the cause.
#   * root-owned files in ~/klipper or ~/moonraker — Moonraker runs as the printer user, so it cannot
#     write git refs and every update fails with "Git Command 'fetch origin --prune' failed", while the
#     repository itself looks perfectly healthy. This one cost a real diagnosis session.
#
# Usage:  bash emergency-repair.sh [--no-restart]
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
KL="${ARCO_KLIPPER:-$HOME/klipper}"
MR="${ARCO_MOONRAKER:-$HOME/moonraker}"
CFG="${ARCO_CONFIG:-$HOME/printer_data/config}"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

FIXED=0
step(){ printf '\n>> %s\n' "$*"; }
fixed(){ FIXED=$((FIXED+1)); printf '   FIXED: %s\n' "$*"; }
okay(){ printf '   ok: %s\n' "$*"; }
warn(){ printf '   WARN: %s\n' "$*"; }
# Sub-scripts do their own repairs, so the summary has to hear about them or it lies: a run where
# apply-arco-extras.sh reinstalled a module and declared its config section would still have ended with
# "Nothing needed repairing", because only this script's own steps incremented the counter.
CHANGE_MARKERS='installed/updated|declared \[|RESTORED|restored to|re-?added|safety copy (created|refreshed)'
run(){
  [ -f "$DIR/$1" ] || { warn "$1 not found next to this script"; return; }
  local out; out="$(bash "$DIR/$1" "${@:2}" 2>&1)"
  printf '%s\n' "$out" | sed 's/^/   /'
  if printf '%s\n' "$out" | grep -qE "$CHANGE_MARKERS"; then FIXED=$((FIXED+1)); fi
}

echo "=============================================================="
echo "  Arco Unleashed — emergency repair"
echo "  Safe to run at any time; on a healthy printer it changes nothing."
echo "=============================================================="

step "1/7  phrozen_dev (display + AMS) — restore if a Klipper update deleted it"
run apply-phrozen-restore.sh "$KL"

step "2/7  Klipper core — undo the v0.11 files a Phrozen install copies over it"
run apply-core-restore.sh "$KL"

step "3/7  Our Klipper modules — reinstall whatever is missing"
run apply-arco-extras.sh "$KL"

step "4/7  Config patches + phrozen_dev v0.13 API fixes"
run apply-config-patches.sh
run apply-phrozen-patches.sh

step "5/7  MCU timing declaration in AddOn.cfg"
# The extra only runs when the config asks for it. A Phrozen update that replaces AddOn.cfg, or a
# config restored from an older backup, silently drops the section — and with it the timing widening.
if [ ! -f "$CFG/AddOn.cfg" ]; then
  warn "no AddOn.cfg at $CFG — skipped"
elif grep -q '^\[arco_mcu_timing\]' "$CFG/AddOn.cfg"; then
  okay "[arco_mcu_timing] present"
else
  cat >> "$CFG/AddOn.cfg" <<'EOF'

# -----------------------------------------------------------------------------
# MCU host timing (re-added by emergency-repair). Without this section the timing
# widening is never applied and homing can fail with "Timer too close".
# ARCO_MCU_TIMING reports the values actually in effect.
# -----------------------------------------------------------------------------
[arco_mcu_timing]
EOF
  fixed "added [arco_mcu_timing] to AddOn.cfg"
fi

step "6/7  Repository ownership — the reason 'update Moonraker' can fail"
for repo in "$KL" "$MR"; do
  [ -d "$repo" ] || continue
  name=$(basename "$repo")
  n=$(find "$repo" ! -user "$(id -un)" 2>/dev/null | wc -l)
  if [ "$n" = 0 ]; then
    okay "$name owned correctly"
  elif chown -R "$(id -un):$(id -gn)" "$repo" 2>/dev/null \
    || sudo -n chown -R "$(id -un):$(id -gn)" "$repo" 2>/dev/null; then
    fixed "$name: $n files were not yours — its update button would have failed"
  else
    warn "$name: $n files are not yours and this needs root. Run:"
    warn "  sudo chown -R $(id -un):$(id -gn) $repo"
  fi
done

step "7/7  Restart and check"
if [ "$RESTART" = 1 ]; then
  sudo -n systemctl restart klipper 2>/dev/null || sudo systemctl restart klipper 2>/dev/null \
    || warn "could not restart klipper — do it by hand: sudo systemctl restart klipper"
  sleep 12
fi
state=$(curl -s --max-time 10 http://127.0.0.1:7125/printer/info 2>/dev/null \
        | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')
msg=$(curl -s --max-time 10 http://127.0.0.1:7125/printer/info 2>/dev/null \
        | sed -n 's/.*"state_message":"\([^"]*\)".*/\1/p')

echo
echo "=============================================================="
if [ "$FIXED" = 0 ]; then
  echo "  Nothing needed repairing."
else
  echo "  Repaired $FIXED item(s)."
fi
case "$state" in
  ready)   echo "  Klipper: ready — ${msg:-Printer is ready}";;
  "")      echo "  Klipper: no answer from Moonraker on :7125. Check: systemctl status klipper moonraker";;
  *)       echo "  Klipper: $state — ${msg:-see klippy.log}"
           echo "  If it still refuses to start, the message in Mainsail names the section it choked on."
           echo "  A missing phrozen_dev cannot be repaired from here: reinstall the module from your"
           echo "  own Arco_FW_V*.zip via this menu — Phrozen's software is never shipped with the kit."
           echo "  Note: the gateway frp-oms/phrozen_master is NOT in that zip. It"
           echo "  belongs to the original OS, so its only copy is the arco-phrozen-ams.tar.gz"
           echo "  before flashing:  tar xzf arco-phrozen-ams.tar.gz -C /tmp"
           echo "                    cp -a /tmp/frp-oms/. ~/klipper/klippy/extras/phrozen_dev/frp-oms/";;
esac
echo "=============================================================="
