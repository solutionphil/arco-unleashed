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
# module — but they are NOT the whole story, and assuming they were cost a real printer its AMS server:
# frp-oms/phrozen_master is the AMS UDS server (/tmp/UNIX.domain). It lives inside this directory, so a
# git clean deletes it too — yet it does NOT come from Arco_FW_V*.zip. It is part of the printer's
# ORIGINAL base OS, and the only copy a user has is the arco-phrozen-ams.tar.gz that collect_data_arco.sh
# produced before flashing. Restoring the module from a firmware package therefore brings back something
# that imports fine and is still missing its AMS half.
# That matters most in the other direction: a module without it must never be allowed to overwrite a
# backup that has it, or the last good copy is lost silently.
has_master(){ [ -x "$1/frp-oms/phrozen_master" ] || [ -f "$1/frp-oms/phrozen_master" ]; }
complete(){ [ -f "$1/cmds.py" ] && [ -f "$1/base.py" ] && [ -f "$1/__init__.py" ]; }

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
  # Never trade a backup that still has the AMS server for one that does not — that is how the last
  # copy disappears without anybody noticing until the AMS is needed.
  if complete "$BK" && has_master "$BK" && ! has_master "$PD"; then
    echo "  phrozen_dev: installed module has no frp-oms/phrozen_master — keeping the older backup, which does" >&2
    echo "  phrozen_dev: (restore it with: tar xzf arco-phrozen-ams.tar.gz -C /tmp && cp -a /tmp/frp-oms/. $PD/frp-oms/)" >&2
    exit 0
  fi
  if ! complete "$BK"; then
    mirror "$PD" "$BK" && echo "  phrozen_dev: safety copy created ($BK)"
    has_master "$PD" || echo "  phrozen_dev: NOTE the module has no frp-oms/phrozen_master (AMS server) — see arco-phrozen-ams.tar.gz" >&2
  elif [ "$PD/cmds.py" -nt "$BK/cmds.py" ]; then
    mirror "$PD" "$BK" && echo "  phrozen_dev: safety copy refreshed (installed module is newer)"
  fi
  exit 0
fi

if complete "$BK"; then
  mkdir -p "$(dirname "$PD")"
  if mirror "$BK" "$PD"; then
    echo "  phrozen_dev: RESTORED from $BK — a Klipper update had removed it"
  else
    echo "  phrozen_dev: restore from $BK FAILED" >&2
  fi
  exit 0
fi

echo "  phrozen_dev: missing, and there is no safety copy in $BK." >&2
echo "  phrozen_dev: printer.cfg declares [phrozen_dev], so Klipper will not start. Re-install the module" >&2
echo "  phrozen_dev: from Phrozen's Arco_FW_V*.zip via the setup menu (unleashed_setup.sh)." >&2
echo "  phrozen_dev: The AMS server frp-oms/phrozen_master is NOT in that zip — it comes from the printer's" >&2
echo "  phrozen_dev: original OS. Restore it from your own arco-phrozen-ams.tar.gz (collect_data_arco.sh)." >&2
# Never fail the unit: klippy's own config error names the problem more precisely than we can.
exit 0
