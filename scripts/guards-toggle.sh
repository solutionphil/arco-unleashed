#!/bin/bash
# guards-toggle.sh — switch individual self-heal guards on and off.
#
#   bash guards-toggle.sh status     # what is wired, and what each one does
#   bash guards-toggle.sh detail     # the long version, including what breaks without it
#   bash guards-toggle.sh checkbox   # whiptail checklist (this is what the menu calls)
#   bash guards-toggle.sh list       # machine-readable: id <TAB> ON|OFF <TAB> short
#   bash guards-toggle.sh apply "id1 id2 ..."   # exactly these on, every other one off
#
# WHY THIS EXISTS. check-guards.sh answers "are they all wired?" and installs missing ones. That is
# the right default and most owners never need more. But the guards are not only repair -- they are
# ENFORCEMENT: each one puts a file back the way this project wants it, before every single klippy
# start. For anyone modifying the printer themselves that is not protection, it is their edit being
# reverted on every boot with no message. apply-core-restore.sh checks klippy/mcu.py back out to HEAD;
# apply-config-patches.sh re-applies our edits to printer_gcode_macro.cfg. Someone running their own
# patched core, or hand-tuning Phrozen's macros, needs to be able to say so.
#
# HOW A GUARD IS DISABLED. Each guard is one drop-in file in its unit's .service.d directory --
# klipper.service.d for all but one; the update-manager entry rides on moonraker. systemd only reads
# files ending in `.conf`, so renaming to `.conf.disabled` removes the guard and keeps the file --
# nothing is edited, nothing is deleted, and turning it back on is a rename. The same reversible
# philosophy as the sentinel comments in the config files.
#
# THE DROP-IN DIRECTORY IS NOT ALL GUARDS. It also holds CPU affinity, BLAS thread limits and the
# nice level -- performance tuning, not self-heal. Those are deliberately invisible here: offering
# "CPU affinity" in a list of guards invites someone to switch it off looking for a guard they can
# live without, and get a printer with timing problems instead. Only drop-ins carrying an
# ExecStartPre are guards, and that is the test used below.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# Guards stopped being klipper-only when the Moonraker update-manager entry arrived, so the drop-in
# directory is derived per guard instead of fixed. A guard on a unit this screen does not know about
# would have no off switch at all -- and one that cannot be switched off is not a guard, it is a
# decision made for the owner.
DD_ROOT=/etc/systemd/system
dd_of(){ printf '%s/%s.service.d' "$DD_ROOT" "${1:-klipper}"; }

# id | drop-in prefix | short (fits a whiptail row) | risk | service
GUARDS=(
  "phrozen_restore|13-arco-phrozen-restore|Puts phrozen_dev back after a Klipper update|HIGH|klipper"
  "core_restore|14-arco-core-restore|Restores Klipper core files voronFDM overwrites|HIGH|klipper"
  "extras|16-arco-extras|Reinstalls this project's own Klipper modules|HIGH|klipper"
  "config_patches|17-arco-config-patches|Re-applies our edits to Phrozen's macro config|MED|klipper"
  "phrozen_patches|18-arco-phrozen-patches|Keeps phrozen_dev working on Klipper v0.13|HIGH|klipper"
  "imageid|19-arco-imageid|Keeps /etc/ImageId.json correct (AMS work mode)|MED|klipper"
  "kaos|21-kaos-guard|Repairs the optional KAOS bridge before start|LOW|klipper"
  "update_manager|22-arco-update-manager|Lists the kit in Mainsail/Fluidd's update manager|LOW|moonraker"
)

# The long form. Every entry answers the two questions a checkbox cannot: what goes wrong without it,
# and why someone would legitimately want it off. The second question is the whole point of this
# screen -- a guard nobody has a reason to disable does not need a checkbox.
detail_of(){
  case "$1" in
    phrozen_restore) cat <<'T'
  Keeps a copy of Phrozen's phrozen_dev module OUTSIDE the Klipper tree, and
  puts it back if it disappeared.
  WITHOUT IT: phrozen_dev is untracked, so Moonraker's "Hard recover" and any
    git clean delete it. printer.cfg declares [phrozen_dev], so klippy then
    refuses the config outright -- the printer sits halted with no display.
  TURN IT OFF IF: you are deliberately running without phrozen_dev, or you keep
    your own copy somewhere else and do not want ours restored over it.
T
;;
    core_restore) cat <<'T'
  Heals Klipper core files that Phrozen's voronFDM replaces with its v0.11
  copies on the first start after a firmware install.
  WITHOUT IT: klippy dies on "SerialReader ... warn_prefix" -- Phrozen's older
    mcu.py calls an argument Klipper renamed in v0.13. The printer will not
    start until it is repaired by hand.
  It only acts on that exact damage: it looks for the old warn_prefix call in
    mcu.py and exits at once if it is not there. A Klipper core you patched
    yourself is NOT reverted, unless your change happens to reintroduce that
    same old API call.
  TURN IT OFF IF: you patch mcu.py or virtual_sdcard.py in a way this check
    mistakes for the clobber. That is rare -- leaving it on is usually right.
T
;;
    extras) cat <<'T'
  Reinstalls this project's own Klipper modules (arco_mcu_timing,
  arco_tool_gate, arco_fila_status ...) if they are missing.
  WITHOUT IT: after a Klipper re-clone or a git clean, printer.cfg declares
    sections whose modules are gone and klippy refuses the config.
  TURN IT OFF IF: you maintain those modules yourself and do not want the kit's
    versions written over yours.
T
;;
    config_patches) cat <<'T'
  Re-applies our edits to Phrozen's printer_gcode_macro.cfg (they are config
  edits, so a Phrozen firmware update reverts them).
  WITHOUT IT: the printer still runs, but features quietly regress after a
    Phrozen update -- this is the one guard whose absence is not obvious.
  TURN IT OFF IF: you want to hand-tune Phrozen's macros. While it is on, your
    changes to the lines it manages are re-applied away on every start.
T
;;
    phrozen_patches) cat <<'T'
  Applies the three phrozen_dev source edits that make it work on v0.13,
  plus the auto-calibration handshake macros.
  WITHOUT IT: phrozen_dev raises API errors on v0.13 and auto-calibration never
    signals that it finished.
  TURN IT OFF IF: your phrozen_dev is already correct for v0.13 and you do
    not want it patched again.
T
;;
    imageid) cat <<'T'
  Guarantees /etc/ImageId.json reads {"ImageId":16}.
  WITHOUT IT: phrozen_dev gates image-specific code on that value; if the file
    is missing the AMS work mode is stuck at UNKNOWN and paths misfire.
  TURN IT OFF IF: you are deliberately running a different ImageId.
T
;;
    kaos) cat <<'T'
  Repairs the optional KAOS bridge's files before Klipper starts, and keeps the
  vendor dev.py in place while KAOS is switched off.
  WITHOUT IT: nothing at all, if you never use KAOS. With KAOS in use, its
    extras are not repaired and PRZ_SPITTING_END may not resolve.
  TURN IT OFF IF: you do not use the KAOS bridge and want one less thing
    running at start. Safe either way -- that is why it ships enabled.
T
;;
    update_manager) cat <<'T'
  Lists Arco Unleashed in Mainsail's and Fluidd's update manager, next to
  Klipper and Moonraker, so the kit updates with a button instead of a command.
  It adds that entry ONLY once the kit is a real git clone -- the copy in the
    image is not one, and the entry stays away until ARCO_UPDATE adopts it.
  WITHOUT IT: nothing breaks. The kit still updates with ARCO_UPDATE in the
    console, or from a USB tarball with update-from-usb.sh.
  TURN IT OFF IF: you do not want the kit offering itself for update in the
    web interface, or you keep your own entry for it and want yours left alone.
    This is the only guard on moonraker.service rather than klipper.
T
;;
  esac
}

field(){ printf '%s' "$1" | cut -d'|' -f"$2"; }

# A guard is present-and-on if its .conf exists; present-but-off if only .conf.disabled does.
state_of(){
  local pre="$1" dd; dd="$(dd_of "${2:-klipper}")"
  if [ -f "$dd/$pre.conf" ];          then echo ON
  elif [ -f "$dd/$pre.conf.disabled" ]; then echo OFF
  else                                     echo ABSENT
  fi
}

cmd_list(){
  for g in "${GUARDS[@]}"; do
    local id pre svc; id=$(field "$g" 1); pre=$(field "$g" 2); svc=$(field "$g" 5)
    local st; st=$(state_of "$pre" "$svc")
    [ "$st" = ABSENT ] && continue          # never offer a guard this image does not carry
    printf '%s\t%s\t%s\n' "$id" "$st" "$(field "$g" 3)"
  done
}

cmd_status(){
  echo "Self-heal guards — individually switchable"
  echo "------------------------------------------"
  local any=0
  for g in "${GUARDS[@]}"; do
    local id pre st risk svc; id=$(field "$g" 1); pre=$(field "$g" 2); risk=$(field "$g" 4); svc=$(field "$g" 5)
    st=$(state_of "$pre" "$svc")
    case "$st" in
      ON)      printf "  [x] %-16s %s\n" "$id" "$(field "$g" 3)";;
      OFF)     printf "  [ ] %-16s %s  (OFF)\n" "$id" "$(field "$g" 3)"; any=1;;
      ABSENT)  continue;;
    esac
    [ "$risk" = HIGH ] && [ "$st" = OFF ] && \
      printf "      ^ this one is load-bearing — see 'detail'\n"
  done
  [ "$any" = 1 ] && echo && echo "  Something is switched off. That is allowed, but it is not the"
  [ "$any" = 1 ] && echo "  shipped state — 'detail' explains what each one covers."
  return 0
}

cmd_detail(){
  for g in "${GUARDS[@]}"; do
    local id pre svc dd st
    id=$(field "$g" 1); pre=$(field "$g" 2); svc=$(field "$g" 5)
    dd="$(dd_of "$svc")"; st=$(state_of "$pre" "$svc")
    [ "$st" = ABSENT ] && continue
    printf "\n%s  [%s]  risk if off: %s\n" "$id" "$st" "$(field "$g" 4)"
    detail_of "$id"
  done
  echo
}

# Enable exactly the ids given, disable every other KNOWN guard. Unknown drop-ins are never touched.
cmd_apply(){
  local want=" ${1:-} "
  local changed=0 failed=0
  # Every rename is reported as done OR as failed. Renaming under /etc needs root, and if sudo is
  # refused the plain `cmd && report` form leaves the counter at zero and prints "(no change)" --
  # which reads as "nothing needed doing" when it actually means "nothing could be done". A guard
  # the owner believes they switched off, and which is still running, is worse than either state.
  for g in "${GUARDS[@]}"; do
    local id pre st; id=$(field "$g" 1); pre=$(field "$g" 2); st=$(state_of "$pre")
    [ "$st" = ABSENT ] && continue
    if printf '%s' "$want" | grep -q " $id "; then
      [ "$st" = OFF ] || continue
      if sudo mv -f "$dd/$pre.conf.disabled" "$dd/$pre.conf" 2>/dev/null; then
        echo "  $id: OFF -> ON"; changed=1
      else
        echo "  $id: FAILED to switch ON — still OFF"; failed=1
      fi
    else
      [ "$st" = ON ] || continue
      if sudo mv -f "$dd/$pre.conf" "$dd/$pre.conf.disabled" 2>/dev/null; then
        echo "  $id: ON -> OFF"; changed=1
      else
        echo "  $id: FAILED to switch OFF — STILL ACTIVE"; failed=1
      fi
    fi
  done
  if [ "$failed" = 1 ]; then
    echo
    echo "  Some guards could not be changed. Editing $DD_ROOT"
    echo "  needs root, and sudo was refused. Run this from the setup menu, where it"
    echo "  can ask for your password. Nothing was left half-applied — every guard is"
    echo "  either in its old state or its new one, and the lines above say which."
  fi
  if [ "$changed" = 0 ]; then
    [ "$failed" = 0 ] && echo "  (no change)"
    return 0
  fi
  sudo systemctl daemon-reload
  echo "  systemd reloaded. Each guard runs just before its own service starts, so this"
  echo "  takes effect on the next restart of that service (klipper for all but the"
  echo "  update-manager entry, which follows moonraker)."
  return 0
}

cmd_checkbox(){
  command -v whiptail >/dev/null 2>&1 || { echo "whiptail missing"; exit 1; }
  mapfile -t ROWS < <(cmd_list)
  [ "${#ROWS[@]}" -gt 0 ] || { echo "No guards found under $DD_ROOT."; exit 1; }

  # The long descriptions go to the TERMINAL before the dialog, because a whiptail row is one short
  # line and the request was for more detail, not less. The reader sees the full picture, then ticks.
  cmd_detail
  echo "Press ENTER for the checklist..."; read -r _

  local args=() maxs=0
  for r in "${ROWS[@]}"; do
    local id st short; id="${r%%$'\t'*}"; local rest="${r#*$'\t'}"
    st="${rest%%$'\t'*}"; short="${rest#*$'\t'}"
    args+=( "$id" "$short" "$( [ "$st" = ON ] && echo ON || echo OFF )" )
    [ "${#short}" -gt "$maxs" ] && maxs=${#short}
  done
  local cols rows width listh height
  cols=$(tput cols 2>/dev/null || echo 80); rows=$(tput lines 2>/dev/null || echo 24)
  width=$(( maxs + 26 )); [ "$width" -gt $(( cols - 2 )) ] && width=$(( cols - 2 ))
  [ "$width" -lt 60 ] && width=60
  listh=${#ROWS[@]}; height=$(( listh + 8 ))
  if [ "$height" -gt $(( rows - 2 )) ]; then
    height=$(( rows - 2 )); listh=$(( height - 8 )); [ "$listh" -lt 3 ] && listh=3
  fi

  local SEL
  SEL=$(whiptail --title "Arco Unleashed - Self-heal guards" \
    --checklist "Space = toggle, Tab -> <Ok>. Ticked = guard active:" \
    "$height" "$width" "$listh" "${args[@]}" 3>&1 1>&2 2>&3) \
    || { echo "(cancelled - nothing changed)"; exit 0; }
  SEL=$(echo "$SEL" | tr -d '"')

  # Confirm the load-bearing ones separately. Not a veto -- the owner asked for individual control --
  # but "your printer will not start after the next Phrozen update" is worth one deliberate keypress.
  for g in "${GUARDS[@]}"; do
    local id risk pre; id=$(field "$g" 1); risk=$(field "$g" 4); pre=$(field "$g" 2)
    [ "$risk" = HIGH ] || continue
    [ "$(state_of "$pre")" = ABSENT ] && continue
    if ! printf ' %s ' $SEL | grep -q " $id "; then
      if ! whiptail --title "Turning off: $id" --yesno \
        "$(detail_of "$id")\n\nThis one is load-bearing. Really switch it off?" 18 76; then
        SEL="$SEL $id"
      fi
    fi
  done
  cmd_apply "$SEL"
}

case "${1:-status}" in
  status)   cmd_status;;
  detail)   cmd_detail;;
  list)     cmd_list;;
  checkbox) cmd_checkbox;;
  apply)    cmd_apply "${2:-}";;
  *) echo "Usage: bash guards-toggle.sh status|detail|list|checkbox|apply \"<ids>\"";;
esac
