#!/bin/bash
# apply-phrozen-restore.sh — keep a copy of phrozen_dev OUTSIDE the Klipper tree, and put it back if
# a Klipper update removed it.
#
# Why this has to exist: phrozen_dev lives in klippy/extras/ but is NOT tracked by Klipper's git.
# Moonraker's update manager offers "hard recover", which runs `git reset --hard` + `git clean` — and
# that deletes every untracked file in the tree, phrozen_dev included. printer.cfg declares
# [phrozen_dev], so klippy then refuses the config outright and the printer sits halted with no
# display and no AMS. It is Phrozen's proprietary code, so this project cannot ship a replacement
# copy: the only thing that can rescue a recipient is a copy taken from THEIR OWN installation.
# (Hit the dev printer on 2026-07-21; recovery needed a month-old backup that happened to exist on a
# PC. A recipient would have had nothing.)
#
# Direction is decided by what is actually on disk — this never guesses:
#   module present  -> refresh the safety copy when the installed module is newer (Phrozen FW update)
#   module missing  -> restore it from the safety copy
#   both missing    -> say so clearly; only re-installing from Arco_FW_V*.zip can fix that
#
# It deliberately copies the PATCHED module: this guard runs before apply-phrozen-patches.sh, so what
# it sees is whatever the last start left behind, v0.13 API fixes included. Restoring that brings the
# printer back in a single boot, and re-patching is idempotent anyway.
#
# Idempotent, no root (the copy lives in the service user's home), and cheap: a timestamp comparison,
# with no data movement unless something actually changed.
#
# Usage:  bash apply-phrozen-restore.sh [path-to-klipper]
set -u
KL="${1:-$HOME/klipper}"
PD="$KL/klippy/extras/phrozen_dev"
BK="${ARCO_PHROZEN_BK:-$HOME/.arco-phrozen-backup}"

# "complete enough to be worth trusting". The three .py files are what klippy needs to import the
# module — but they are NOT the whole story, and assuming they were cost a real printer its gateway:
# frp-oms/phrozen_master serves /tmp/UNIX.domain — voronFDM (the display) is the client, and it holds
# the AMS work mode in hdlDat/Phrozen_Dev.json. It lives inside this directory, so a
# git clean deletes it too — yet it does NOT come from Arco_FW_V*.zip. It is part of the printer's
# ORIGINAL base OS, and the only copy a user has is the arco-phrozen-ams.tar.gz that collect_data_arco.sh
# produced before flashing. Restoring the module from a firmware package therefore brings back something
# that imports fine and is still missing its AMS half.
# That matters most in the other direction: a module without it must never be allowed to overwrite a
# backup that has it, or the last good copy is lost silently.
has_master(){ [ -x "$1/frp-oms/phrozen_master" ] || [ -f "$1/frp-oms/phrozen_master" ]; }

# Existence is not health, and treating it as health destroyed a tester's last good copy on 2026-08-14.
# His cmds.py came back from an update 800422 bytes instead of 800809, the tail of it NUL bytes. Every
# file test this function used to run passed, so the next boot happily mirrored the damaged module over
# the safety copy — and now BOTH were broken, with klippy refusing the module outright ("source code
# string cannot contain null bytes"). Nothing in the kit could put it back.
# A file holding NUL bytes cannot be a Python source file, full stop, so the verdict is unambiguous and
# there are no false positives to weigh: this checks only the three .py files, never the binaries or
# serial-screen/use_conf.txt, which legitimately contain NUL bytes on a healthy printer.
complete(){
  local f a b
  for f in cmds.py base.py __init__.py; do
    [ -s "$1/$f" ] || return 1
    a=$(LC_ALL=C tr -d '\000' < "$1/$f" | wc -c) || return 1
    b=$(wc -c < "$1/$f") || return 1
    [ "$a" -eq "$b" ] || return 1
  done
  return 0
}

# Copy via a staging directory and swap, so an interrupted run can never leave a half-written module
# behind (which would be worse than the missing one it replaced).
mirror(){ # $1=src $2=dst
  rm -rf "$2.new" || return 1
  mkdir -p "$2.new" || return 1
  cp -a "$1/." "$2.new/" || { rm -rf "$2.new"; return 1; }
  rm -rf "$2"
  mv "$2.new" "$2"
}

if complete "$PD"; then
  # Never trade a backup that still has the gateway for one that does not — that is how the last copy
  # disappears without anybody noticing until the display or the AMS needs it.
  if complete "$BK" && has_master "$BK" && ! has_master "$PD"; then
    echo "  phrozen_dev: installed module has no frp-oms/phrozen_master — keeping the older backup, which does" >&2
    echo "  phrozen_dev: (restore it with: tar xzf arco-phrozen-ams.tar.gz -C /tmp && cp -a /tmp/frp-oms/. $PD/frp-oms/)" >&2
    exit 0
  fi
  if ! complete "$BK"; then
    mirror "$PD" "$BK" && echo "  phrozen_dev: safety copy created ($BK)"
    has_master "$PD" || echo "  phrozen_dev: NOTE no frp-oms/phrozen_master (the gateway) — see the tarball" >&2
  elif [ "$PD/cmds.py" -nt "$BK/cmds.py" ]; then
    mirror "$PD" "$BK" && echo "  phrozen_dev: safety copy refreshed (installed module is newer)"
  fi
  exit 0
fi

if complete "$BK"; then
  mkdir -p "$(dirname "$PD")"
  if mirror "$BK" "$PD"; then
    echo "  phrozen_dev: RESTORED from $BK — the installed module was missing or damaged"
  else
    echo "  phrozen_dev: restore from $BK FAILED" >&2
  fi
  exit 0
fi

echo "  phrozen_dev: missing or damaged, and the safety copy in $BK is no better." >&2
echo "  phrozen_dev: printer.cfg declares [phrozen_dev], so Klipper will not start." >&2
echo "  phrozen_dev: If the files are DAMAGED rather than gone, this replaces just the broken ones from" >&2
echo "  phrozen_dev: Phrozen's own public repository, keeping everything a re-install would take away:" >&2
echo "  phrozen_dev:     bash ~/arco-unleashed/scripts/repair-phrozen.sh" >&2
echo "  phrozen_dev: If they are GONE, re-install from Phrozen's Arco_FW_V*.zip via the setup menu" >&2
echo "  phrozen_dev: (type: unleashed)." >&2
echo "  phrozen_dev: The gateway frp-oms/phrozen_master is NOT in that zip. It" >&2
echo "  phrozen_dev: belongs to the original OS. Restore it from your own" >&2
echo "  phrozen_dev: arco-phrozen-ams.tar.gz (collect_data_arco.sh)." >&2
# Never fail the unit: klippy's own config error names the problem more precisely than we can.
exit 0
