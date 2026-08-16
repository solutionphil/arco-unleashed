#!/bin/bash
# phrozengo.sh — manage Phrozen cloud connectivity (PhrozenGo app + frp SSH tunnel + OTA updater).
# Keeps the LOCAL display/light (voronFDM) while controlling the cloud "phone home" and auto-updates.
#
# Three independent controls:
#   - Privacy:  close the frpc SSH tunnel (Tencent server) — the app still works via TUTK.
#   - OTA:      Phrozen's auto-update (phrozen_slave_ota). Turning it OFF protects your v0.13 from
#               a hostile Phrozen firmware update (which clobbers klippy core -> "warn_prefix" halt).
#   - Disable PhrozenGo: stop the cloud app entirely (no phone-home: frpc + OTA off), free the
#               webcam + resources, and stop Phrozen deleting Obico on boot. This is the DEFAULT
#               delivery state on both install paths (zip and GitHub download).
#
# What this deliberately does NOT touch: phrozen_master. Measured on hardware 2026-08-01 -- that
# binary is Phrozen's AMS/Zigbee gateway. It serves /tmp/UNIX.domain (without it voronFDM retries
# "connect to the server fail" ~11x/min forever) and it holds the AMS work mode in
# hdlDat/Phrozen_Dev.json, which is the gate for runout protection. It used to be masked and killed
# here as "the cloud master", which silently cost every AMS owner their gateway. Its cloud-looking
# parts are vestigial OEM leftovers -- it is an HDL Zigbee smart-home daemon (doorlock/scene/LED
# code paths, zero paired devices): the MQTT broker on :1883 never had a single client and the
# outbound connection sat in SYN-SENT for hours without ever completing. The PhrozenGo app does not
# use it either; the app talks to Moonraker on :7125 and has its own TLS cloud link on :8883.
#
# NOTE: on V199 the ACTIVE launcher is a model-specific KlipperScreen-start-ARCO300-*.sh (exec'd by
# the generic one), so we edit ALL *start*.sh files, not just one.
#
# Usage:  bash phrozengo.sh [menu|status|privacy on|privacy off|ota on|ota off|disable|enable]
set -uo pipefail
PD="$HOME/klipper/klippy/extras/phrozen_dev"
# The choice has to be recorded OUTSIDE phrozen_dev, because it is written INTO phrozen_dev: disabling
# PhrozenGo comments lines out of Phrozen's own start scripts. Anything that replaces that module --
# a Phrozen firmware update, or our own restore guard putting the safety copy back -- brings the
# original lines with it, and one of them deletes moonraker-obico on every boot. A tester lost their
# Obico install to exactly that. The marker lets `reapply` put the choice back, the same way the
# Beacon and sensorless toggles survive the same kind of replacement.
CFG="${ARCO_CONFIG:-$HOME/printer_data/config}"
MARKER="$CFG/.phrozengo-off"
PGSTARTS=("$PD/PhrozenGoStart.sh" "$PD/serial-screen/PhrozenGoStart.sh")
C0='\033[0m'; CG='\033[1;32m'; CC='\033[1;36m'; CY='\033[1;33m'; CR='\033[1;31m'; CW='\033[1;37m'

# all launcher scripts that may spawn the cloud/OTA processes
STARTS=()
for f in "$PD"/KlipperScreen-start*.sh "$PD"/start*.sh; do [ -f "$f" ] && STARTS+=("$f"); done
[ "${#STARTS[@]}" -gt 0 ] || {
  # `reapply` runs from an ExecStartPre on every klipper start, so it must be silent when there is
  # nothing to work on -- an error line on every boot is how people learn to stop reading the log.
  [ "${1:-}" = reapply ] && exit 0
  echo "ERROR: no start scripts in $PD (is the phrozen_dev module installed?)"; exit 1; }

# --- helpers: mask = comment the active launch line(s); unmask = restore them ---
mask(){   local pat="$1" tag="$2" f; for f in "${STARTS[@]}"; do sed -i "/$pat/{/^[[:space:]]*#/!s|^|# $tag |}" "$f"; done; }
unmask(){ local tag="$1" f;          for f in "${STARTS[@]}"; do sed -i "s|^# $tag ||" "$f"; done; }
# active = at least one uncommented launch line for the pattern exists
active(){ local pat="$1" f; for f in "${STARTS[@]}"; do grep -qE "^[[:space:]]*/[^#]*$pat" "$f" && return 0; done; return 1; }

# --- safe process kill -------------------------------------------------------------------------
# `pkill -f` matches the ENTIRE command line, so it kills anything that merely MENTIONS the name:
# an editor, a grep, a shell one-liner, an ssh session. Not theoretical -- running a diagnostic
# command that contained "phrozen_master" got that very session killed mid-sentence.
# proc_is only accepts a match in argv[0] (the program) or argv[1] (the script an interpreter runs,
# as in `/bin/sh /path/frpc_script`). `bash -c "... phrozen_master ..."` carries -c in argv[1], so
# it is left alone. This script's own ancestors are never killed either.
proc_is(){
  local a0 a1
  # The process can exit between pgrep and this read -- pgrep itself does. Without this guard the
  # shell (not tr) reports "No such file or directory", so 2>/dev/null on the pipeline is not enough.
  [ -r "/proc/$1/cmdline" ] || return 1
  a0=$({ tr '\0' '\n' < "/proc/$1/cmdline"; } 2>/dev/null | sed -n 1p)
  a1=$({ tr '\0' '\n' < "/proc/$1/cmdline"; } 2>/dev/null | sed -n 2p)
  case "$a0" in *"$2"*) return 0;; esac
  case "$a1" in *"$2"*) return 0;; esac
  return 1
}
kill_matching(){
  local pat="$1" p chain=" $$ " a
  a=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
  while [ -n "$a" ] && [ "$a" != 0 ] && [ "$a" != 1 ]; do
    chain="$chain$a "; a=$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ')
  done
  for p in $(pgrep -f "$pat" 2>/dev/null); do
    case "$chain" in *" $p "*) continue;; esac
    proc_is "$p" "$pat" && kill "$p" 2>/dev/null
  done
  return 0
}
running(){ local p; for p in $(pgrep -f "$1" 2>/dev/null); do proc_is "$p" "$1" && return 0; done; return 1; }

frpc_state(){ active 'frpc_script'      && echo ON || echo OFF; }
ota_state(){  active 'phrozen_slave_ota' && echo ON || echo OFF; }
# Decided by what CAN run, never by phrozen_master (see the header): that one stays up either way.
pgo_state(){
  local f seen=0
  for f in "${PGSTARTS[@]}"; do
    [ -f "$f" ] || continue
    seen=1
    grep -q 'PHROZENGO-DISABLED' "$f" && { echo OFF; return; }
  done
  [ "$seen" = 0 ] && { echo OFF; return; }   # no launcher at all (GitHub install) -> nothing to run
  echo ON
}
# The boot-time `rm -rf ~/moonraker-obico` lines live in Phrozen's start scripts, which the GitHub
# download ships too -- so they are exposed even on an install that never had the cloud app.
obico_exposed(){ local f; for f in "${STARTS[@]}"; do
  grep -qE '^[[:space:]]*rm -rf .*moonraker-obico' "$f" && return 0; done; return 1; }

privacy_on(){  mask 'frpc_script' 'DISABLED-FRPC'; kill_matching frpc_script
               echo "  -> SSH tunnel (frpc) CLOSED. App still works via TUTK."; }
privacy_off(){ unmask 'DISABLED-FRPC'; echo "  -> SSH tunnel (frpc) ENABLED (on next start/boot)."; }

ota_off(){ mask 'phrozen_slave_ota' 'DISABLED-OTA'; kill_matching phrozen_slave_ota
           echo "  -> Phrozen OTA auto-update DISABLED (protects your v0.13 from hostile updates)."; }
ota_on(){  unmask 'DISABLED-OTA'; echo "  -> Phrozen OTA auto-update ENABLED (on next start/boot)."; }

disable_pgo(){
  # 1) stop Phrozen from deleting Obico on boot
  for f in "${STARTS[@]}"; do sed -i '/moonraker-obico/{/^[[:space:]]*#/!s|^|# PHROZENGO-DISABLED |}' "$f"; done
  # 2) neutralize the PhrozenGo launcher(s) that voronFDM spawns
  for f in "${PGSTARTS[@]}"; do
    [ -f "$f" ] || continue
    grep -q 'PHROZENGO-DISABLED' "$f" || { cp "$f" "$f.bak"; printf '#!/bin/bash\n# PHROZENGO-DISABLED by phrozengo.sh — restore from .bak to re-enable\nexit 0\n' > "$f"; }
  done
  # 3) mask the tunnel + OTA launches in every start script. NOT phrozen_master -- see the header:
  #    that is the AMS gateway, not part of the cloud app, and masking it broke the AMS silently.
  privacy_on >/dev/null
  ota_off >/dev/null
  # 4) kill anything still running (phrozen_master deliberately absent from this list)
  for p in PhrozenGoStart 'PhrozenGo/run.sh' phrozen-go-release frpc_script phrozen_slave_ota; do
    kill_matching "$p"
  done
  # Record the choice outside phrozen_dev, so `reapply` can put it back after a replacement.
  mkdir -p "$CFG" 2>/dev/null; : > "$MARKER" 2>/dev/null
  sync_flag 0
  echo "  -> PhrozenGo cloud DISABLED: no phone-home, OTA off, webcam + resources free for Obico."
  echo "     Local display + light (voronFDM) stay active."
}
enable_pgo(){
  # The cloud app is NOT part of what the GitHub download installs (PhrozenGo.tar, PhrozenGoStart.sh
  # and the frpc binary are absent from Phrozen's public repository), and it is off by default on
  # both install paths. So "re-enable" can be asked for on a printer that has nothing to enable --
  # say so instead of silently unmasking lines that launch files which do not exist.
  local have=0 f
  for f in "${PGSTARTS[@]}"; do [ -f "$f" ] || [ -f "$f.bak" ] && have=1; done
  [ -d "$HOME/PhrozenGo" ] || [ -f "$PD/PhrozenGo.tar" ] || [ "$have" = 1 ] || {
    echo "  PhrozenGo is NOT INSTALLED on this printer, so there is nothing to enable."
    echo "  It is not part of Phrozen's public repository — it only ships in the official"
    echo "  firmware package. To get it:"
    echo "    1. download Arco_FW_V*.zip from Phrozen's website"
    echo "    2. install it the Phrozen way (USB firmware update on the printer)"
    echo "    3. come back here and choose 'Re-enable PhrozenGo'"
    echo "  Your v0.13 patches survive that — the self-heal guards re-apply them on the next boot."
    return 1; }
  for f in "${PGSTARTS[@]}"; do [ -f "$f.bak" ] && mv "$f.bak" "$f"; done
  for f in "${STARTS[@]}"; do sed -i 's|^# PHROZENGO-DISABLED ||' "$f"; done
  privacy_off >/dev/null
  ota_on >/dev/null
  rm -f "$MARKER" 2>/dev/null
  sync_flag 1
  echo "  -> PhrozenGo cloud RE-ENABLED (cloud + frpc + OTA)."
}

# Tell Klipper which way the cloud switch went. The P114 gate in AddOn.cfg uses this: with the
# cloud off nothing is polling for AMS status, so the poll is swallowed rather than paid for. Best
# effort on purpose -- if Klipper is down the file state above is still correct, and the next run of
# this script (reapply included) sets the variable.
sync_flag(){
  curl -s --max-time 5 -X POST \
    "http://localhost:7125/printer/gcode/script?script=SAVE_VARIABLE%20VARIABLE=phrozengo%20VALUE=$1" \
    >/dev/null 2>&1 || true
}

apply_note(){ echo "  (run: sudo systemctl restart KlipperScreen   — or reboot — to apply fully)"; }
pause_k(){ printf "\n   ... ENTER to continue"; read -r _; }

status(){
  printf "${CW}  frpc SSH tunnel : %s\n  OTA auto-update : %s\n  PhrozenGo cloud : %s${C0}\n" \
    "$(frpc_state)" "$(ota_state)" "$(pgo_state)"
  # Shown separately and never as part of "the cloud", so nobody switches it off by reflex.
  printf "  AMS gateway     : %s  ${CC}(phrozen_master - leave this on)${C0}\n" \
    "$(running phrozen_master && echo running || echo "NOT running")"
  local r="" p
  for p in frpc_script phrozen_slave_ota PhrozenGoStart phrozen-go-release; do
    running "$p" && r="$r $p"
  done
  printf "  cloud processes : %s\n" "${r:- (none)}"
}

menu(){
  while true; do
    clear 2>/dev/null || true
    printf "${CC}   /====== PhrozenGo / Phrozen Cloud ======\\\\${C0}\n\n"
    status; echo
    printf "    1)  Privacy: toggle SSH tunnel (frpc) ON/OFF\n"
    printf "    2)  OTA auto-update: toggle ON/OFF\n"
    printf "        ${CC}(OFF protects your v0.13 from Phrozen updates)${C0}\n"
    printf "    3)  Disable PhrozenGo  ${CC}(no phone-home, free webcam for Obico)${C0}\n"
    printf "        ${CC}(the default; the AMS gateway keeps running)${C0}\n"
    printf "    4)  Re-enable PhrozenGo\n"
    printf "    q)  Back\n\n"
    read -rp "   Select: " c
    case "$c" in
      1) if [ "$(frpc_state)" = ON ]; then privacy_on; else privacy_off; fi; apply_note; pause_k;;
      2) if [ "$(ota_state)"  = ON ]; then ota_off;    else ota_on;     fi; apply_note; pause_k;;
      3) disable_pgo; apply_note; pause_k;;
      4) enable_pgo && apply_note; pause_k;;
      q|Q) return;;
    esac
  done
}

case "${1:-menu}" in
  menu)    menu;;
  status)  status;;
  privacy) case "${2:-}" in on) privacy_on;; off) privacy_off;; *) echo "Usage: phrozengo.sh privacy on|off";; esac; apply_note;;
  ota)     case "${2:-}" in on) ota_on;; off) ota_off;; *) echo "Usage: phrozengo.sh ota on|off";; esac; apply_note;;
  disable) disable_pgo; apply_note;;
  # Called by apply-config-patches.sh on every klipper start, gated on the marker, so the choice
  # survives a phrozen_dev replacement. Silent when there is nothing to do: this runs on every boot.
  reapply) [ -e "$MARKER" ] || exit 0
           # Two independent ways a replacement can undo this, so both are checked: the launcher
           # stub can come back as the real script, AND the boot-time Obico deletion can reappear
           # in the start scripts. Testing only the first left the second silently active.
           if [ "$(pgo_state)" = ON ] || obico_exposed; then
             disable_pgo >/dev/null 2>&1
             echo "  phrozengo: re-applied (a phrozen_dev replacement had undone it - Obico is safe again)"
           fi;;
  enable)  enable_pgo && apply_note;;
  *) echo "Usage: bash phrozengo.sh [menu|status|privacy on|privacy off|ota on|ota off|disable|enable]";;
esac
