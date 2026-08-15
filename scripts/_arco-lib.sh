#!/bin/bash
# _arco-lib.sh — shared helpers + actions for arco-setup-manual.sh / unleashed_setup.sh
# Not meant to be run directly; sourced by the front-ends (which set $DIR).

C0='\033[0m'; CG='\033[1;32m'; CC='\033[1;36m'; CY='\033[1;33m'; CR='\033[1;31m'; CW='\033[1;37m'

header() {  # $1 = variant subtitle
  clear 2>/dev/null || true
  printf "${CC}
   /=================================================\\
   |    ${CW}~~  Arco Unleashed - Bookworm Edition  ~~${CC}    |
   \\=================================================/${C0}\n"
  printf "${CW}   %s${C0}\n\n" "$1"
}

pause(){ printf "\n${CW}   ... press ENTER to continue${C0}"; read -r _; }

# ---- actions (root-needing ones call sudo internally or here) ----
a_resize(){ bash "$DIR/resize-emmc.sh"; }
a_sysprep(){
  echo "[System prep] 1/7 - protecting critical apt packages (hold)..."
  sudo bash "$DIR/apt-hold.sh"
  echo
  echo "[System prep] 2/7 - CPU governor -> performance (persistent service)..."
  echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null
  sudo sed -i 's/^GOVERNOR=.*/GOVERNOR=performance/' /etc/default/cpufrequtils 2>/dev/null || true
  # armbian's 'ondemand' is not reliably overridden -> a dedicated boot service pins 'performance'.
  # At max_accel=40000 the DVFS ramp-lag of ondemand/schedutil starves the step queue at a burst start
  # -> MCU "Timer too close". 'performance' pins 1296 MHz (cool ~51C, no throttle). Persists across boot.
  sudo cp "$DIR/arco-cpu-governor.service" /etc/systemd/system/
  sudo systemctl enable arco-cpu-governor.service >/dev/null 2>&1
  echo "  active governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  # boot splash on the serial display (cosmetic; draws before voronFDM takes over). Was previously only
  # hand-installed on the dev printer -> fresh builds never got it (fresh-flash finding 2026-07-02).
  sudo cp "$DIR/arco-splash.service" /etc/systemd/system/
  sudo systemctl enable arco-splash.service >/dev/null 2>&1
  echo "  boot splash service installed"
  echo
  echo "[System prep] 3/7 - chamber light gpiochip permission fix..."
  sudo bash "$DIR/fix-gpio-led.sh"
  echo
  echo "[System prep] 4/7 - USB automount (so the display sees a stick)..."
  # armbian-mkspi has no USB automount; without it the Phrozen display never sees an inserted stick.
  sudo bash "$DIR/../system/install-usb-automount.sh"
  echo
  echo "[System prep] 5/7 - boot + realtime tuning (network-wait, affinity,"
  echo "                     IRQ pinning, numpy=1, USB no-suspend, ImageId)..."
  # Neither needs the network to start (Klipper=local MCUs, Moonraker/voronFDM=localhost).
  sudo bash "$DIR/optimize-boot.sh"
  echo
  echo "[System prep] 6/7 - reduce eMMC wear: mount rootfs noatime..."
  # atime is a write-on-read; nothing here needs it. Pairs with the commit=120 already on /.
  sudo bash "$DIR/optimize-fs.sh"
  echo
  echo "[System prep] 7/7 - serve Mainsail on :80 as well as :81 (the stock Arco URL)..."
  # Phrozen's Buster served Mainsail on :80, so http://<printer-ip>/ is what every owner's bookmark
  # expects. KIAUH put it on :81 during the migration and left :80 unbound -- nobody decided that.
  # :81 is kept, so URLs learned since the migration keep working. Idempotent; rolls itself back if
  # nginx rejects the edit.
  sudo bash "$DIR/setup-nginx-ports.sh"
}
a_patches(){
  printf "${CW}   Install phrozen_dev${C0}  (Phrozen's module — you supply it on USB)\n"
  printf "    f) Install from USB  ${CC}(Arco_FW_V*.zip on FAT32) + v0.13 patches${C0}\n"
  printf "    p) Re-apply patches  ${CC}(v0.13 API + handshakes + timing; no install)${C0}\n"
  printf "   Select [f/p/back]: "; read -r x
  case "$x" in
    f|F) bash "$DIR/fetch-phrozen-fw.sh"      && bash "$DIR/phrozen-recover.sh" backup;;  # install + capture initial golden
    p|P) bash "$DIR/apply-phrozen-patches.sh" && bash "$DIR/phrozen-recover.sh" backup;;  # re-patch + refresh golden
    *) echo "  (back)";;
  esac
}
# "Re-apply Klipper patches" was retired: apply-phrozen-patches runs as an ExecStartPre on every klipper
# start AND inside Emergency repair, so a manual entry for it only added a decision nobody could make
# correctly. What is NOT covered anywhere is whether the guards are wired at all — the drop-ins are
# written when the image is built, not when the kit updates itself, so a long-running printer can quietly
# be missing a guard the current kit assumes. That is what this checks.
a_image_backup(){
  printf "${CW}   Save the whole system${C0} — a disk image of this printer onto a USB stick.\n\n"
  printf "   What you get: ${CW}arco-emmc-backup.img.gz${C0} (about 2 GB), with a .sha256 and\n"
  printf "   a .rawsize beside it. A ${CW}bootable disk image${C0}: every file, the partition\n"
  printf "   table, the bootloader. It can be written back onto an eMMC to put this\n"
  printf "   printer back exactly as it is now.\n\n"
  printf "   Entry ${CW}2${C0} is the other kind — your ${CW}settings${C0} only, as\n"
  printf "   arco-user-settings-<date>.tar.gz, a few MB. Quick and no reboot, but it\n"
  printf "   cannot be flashed and will not revive a printer that no longer boots.\n\n"
  printf "${CC}   How it works: the printer reboots, images the eMMC before the system starts\n"
  printf "   (the only moment it is not in use, which is what makes the copy consistent),\n"
  printf "   then reboots back into what you have now. Nothing here is written to or\n"
  printf "   changed. Pulling the stick at any point cancels it.${C0}\n\n"
  printf "   Measured on a 32 GB eMMC: about half an hour, and the file came out at\n"
  printf "   2.3 GB. An 8 GB eMMC is proportionally quicker. Use a stick of 8 GB or\n"
  printf "   more; it tells you before starting if there is not enough room.\n\n"
  printf "${CR}   Keep the file to yourself:${C0} it is a byte-for-byte copy, so it carries your\n"
  printf "   WiFi password, SSH keys and any API tokens. Never post it anywhere.\n\n"
  local sf="$DIR/../selfflash/install-unleashed.sh"
  if [ ! -f "$sf" ]; then
    printf "${CR}   selfflash/install-unleashed.sh is not in this kit — cannot back up.${C0}\n"; return 1
  fi
  # Say it here, before the confirmation, rather than letting the script refuse after the reboot prompt.
  local stick=""
  for d in /media/usb* /media/*/* /mnt/usb* "$HOME/printer_data/gcodes/USB"; do
    [ -d "$d" ] && touch "$d/.arco-probe" 2>/dev/null && { rm -f "$d/.arco-probe"; stick="$d"; break; }
  done
  if [ -z "$stick" ]; then
    printf "${CR}   No writable USB stick found.${C0} Plug a FAT32 stick in (it mounts under\n"
    printf "   ~/printer_data/gcodes/USB), then come back — nothing was changed.\n"
    return 1
  fi
  printf "   Stick found at ${CW}%s${C0}, %s free.\n\n" "$stick" \
    "$(df -h --output=avail "$stick" 2>/dev/null | tail -1 | tr -d ' ')"
  # Said at the point of saving, because this is the only moment it can still be acted on: an image
  # taken now, from Unleashed, restores Unleashed. The one that takes a printer back to Phrozen's
  # system has to be made BEFORE the migration, on the original Buster, and afterwards it cannot be
  # produced at all — the system it would copy is gone.
  printf "${CY}   Going back to Phrozen's system later needs an image of the ORIGINAL\n"
  printf "   Buster system — made before Unleashed was installed. Saving now gives\n"
  printf "   you an Unleashed image, which restores Unleashed. If you never made a\n"
  printf "   pre-Unleashed one, there is no way to make it now.${C0}\n\n"
  # Three items on one prompt line came to 87 characters, which wraps in an 80-column PuTTY -- the very
  # defect capture-menu-screens.sh exists to catch, and it caught this one.
  printf "   [s] save an image now      [r] restore from an image\n"
  printf "   [b] going back to Buster   ${CC}(removes Unleashed entirely)${C0}\n\n"
  printf "   Choose, or ENTER to go back: "; read -r x
  case "$x" in
    s|S) printf "\n${CC}   Starting — the first step measures the eMMC and takes about a\n"
         printf "   minute with nothing on screen. That is normal. Please wait.${C0}\n"
         sudo bash "$sf" --backup;;
    r|R) a_image_restore "$stick" "$sf";;
    b|B) a_revert_to_buster "$stick" "$sf";;
    *) echo "  (nothing done)";;
  esac
}

# Going back to Phrozen's original system. This lives next to restore because it IS a restore -- plus
# the half that a restore alone silently skips: the MCUs. Swapping the eMMC back to Buster is not
# enough, the firmware sits on the chips. A Buster host (Klipper v0.11) will not talk to MCUs running
# v0.13, so the printer boots and then cannot find its own hardware, with nothing saying why.
#
# The order is the whole reason this is a guided action rather than a note in the manual: the MCU
# flasher needs katapult, dfu-util and a modern Python, i.e. it needs THIS system. Do it after the
# eMMC is back on Buster and the tools are gone -- then only opening the printer helps. So: MCUs
# first, eMMC second, and the menu enforces it.
#
# We cannot tell a pre-Unleashed image from an Unleashed one: our own backup tool names both
# arco-emmc-backup.img.gz, and looking inside would mean unpacking gigabytes. So it is asked, and the
# question says exactly what is being asserted.
a_revert_to_buster(){
  local stick="$1" sf="$2" fb="$DIR/../revert-to-buster/flash-buster-mcus.sh"
  printf "\n${CR}   ══ Going back to Buster ══${C0}\n\n"
  printf "${CW}   This removes Arco Unleashed from this printer, completely.${C0}\n\n"
  printf "   Gone afterwards, among others:\n"
  printf "     · Klipper v0.13 and the Bookworm system — back to v0.11 on Buster\n"
  printf "     · the self-heal guards that survive Klipper and Phrozen updates\n"
  printf "     · sensorless XY homing, the AddOn macros, the belt and idler tools\n"
  printf "     · Fluidd, the Arco Mainsail theme, the WiFi setup portal\n"
  printf "     · this backup and restore feature itself\n"
  printf "   Your prints, your Orca profiles and your AMS keep working — this is\n"
  printf "   about the printer's own system, not your files on it.\n\n"
  printf "${CY}   You need an image of the ORIGINAL system on the stick${C0} — one you made\n"
  printf "   yourself BEFORE installing Unleashed. Phrozen's firmware zip is not\n"
  printf "   one: that is an update package, not a system. Without such an image\n"
  printf "   this cannot be done from here at all.\n\n"
  if [ ! -f "$fb" ]; then
    printf "${CR}   revert-to-buster/flash-buster-mcus.sh is not in this kit — stopping.${C0}\n"; return 1
  fi
  # Any *.img.gz with a checksum, minus the Unleashed release image: a stock image the owner named
  # something of their own is still perfectly valid, and refusing it over a filename would be silly.
  local imgs="" f skipped=0
  for f in "$stick"/*.img.gz; do
    [ -f "$f" ] && [ -f "$f.sha256" ] || continue
    case "$(basename "$f")" in
      Arco-Unleashed*) continue;;                 # the release image, not anyone's backup
      # A backup named -unleashed holds THIS project, so writing it here would flash the MCUs back to
      # v0.11 for a system that needs v0.13. It is not a candidate at any price; the old y/N question
      # asked the owner to catch that from memory, and the name now answers it.
      *-unleashed*) skipped=$((skipped+1)); continue;;
    esac
    imgs="$imgs$f
"
  done
  if [ -z "$imgs" ]; then
    printf "${CR}   No usable image on this stick:${C0} %s\n" "$stick"
    printf "   There must be a .img.gz with its .sha256\n"
    printf "   beside it. If you never took one before installing Unleashed, this\n"
    printf "   is the end of the road from here — the original system no longer\n"
    printf "   exists on this printer to copy. Nothing was changed.\n"
    return 1
  fi
  # NUMBERED, because the prompt below asks for a number. Without the index the list and the question do
  # not meet: "Which one? [1-2]" over two bare filenames leaves the reader counting lines and hoping the
  # order is the one meant -- on a screen whose next question is whether to overwrite the whole system.
  # Reported from a real revert on 2026-08-10.
  printf "   Found:\n\n"
  printf '%s' "$imgs" | { i=0; while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i+1))
    printf "     ${CW}%s)${C0} %s  ${CC}%s, %s${C0}\n" "$i" "$(basename "$f")" \
      "$(du -h "$f" 2>/dev/null | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)"
  done; }
  local n pick
  n=$(printf '%s' "$imgs" | grep -c .)
  if [ "$n" = 1 ]; then
    pick=$(printf '%s' "$imgs" | head -1)
  else
    printf "\n   Which one? [1-%s] / ENTER=back: " "$n"; read -r y
    case "$y" in ''|*[!0-9]*) echo "  (nothing done)"; return 0;; esac
    [ "$y" -ge 1 ] && [ "$y" -le "$n" ] || { echo "  (nothing done)"; return 0; }
    pick=$(printf '%s' "$imgs" | sed -n "${y}p")
  fi
  printf "\n   Using: ${CW}%s${C0}\n" "$(basename "$pick")"
  printf "${CR}   Is that an image of the ORIGINAL Phrozen system, taken before\n"
  printf "   Unleashed was installed?${C0} If it is an Unleashed image, the MCUs would\n"
  printf "   be flashed back to v0.11 for a system that expects v0.13, and the\n"
  printf "   printer would not run. [y/N]: "; read -r y
  case "$y" in y|Y) : ;; *) echo "  (nothing done)"; return 0;; esac
  printf "\n${CR}   Last stop.${C0} Two things happen, in this order and without a way back:\n"
  printf "     1. both MCUs are flashed to Buster firmware (Klipper v0.11).\n"
  printf "        Klipper here stops connecting straight away — that is expected.\n"
  printf "     2. the eMMC is armed to be overwritten with the image on the next\n"
  printf "        boot, and the printer reboots into that.\n"
  printf "   Step 1 must happen first: afterwards this system is gone, and with it\n"
  printf "   the only tools that can reach the MCUs without opening the printer.\n\n"
  printf "${CW}   Type${C0} REMOVE UNLEASHED ${CW}to go ahead, anything else cancels: ${C0}"
  read -r sure
  [ "$sure" = "REMOVE UNLEASHED" ] || { echo "  (nothing done)"; return 0; }
  printf "\n${CC}   1/2 — flashing the MCUs back to v0.11...${C0}\n"
  if ! bash "$fb" all; then
    printf "\n${CR}   MCU flash FAILED — stopping here, and that is the good outcome.${C0}\n"
    printf "   Nothing has been armed, the eMMC is untouched and this system still\n"
    printf "   works. Read the output above, fix it, and start again. Do NOT\n"
    printf "   restore the image on its own: a Buster system with v0.13 MCUs\n"
    printf "   cannot repair itself.\n"
    return 1
  fi
  printf "\n${CC}   2/2 — arming the eMMC restore...${C0}\n"
  # ARCO_RESTORING: this IS a restore, even though the file is not one of our arco-emmc-backup* names.
  # Without it the flasher runs its install script -- captures the Wi-Fi, seeds it, and prints the
  # "replacing the factory OS" disclaimer -- while putting the factory OS back.
  sudo ARCO_RESTORING=1 bash "$sf" --arm --image "$pick"
}

# Restoring belongs next to saving -- someone who made the backup here should not have to find a command
# line to use it. It is also the most destructive thing this kit can do, so it names the file it will
# write, says plainly what happens if it fails, and then hands over to install-unleashed.sh, which still
# demands the target device typed out in full before anything is armed.
a_image_restore(){
  local stick="$1" sf="$2" i=0 n
  printf "\n${CW}   Restore this printer from a disk image${C0}\n\n"
  # Backups are named for the system they hold: -stock is Phrozen's, -unleashed is ours. The bare name
  # is what versions before that produced, and sticks carrying one still exist, so it is still listed.
  local imgs=""
  for f in "$stick"/arco-emmc-backup-stock.img.gz "$stick"/arco-emmc-backup-unleashed.img.gz \
           "$stick"/arco-emmc-backup.img.gz \
           "$stick"/arco-emmc-backup-stock.img.gz.previous "$stick"/arco-emmc-backup-unleashed.img.gz.previous \
           "$stick"/arco-emmc-backup.img.gz.previous; do
    [ -f "$f" ] && [ -f "$f.sha256" ] && imgs="$imgs$f
"
  done
  if [ -z "$imgs" ]; then
    printf "${CR}   No restorable image on the stick.${C0} There must be an\n"
    printf "   arco-emmc-backup-*.img.gz ${CW}and${C0} its .sha256 beside it — without\n"
    printf "   the checksum the flasher refuses, and rightly so.\n"
    return 1
  fi
  printf "   Found on %s:\n\n" "$stick"
  # Numbered, for the same reason as the list in the revert helper: the prompt below says "in the order
  # listed", and there can be six entries here -- two kinds of backup, each with a .previous, plus a
  # bare-named one from an older kit. Asking someone to count those by eye, on the screen that
  # overwrites their whole eMMC, is asking for the wrong number.
  printf '%s' "$imgs" | { i=0; while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i+1))
    # Say what each one IS. The name carries it, but only if you know the convention -- and the wrong
    # choice here is the one that leaves a printer unable to talk to its own MCUs.
    case "$(basename "$f")" in
      *-stock*)     k="Phrozen's original system";;
      *-unleashed*) k="Arco Unleashed";;
      *)            k="older backup, system unknown";;
    esac
    printf "     ${CW}%s)${C0} %-38s ${CC}%s, %s${C0}\n        ${CY}%s${C0}\n" "$i" "$(basename "$f")" \
      "$(du -h "$f" 2>/dev/null | cut -f1)" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$k"
  done; }
  n=$(printf '%s' "$imgs" | grep -c .)
  # The trap this closes: restoring an image that PREDATES Unleashed leaves the MCUs on v0.13 under a
  # Buster host that speaks v0.11, so the printer boots and cannot find its own hardware -- and by then
  # the tools to reflash them are gone with the system that had them. Backups made from now on say
  # which they are in the name, and the list above spells it out; older ones cannot, hence this line.
  printf "${CY}   Restoring a PRE-UNLEASHED image? Use [b] going back to Buster instead.${C0}\n"
  printf "   That one flashes the MCUs back to v0.11 first, which this does not —\n"
  printf "   and afterwards there is no way left to do it without opening the\n"
  printf "   printer. For an image taken FROM Unleashed, carry on here.\n\n"
  printf "${CR}   This overwrites the whole eMMC.${C0} Everything on this printer is\n"
  printf "   replaced by the image — anything done since it was taken is gone.\n"
  printf "   Once writing starts it cannot be undone, and a failure part-way\n"
  printf "   leaves a printer that only opening it and pulling the eMMC can save.\n\n"
  printf "   First it refuses any image whose CONTENTS would not fit this\n"
  printf "   printer's eMMC — a 2 GB file unpacks to the full size of the\n"
  printf "   machine it came from — then it verifies the .sha256, which reads\n"
  printf "   the whole file off the stick and takes a few minutes. Only after\n"
  printf "   that are you asked to type the target device in full.\n\n"
  # Numbered by position in the list above. The old two-way "current or .previous" prompt could not
  # address more than two, and there can now be six: two kinds of backup, each with its .previous,
  # plus a bare-named one from an older kit.
  local pick
  if [ "$n" = 1 ]; then
    pick=$(printf '%s' "$imgs" | head -1)
    printf "   Restore ${CW}%s${C0}? [y/N]: " "$(basename "$pick")"; read -r y
    case "$y" in y|Y) : ;; *) echo "  (nothing done)"; return 0;; esac
  else
    printf "   Which one? [1-%s], in the order listed / ENTER=back: " "$n"; read -r y
    case "$y" in ''|*[!0-9]*) echo "  (nothing done)"; return 0;; esac
    { [ "$y" -ge 1 ] && [ "$y" -le "$n" ]; } || { echo "  (nothing done)"; return 0; }
    pick=$(printf '%s' "$imgs" | sed -n "${y}p")
    printf "   Restore ${CW}%s${C0}? [y/N]: " "$(basename "$pick")"; read -r c
    case "$c" in y|Y) : ;; *) echo "  (nothing done)"; return 0;; esac
  fi
  sudo bash "$sf" --arm --image "$pick"
}

a_guards(){
  printf "${CW}   Self-heal guards${C0} — klipper.service runs each one before every start.\n"
  printf "   They are what makes a Klipper or Phrozen update survivable. They are\n"
  printf "   installed when the image is built, so a kit that updated itself since\n"
  printf "   then can be missing one, with no symptom until it is needed.\n\n"
  bash "$DIR/check-guards.sh"
  local rc=$?
  if [ "$rc" != 0 ]; then
    printf "\n   Install the missing ones now? [y/N]: "; read -r x
    case "$x" in y|Y) bash "$DIR/check-guards.sh" --fix;; *) echo "  (left unchanged)";; esac
  fi
  # Individual control, because a guard is not only repair -- it also OVERWRITES your own edits
  # before every start. Anyone running a patched core or hand-tuned Phrozen macros needs to be
  # able to say so, instead of watching their change disappear on each boot with no message.
  printf "\n${CC}   Guards also enforce. Most check first and do nothing on a healthy\n"
  printf "   printer, but some do put a file back the way this project wants it,\n"
  printf "   which can undo your own edit. If you mod the printer yourself you can\n"
  printf "   switch individual ones off — each with a full description of what it\n"
  printf "   covers, what breaks without it, and whether it would touch your work.${C0}\n"
  printf "   [c]heckbox: switch individual guards / [d]etails / ENTER=back: "; read -r y
  case "$y" in
    c|C) bash "$DIR/guards-toggle.sh" checkbox;;
    d|D) bash "$DIR/guards-toggle.sh" detail;;
    *) echo "  (back)";;
  esac
}
# One action for "something broke", so nobody has to diagnose before they may repair. Everything it runs
# is idempotent, so it is safe on a healthy printer and covers all three update paths (Phrozen firmware,
# Klipper, Moonraker) plus the two failures no guard catches: a missing [arco_mcu_timing] section and
# root-owned files in the git repos, which silently break Moonraker's update button.
a_emergency(){
  printf "${CW}   Emergency repair${C0} — when a Phrozen, Klipper or Moonraker update\n"
  printf "   broke something. Runs every repair in order and reports what was\n"
  printf "   actually wrong. Safe to run on a healthy printer.\n"
  printf "   Klipper will be restarted at the end. Continue? [y/N]: "; read -r x
  case "$x" in
    y|Y) bash "$DIR/emergency-repair.sh";;
    *) echo "  (cancelled)";;
  esac
}
a_flash(){ bash "$DIR/flash_mcus.sh"; }
a_serial(){ bash "$DIR/set-mcu-serial.sh"; }
# AMS on/off. This handler existed for a long time and was reachable from NOWHERE -- no menu key called
# it -- while README, MANUAL and QUICKSTART all told owners to switch AMS "in the setup menu". Four
# documents describing a menu item that was not there.
#
# Wiring it to ams_toggle.sh alone would still have been wrong, and the script says so itself: it only
# edits the state files. The runtime switch is the gcode -- G28, then P0 M1/M3, P28, P30 -- plus
# SAVE_VARIABLE for the Orca start-gcode flag and ARCO_TOOLS_SHOW to restore T1-T15. All of that lives
# in the AMS_ON / AMS_OFF macros, so the menu runs THOSE, through Moonraker, and the printer ends up in
# one consistent state instead of half-switched.
a_ams(){
  printf "${CW}   AMS / Chroma Kit${C0} — tell the printer whether one is attached.\n"
  printf "${CC}   Do this once whenever you physically connect or disconnect it. Orca then\n"
  printf "   picks single-colour, multicolour or auto-refill by itself.${C0}\n"
  printf "${CY}   THIS MOVES THE PRINTER:${C0} it homes first, then the AMS command moves the\n"
  printf "   toolhead to the spit area. Keep hands clear.\n"
  printf "   [o]n (AMS attached) / o[f]f (no AMS) / ENTER=back: "; read -r m
  local macro=""
  case "$m" in o|O) macro=AMS_ON;; f|F) macro=AMS_OFF;; *) echo "  (back)"; return 0;; esac
  # Klipper has to be up to accept it; if it is not, say the one thing that helps rather than failing
  # with an HTTP error the reader cannot act on.
  local st; st=$(curl -s --max-time 5 http://localhost:7125/printer/info 2>/dev/null | tr -d ' "' | grep -o 'state:[a-z]*' | cut -d: -f2)
  if [ "$st" != "ready" ]; then
    echo "  Klipper is not ready (state: ${st:-no answer}), so the switch cannot run."
    echo "  Fix that first — the menu's Emergency repair is the one action to try —"
    echo "  or run $macro yourself in Mainsail once the printer is up."
    return 1
  fi
  echo "  running $macro ..."
  curl -s --max-time 20 -X POST http://localhost:7125/printer/gcode/script \
       --data-urlencode "script=$macro" >/dev/null \
    && echo "  sent. Watch Mainsail's console for the result — it homes before it switches." \
    || echo "  could not send it; run $macro in Mainsail instead."
}
a_phrozengo(){ bash "$DIR/phrozengo.sh" menu; }
# Beacon: an experimental HARDWARE conversion, not a config preference — hence its own entry rather
# than a checkbox in the feature list. Turning it on with no probe attached would leave the printer
# unable to home, so the script itself refuses unless the module and the device are both there.
a_beacon(){
  bash "$DIR/beacon_toggle.sh" status
  printf "\n${CY}   EXPERIMENTAL — not yet hardware-tested${C0}: contributed config,\n"
  printf "   never run on a machine by an Unleashed developer. You would be\n"
  printf "   the first. Needs a physically installed Beacon.\n"
  printf "   After switching, do NOT use the Arco display for Z-calibration,\n"
  printf "   auto-levelling or mesh — use Mainsail/Fluidd instead.\n"
  printf "   [o]n  /  o[f]f  /  ENTER=back: "; read -r x
  case "$x" in
    o|O) bash "$DIR/beacon_toggle.sh" on;;
    f|F) bash "$DIR/beacon_toggle.sh" off;;
    *) echo "  (unchanged)";;
  esac
}
# Sensorless XY. Deliberately not a checkbox in the feature list either, for a different reason
# than Beacon: this one is PROVEN on hardware, but a wrong sensitivity means the carriage grinds
# into the rail instead of stopping, and on CoreXY it drags the other axis with it. That is a
# decision to make while looking at the machine, not while scrolling a list.
a_sensorless(){
  bash "$DIR/sensorless_toggle.sh" status
  printf "\n${CY}   An ALTERNATIVE to the microswitches, not an improvement.${C0} The\n"
  printf "   switches stay the default and the recommendation: same stopping\n"
  printf "   point every time, no tuning.\n\n"
  printf "${CC}   Turn this on when a switch or its wiring has failed.${C0} X's switch\n"
  printf "   hangs off the TOOLHEAD MCU while its DIAG line goes to the main\n"
  printf "   one, so a broken toolhead cable kills the switch but not this\n"
  printf "   path — which can get a printer working again. Z is untouched\n"
  printf "   either way; it keeps its load-cell probe.\n\n"
  printf "${CY}   Watch the first few homings.${C0} If the sensitivity is wrong the\n"
  printf "   carriage grinds into the rail rather than stopping — have ${CW}M112${C0}\n"
  printf "   within reach. Listen for the endstop to click: that is how you\n"
  printf "   know it reached the wall, because Klipper reports position 0\n"
  printf "   either way.\n"
  printf "   Sensitivity is ${CW}driver_SGT${C0} in the [tmc5160 ...] sections —\n"
  printf "   ${CW}lower is MORE sensitive${C0}.\n"
  printf "   [o]n  /  o[f]f  /  ENTER=back: "; read -r x
  case "$x" in
    o|O) bash "$DIR/sensorless_toggle.sh" on;;
    f|F) bash "$DIR/sensorless_toggle.sh" off;;
    *) echo "  (unchanged)";;
  esac
}
a_addon(){
  bash "$DIR/addon-toggle.sh" status
  # Two lines, because one was 103 characters and PuTTY opens 80: the options wrapped mid-word and
  # the reader had to reassemble them. A prompt that has to be decoded is a broken prompt.
  printf "   [o]n all  /  o[f]f all  /  [c]heckbox features\n"
  printf "   [t]heme on/off  /  [w]eb: Fluidd  /  ENTER=back: "; read -r x
  case "$x" in
    o|O) bash "$DIR/addon-toggle.sh" on;;
    f|F) bash "$DIR/addon-toggle.sh" off;;
    c|C) bash "$DIR/addon-features.sh";;
    t|T) a_theme;;
    w|W) a_fluidd;;
    *) echo "  (unchanged)";;
  esac
}
a_fluidd(){  # second web interface on :8808 — the port the stock Arco uses
  local code
  # curl already prints 000 on a failed connect AND exits non-zero -- a '|| echo ...' fallback would
  # append to that, not replace it ("000---").
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:8808/ 2>/dev/null)
  [ -n "$code" ] || code='---'
  # Report what is actually true, not just whether the directory exists: the two can disagree (a
  # different FLUIDD_DEST, an nginx site that is down, a stale tree). Saying "not installed" while the
  # port serves 200 is worse than saying nothing.
  if [ -d "$HOME/fluidd" ] && [ "$code" = 200 ]; then
    printf "   Fluidd: ${CG}installed and answering${C0} on http://<printer-ip>:8808/\n"
  elif [ -d "$HOME/fluidd" ]; then
    printf "   Fluidd: files are here, but :8808 says ${CY}HTTP %s${C0}\n" "$code"
    printf "           — the nginx site is missing or down\n"
  elif [ "$code" = 200 ]; then
    printf "   Fluidd: ${CY}answers on :8808, but not from %s${C0}\n" "$HOME/fluidd"
    printf "           — served from elsewhere; check the site's root path.\n"
    printf "           Installing now would add a second copy.\n"
  else
    printf "   Fluidd: ${CY}not installed${C0} — :8808 says HTTP %s; the site\n" "$code"
    printf "           already exists (Phrozen ships Fluidd there); only the\n"
    printf "           files are missing.\n"
  fi
  printf "   [i]nstall / update to the latest release  /  ENTER=back: "; read -r y
  case "$y" in
    i|I) bash "$DIR/install-fluidd.sh";;   # needs internet; no restart, safe during a print
    *) echo "  (unchanged)";;
  esac
}
a_theme(){   # Mainsail theme: Voron light/dark or stock (off)
  local TS="$HOME/printer_data/config/unleashed-theme.sh"
  [ -f "$TS" ] || { printf "   Mainsail theme not installed yet. Install it with:\n     bash %s/../mainsail-theme/setup-theme-macros.sh\n" "$DIR"; return; }
  printf "   %s\n" "$(sh "$TS" | head -1)"
  printf "   theme  [l]ight  /  [d]ark  /  o[f]f (stock)\n"
  printf "   [r]einstall theme + macro groups  /  ENTER=back: "; read -r t
  case "$t" in
    l|L) sh "$TS" light;;
    d|D) sh "$TS" dark;;
    f|F) sh "$TS" stock;;
    r|R) printf "   Re-applying Unleashed Mainsail (theme + macro groups/filters)...\n"
         bash "$DIR/../mainsail-theme/setup-theme-macros.sh" 2>/dev/null || true
         bash "$DIR/../mainsail-theme/mainsail-seed.sh" apply;;
    *) echo "  (unchanged)"; return;;
  esac
  printf "   -> reload Mainsail in the browser (Ctrl+F5)\n"
}
# Seven entries, all lettered, several of them called "backup" -- and two of them were not about the
# user's settings at all but about repairing Klipper after a Phrozen update. Nobody could tell from the
# screen what any single one would do. Now: one sentence of scope, then SAVE above PUT BACK in the order
# the job is actually done, and numbers instead of letters so nothing collides with the main menu, where
# 'i' means the whole-system image.
a_recover(){
  printf "${CW}   Your settings — save and put back${C0}\n"
  printf "${CC}   Everything you configured and measured: printer config, calibration,\n"
  printf "   the web interface (theme, presets, history), WiFi and phrozen_dev. The\n"
  printf "   self-heal guards repair the software by themselves — but nothing can\n"
  printf "   guess back the numbers YOUR machine measured.${C0}\n"
  printf "${CC}   What you get: ${CW}arco-user-settings-<date>.tar.gz${C0}${CC}, a few MB. NOT\n"
  printf "   bootable and not flashable. For something that is, use ${CW}i)${C0}${CC} in the main\n"
  printf "   menu: a full disk image of the whole system, ~2 GB, that can be written\n"
  printf "   back onto an eMMC. That one reboots the printer; this one does not.${C0}\n\n"
  printf "${CY}   SAVE:${C0}\n"
  printf "    1) Save my settings now        ${CC}(here on the printer — do it once)${C0}\n"
  printf "    2) Copy that save to a stick   ${CC}(the one on the printer dies with the eMMC)${C0}\n\n"
  printf "${CY}   PUT BACK:${C0}\n"
  printf "    3) Put my settings back        ${CC}(config, web interface, WiFi — all of it)${C0}\n"
  printf "    4) Put only calibration back   ${CC}(PID values and bed mesh; asks first)${C0}\n"
  printf "    5) Read a save off a stick     ${CC}(fetches it, then use 3 or 4)${C0}\n\n"
  printf "   Select 1-5 / ENTER=back: "; read -r x
  case "$x" in
    1) bash "$DIR/phrozen-recover.sh" backup;;
    2) local d="$HOME/printer_data/gcodes/USB"
       printf "   Save to USB stick, or somewhere else?\n"
       printf "   USB path [%s]: " "$d"; read -r p
       bash "$DIR/phrozen-recover.sh" usb "${p:-$d}";;
    3) bash "$DIR/phrozen-recover.sh" restore-settings;;
    4) bash "$DIR/phrozen-recover.sh" restore-calibration;;
    5) printf "   Archive file (ENTER = newest on the stick): "; read -r f
       bash "$DIR/phrozen-recover.sh" import "${f:-}";;
    *) echo "  (back)";;
  esac
  # The two that were removed are still here, just not on a menu about the user's data. Naming them
  # keeps them findable for anyone who used them, instead of them silently disappearing.
  printf "\n${CC}   Repairing the SOFTWARE after a Phrozen update is not on this menu —\n"
  printf "   that is ${CW}r) Emergency repair${C0}${CC} in the main menu. The deeper core restore,\n"
  printf "   and preparing an update stick that keeps your config, are still there:\n"
  printf "     cd ~/arco-unleashed/scripts\n"
  printf "     bash phrozen-recover.sh restore\n"
  printf "     bash phrozen-recover.sh pre-patch <usb path to phrozen_dev>${C0}\n"
}
# Deliberately shows the status first and only then offers to move. Which channel a printer is on is
# the thing an owner actually needs to know here, and a menu entry that switches before saying where you
# are makes the answer cost a switch.
a_channel(){
  bash "$DIR/channel.sh" status
  printf "\n${CC}   beta carries features that are not proven yet. Nothing is lost by trying it —\n"
  printf "   'stable' brings the files straight back. Config a beta feature already wrote is\n"
  printf "   NOT undone; it gets listed so you can switch it off yourself.${C0}\n"
  # alpha is offered, not hidden. Hiding it would only mean the people who go looking find it without
  # the warning attached -- and the phrase is what decides who gets in, not the menu.
  printf "   [b]eta / [a]lpha (needs an access phrase) / [s]table / ENTER=leave as it is: "; read -r x
  case "$x" in
    b|B) bash "$DIR/channel.sh" beta;;
    a|A) bash "$DIR/channel.sh" alpha;;
    s|S) bash "$DIR/channel.sh" stable;;
    *) echo "  (unchanged)";;
  esac
}

a_selfupdate(){
  local KITDIR; KITDIR="$(cd "$DIR/.." && pwd)"
  # A flat copy from the image cannot pull anything, so offering "update now" there would be a button
  # that only ever fails. Offer the one thing that helps instead.
  if [ ! -d "$KITDIR/.git" ]; then
    printf "${CW}   This kit came from the image as a plain copy${C0}, so it has nothing to\n"
    printf "   pull updates from yet. Adopting it teaches git where these files came\n"
    printf "   from — your files are not replaced and no kit is downloaded.\n"
    printf "   [a]dopt now (needs internet) / ENTER=back: "; read -r x
    case "$x" in
      # Adoption on its own updates nothing, and `check` signs off by naming a shell command -- the
      # same dead end the console commands were built to remove: the reader is standing in a menu,
      # not at a prompt. Offer the step instead of describing it. check returns 0 only when there is
      # something to apply, so an already-current kit does not get a pointless prompt.
      a|A) if bash "$DIR/selfupdate.sh" adopt && bash "$DIR/selfupdate.sh" check; then
             printf "   [u]pdate now / ENTER=back: "; read -r y
             case "$y" in u|U) bash "$DIR/selfupdate.sh" update;; *) echo "  (back)";; esac
           fi;;
      *) echo "  (back)";;
    esac
    return 0
  fi
  bash "$DIR/selfupdate.sh" check
  printf "   [u]pdate now / ENTER=back: "; read -r x
  case "$x" in u|U) bash "$DIR/selfupdate.sh" update;; *) echo "  (back)";; esac
}

# Runs once at menu start: if a kit update is on GitHub, ask y/n and (on yes) pull + reload.
startup_update_check(){
  local SELF="${1:-}"
  local KIT; KIT="$(cd "$DIR/.." && pwd)"
  [ -d "$KIT/.git" ] || return 0                 # not a git clone -> skip silently
  command -v git >/dev/null 2>&1 || return 0
  local out; out=$(bash "$DIR/selfupdate.sh" check 2>/dev/null || true)
  echo "$out" | grep -q "Update available" || return 0
  printf "\n${CY}   === Kit update available ===${C0}\n"
  echo "$out" | sed 's/^/   /'
  printf "${CG}   Apply this update now? [y/N]: ${C0}"; read -r yn
  [[ "${yn:-}" =~ ^[yY]$ ]] || { echo "   (skipped — continuing with current version)"; return 0; }
  bash "$DIR/selfupdate.sh" update
  echo "   Reloading updated menu..."; sleep 1
  [ -n "$SELF" ] && exec bash "$SELF"             # restart with the pulled version
}
