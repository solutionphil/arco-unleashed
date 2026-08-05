#!/bin/bash
# apply-core-restore.sh — heal Klipper core files that voronFDM clobbers with its v0.11 copies.
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

# Detect the clobber at the SerialReader call site in mcu.py: v0.13 calls it with mcu_name=, Phrozen's
# old mcu.py with warn_prefix=. The check looks for warn_prefix in mcu.py's SerialReader( call -- this
# is NOT fooled by our timing patch (which only changes TIMEOUT_TIME/RETRY_TIME/TRSYNC_TIMEOUT, never
# the SerialReader call), and serialhdl.py is the wrong file to check (v0.13 keeps the word warn_prefix
# elsewhere, and it is never clobbered anyway).
grep -qE 'SerialReader\([^)]*warn_prefix' "$KL/klippy/mcu.py" 2>/dev/null || exit 0   # v0.13 intact

echo "  Klipper mcu.py clobbered by voronFDM (old SerialReader warn_prefix API) -> restoring v0.13"
git config --global --add safe.directory "$KL" 2>/dev/null || true
# virtual_sdcard.py is clobbered by the same serial-screen copy; restore both. (serialhdl.py is not
# touched by Phrozen, so it is left alone.)
git -C "$KL" checkout HEAD -- klippy/mcu.py klippy/extras/virtual_sdcard.py 2>&1 | sed 's/^/    /'
echo "    restored mcu.py + virtual_sdcard.py (timing comes from the arco_mcu_timing extra — mcu.py stays pristine)"
