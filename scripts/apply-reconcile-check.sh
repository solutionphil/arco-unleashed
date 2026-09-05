#!/bin/bash
# apply-reconcile-check.sh — notice that the kit has moved since the last root-side run, and arm the
# reconcile so it happens.
#
# THE HOLE THIS CLOSES. A kit update can bring things only root can install: a systemd unit, a drop-in,
# a line in /etc. Nothing in the update path has root, so selfupdate.sh arms a marker and asks for a
# power-cycle, and ensure-imageid.sh -- the one guard that runs with '+' -- acts on it at the next boot.
#
# That works when the owner updates from the setup menu. It does nothing at all when they update from
# Mainsail or Fluidd, because Moonraker's update manager is a plain `git pull` and never calls
# after_update(). The convenient route, which is the one most people take, therefore pulls the files onto
# the disk and leaves everything root-side unapplied -- silently, and for good, until somebody happens to
# open the menu.
#
# It is not hypothetical. On 2026-08-15 it hit the same printer twice in one day: first the startup
# banner and the welcome dialog were missing, then the macro groups. Both times the files were present,
# both times the reason was the same, and both times it was only found by going looking.
#
# WHY IT KEYS ON THE COMMIT. Arming from "who ran the update" means covering every path there is and
# every path there will be. Arming from "the kit is not the one root last saw" needs no such list: it
# compares what is here against what was here when optimize-boot.sh last finished, so it is right no
# matter how the change arrived -- menu, web interface, USB tarball, or somebody's own git pull.
#
# CHEAP. The steady state is "same commit", and reaching that answer is two small reads and a string
# compare. It runs before every klipper start, so it has no business being more than that.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$DIR/.." && pwd)"
DATA="$(cd "$KIT/.." && pwd)/printer_data"
MARK="$DATA/.arco-reconcile-pending"
STAMP="$DATA/.arco-reconcile-done"

[ -d "$DATA" ] || exit 0
# Already armed: the owner has been asked and has not power-cycled yet. Saying it again on every klipper
# restart would be nagging, and the marker is what matters, not the message.
[ -f "$MARK" ] && exit 0

# The commit this kit IS. A clone answers from git; the image's flat copy carries .kit-commit instead.
# If neither can say, do nothing -- guessing here would arm the reconcile on every boot for ever.
cur=""
if [ -d "$KIT/.git" ] && command -v git >/dev/null 2>&1; then
  # -c safe.directory: this also runs as ROOT (ensure-imageid.sh, drop-in 19) against a clone owned by
  # the printer user, and a plain `git -C` refuses that as dubious ownership. Without it the fallback
  # below answered with the flat .kit-commit baked into the image -- a value that never moves -- so
  # the stamp could never match and the root-side setup ran on EVERY klipper start: 56 runs in the
  # log on 2026-09-05, three of them for one and the same kit commit within twenty minutes, each a
  # 60 s run competing with Moonraker, Spoolman and the display for the two service cores. The same
  # trap, fixed the same way, sits in optimize-boot.sh where the stamp is written.
  cur="$(git -c safe.directory='*' -C "$KIT" rev-parse HEAD 2>/dev/null || true)"
  # A clone git cannot read is a fault to leave alone, not a reason to compare against a constant:
  # with .git present the flat file is never the truth.
  [ -n "$cur" ] || exit 0
fi
[ -n "$cur" ] || cur="$(tr -dc '0-9a-f' < "$KIT/.kit-commit" 2>/dev/null | head -c 40)"
[ -n "$cur" ] || exit 0

last="$(head -c 40 "$STAMP" 2>/dev/null || true)"
[ "$cur" = "$last" ] && exit 0

# Drop-in 19 runs this as root and starts the setup at once; drop-in 25 runs it again as the owner a
# few seconds later, while that run is still going and the stamp is not yet written. Re-arming then
# buys a second full run on the next start -- the log showed most kit commits recorded twice.
if systemctl is-active --quiet arco-reconcile.service 2>/dev/null; then
  exit 0
fi

# No stamp at all is the interesting case rather than an error: it means optimize-boot.sh has never
# recorded a run here, which is true of a printer updated from the web interface since before this guard
# existed. Arm it once; from then on the stamp keeps it quiet.
if ( : > "$MARK" ) 2>/dev/null; then
  sync
  if [ -z "$last" ]; then
    echo "  kit: root-side setup has never run against this version — armed for the next start"
  else
    echo "  kit: updated since the last root-side setup (${last:0:8} -> ${cur:0:8}) — armed"
  fi
  echo "  kit: >> please POWER-CYCLE the printer once. Nothing is lost by leaving it until later."
else
  echo "  kit: cannot arm the root-side setup ($MARK is not writable)." >&2
  echo "  kit: run it by hand instead:  sudo bash $DIR/optimize-boot.sh" >&2
fi
exit 0
