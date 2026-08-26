#!/bin/bash
# unleashed_setup_manual.sh — setup menu for the BASE-image / manual install path.
# Run AFTER: base image flashed + first boot/SSH + KIAUH (Klipper stack installed).
# This is what the `unleashed` command launches on the base image. It DOES the system prep,
# the phrozen_dev install (from the user's USB) and the MCU flash — unlike unleashed_setup.sh,
# which is the IMAGE path and assumes those are already baked in.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_arco-lib.sh"

menu() {
  header "MANUAL INSTALL (base image)"
  printf "${CY}   SYSTEM (any time):${C0}\n"
  printf "    1)  System prep            ${CC}(apt-hold, governor, boot tweaks)${C0}\n\n"
  printf "${CY}   AFTER KLIPPER INSTALL (KIAUH):${C0}\n"
  printf "    2)  Install phrozen_dev   ${CC}(your USB: Arco_FW_V*.zip + AMS files)${C0}\n"
  printf "    3)  Flash MCUs                ${CC}(flash_mcus · Katapult + F407 serial auto)${C0}\n\n"
  printf "${CY}   EXTRAS:${C0}\n"
  printf "    4)  AddOn.cfg + Features  ${CC}(features · Mainsail theme · Fluidd)${C0}\n"
  printf "    5)  PhrozenGo / Cloud     ${CC}(off for Obico · tunnel off)${C0}\n"
  printf "    b)  Beacon probe              ${CR}(EXPERIMENTAL — not yet hardware-tested)${C0}\n"
  printf "                                  ${CC}Beacon as new probing device for meshing${C0}\n\n"
  printf "${CY}   RECOVERY:${C0}\n"
  printf "    6)  Phrozen-update protection ${CC}(backup / pre-patch / restore)${C0}\n\n"
  printf "${CY}   SCRIPT UPDATE:${C0}\n"
  printf "    7)  Check for Unleashed updates ${CC}(kit · git)${C0}\n"
  printf "    c)  Update channel        ${CC}(stable, or beta to test new features early)${C0}\n\n"
  printf "    q)  Quit\n\n"
  printf "${CW}   DTB and WiFi are baked in. Step 2 unpacks your USB and installs${C0}\n"
  printf "${CW}   the display and AMS gateway; then restart klipper to bring it up.${C0}\n"
  printf "${CW}   Display setup is pre-seeded. Finally calibrate (mesh, z-offset,${C0}\n"
  printf "${CW}   PID, input shaper).${C0}\n\n"
}

startup_update_check "$0"

while true; do
  menu
  read -rp "   Select: " c
  case "$c" in
    1) a_sysprep;   pause;;
    2) a_patches;   pause;;
    3) a_flash;     pause;;
    4) a_addon;     pause;;
    5) a_phrozengo; pause;;
    b|B) a_beacon;  pause;;
    6) a_recover;   pause;;
    7) a_selfupdate; pause;;
    c|C) a_channel;  pause;;
    q|Q) echo "Bye."; exit 0;;
    *) ;;
  esac
done
