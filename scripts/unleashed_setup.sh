#!/bin/bash
# unleashed_setup.sh — menu for the IMAGE path (ready-made eMMC image flashed).
# The host software is already baked in (Klipper stack, patches, system prep, light fix).
# What's still needed on the recipient's hardware: resize, MCU firmware, F407 serial.
# Usage:  bash scripts/unleashed_setup.sh
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_arco-lib.sh"

menu() {
  header
  # Every line below fits 80 COLUMNS. PuTTY opens 80x24 by default, and anything wider wraps
  # mid-word: the first thing a new owner saw was a menu with its own text spilling into the
  # next line and the columns destroyed. Descriptions that do not fit get a continuation line
  # rather than a longer one. Colour escapes carry no display width, so measure without them.
  printf "${CY}   ESSENTIAL — first install:${C0}\n"
  # Asked, not asserted. All three variants fit 80 columns; see the note above about PuTTY.
  case "$(mcu_state)" in
    OK)  printf "    1)  Flash MCUs            ${CG}(MCUs already on v0.13 — nothing to do)${C0}\n";;
    OLD) printf "    1)  Flash MCUs            ${CR}(your MCUs still need v0.13 firmware!)${C0}\n";;
    *)   printf "    1)  Flash MCUs            ${CC}(klipper is not up — cannot check)${C0}\n";;
  esac
  printf "                              ${CC}Katapult (toolhead) + F407 DFU${C0}\n\n"
  printf "${CY}   MAINTENANCE:${C0}\n"
  # The line that used to sit here read "2 = the numbers you measured · i = every file". It is a
  # comparison of the two entries above it, but it hangs under 'i' and reads as part of 'i'. Folded
  # into each entry instead, which frees the line for what 'i' actually holds now -- the way back to
  # Phrozen's system, the most consequential thing in this menu and invisible from the top level.
  printf "    2)  Save / restore SETTINGS ${CC}(the numbers you measured — quick, no reboot)${C0}\n"
  printf "    i)  Save the WHOLE SYSTEM   ${CC}(every file, as one image — reboots)${C0}\n"
  printf "                              ${CC}also: restore an image · go back to Buster${C0}\n"
  printf "    3)  Check self-heal guards   ${CC}(all wired? a kit update adds none)${C0}\n\n"
  printf "${CY}   SOMETHING BROKE:${C0}\n"
  printf "    r)  Emergency repair      ${CR}(halted, no display, update failing)${C0}\n"
  printf "                              ${CC}fixes what it can, then says what broke${C0}\n\n"
  printf "${CY}   EXTRAS:${C0}\n"
  printf "    a)  AMS on / off          ${CC}(after attaching or removing the AMS)${C0}\n"
  printf "    4)  AddOn.cfg + Features  ${CC}(features · Mainsail theme · Fluidd)${C0}\n"
  printf "    5)  PhrozenGo / Cloud     ${CC}(off for Obico · tunnel off for privacy)${C0}\n"
  printf "    b)  Beacon probe          ${CR}(EXPERIMENTAL — not hardware-tested)${C0}\n"
  printf "                              ${CC}Beacon as probing device for meshing${C0}\n"
  printf "    s)  Sensorless XY homing  ${CC}(ALTERNATIVE — switches stay default)${C0}\n"
  printf "                              ${CC}only if a switch or its cable failed${C0}\n\n"
  printf "${CY}   UPDATE:${C0}\n"
  printf "    6)  Check for updates     ${CC}(kit · git)${C0}\n"
  printf "    c)  Update channel        ${CC}(stable, or beta to test new features early)${C0}\n\n"
  printf "    q)  Quit\n\n"
  printf "${CW}   WiFi came from the setup portal · phrozen_dev from your USB${C0}\n"
  printf "${CW}   stick · the eMMC auto-resized on first boot. Remember to calibrate.${C0}\n\n"
}

startup_update_check "$0"

while true; do
  menu
  read -rp "   Select: " c
  case "$c" in
    1) a_flash;      pause;;
    2) a_recover;    pause;;
    3) a_guards;     pause;;
    i|I) a_image_backup; pause;;
    r|R) a_emergency; pause;;
    a|A) a_ams;      pause;;
    4) a_addon;      pause;;
    5) a_phrozengo;  pause;;
    b|B) a_beacon;   pause;;
    s|S) a_sensorless; pause;;
    6) a_selfupdate; pause;;
    c|C) a_channel;  pause;;
    q|Q) echo "Bye."; exit 0;;
    *) ;;
  esac
done
