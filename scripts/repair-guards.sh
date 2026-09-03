#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# repair-guards.sh — put the self-heal guards back when a power-cycle truncated them.
#
#   bash repair-guards.sh              check, and repair inline (the caller waits)
#   bash repair-guards.sh --detach     check, and hand the repair to systemd (the caller returns)
#
# WHY THIS EXISTS. / is mounted commit=120, so a file written seconds before the plug is pulled can
# come back with its directory entry intact and its contents gone. On 02.09.2026 the dev printer came
# back from exactly that with SIX guard drop-ins present and 0 bytes long. The names survive, the
# ExecStartPre lines do not, and every guard they carried silently stops running.
#
# WHAT MAKES IT A DEAD END. 19-arco-imageid.conf is the only drop-in with a root-privileged
# ExecStartPre (the '+'), and it is the only thing that consumes the reconcile marker. Lose it and
# drop-in 25 keeps arming .arco-reconcile-pending while nothing can apply it. A kit update still
# arrives -- git runs as the owner -- and cannot put itself into effect.
#
# HOW IT REACHES A PRINTER ALREADY IN THAT STATE. Not as a new unit: installing one needs root, which
# is what is gone. It rides in apply-console-filters.sh, which arco-console-filters.service -- a FULL
# unit file, root, enabled -- runs from the kit clone, so a normal update changes what it does. Once
# optimize-boot.sh has run again it installs arco-guard-repair.service, ordered before klipper, and
# that one repairs in the same boot instead of the next.
#
# ── FOUR THINGS THIS GOT WRONG THE FIRST TIME, all found by review before it shipped ──────────────
#
# 1. "ANY zero-length .conf" made the repair unfixable. A 0-byte file this kit does not write -- one an
#    owner or another project left behind -- would never be repaired by optimize-boot.sh, so the check
#    stayed true and ran a 60-second script on EVERY boot for ever. The set is now derived from the
#    lines that WRITE a drop-in, not from every mention of a path -- the first attempt at this fix got
#    that wrong too, and swept in a file the KAOS sideloader owns. Only a file this kit actually
#    writes can count as damage.
#
# 2. A guard the owner deliberately switched OFF looked like the dead end. guards-toggle.sh renames a
#    drop-in to .conf.disabled, so switching off 19-arco-imageid removes the root ExecStartPre by
#    design -- and with a reconcile armed, check 2 fired and reinstalled it every boot, silently
#    undoing the decision guards-toggle exists to make. It now yields to .conf.disabled.
#
# 3. Nothing bounded the retries. If a repair does not fix the damage, running it again every boot
#    for ever is not self-healing, it is a loop. The signature of what was damaged is recorded, and
#    the same signature is not attempted twice; a changed kit or changed damage clears it.
#
# 4. `bash` on an EMPTY optimize-boot.sh exits 0, so the repair announced success having done nothing
#    -- and an empty optimize-boot.sh is precisely what the failure this repairs would produce. Its
#    size is checked, and the repair is confirmed by re-testing rather than by an exit code.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SELFDIR="$(cd "$(dirname "$0")" && pwd)"
DD_ROOT="${ARCO_SYSTEMD_DIR:-/etc/systemd/system}"
AHOME="${ARCO_HOME:-$(dirname "$(cd "$SELFDIR/.." && pwd)")}"
OB="$SELFDIR/optimize-boot.sh"
STAMP="$AHOME/printer_data/.arco-guard-repair-failed"
RLOG="$AHOME/printer_data/logs/arco-guard-repair.log"
DETACH=0
[ "${1:-}" = "--detach" ] && DETACH=1

# The owner can switch this off like any other guard (guards-toggle.sh: guard_repair). One marker,
# honoured here, because there are two callers and a switch that only reached one of them would be a
# lie. Checked before anything is printed: "off" means silent, not "quietly declined".
OFFMARK="${ARCO_GUARD_REPAIR_OFF:-/etc/arco-guard-repair.disabled}"
[ -e "$OFFMARK" ] && exit 0

log(){ echo "  guard-repair: $*"; }

# The drop-ins this kit writes, straight from the script that writes them -- never a hand-kept list,
# which is how check-guards.sh once reported a moonraker guard as missing from klipper for ever.
# Only the lines that actually WRITE a drop-in, matched the way .github/ci/check-guards-toggle.sh
# matches them. The first version grepped for the path ANYWHERE in optimize-boot.sh and so swept in
# three files it never writes: 21-kaos-guard.conf, which the KAOS sideloader writes, and
# 10-arco-nice/15-arco-mcu-timing, which this script only ever removes. A truncated 21-kaos-guard
# therefore counted as damage this repair cannot fix -- a full run before klipper, then "STILL
# DAMAGED", then a remedy that provably does not help because the file's writer is another script.
# The header below used to claim this was "derived the same way check-guards.sh derives its own". It
# was not: check-guards PAIRS the path with an ExecStartPre line, and that pairing is the whole point.
owned(){
  grep -oE '^[[:space:]]*(install|dropin) .*\$SD/[A-Za-z0-9_.-]+.service\.d/[A-Za-z0-9._-]+\.conf' "$OB" 2>/dev/null \
    | grep -oE '[A-Za-z0-9_.-]+.service\.d/[A-Za-z0-9._-]+\.conf' | sort -u
}

damage(){
  # 🔴 AN EMPTY LIST IS ITSELF THE WORST CASE. owned() greps optimize-boot.sh, and a truncated
  # optimize-boot.sh -- precisely what this failure produces -- yields nothing. Without this the loop
  # below would run zero times, find no damage, and exit silently at the one moment it matters most.
  # The size check further down never gets reached, because it sits after the damage test.
  if [ -z "$(owned)" ]; then
    printf '%s' "cannot-read-guard-list-from-optimize-boot"
    return
  fi
  local d="" rel f
  while read -r rel; do
    [ -n "$rel" ] || continue
    f="$DD_ROOT/$rel"
    # Absent is not damage: it may never have been installed, and .conf.disabled is the owner's choice.
    [ -e "$f" ] || continue
    [ -s "$f" ] || d="$d $(basename "$rel")"
  done <<< "$(owned)"
  # The dead end, for the case where a file came back non-empty but wrong. Skipped when the owner
  # switched that guard off on purpose -- then having no root ExecStartPre is the intended state.
  if [ -f "$AHOME/printer_data/.arco-reconcile-pending" ] \
     && [ ! -e "$DD_ROOT/klipper.service.d/19-arco-imageid.conf.disabled" ] \
     && ! systemctl cat klipper.service 2>/dev/null | grep -q 'ExecStartPre=+'; then
    d="$d reconcile-has-no-root-consumer"
  fi
  printf '%s' "${d# }"
}

damaged="$(damage)"
[ -n "$damaged" ] || exit 0            # the healthy path: a stat over a dozen files

log "damage found: $damaged"

[ "$(id -u)" = 0 ] || { log "not root — run: sudo bash $OB && sync"; exit 0; }
[ -s "$OB" ] || { log "optimize-boot.sh is missing or itself empty — cannot repair"; exit 0; }

# Do not attempt the same damage twice. A repair that did not take is a fault to report, not a reason
# to spend a minute of every boot on it for ever.
sig="$(git -C "$SELFDIR/.." rev-parse --short HEAD 2>/dev/null || echo nogit)|$damaged"
if [ "$(cat "$STAMP" 2>/dev/null)" = "$sig" ]; then
  log "this exact damage already survived a repair — not retrying. Run by hand: sudo bash $OB && sync"
  exit 0
fi

if [ "$DETACH" = 1 ] && command -v systemd-run >/dev/null 2>&1; then
  # The caller here is a Type=oneshot unit that multi-user.target waits for. Running a 60-second
  # script inside it would hold up the boot -- this kit has already lost 8m36s to exactly that shape.
  log "handing the repair to systemd (this boot's guards are repaired for the NEXT start)"
  systemd-run --collect --unit=arco-guard-repair-run \
    --description="Arco Unleashed - guard repair" /bin/bash "$OB" >/dev/null 2>&1 && exit 0
  log "systemd-run refused — running inline instead"
fi

mkdir -p "$(dirname "$RLOG")" 2>/dev/null || true
log "re-running optimize-boot.sh (output in $RLOG)"
bash "$OB" >>"$RLOG" 2>&1
# The exit code is not the evidence: ask the same question again. If it still answers yes, the repair
# did not take, and the answer is recorded so the next boot does not repeat it.
left="$(damage)"
if [ -z "$left" ]; then
  sync 2>/dev/null || true
  rm -f "$STAMP" 2>/dev/null || true
  log "repaired. The guards run from the next start of the service they sit on."
else
  printf '%s' "$sig" > "$STAMP" 2>/dev/null || true
  log "STILL DAMAGED after the repair: $left — see $RLOG. Not retrying automatically."
fi
exit 0
