#!/bin/bash
# pin-klipper-updates.sh — tell Moonraker, in writing, that Klipper is pinned on purpose.
#
# Usage:  bash pin-klipper-updates.sh [apply|remove|status]     (default: apply)
#
# WHAT THIS DOES AND WHAT IT DOES NOT DO -- read before expecting too much:
#
#   * It stops Moonraker offering "v0.13.0-699 -> v0.13.0-707". With a pinned_commit set, Moonraker
#     treats the current commit as the upstream (git_deploy.py: `self.upstream_commit =
#     self.current_commit`), so there is nothing to nag about.
#   * It makes the pin VISIBLE. Today the pin is an invisible `git checkout --detach` from the image
#     build, so Moonraker's "Detached HEAD detected" reads like a defect on the user's machine. With
#     this block in moonraker.conf the intent is written down where someone looks for it.
#
#   * It does NOT remove the "invalid" badge, and it does NOT re-enable the update button.
#     Checked in Moonraker's own source rather than assumed: pinned_commit appears ZERO times in
#     _generate_warn_msg(), and validity is decided by
#         has_recoverable_errors() = diverged OR is_dirty() OR (head_detached AND not debug)
#     (Historic: we USED to be dirty because mcu.py was patched in place. That moved to the untracked
#      arco_mcu_timing extra, so the repo is clean now and Moonraker can actually update Klipper.)
#     and detached (the pin). Nothing short of carrying the patch as a commit in our own klipper fork
#     clears that -- and Moonraker's debug mode, which forgives the detached head, also exposes the
#     /debug HTTP endpoints, which is a bad trade for a badge.
#
# UPDATING ANYWAY is safe and needs no button. klipper.service carries seven ExecStartPre guards
# (apply-phrozen-restore, apply-core-restore, apply-arco-extras, apply-config-patches,
#  apply-phrozen-patches, ensure-imageid, kaos-guard),
# so a pull, a reset, even Moonraker's own `reset --hard` + `git clean -d -f` recovery all self-heal
# before klippy imports anything:
#
#     cd ~/klipper && git checkout master && git pull && sudo systemctl restart klipper
#
# NOTE: the shipped image no longer pins Klipper — the reason (a patched mcu.py) is gone and the pin
# cost the update button. This script stays for anyone who deliberately wants to hold a version.
set -uo pipefail
CFG="$HOME/printer_data/config/moonraker.conf"
KLIPPER="${KLIPPER_DIR:-$HOME/klipper}"
ACT="${1:-apply}"

have_block(){ grep -qE '^\[update_manager klipper\]' "$CFG"; }

status(){
  [ -f "$CFG" ] || { echo "no moonraker.conf at $CFG"; return 1; }
  if have_block; then
    echo "klipper update pin: SET"
    sed -n '/^\[update_manager klipper\]/,/^\[/p' "$CFG" | grep -E '^pinned_commit' | sed 's/^/  /'
  else
    echo "klipper update pin: not set"
  fi
  [ -d "$KLIPPER/.git" ] && echo "  klipper is at: $(git -C "$KLIPPER" describe --tags --always --dirty 2>/dev/null)"
}

case "$ACT" in
  status) status; exit $?;;
  remove)
    [ -f "$CFG" ] || { echo "no moonraker.conf"; exit 1; }
    have_block || { echo "no pin to remove"; exit 0; }
    cp -a "$CFG" "$CFG.pre-unpin.$(date +%s).bak"
    sed -i '/^# --- Arco Unleashed: Klipper is pinned/,/^$/d; /^\[update_manager klipper\]/,/^$/d' "$CFG"
    echo "pin removed -> restart moonraker to apply:  sudo systemctl restart moonraker"
    echo "  (the 'invalid' badge stays either way -- it is the dirty tree + detached head, not this)"
    exit 0;;
  apply) ;;
  *) echo "Usage: bash pin-klipper-updates.sh [apply|remove|status]"; exit 1;;
esac

[ -f "$CFG" ] || { echo "no moonraker.conf at $CFG"; exit 1; }
[ -d "$KLIPPER/.git" ] || { echo "no klipper git repo at $KLIPPER"; exit 1; }

SHA=$(git -C "$KLIPPER" rev-parse HEAD 2>/dev/null)
DESC=$(git -C "$KLIPPER" describe --tags --always 2>/dev/null)
[ -n "$SHA" ] || { echo "cannot read klipper's HEAD"; exit 1; }

if have_block; then
  CUR=$(sed -n '/^\[update_manager klipper\]/,/^\[/p' "$CFG" | grep -E '^pinned_commit' | awk '{print $2}')
  if [ "$CUR" = "$SHA" ]; then
    echo "already pinned to $DESC ($SHA) -- unchanged"
    exit 0
  fi
  echo "re-pinning: $CUR -> $SHA"
  cp -a "$CFG" "$CFG.pre-pin.$(date +%s).bak"
  sed -i "/^\[update_manager klipper\]/,/^\[/ s|^pinned_commit:.*|pinned_commit: $SHA|" "$CFG"
else
  cp -a "$CFG" "$CFG.pre-pin.$(date +%s).bak"
  cat >> "$CFG" <<EOF

# --- Arco Unleashed: Klipper is pinned ON PURPOSE ---------------------------------------------------
# This build patches Klipper: klippy/mcu.py carries widened MCU timing (TIMEOUT_TIME, RETRY_TIME,
# TRSYNC_TIMEOUT) against "Timer too close" at max_accel 40000, and klippy/extras/ carries our own
# modules. The image therefore ships Klipper at a known-good commit rather than tracking master.
#
# That is why the update manager shows "Detached HEAD" and "Repo is dirty" -- both are intended, not a
# fault on your printer. The badge cannot be cleared while the patch lives in the working tree; only
# this nag ("a newer version is available") is silenced here.
#
# TO UPDATE KLIPPER ANYWAY (safe -- klipper.service re-applies every patch via ExecStartPre before
# klippy starts, so nothing is lost):
#     cd ~/klipper && git checkout master && git pull && sudo systemctl restart klipper
#     bash ~/arco-unleashed/scripts/pin-klipper-updates.sh     # re-pin to the new commit
# Pinned at: $DESC
[update_manager klipper]
pinned_commit: $SHA
EOF
  echo "pinned to $DESC ($SHA)"
fi

echo
echo "Restart moonraker to apply:  sudo systemctl restart moonraker"
echo "  This does NOT interrupt a print (klipper keeps running), but the web UI drops for a few seconds."
