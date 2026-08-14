#!/bin/bash
# apply-core-restore.sh — heal Klipper core files that are no longer the v0.13 originals.
#
# Two separate failures, one guard. Both leave klippy halted on a file that is wrong on disk, so neither
# is fixed by a reboot, and all three files are tracked by Klipper's git, so restoring them is exact.
#
# On its first start after a Phrozen firmware install, voronFDM copies phrozen_dev/serial-screen/mcu.py
# and virtual_sdcard.py into klippy/ (overwriting this build's v0.13 core) and DELETES the source.
# Phrozen's mcu.py is from an older Klipper base: it calls SerialReader(reactor, warn_prefix=wp), but
# Klipper renamed that argument to mcu_name in v0.13. This build's serialhdl.py (untouched, still v0.13)
# only knows mcu_name, so the clobbered mcu.py halts Klipper with
#   "SerialReader.__init__() got an unexpected keyword argument 'warn_prefix'".
# A reboot does not fix it: the wrong mcu.py is on disk, not a transient state.
#
# fetch-phrozen-fw.sh neutralizes the serial-screen source so OUR install never trips this. But a
# recipient who runs Phrozen's OWN V199 installer (not our setup menu) gets clobbered with no
# protection -- this happened to a tester 2026-07-17. This guard runs as an ExecStartPre before EVERY
# klipper start and self-heals it, so no manual git-checkout is ever needed on the recipient side.
#
# Idempotent + check-first: a no-op in ms unless mcu.py is actually clobbered. Runs BEFORE
# Nothing re-patches mcu.py afterwards any more: the MCU timing lives in klippy/extras/arco_mcu_timing.py
# re-applied on top.
#
# Usage:  bash apply-core-restore.sh [path-to-klipper]
set -uo pipefail
KL="${1:-$HOME/klipper}"
[ -d "$KL/.git" ] || exit 0

NEED=""

# The clobber shows at the SerialReader call site in mcu.py: v0.13 calls it with mcu_name=, Phrozen's
# old mcu.py with warn_prefix=. Checking the call site is NOT fooled by our timing patch, which only
# ever touched TIMEOUT_TIME/RETRY_TIME/TRSYNC_TIMEOUT. virtual_sdcard.py comes over in the same copy.
if grep -qE 'SerialReader\([^)]*warn_prefix' "$KL/klippy/mcu.py" 2>/dev/null; then
  echo "  Klipper mcu.py clobbered by voronFDM (old SerialReader warn_prefix API) -> restoring v0.13"
  NEED="$NEED klippy/mcu.py klippy/extras/virtual_sdcard.py"
fi

# serialhdl.py used to be excluded here, on the reasoning that Phrozen never touches it. That reasoning
# was about the WRONG failure. It is not about who overwrites the file -- it is that the file can end up
# broken at all, and when it does, this guard was the one thing positioned to notice and said nothing.
# A tester hit it on 2026-08-14: klippy halted with "module 'serialhdl' has no attribute 'SerialReader'",
# which is what a file that still parses but no longer defines the class produces -- emptied or written
# short, not clobbered with an older version. It survived every reboot, because the damage is on disk.
# Detect the symptom rather than a cause: serialhdl.py must define SerialReader. It is tracked by
# Klipper's git, so restoring it is exact and costs nothing.
if ! grep -q 'class SerialReader' "$KL/klippy/serialhdl.py" 2>/dev/null; then
  echo "  Klipper serialhdl.py does not define SerialReader (missing, empty or truncated) -> restoring v0.13"
  NEED="$NEED klippy/serialhdl.py"
fi

[ -n "$NEED" ] || exit 0

git config --global --add safe.directory "$KL" 2>/dev/null || true
# shellcheck disable=SC2086 -- NEED is a deliberate list of paths, none of which can contain spaces.
git -C "$KL" checkout HEAD -- $NEED 2>&1 | sed 's/^/    /'
echo "    restored:$NEED (MCU timing comes from the arco_mcu_timing extra — mcu.py stays pristine)"

# Say so if git could not deliver. Silence here reads as success, and the next thing the owner sees is
# klippy halting again with the same message and no explanation of why the self-heal did not take.
for rel in $NEED; do
  case "$rel" in
    *serialhdl.py) grep -q 'class SerialReader' "$KL/$rel" 2>/dev/null || \
      echo "  WARNING: $rel is STILL broken after git checkout — the repository itself may be damaged." >&2 ;;
  esac
done
