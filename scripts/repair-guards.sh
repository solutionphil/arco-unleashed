#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# repair-guards.sh — put the self-heal guards back when a power-cycle truncated them.
#
# WHY THIS EXISTS. / is mounted commit=120, so a file written seconds before the plug is pulled can
# come back with its directory entry intact and its contents gone. On 02.09.2026 the dev printer came
# back from exactly that with SIX guard drop-ins present and 0 bytes long. The names survive, the
# ExecStartPre lines do not, and every guard they carried silently stops running.
#
# WHAT MAKES IT A DEAD END RATHER THAN A NUISANCE. 19-arco-imageid.conf is the only drop-in with a
# root-privileged ExecStartPre (the '+' prefix), and it is the only thing that ever consumes the
# reconcile marker. Lose it and drop-in 25 keeps arming .arco-reconcile-pending while nothing can
# apply it: the printer asks for a power-cycle for ever and installs nothing. A kit update still
# arrives -- git runs as the owner -- but it cannot put itself into effect. Until now the only exit
# was an SSH session and optimize-boot.sh by hand.
#
# HOW IT GETS ONTO A PRINTER THAT IS ALREADY IN THAT STATE. Not as a new unit: installing one needs
# root, which is the thing that is gone. It rides in a script that a SURVIVING root unit already
# runs. Full unit files do not suffer the drop-in's fate, and arco-console-filters.service is root,
# enabled, WantedBy=multi-user.target, and its first ExecStart is a kit script -- so a normal update
# changes what it does. That is the bootstrap, and it costs no new install step.
#
# Once optimize-boot.sh has run again it installs arco-guard-repair.service, which is ordered BEFORE
# klipper and therefore heals the same boot instead of the next one. This script is the way in; that
# unit is the way it should work from then on.
#
# 🔴 THE TEST IS SIZE, NOT CONTENT. "Has no ExecStartPre" looks like the better check and is wrong:
# 20-arco-affinity.conf (CPUAffinity), arco-nice.conf (Nice) and 20-arco-numpy.conf (Environment)
# legitimately carry none. A zero-length drop-in, on the other hand, is never anything but damage.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -u

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
DD_ROOT="${ARCO_SYSTEMD_DIR:-/etc/systemd/system}"
AHOME="${ARCO_HOME:-/home/mks}"

log(){ echo "  guard-repair: $*"; }

# Never break the host script. It runs the console filters and the macro groups after us, and a
# printer that heals nothing is still better than one that also loses those.
trap 'exit 0' ERR

damaged=""

# 1. Any zero-length drop-in of ours, on either service.
for svc in klipper moonraker; do
  d="$DD_ROOT/$svc.service.d"
  [ -d "$d" ] || continue
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    if [ ! -s "$f" ]; then
      damaged="$damaged $(basename "$f")"
    fi
  done
done

# 2. The dead end itself, in case the file came back non-empty but wrong: a reconcile is armed and
#    no root-privileged ExecStartPre exists to consume it.
if [ -f "$AHOME/printer_data/.arco-reconcile-pending" ] \
   && ! systemctl cat klipper.service 2>/dev/null | grep -q 'ExecStartPre=+'; then
  damaged="$damaged reconcile-has-no-root-consumer"
fi

if [ -z "$damaged" ]; then
  exit 0                      # the healthy path, and it is a stat over a dozen files
fi

log "damage found:$damaged"

if [ "$(id -u)" != 0 ]; then
  log "not root — cannot repair. Run: sudo bash $SELFDIR/optimize-boot.sh && sync"
  exit 0
fi

if [ ! -x "$SELFDIR/optimize-boot.sh" ] && [ ! -f "$SELFDIR/optimize-boot.sh" ]; then
  log "optimize-boot.sh is missing from $SELFDIR — cannot repair"
  exit 0
fi

log "re-running optimize-boot.sh to reinstall them"
if bash "$SELFDIR/optimize-boot.sh" >/dev/null 2>&1; then
  sync 2>/dev/null || true
  log "repaired. The guards run from the next start of the service they sit on."
else
  # Deliberately no back-off marker. A failure that repeats every boot is a fault worth seeing in the
  # log every boot; suppressing it would hide exactly the case somebody needs to be told about.
  log "optimize-boot.sh failed — repair not complete, will try again next boot"
fi
exit 0
