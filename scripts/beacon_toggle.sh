#!/bin/bash
# beacon_toggle.sh — EXPERIMENTAL: switch the Arco between Phrozen's piezo probe and a Beacon
# eddy-current probe (new probing device for meshing, virtual Z endstop).
#
# Why this is a script and not an AddOn.cfg feature: the feature menu can only comment blocks in
# AddOn.cfg. Beacon needs four things REMOVED from printer.cfg that no include can undo —
# [probe] (claims !PB9), [homing_override] (claims G28, and drives Z against the piezo),
# stepper_z's position_endstop (Klipper rejects it as unused with a virtual endstop) and
# stepper_z1's endstop_pin (a second endstop on the same rail). Everything additive lives in
# beacon.cfg via section merge; only those four are touched here, each marked with #:beacon:
# so `off` restores the file exactly.
#
# Usage:  beacon_toggle.sh status | on | off
#         BEACON_SERIAL=/dev/serial/by-id/...  beacon_toggle.sh on     (skip autodetect)
#
# `on` refuses to change anything unless the beacon module and the probe itself are present,
# and rolls the config back if Klipper does not come up.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="${ARCO_CONFIG:-$HOME/printer_data/config}"
PRINTER="$CFG/printer.cfg"
BEACON_CFG="$CFG/beacon.cfg"
TPL="$DIR/../config-templates/beacon.cfg.template"
KL="${KLIPPER_DIR:-$HOME/klipper}"
EXTRAS="$KL/klippy/extras"
MARKER="$CFG/.beacon-mode"
REPO="${BEACON_REPO:-https://github.com/beacon3d/beacon_klipper.git}"
SRC="$HOME/beacon_klipper"
# beacon.cfg holds the two values that are expensive to re-derive (measured y_offset, verified
# z_positions order). A Phrozen update can wipe printer_data/config, so keep a copy outside it —
# same reasoning as apply-phrozen-restore.sh keeping phrozen_dev out of the Klipper tree.
SAFE="$HOME/.arco-beacon/beacon.cfg"

C0='\033[0m'; CG='\033[1;32m'; CY='\033[1;33m'; CR='\033[1;31m'; CW='\033[1;37m'
say(){ printf "   $*\n"; }
die(){ printf "${CR}   ERROR: %s${C0}\n" "$*"; exit 1; }

[ -f "$PRINTER" ] || die "printer.cfg not found at $PRINTER"

# ---------------------------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------------------------
is_on(){ grep -qE '^[[:space:]]*\[include beacon\.cfg\]' "$PRINTER"; }
have_module(){ [ -f "$EXTRAS/beacon.py" ] || [ -L "$EXTRAS/beacon.py" ]; }
find_serial(){
  local s
  s="${BEACON_SERIAL:-}"
  [ -n "$s" ] && { echo "$s"; return 0; }
  s=$(ls /dev/serial/by-id/ 2>/dev/null | grep -i beacon | head -1)
  [ -n "$s" ] && echo "/dev/serial/by-id/$s"
}

cmd_status(){
  printf "${CW}   Beacon probe (experimental)${C0}\n"
  if is_on; then printf "   mode:    ${CG}BEACON${C0} (piezo probe sections disabled in printer.cfg)\n"
  else           printf "   mode:    ${CW}Phrozen piezo probe${C0} (stock)\n"; fi
  if have_module; then printf "   module:  ${CG}beacon.py present${C0} (out-of-tree — Klipper does not ship one)\n"
  else                 printf "   module:  ${CY}beacon.py NOT installed${C0} — \`on\` offers to fetch it (internet, once)\n"; fi
  local s; s=$(find_serial)
  if [ -n "$s" ]; then printf "   probe:   ${CG}%s${C0}\n" "$s"
  else                 printf "   probe:   ${CY}no Beacon on USB${C0}\n"; fi
  [ -f "$BEACON_CFG" ] && printf "   config:  %s\n" "$BEACON_CFG"
}

# ---------------------------------------------------------------------------------------------
# printer.cfg surgery — the ONLY four places, each marked so `off` is exact
# ---------------------------------------------------------------------------------------------
# Sentinel mirrors AddOn.cfg's "#:off:" convention: prefix, never rewrite. A commented line keeps
# its original text, so `off` is a prefix strip and cannot corrupt a value.
edit_printer(){   # $1 = on|off
  python3 - "$PRINTER" "$1" <<'PYEOF'
import re, shutil, sys
path, mode = sys.argv[1], sys.argv[2]
S = "#:beacon:"
src = open(path, encoding="utf-8", errors="surrogateescape").read()
nl = "\r\n" if "\r\n" in src else "\n"
lines = src.replace("\r\n", "\n").split("\n")

def bare(l):
    # strip OUR sentinel as a prefix. Not str.lstrip(S) -- that strips CHARACTERS, so
    # "#:beacon:[probe]" would come back as "probe]" and match nothing.
    t = l.strip()
    return t[len(S):].strip() if t.startswith(S) else t

def is_header(l):
    b = bare(l)
    return b.startswith("[") and b.endswith("]")

def section_range(name):
    # returns (start, end) of a [name] section: header .. line before the next section header
    want = "[%s]" % name
    for i, l in enumerate(lines):
        b = bare(l)
        if b == want or (b.startswith("#") and b.lstrip("#").strip() == want):
            j = i + 1
            while j < len(lines) and not is_header(lines[j]):
                j += 1
            return i, j
    return None, None

def disable_line(idx):
    if not lines[idx].startswith(S):
        lines[idx] = S + lines[idx]

def option_in(section, option):
    a, b = section_range(section)
    if a is None:
        return None
    pat = re.compile(r'^\s*(%s)?\s*%s\s*[:=]' % (re.escape(S), re.escape(option)))
    for k in range(a + 1, b):
        if pat.match(lines[k]):
            return k
    return None

changed = []
if mode == "on":
    # 1+2) whole sections: [probe] (same !PB9 pin) and [homing_override] (claims G28)
    for sec in ("probe", "homing_override"):
        a, b = section_range(sec)
        if a is not None and not lines[a].startswith(S):
            for k in range(a, b):
                if lines[k].strip():
                    disable_line(k)
            changed.append("disabled [%s]" % sec)
    # 3) stepper_z: position_endstop is UNREAD with a virtual endstop -> Klipper rejects it as an
    #    invalid option and refuses to start. endstop_pin/position_min are overridden by beacon.cfg.
    k = option_in("stepper_z", "position_endstop")
    if k is not None and not lines[k].startswith(S):
        disable_line(k); changed.append("disabled stepper_z position_endstop")
    # 4) stepper_z1: a second physical endstop on a rail homed by the probe
    k = option_in("stepper_z1", "endstop_pin")
    if k is not None and not lines[k].startswith(S):
        disable_line(k); changed.append("disabled stepper_z1 endstop_pin")
    if not re.search(r"(?m)^\s*\[include beacon\.cfg\]\s*$", "\n".join(lines)):
        # AT THE END, not with the other includes at the top. Klipper parses the lines between
        # includes as units in file order, so a section merge only overrides what was read
        # BEFORE it -- an include at the top would let printer.cfg's own [stepper_z] win and
        # the machine would silently keep homing Z against the (absent) piezo probe.
        while lines and not lines[-1].strip():
            lines.pop()
        lines += ["", "# Beacon probe (experimental) -- managed by scripts/beacon_toggle.sh.",
                  "# Must stay LAST: its section merges override the piezo values above.",
                  "[include beacon.cfg]", ""]
        changed.append("+ [include beacon.cfg] (at the end of the file)")
else:
    out = []
    for l in lines:
        if l.startswith(S):
            out.append(l[len(S):]); continue
        if l.strip() == "[include beacon.cfg]":
            changed.append("- [include beacon.cfg]"); continue
        if l.strip().startswith("# Beacon probe (experimental) -- managed by") or \
           l.strip().startswith("# Must stay LAST:"):
            continue                      # our own include banner, not the user's comment
        out.append(l)
    if len(out) != len(lines) or any(l.startswith(S) for l in lines):
        changed.append("restored the piezo probe sections")
    lines = out

if changed:
    shutil.copy2(path, path + ".beacon.bak")
    # newline="" -> write the line endings we chose verbatim. Without it Python would translate
    # every "\n" again and a CRLF file (Phrozen ships CRLF) would come back with "\r\r\n".
    with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(nl.join(lines))
print("\n".join("   " + c for c in changed) if changed else "   (printer.cfg already in that state)")
PYEOF
}

# ---------------------------------------------------------------------------------------------
# beacon module (fetched, never redistributed — same policy as everything third-party here)
# ---------------------------------------------------------------------------------------------
# Klipper does NOT ship this. Mainline v0.13 has generic eddy-current probe support
# (probe_eddy_current + ldc1612, for LDC1612-based probes such as BTT Eddy), but Beacon speaks its
# own protocol over its own MCU, so it needs the vendor's out-of-tree module. Verified against
# Klipper master: klippy/extras has probe_eddy_current.py and ldc1612.py, and no beacon.py.
install_module(){
  have_module && { say "beacon module: ${CG}already installed${C0} ($EXTRAS/beacon.py)"; return 0; }
  printf "
   The Beacon Klipper module is ${CY}not installed${C0}, and Klipper does not ship one — Beacon is
   out-of-tree (mainline only has probe_eddy_current for LDC1612 probes like BTT Eddy).

     download from : %s
     licence       : GPL-3.0 (beacon3d)
     goes to       : %s
     needs         : internet, once. Nothing is redistributed by this kit.
" "$REPO" "$EXTRAS/beacon.py"
  printf "   Download and install it now? [Y/n]: "; read -r yn
  case "${yn:-y}" in y|Y|"") ;; *) say "(declined — nothing was changed)"; return 1;; esac
  if [ ! -f "$SRC/beacon.py" ]; then
    say "cloning $REPO ..."
    git clone --depth 1 "$REPO" "$SRC" >/dev/null 2>&1 \
      || { printf "${CR}   could not clone %s${C0}\n" "$REPO"
           say "no internet? clone it on a PC, copy it to $SRC, then run this again."
           return 1; }
  else
    say "using the copy already in $SRC"
  fi
  # Copy, do not symlink: a symlink into a git clone breaks the moment that clone is updated or
  # removed, and it would break at the next klipper start rather than here where we can say so.
  install -Dm644 "$SRC/beacon.py" "$EXTRAS/beacon.py" || return 1
  say "installed $EXTRAS/beacon.py"
}

# Restarting Klipper mid-print ruins the print. Objective check, so it is not left to the warning
# text — and it is checked FIRST, before anything asks the user to decide something.
is_printing(){
  local R
  R=$(curl -s -m 4 "http://localhost:7125/printer/objects/query?print_stats" 2>/dev/null)
  echo "$R" | grep -qE '"state":[ ]*"(printing|paused)"'
}

restart_and_verify(){   # $1 = what to restore on failure ("on"/"off" -> the opposite)
  printf "   restarting Klipper "
  curl -s -m 5 -X POST "http://localhost:7125/printer/gcode/script?script=FIRMWARE_RESTART" >/dev/null 2>&1 \
    || sudo systemctl restart klipper >/dev/null 2>&1
  sleep 3
  local ok=-1 msg="" R
  for _ in $(seq 1 25); do
    R=$(curl -s -m 4 "http://localhost:7125/printer/info" 2>/dev/null)
    echo "$R" | grep -qE '"state":[ ]*"ready"' && { ok=1; break; }
    if echo "$R" | grep -qE '"state":[ ]*"(error|shutdown)"'; then
      ok=0
      msg=$(echo "$R" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'].get('state_message','')[:400])" 2>/dev/null)
      break
    fi
    printf "."; sleep 2
  done
  echo
  if [ "$ok" = 1 ]; then printf "${CG}   Klipper is ready.${C0}\n"; return 0; fi
  if [ "$ok" = 0 ]; then
    printf "${CR}   Klipper reports a config error:${C0}\n"; echo "$msg" | sed 's/^/        /'
  else
    printf "${CY}   Timed out waiting for Klipper.${C0}\n"
  fi
  return 1
}

rollback(){
  [ -f "$PRINTER.beacon.bak" ] || { say "no backup to roll back to"; return; }
  cp "$PRINTER.beacon.bak" "$PRINTER"
  rm -f "$MARKER"
  say "printer.cfg restored from $PRINTER.beacon.bak"
  restart_and_verify >/dev/null 2>&1 && printf "${CG}   rolled back, Klipper is ready.${C0}\n" \
    || printf "${CR}   rolled back but Klipper still unhappy — check Mainsail.${C0}\n"
}

cmd_on(){
  is_on && { say "already in Beacon mode."; cmd_status; return 0; }
  printf "${CY}
   ┌───────────────────────────────────────────────────────────────────────────┐
   │  Beacon as new probing device for meshing — EXPERIMENTAL                  │
   ├───────────────────────────────────────────────────────────────────────────┤
   │  * Nobody on the Arco Unleashed side has run this on a machine. It is      │
   │    built from one converted printer's config, contributed by a third       │
   │    party. Treat every number in beacon.cfg as a starting point.            │
   │                                                                           │
   │  * DO NOT USE THE ARCO DISPLAY FOR ANYTHING Z-RELATED afterwards:          │
   │    no Z-calibration, no auto-levelling, no mesh from the touchscreen.      │
   │    Its calibration flow assumes Phrozen's piezo probe, it declares Z       │
   │    positions instead of measuring them, and it loads a mesh probed with    │
   │    a different Z reference. Use Mainsail or Fluidd instead.                │
   │                                                                           │
   │  * FIRST MOVE AFTER SWITCHING: stay at the emergency stop. Home, then      │
   │    check z_tilt direction and the probe offset before you print.          │
   │                                                                           │
   │  * A Phrozen firmware update REPLACES printer.cfg and silently puts the    │
   │    piezo config back while a Beacon is on the toolhead. Run the menu's     │
   │    'Before/after a Phrozen update' step before printing again.            │
   └───────────────────────────────────────────────────────────────────────────┘${C0}
"
  # --- gate 1: is this even a safe moment? Objective, so nobody has to remember it -------------
  if is_printing; then
    die "a print is running or paused. Switching restarts Klipper — finish or cancel it first."
  fi

  # --- gate 2: the hardware question. Nothing here can be detected, so it has to be asked ------
  # Deliberately BEFORE the download: someone who has not fitted the probe yet should not end up
  # with a module installed and a half-finished conversion.
  printf "${CW}   Before anything is downloaded or changed — is the machine physically ready?${C0}
     * The Beacon is ${CW}mounted and wired${C0}, and its USB cable is plugged into the host.
     * Phrozen's piezo probe is no longer what senses the bed (it gets disabled here).
     * The mount is ${CW}rigid${C0} — a magnet-only cover gives phantom resonances and a noisy mesh.
     * The bed is ${CW}clear${C0}, the nozzle is clean, and nothing is in the way of a homing move.
   Is all of that true? [y/N]: "
  read -r hw
  case "$hw" in y|Y) ;; *) say "(cancelled — nothing was downloaded, nothing was changed)"; return 0;; esac

  # --- gate 3: the objective evidence that a Beacon really is attached -------------------------
  local serial; serial=$(find_serial)
  if [ -z "$serial" ]; then
    printf "${CY}   No Beacon found in /dev/serial/by-id.${C0}\n"
    say "That is the one thing this script can actually verify, and it says the probe is not there."
    say "Plug it in and run this again, or pass BEACON_SERIAL=... if you know the path."
    die "no probe detected — nothing was downloaded, nothing was changed."
  fi
  say "probe detected: ${CG}$serial${C0}"

  # --- gate 4: fetch the module (asks before downloading) -------------------------------------
  install_module || die "beacon module not installed — nothing else was changed."

  # --- gate 5: the config change itself --------------------------------------------------------
  printf "\n   This now rewrites printer.cfg (a backup is kept) and restarts Klipper.\n"
  printf "   Type ${CW}BEACON${C0} to continue, anything else to cancel: "; read -r confirm
  [ "$confirm" = "BEACON" ] || { say "(cancelled — printer.cfg untouched; the module stays installed, which is harmless)"; return 0; }

  if [ ! -f "$BEACON_CFG" ]; then
    [ -f "$TPL" ] || die "template missing: $TPL"
    sed "s|@BEACON_SERIAL@|$serial|" "$TPL" > "$BEACON_CFG"
    say "wrote $BEACON_CFG (from the kit template)"
  else
    say "keeping your existing $BEACON_CFG (delete it to get the template back)"
    grep -q "@BEACON_SERIAL@" "$BEACON_CFG" && sed -i "s|@BEACON_SERIAL@|$serial|" "$BEACON_CFG"
  fi

  edit_printer on
  install -Dm644 "$BEACON_CFG" "$SAFE" 2>/dev/null && say "kept a copy at $SAFE (survives a Phrozen update)"
  date -u +"beacon mode enabled %Y-%m-%dT%H:%M:%SZ" > "$MARKER"
  if restart_and_verify; then
    printf "${CG}
   Beacon mode is ON.${C0}
   Next, in Mainsail/Fluidd — NOT on the display:
     1) STEPPER_BUZZ STEPPER=stepper_z  and  STEPPER=stepper_z1
        Watch which side moves and fix the z_positions order in beacon.cfg if it is swapped.
        A wrong order makes Z_TILT_ADJUST diverge instead of converge.
     2) G28   then   Z_TILT_ADJUST
     3) BEACON_CAL     (contact auto-calibration at the bed centre)
     4) BEACON_MESH    (re-probe the mesh — the old one was probed with the piezo)
   Turn it back off any time with:  bash %s off\n" "$0"
  else
    printf "${CY}   Rolling back.${C0}\n"; rollback
    return 1
  fi
}

cmd_off(){
  is_on || { say "not in Beacon mode — nothing to do."; return 0; }
  say "restoring Phrozen's piezo probe config..."
  edit_printer off
  rm -f "$MARKER"
  # beacon.cfg is deliberately KEPT: it holds your measured y_offset and z_positions, which are
  # the expensive part to re-derive. Nothing reads it while the include is gone.
  say "beacon.cfg kept at $BEACON_CFG (your calibrated values); beacon.py left in place."
  if restart_and_verify; then
    printf "${CG}   Back on the Phrozen piezo probe.${C0}\n"
    say "If the Beacon is still on the toolhead, remember the piezo probe is what homes Z now."
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------------------------
# reapply — the update guard. Run from apply-config-patches.sh (ExecStartPre), so it happens
# BEFORE klippy parses the config on every start.
#
# This exists because a Phrozen firmware update REPLACES printer.cfg wholesale. Everything else
# in this kit degrades gracefully when that happens; this does not. Losing the beacon edits means
# the machine boots believing it has a piezo probe on !PB9 while a Beacon sits on the toolhead --
# the next G28 drives Z down waiting for a trigger that never comes. So the marker file is the
# source of truth, not printer.cfg: if the marker says Beacon and the config disagrees, the config
# is what is wrong.
#
# Deliberately silent and non-interactive: no prompts, no restart, no network, no serial check.
# It only restores what `on` already decided, and it is a no-op (one grep) on every machine that
# never enabled Beacon -- which is all of them by default.
cmd_reapply(){
  [ -f "$MARKER" ] || exit 0
  local fixed=0
  if ! have_module && [ -f "$SRC/beacon.py" ]; then
    install -Dm644 "$SRC/beacon.py" "$EXTRAS/beacon.py" 2>/dev/null \
      && { echo "  beacon: restored klippy/extras/beacon.py"; fixed=1; }
  fi
  if ! is_on; then
    edit_printer on >/dev/null 2>&1
    echo "  beacon: printer.cfg had lost the Beacon config (Phrozen update?) -- re-applied"
    fixed=1
  fi
  if [ ! -f "$BEACON_CFG" ]; then
    if [ -f "$SAFE" ]; then
      # YOUR calibrated file first — the template's y_offset and z_positions are one other
      # printer's numbers, and a wrong z_positions order makes z_tilt diverge.
      install -Dm644 "$SAFE" "$BEACON_CFG"
      echo "  beacon: beacon.cfg was missing -- restored your saved copy from $SAFE"
      fixed=1
    elif [ -f "$TPL" ]; then
      local s; s=$(find_serial)
      sed "s|@BEACON_SERIAL@|${s:-@BEACON_SERIAL@}|" "$TPL" > "$BEACON_CFG"
      echo "  beacon: beacon.cfg was missing and no saved copy existed -- fell back to the kit"
      echo "          template. CHECK y_offset AND the z_positions order before homing."
      [ -n "$s" ] || echo "          NOTE: no Beacon on USB, so the serial is still a placeholder."
      fixed=1
    fi
  fi
  [ "$fixed" = 0 ] && exit 0
  exit 0
}

case "${1:-status}" in
  status)  cmd_status;;
  on)      cmd_on;;
  off)     cmd_off;;
  reapply) cmd_reapply;;
  *) echo "usage: $0 status|on|off|reapply"; exit 1;;
esac
