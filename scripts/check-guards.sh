#!/bin/bash
# check-guards.sh — are the self-heal guards actually wired into the services that run them?
#
# Everything this project patches heals itself, but only because a service carries an ExecStartPre for
# each guard — klipper.service for nearly all of them, moonraker.service for the update-manager entry.
# Those drop-ins are written by optimize-boot.sh when the image is built or the kit is set up — NOT
# when the kit updates itself. So a printer that has been running for a while can be missing a guard
# that the current kit takes for granted, and nothing says so: the printer looks fine until the exact
# failure that guard exists to catch.
#
# That is not hypothetical. On the dev printer, 14-arco-core-restore was absent for weeks after the kit
# gained it, which is why a voronFDM clobber still had to be repaired by hand.
#
# This compares what each service actually runs against what the kit's own optimize-boot.sh installs —
# so the expected list has one source of truth and cannot drift from it.
#
# Usage:  bash check-guards.sh [--fix]
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

OB="$DIR/optimize-boot.sh"
[ -f "$OB" ] || { echo "ERROR: optimize-boot.sh not found next to this script."; exit 1; }

# The kit's own installer is the reference, and it is read PER SERVICE. Until the Moonraker
# update-manager entry every guard lived on klipper.service and a flat list was enough. That one runs
# on moonraker.service, and checking it against klipper would report it missing on every printer,
# forever -- the precise kind of false alarm that teaches people to ignore this output. In
# optimize-boot.sh the drop-in path names the service and always precedes the ExecStartPre lines
# belonging to it, so one pass yields "<service> <script>" pairs.
expected=$(awk '
  /service\.d\// { s = $0; sub(/.*\$SD\//, "", s); sub(/\.service\.d\/.*/, "", s); svc = s }
  /ExecStartPre=/ && svc != "" {
      if (match($0, /(apply|ensure)-[a-z-]+\.sh/)) print svc " " substr($0, RSTART, RLENGTH)
  }' "$OB" | sort -u)
[ -n "$expected" ] || { echo "ERROR: could not read the expected guards from optimize-boot.sh."; exit 1; }

# A guard the owner switched off with guards-toggle.sh is NOT missing, and must not be reinstalled by
# --fix: that would silently undo a deliberate decision, which is the exact behaviour guards-toggle
# exists to make controllable. Those drop-ins are kept as *.conf.disabled, so they are still on disk
# and distinguishable from one that was never installed at all.
turned_off=$(cat /etc/systemd/system/*.service.d/*.conf.disabled 2>/dev/null \
             | grep -oE '(apply|ensure|kaos)-[a-z-]+\.sh' | sort -u)

missing=""
for svc in $(printf '%s\n' "$expected" | awk '{print $1}' | sort -u); do
  hdr="Self-heal guards on $svc.service"
  echo "$hdr"
  printf '%*s\n' "${#hdr}" '' | tr ' ' '-'
  installed=$(systemctl cat "$svc" 2>/dev/null | grep -oE '(apply|ensure)-[a-z-]+\.sh' | sort -u)
  want=$(printf '%s\n' "$expected" | awk -v s="$svc" '$1 == s { print $2 }')

  while read -r g; do
    [ -n "$g" ] || continue
    if printf '%s\n' "$installed" | grep -qx "$g"; then
      printf "  ok       %s\n" "$g"
    elif printf '%s\n' "$turned_off" | grep -qx "$g"; then
      printf "  off      %s  (switched off on purpose — setup menu > guards)\n" "$g"
    else
      printf "  MISSING  %s\n" "$g"
      missing="$missing $g"
    fi
  done <<EOF
$want
EOF

  # Anything wired that the kit no longer ships is stale — it points at a script that may be gone.
  while read -r g; do
    [ -n "$g" ] || continue
    printf '%s\n' "$want" | grep -qx "$g" && continue
    printf "  STALE    %s  (wired, but this kit no longer installs it)\n" "$g"
    [ -f "$DIR/$g" ] || printf "           and the script is not in the kit either — that guard fails on every start\n"
  done <<EOF
$installed
EOF
  echo
done

# --------------------------------------------------------- single-axis home guard (printer.cfg)
# Reported from a printer on 2026-08-08: toolhead at the back, firmware restart, `G28 X`, crash.
# Phrozen's [homing_override] carries `axes: z`, so a single-axis home never reaches it and skips the
# body's own `G28 Y0` -> `G1 Y50` -> `G28 X0` order — and a restart does not leave the machine
# unhomed, because SET_KINEMATIC_POSITION reports 150/150/150 no matter where the head is.
#
# apply-config-patches.sh repairs this before every klipper start, so a healthy printer is silent
# here. It is still worth checking: printer.cfg is never regenerated on an existing printer, this is
# the one guard whose absence ends in a mechanical crash rather than an error message, and on a
# machine running KAOS's own section our patch deliberately stands aside — which is a different state
# worth naming rather than passing over.
PCFG_H="${HOME:-/home/mks}/printer_data/config/printer.cfg"
home_trouble=""
if [ -f "$PCFG_H" ]; then
  echo "Single-axis home guard (G28 X / G28 Y)"
  echo "--------------------------------------"
  if grep -qF 'unleashed-x-kaos: homing_override replaced with KAOS' "$PCFG_H"; then
    echo "  n/a      KAOS's own [homing_override] is installed — our patch stands aside there."
    echo "           Note KAOS homes X without bringing Y clear first, so the crash above is"
    echo "           still possible under KAOS. Reported upstream; KAOS_OFF restores the"
    echo "           guarded vendor section."
  elif grep -qF 'arco-unleashed: single-axis home guard' "$PCFG_H"; then
    echo "  ok       [homing_override] is axis-aware — G28 X homes Y clear before X travels"
  else
    echo "  MISSING  G28 X would home X wherever Y happens to be — crash risk with the"
    echo "           toolhead at the back after a firmware restart"
    echo "           repair:  bash $DIR/apply-config-patches.sh"
    echo "                    then: sudo systemctl restart klipper"
    home_trouble=1
  fi
  echo
fi

# ------------------------------------------------------------------- KAOS trust chain
# Soft and optional: the bridge is a separate add-on and most printers do not have it. But when it
# IS installed there is one failure it cannot announce itself — a bridge predating 2026-07-27 has
# no kaos-home-hook.sh, and that helper is the only thing that can put the _ARCO_POST_HOME_HOOK
# call into [homing_override]. printer.cfg is never regenerated on an existing printer, so the call
# does not arrive with a kit update either. Result: the trust wiring loads, KAOS's motion guard
# arms, and no amount of homing can grant trust. The printer homes and then refuses to move, and
# from the display that reads as the cutter calibration stopping dead at 0.0.
KAOS_DIR="$(cd "$DIR/.." 2>/dev/null && pwd || echo /nonexistent)/unleashed-x-kaos"
PCFG="${HOME:-/home/mks}/printer_data/config/printer.cfg"
kaos_trouble=""
if [ -d "$KAOS_DIR" ] && [ -f "$PCFG" ]; then
  echo "Unleashed x KAOS trust chain"
  echo "---------------------------"
  if ! grep -qE '^[[:space:]]*\[include kaos-trust-wiring\.cfg\]' "$PCFG"; then
    echo "  n/a      trust wiring is not included (KAOS off) — no post-home hook expected"
  elif grep -qF 'unleashed-x-kaos: homing_override replaced with KAOS' "$PCFG"; then
    # There are two ways a home can reach KAOS, and only one of them is the hook. When the bridge
    # has installed KAOS's own homing_override, that section grants trust itself -- per axis, at the
    # moment each is earned -- and the hook is deliberately absent, because it would grant full XYZ
    # after a home of X alone. Reporting that as MISSING is a false alarm, and a false alarm here
    # teaches people to stop reading this output.
    echo "  ok       KAOS's own [homing_override] is installed — it grants trust per axis"
    echo "           (trust does NOT survive a klipper restart: home again after every one)"
  elif grep -qE '^[[:space:]]*_ARCO_POST_HOME_HOOK[[:space:]]*$' "$PCFG"; then
    echo "  ok       post-home hook is in [homing_override] — a home can grant trust"
    echo "           (trust does NOT survive a klipper restart: home again after every one)"
  else
    echo "  MISSING  post-home hook — homing can never grant trust, so KAOS blocks every travel"
    if [ -f "$KAOS_DIR/scripts/kaos-home-hook.sh" ]; then
      echo "           repair:  bash $KAOS_DIR/scripts/kaos-home-hook.sh apply $PCFG"
      echo "                    then: sudo systemctl restart klipper   and  G28"
    else
      echo "           this bridge has no scripts/kaos-home-hook.sh — it predates the fix."
      echo "           Update the unleashed-x-kaos bridge; without that helper nothing on the"
      echo "           printer is able to add the hook, and the next klipper start cannot repair it."
    fi
    kaos_trouble=1
  fi
fi

echo
if [ -z "$missing" ]; then
  if [ -n "$kaos_trouble" ]; then
    echo "The kit's own guards are all in place, but the KAOS trust chain above is broken."
    exit 1
  fi
  echo "All guards this kit expects are in place."
  exit 0
fi

echo "Missing:$missing"
echo "These are installed by optimize-boot.sh, which is idempotent and safe to re-run."
if [ "$FIX" = 0 ]; then
  echo "Re-run this with --fix, or run it yourself:  sudo bash $OB"
  exit 1
fi

echo
echo ">> running optimize-boot.sh to install them"
if sudo -n bash "$OB" 2>/dev/null || sudo bash "$OB"; then
  echo
  echo ">> re-checking"
  # Across every service the installer writes to, not just klipper — a moonraker guard reinstalled
  # here would otherwise still be reported as missing.
  installed=$(for s in $(printf '%s\n' "$expected" | awk '{print $1}' | sort -u); do
                systemctl cat "$s" 2>/dev/null
              done | grep -oE '(apply|ensure)-[a-z-]+\.sh' | sort -u)
  still=""
  for g in $missing; do
    printf '%s\n' "$installed" | grep -qx "$g" || still="$still $g"
  done
  if [ -z "$still" ]; then
    echo "  all guards present now."
  else
    echo "  STILL MISSING:$still — check the output above."
    exit 1
  fi
else
  echo "  could not run optimize-boot.sh (needs root). Run:  sudo bash $OB"
  exit 1
fi
