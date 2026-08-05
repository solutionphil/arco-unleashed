#!/bin/bash
# sensorless_toggle.sh — switch XY homing between the physical microswitches and StallGuard.
#
#   sensorless_toggle.sh [status|on|off|reapply]
#
# Z is never touched. It keeps its load-cell probe and its own homing_override.
#
# ── What this is for ─────────────────────────────────────────────────────────────────────────────
# X's microswitch hangs off the TOOLHEAD MCU (!MKS_THR:PB12) while its DIAG line goes to the main
# MCU. A broken toolhead cable therefore kills X homing but NOT the sensorless path -- which makes
# this a genuine repair option, not just a party trick.
#
# ── What it changes, and why each one is needed ──────────────────────────────────────────────────
#   [stepper_x] / [stepper_y]  endstop_pin -> tmc5160_...:virtual_endstop
#   [stepper_y] (or x)         homing_speed equalised, because StallGuard's reading is
#                              velocity-dependent: two axes at different speeds cannot share a
#                              sensitivity value, and one of them will be wrong.
#   [include sensorless.cfg]   a delayed_gcode that gates StallGuard by velocity. Without it Klipper
#                              substitutes tcoolthrs=0xfffff at homing and StallGuard is armed at
#                              STANDSTILL -- the endstop reads triggered before the carriage moves,
#                              and every G28 ends in a twitch regardless of sgt. That symptom cost
#                              this project several sessions before it was understood.
#
# Sensitivity itself (driver_SGT) is NOT written here. It is already 1 in the shipped config, which
# is the value proven on hardware at 30 mm/s and 1.2 A; if a machine needs a different one it
# belongs in printer.cfg where the owner can see it, not buried in a toggle.
#
# ── How it is reversible ─────────────────────────────────────────────────────────────────────────
# Same convention as beacon_toggle.sh: lines are DISABLED by prefixing "#:sl:" and never rewritten,
# so `off` is a prefix strip that cannot corrupt a value. Lines this script ADDS carry a trailing
# "#:sl+" so `off` can delete exactly those and nothing else.
#
# A Phrozen firmware update ships its own printer.cfg and would silently restore the microswitches
# while the owner believes the machine is sensorless. The marker file, not printer.cfg, is the
# source of truth: `reapply` is called from apply-config-patches.sh before klippy parses anything.
set -uo pipefail

CFG="${ARCO_CONFIG:-$HOME/printer_data/config}"
PRINTER="$CFG/printer.cfg"
SL_CFG="$CFG/sensorless.cfg"
MARKER="$CFG/.sensorless-mode"
DIR="$(cd "$(dirname "$0")" && pwd)"
TPL="$DIR/../config-templates/sensorless.cfg.template"
API="http://127.0.0.1:7125"

C0=$'\033[0m'; CR=$'\033[31m'; CG=$'\033[32m'; CY=$'\033[33m'; CW=$'\033[97m'; CC=$'\033[36m'
say(){ printf "   $*\n"; }
die(){ printf "${CR}   ERROR: %s${C0}\n" "$*"; exit 1; }

[ -f "$PRINTER" ] || die "no printer.cfg at $PRINTER"

is_on(){ grep -qE '^[[:space:]]*\[include sensorless\.cfg\]' "$PRINTER" 2>/dev/null; }

axis_mode(){   # $1 = x|y  -> "sensorless" | "switch" | "unknown"
  local st="stepper_$1"
  local line
  line=$(awk -v S="[$st]" '$0==S{f=1;next} f&&/^\[/{f=0} f&&/^[[:space:]]*endstop_pin/' "$PRINTER" | head -1)
  case "$line" in
    *virtual_endstop*) echo sensorless ;;
    "")                echo unknown ;;
    *)                 echo switch ;;
  esac
}

cmd_status(){
  printf "\n   ${CW}Sensorless XY homing${C0}\n"
  if is_on; then printf "   mode:    ${CG}ON${C0}\n"; else printf "   mode:    ${CW}off (microswitches)${C0}\n"; fi
  for a in x y; do
    local m; m=$(axis_mode "$a")
    # Anchor to a line that is NOT commented. Once this toggle is on, the section holds BOTH the
    # disabled original ("#:sl:homing_speed:50") and the active one, and an unanchored match picks
    # the first -- reporting the value the printer is not using.
    local sp; sp=$(awk -v S="[stepper_$a]" '$0==S{f=1;next} f&&/^\[/{f=0} f&&/^[[:space:]]*homing_speed[[:space:]]*:/' "$PRINTER" | head -1 | grep -oE '[0-9.]+' | head -1)
    printf "   %s:       %-11s homing_speed %s\n" "$(echo "$a" | tr 'a-z' 'A-Z')" "$m" "${sp:-?}"
  done
  [ -f "$MARKER" ] && printf "   marker:  %s\n" "$MARKER"
  [ -f "$SL_CFG" ] && printf "   config:  %s\n" "$SL_CFG"
  # Deliberately generic. Third-party tuning add-ons can own sgt and tcoolthrs and rewrite them at
  # every connect, which turns a working setup into an intermittent one -- but this kit does not
  # ship any of them and has no business naming, endorsing or configuring one. Describe the
  # SYMPTOM and the two fields, and let the owner recognise their own add-on.
  if grep -rlqE '^\[(autotune|.*_tune)' "$CFG"/*.cfg 2>/dev/null; then
    printf "   ${CY}note:    another config section is set up to tune your drivers. Anything that\n"
    printf "            rewrites ${CW}sgt${C0}${CY} or ${CW}tcoolthrs${C0}${CY} after start will fight this and make homing\n"
    printf "            intermittent. Check ${CW}DUMP_TMC STEPPER=stepper_x${C0}${CY} if it becomes unreliable.${C0}\n"
  fi
  printf "\n"
}

# ---------------------------------------------------------------------------------------------
# printer.cfg surgery
# ---------------------------------------------------------------------------------------------
edit_printer(){   # $1 = on|off
  python3 - "$PRINTER" "$1" <<'PYEOF'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
S    = "#:sl:"      # prefix = we disabled this line
ADD  = "#:sl+"      # trailing marker = we added this line
src = open(path, encoding="utf-8", errors="surrogateescape").read()
nl = "\r\n" if "\r\n" in src else "\n"
lines = src.replace("\r\n", "\n").split("\n")

def bare(l):
    # Strip OUR markers so a line matches whether or not we have touched it. Prefix strip, not
    # str.lstrip(S): that strips CHARACTERS, so "#:sl:[stepper_x]" would come back as "tepper_x]"
    # and match nothing. The trailing marker has to come off too, or every "is it already there?"
    # check fails on the second run and the toggle duplicates its own edits.
    t = l.strip()
    if t.startswith(S):
        t = t[len(S):].strip()
    if t.endswith(ADD):
        t = t[:-len(ADD)].strip()
    return t

def is_header(l):
    b = bare(l)
    return b.startswith("[") and b.endswith("]")

def section_range(name):
    want = "[%s]" % name
    for i, l in enumerate(lines):
        if bare(l) == want:
            j = i + 1
            while j < len(lines) and not is_header(lines[j]):
                j += 1
            return i, j
    return None, None

def find_opt(sec, opt, want_disabled=None, value_re=None):
    """Index of an option line inside a section. want_disabled selects our own commented copies."""
    a, b = section_range(sec)
    if a is None:
        return None
    pat = re.compile(r'^\s*(#\s*|%s)?\s*%s\s*[:=]\s*(.*)$' % (re.escape(S), re.escape(opt)))
    for i in range(a + 1, b):
        m = pat.match(lines[i])
        if not m:
            continue
        disabled = lines[i].strip().startswith("#")
        if want_disabled is not None and disabled != want_disabled:
            continue
        if value_re and not re.search(value_re, m.group(2) or ""):
            continue
        return i
    return None

changed = []

if mode == "on":
    for ax in ("x", "y"):
        sec = "stepper_%s" % ax
        ai = find_opt(sec, "endstop_pin", want_disabled=False)
        if ai is None:
            print("MISSING:%s" % sec); sys.exit(3)
        if "virtual_endstop" in bare(lines[ai]):
            continue                      # already ours — running twice must change nothing
        # Deliberately NOT "uncomment the virtual line Phrozen ships". That conflates two different
        # undo actions -- delete a line we added vs. re-comment a line we enabled -- and the first
        # version of this got it wrong: `off` deleted a line that had been in the file all along.
        # Disable the active one and add our own instead; the shipped commented line is never
        # touched, so the round trip is exact by construction.
        lines[ai] = S + lines[ai]
        lines.insert(ai + 1, "endstop_pin: tmc5160_%s:virtual_endstop   %s" % (sec, ADD))
        changed.append("%s: switch -> virtual endstop" % sec)

    # Equalise homing_speed. StallGuard is velocity-dependent, so two axes at different speeds
    # cannot share a sensitivity value. Level DOWN to the slower of the two -- never speed an axis
    # up as a side effect of enabling a homing mode.
    speeds = {}
    for ax in ("x", "y"):
        i = find_opt("stepper_%s" % ax, "homing_speed", want_disabled=False)
        if i is not None:
            m = re.search(r'[\d.]+', lines[i].split(":", 1)[1])
            if m:
                speeds[ax] = (i, float(m.group(0)))
    if len(speeds) == 2:
        target = min(v for _, v in speeds.values())
        # Reverse order: inserting shifts every later index, and stepper_y sits below stepper_x.
        for ax in ("y", "x"):
            if ax not in speeds:
                continue
            i, v = speeds[ax]
            if v != target:
                lines[i] = S + lines[i]
                lines.insert(i + 1, "homing_speed: %g   %s" % (target, ADD))
                changed.append("stepper_%s: homing_speed %g -> %g" % (ax, v, target))

    # The include. Must sit ABOVE the SAVE_CONFIG block: a real section after it stops Klipper
    # reading its saved values (control = pid), which halts the printer on the next boot.
    if not any(bare(l) == "[include sensorless.cfg]" for l in lines):
        last = max((i for i, l in enumerate(lines) if bare(l).startswith("[include ")), default=None)
        if last is None:
            print("NOINCLUDE"); sys.exit(3)
        lines.insert(last + 1, "[include sensorless.cfg]   %s" % ADD)
        changed.append("include added")

elif mode == "off":
    out = []
    for l in lines:
        if l.rstrip().endswith(ADD):
            changed.append("removed: %s" % l.strip()[:60]); continue      # a line we added
        if l.strip().startswith(S):
            out.append(l[len(S):] if l.startswith(S) else l.replace(S, "", 1))
            changed.append("restored: %s" % bare(l)[:60]); continue
        out.append(l)
    lines = out

open(path, "w", encoding="utf-8", errors="surrogateescape").write(nl.join(lines))
for c in changed:
    print("CHANGED:%s" % c)
PYEOF
}

is_printing(){
  local s; s=$(curl -s --max-time 4 "$API/printer/objects/query?print_stats" 2>/dev/null | grep -oE '"state":"[a-z]+"' | head -1)
  case "$s" in *printing*|*paused*) return 0 ;; *) return 1 ;; esac
}

restart_and_verify(){
  curl -s --max-time 5 -X POST "$API/printer/gcode/script?script=RESTART" >/dev/null 2>&1
  sleep 8
  local i s
  for i in $(seq 1 25); do
    s=$(curl -s --max-time 4 "$API/printer/info" 2>/dev/null | grep -oE '"state":"[a-z]+"' | head -1)
    [ "$s" = '"state":"ready"' ] && return 0
    sleep 2
  done
  return 1
}

rollback(){   # $1 = backup path
  cp -f "$1" "$PRINTER"
  restart_and_verify >/dev/null 2>&1 || true
  say "${CY}rolled back to $1${C0}"
}

cmd_on(){
  is_on && { say "already on"; cmd_status; return 0; }
  is_printing && die "a print is running — not touching the homing configuration"

  for ax in x y; do
    grep -qE "^\[tmc5160 stepper_$ax\]" "$PRINTER" || die "[tmc5160 stepper_$ax] not found — this printer is not wired for StallGuard on $ax"
    awk -v S="[tmc5160 stepper_$ax]" '$0==S{f=1;next} f&&/^\[/{f=0} f' "$PRINTER" | grep -qE '^[[:space:]]*diag1_pin' \
      || die "[tmc5160 stepper_$ax] has no diag1_pin — StallGuard has no way to signal a stall"
  done
  [ -f "$TPL" ] || die "missing $TPL"

  printf "\n   ${CW}Switch XY homing to StallGuard?${C0}\n\n"
  printf "${CY}   THIS IS AN ALTERNATIVE, NOT AN UPGRADE. The microswitches are the default and\n"
  printf "   they are what we recommend.${C0} They stop at the same physical place every time, for\n"
  printf "   free, with no tuning and nothing to go wrong. Sensorless homing exists here as a\n"
  printf "   ${CW}fallback${C0} — most usefully when a switch or its wiring has failed. On this printer\n"
  printf "   X's switch hangs off the TOOLHEAD MCU while its DIAG line goes to the main one, so a\n"
  printf "   broken toolhead cable kills the switch but not this path.\n\n"
  printf "   ${CW}If your switches work, leave this off.${C0}\n\n"
  printf "   What it does: ${CY}disconnects both microswitches${C0} from Klipper. They stay fitted, but\n"
  printf "   the printer stops at the wall by detecting motor load instead of by a contact.\n\n"
  printf "   If the sensitivity is wrong the carriage GRINDS into the rail instead of stopping,\n"
  printf "   and on CoreXY that drags the other axis with it. Have the printer in sight and be\n"
  printf "   ready with ${CW}M112${C0} the first few times.\n\n"
  printf "   Z is untouched — it keeps its load-cell probe.\n\n"
  printf "   Type ${CW}sensorless${C0} to proceed: "
  read -r ans
  [ "$ans" = "sensorless" ] || { say "cancelled — nothing changed"; return 1; }

  local bak="$PRINTER.pre-sensorless-$(date +%Y%m%d-%H%M%S)"
  cp -a "$PRINTER" "$bak"

  install -m644 "$TPL" "$SL_CFG" || { rollback "$bak"; die "could not install sensorless.cfg"; }
  chown "$(stat -c '%u:%g' "$PRINTER")" "$SL_CFG" 2>/dev/null || true

  local out; out=$(edit_printer on) || { rm -f "$SL_CFG"; cp -f "$bak" "$PRINTER"; die "edit failed: $out"; }
  echo "$out" | sed -n 's/^CHANGED:/   /p'

  : > "$MARKER"
  if restart_and_verify; then
    say "${CG}sensorless XY homing is ON${C0}"
    say "backup: $bak"
    say "Try ${CW}G28 X${C0} first, with the carriage mid-axis. You should HEAR the endstop click:"
    say "that is the proof it reached the wall — Klipper reports position 0 either way."
    return 0
  fi
  say "${CR}klipper did not come back${C0}"
  curl -s --max-time 4 "$API/printer/info" | tr ',' '\n' | grep -i state_message | head -2 | sed 's/^/     /'
  rm -f "$MARKER" "$SL_CFG"
  rollback "$bak"
  return 1
}

cmd_off(){
  is_on || { say "already off"; return 0; }
  is_printing && die "a print is running — not touching the homing configuration"
  local bak="$PRINTER.pre-sensorless-off-$(date +%Y%m%d-%H%M%S)"
  cp -a "$PRINTER" "$bak"
  local out; out=$(edit_printer off) || { cp -f "$bak" "$PRINTER"; die "edit failed: $out"; }
  echo "$out" | sed -n 's/^CHANGED:/   /p'
  rm -f "$MARKER" "$SL_CFG"
  if restart_and_verify; then
    say "${CG}back on the microswitches${C0}"; say "backup: $bak"; return 0
  fi
  say "${CR}klipper did not come back${C0}"; rollback "$bak"; return 1
}

# Called from apply-config-patches.sh on every klipper start. A Phrozen update ships its own
# printer.cfg, which silently restores the microswitches while the owner believes the machine is
# sensorless -- and the first G28 then drives Z into a bed it thinks it has already found. The
# marker is the source of truth, not the config.
cmd_reapply(){
  [ -f "$MARKER" ] || exit 0
  is_on && exit 0
  [ -f "$TPL" ] || { echo "sensorless: marker present but $TPL is missing — cannot reapply"; exit 0; }
  install -m644 "$TPL" "$SL_CFG" 2>/dev/null || true
  chown "$(stat -c '%u:%g' "$PRINTER")" "$SL_CFG" 2>/dev/null || true
  local out; out=$(edit_printer on 2>&1) || { echo "sensorless: reapply failed: $out"; exit 0; }
  echo "sensorless: re-applied after a config replacement (marker $MARKER)"
  echo "$out" | sed -n 's/^CHANGED:/  /p'
  exit 0
}

case "${1:-status}" in
  status)  cmd_status ;;
  on)      cmd_on ;;
  off)     cmd_off ;;
  reapply) cmd_reapply ;;
  *) echo "usage: $(basename "$0") [status|on|off|reapply]"; exit 1 ;;
esac
