#!/bin/bash
# flash_mcus.sh — build & flash the Phrozen Arco MCUs, selectable.
# State 2026-06 (Katapult + host MCU + kernel fixes).
#
# Usage:
#   bash flash_mcus.sh              # interactive menu
#   bash flash_mcus.sh all          # all three
#   bash flash_mcus.sh f407         # main board only
#   bash flash_mcus.sh f103         # toolhead only (Katapult)
#   bash flash_mcus.sh host         # Linux host MCU only
#   bash flash_mcus.sh f407 f103    # combination
#
# REQUIREMENT for f103: the Katapult bootloader is installed once (auto-offered below).

# set -e disabled: the menu's "nothing selected" test returns non-zero on a *valid*
# selection (sum != 0), which under set -e aborted the script right after choosing.
# Build/flash steps do their own explicit error handling (|| return 1 / || echo).
# set -e
KLIPPER_DIR=/home/mks/klipper
KATAPULT_DIR=/home/mks/katapult
# Per-TOOLHEAD marker: records that the Katapult bootloader is flashed onto THIS printer's F103.
# NOT the presence of the katapult repo (that ships with the image) — the recipient's F103 still
# carries the old Phrozen firmware. Stripped during image sanitizing (see IMAGE.md).
# This script is meant to run WITHOUT sudo (it elevates the few steps that need it), and then $HOME is
# right. Run with sudo anyway -- which people do -- and $HOME becomes /root: the marker below lands
# where nothing looks for it, and worse, the printer_MCU.cfg edits further down write to a path that
# does not exist and fail silently. The comment beside that edit already says its absence is "one line
# of scrollback nobody re-reads". The mirror script, revert-to-buster/flash-buster-mcus.sh, had the
# same defect and it cost a real revert on 2026-08-10.
ARCO_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  _h=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$_h" ] && ARCO_HOME="$_h"
fi
KATAPULT_MARK="$ARCO_HOME/.config/arco-unleashed/katapult-f103.done"

# ---- parse selection ----
DO_F407=0; DO_F103=0; DO_HOST=0

show_menu() {
  clear 2>/dev/null || true
  cat <<'EOF'

   /=================================================\
   |        Phrozen Arco  ·  Flash MCUs               |
   |=================================================|
   |  What should be built & flashed?                |
   |                                                 |
   |   1)  Main board     STM32F407   (USB-DFU)      |
   |   2)  Toolhead MKS_THR STM32F103 (Katapult)     |
   |   3)  Linux host MCU             (CPU temp)     |
   |                                                 |
   |   a)  All three                                 |
   |   q)  Cancel                                    |
   \=================================================/

EOF
  read -rp "   Select (e.g. 1  or  '1 3'  or  a): " sel
  case "$sel" in
    q|Q) echo "Cancelled."; exit 0;;
    a|A|all) DO_F407=1; DO_F103=1; DO_HOST=1;;
    *) for t in $sel; do case "$t" in
         1) DO_F407=1;; 2) DO_F103=1;; 3) DO_HOST=1;;
         *) echo "   ignoring '$t'";;
       esac; done;;
  esac
  [ $((DO_F407+DO_F103+DO_HOST)) -eq 0 ] && { echo "Nothing selected."; exit 0; }
}

if [ $# -eq 0 ]; then
  show_menu                      # interactive menu
else
  for a in "$@"; do case "$a" in
    all)  DO_F407=1; DO_F103=1; DO_HOST=1;;
    f407) DO_F407=1;;
    f103) DO_F103=1;;
    host) DO_HOST=1;;
    *) echo "Unknown: $a"; echo "Usage: bash flash_mcus.sh [all|f407|f103|host ...]  (no args = menu)"; exit 1;;
  esac; done
fi
echo "Selection:  F407=$DO_F407  F103=$DO_F103  Host=$DO_HOST"
NEED_POWERCYCLE=0   # set when an MCU (F407/F103) is flashed -> it only boots the new firmware after a power-cycle
cd "$KLIPPER_DIR"

echo ">> Stopping Klipper + display owners (frees the MCU serial ports)..."
sudo systemctl stop klipper 2>/dev/null || true
sudo systemctl stop KlipperScreen 2>/dev/null || true
sudo pkill -x voronFDM 2>/dev/null || true
# systemctl returns as soon as the unit reports 'stopped', but the kernel releases the MCU serial fds a
# beat later. The F407's 1200-baud DFU touch and Katapult both need the port genuinely free, so settle
# before touching them: a missing settle — or a klipper that never actually stopped — is the most likely
# reason a flash silently doesn't take. And say so if it is still up, rather than failing cryptically
# three steps later. (revert-to-buster/flash-buster-mcus.sh has done this all along; this one, the script
# every recipient actually runs, did not.)
sleep 2
if systemctl is-active --quiet klipper 2>/dev/null; then
  echo "!! WARNING: Klipper is STILL running — 'sudo systemctl stop klipper' may have failed (sudo?)."
  echo "   The flash will likely fail. Stop it by hand, then re-run this script."
fi

# ─────────────────────────────────────────
build_f407() {
  echo "[F407] building..."
  if [ ! -f "$KLIPPER_DIR/config.stm32f407" ]; then
    echo "  config.stm32f407 missing -> writing template"
    cat > "$KLIPPER_DIR/config.stm32f407" << 'EOF'
CONFIG_MACH_STM32=y
CONFIG_BOARD_DIRECTORY="stm32"
CONFIG_MCU="stm32f407xx"
CONFIG_CLOCK_FREQ=168000000
CONFIG_USBSERIAL=y
CONFIG_FLASH_SIZE=0x80000
CONFIG_FLASH_BOOT_ADDRESS=0x8000000
CONFIG_RAM_START=0x20000000
CONFIG_RAM_SIZE=0x20000
CONFIG_STACK_SIZE=512
CONFIG_FLASH_APPLICATION_ADDRESS=0x8008000
CONFIG_STM32_SELECT=y
CONFIG_MACH_STM32F407=y
CONFIG_MACH_STM32F4=y
CONFIG_MACH_STM32F4x5=y
CONFIG_HAVE_STM32_USBOTG=y
CONFIG_STM32_USB_DOUBLE_BUFFER_TX=y
CONFIG_HAVE_STM32_CANBUS=y
CONFIG_HAVE_STM32_USBCANBUS=y
CONFIG_STM32_DFU_ROM_ADDRESS=0x1fff0000
CONFIG_STM32_FLASH_START_8000=y
CONFIG_CLOCK_REF_FREQ=8000000
CONFIG_STM32F0_TRIM=16
CONFIG_STM32_USB_PA11_PA12=y
CONFIG_USB=y
CONFIG_USB_VENDOR_ID=0x1d50
CONFIG_USB_DEVICE_ID=0x614e
CONFIG_USB_SERIAL_NUMBER_CHIPID=y
CONFIG_USB_SERIAL_NUMBER="12345"
CONFIG_WANT_ADC=y
CONFIG_WANT_SPI=y
CONFIG_WANT_SOFTWARE_SPI=y
CONFIG_WANT_I2C=y
CONFIG_WANT_SOFTWARE_I2C=y
CONFIG_WANT_HARD_PWM=y
CONFIG_WANT_BUTTONS=y
CONFIG_WANT_TMCUART=y
CONFIG_WANT_NEOPIXEL=y
CONFIG_WANT_PULSE_COUNTER=y
CONFIG_WANT_ST7920=y
CONFIG_WANT_HD44780=y
CONFIG_WANT_ADXL345=y
CONFIG_WANT_LIS2DW=y
CONFIG_WANT_BMI160=y
CONFIG_WANT_MPU9250=y
CONFIG_WANT_ICM20948=y
CONFIG_WANT_THERMOCOUPLE=y
CONFIG_WANT_HX71X=y
CONFIG_WANT_ADS131M0X=y
CONFIG_WANT_ADS1220=y
CONFIG_WANT_LDC1612=y
CONFIG_WANT_SENSOR_ANGLE=y
CONFIG_NEED_SENSOR_BULK=y
CONFIG_WANT_TRIGGER_ANALOG=y
CONFIG_NEED_SOS_FILTER=y
CONFIG_CANBUS_FREQUENCY=1000000
CONFIG_INLINE_STEPPER_HACK=y
CONFIG_HAVE_STEPPER_OPTIMIZED_BOTH_EDGE=y
CONFIG_WANT_STEPPER_OPTIMIZED_BOTH_EDGE=y
CONFIG_HAVE_GPIO=y
CONFIG_HAVE_GPIO_ADC=y
CONFIG_HAVE_GPIO_SPI=y
CONFIG_HAVE_GPIO_SDIO=y
CONFIG_HAVE_GPIO_I2C=y
CONFIG_HAVE_GPIO_HARD_PWM=y
CONFIG_HAVE_STRICT_TIMING=y
CONFIG_HAVE_CHIPID=y
CONFIG_HAVE_BOOTLOADER_REQUEST=y
EOF
  else echo "  using existing config.stm32f407"; fi
  make clean KCONFIG_CONFIG=config.stm32f407
  make olddefconfig KCONFIG_CONFIG=config.stm32f407
  make KCONFIG_CONFIG=config.stm32f407 -j4
}
flash_f407() {
  local dev fdev
  dev=$(ls /dev/serial/by-id/usb-Klipper_stm32f407xx_* 2>/dev/null | head -1)
  if [ -n "$dev" ]; then
    fdev="$dev"; echo "[F407] flashing (DFU via reboot-request) -> $dev"
  elif lsusb 2>/dev/null | grep -qi "0483:df11"; then
    fdev="0483:df11"; echo "[F407] already in DFU (0483:df11) -> flashing directly"
  else
    echo "[F407] NOT reachable — neither a Klipper serial nor a DFU device."
    echo "       • Re-flash case (already Klipper): it should reboot to DFU itself — just retry."
    echo "       • Fresh board (Phrozen firmware): hold BOOT0 on the mainboard + tap RESET to enter DFU,"
    echo "         then re-run.  Verify with:  lsusb | grep 0483:df11"
    return 1
  fi
  # NB: a *successful* DFU download still exits non-zero here because dfu-util's auto-leave ('detach')
  # fails on this board ("can't detach"). So judge success by "File downloaded successfully", not $?.
  local out; out=$(make flash KCONFIG_CONFIG=config.stm32f407 FLASH_DEVICE="$fdev" 2>&1); echo "$out"
  if echo "$out" | grep -qiE "File downloaded successfully|Download[[:space:]]+done"; then
    echo "[F407] firmware WRITTEN OK.  (dfu-util's 'can't detach' is expected on this board — harmless;"
    echo "       the F407 stays in DFU until a POWER-CYCLE, which then boots the new firmware.)"
    NEED_POWERCYCLE=1
    # the chip-ID serial is stable across the flash -> keep printer_MCU.cfg pointing at the right one
    if [ -n "$dev" ]; then
      local cfg="$ARCO_HOME/printer_data/config/printer_MCU.cfg"
      [ -f "$cfg" ] && grep -q "stm32f407xx_" "$cfg" && { cp "$cfg" "$cfg.bak"; \
        sed -i -E "s#^serial:.*stm32f407xx_.*#serial: $dev#" "$cfg"; echo "  printer_MCU.cfg serial -> $dev"; }
    else
      echo "  (flashed via DFU — after the power-cycle, set the F407 serial: bash scripts/set-mcu-serial.sh)"
    fi
  else
    # `make flash` goes through Klipper's flash_usb.py, which does the 1200-baud touch and then waits
    # only 100 ms after the sysfs path reappears before calling dfu-util -- and on this board the chip
    # is not always usable as DFU by then. It reports "No DFU capable USB device available" and stops,
    # while the F407 arrives in DFU a moment later and sits there waiting. Seen on hardware 2026-08-10
    # on the revert path, which uses the same helper; running the script again succeeded instantly.
    #
    # So look again, for the CONDITION rather than a fixed delay, and finish the job here. Not fixed in
    # flash_usb.py itself on purpose: that is Klipper's file, and a Klipper update would take the patch
    # with it -- the same trap as mcu.py. dfu-util is called without flash_usb.py's `-p <buspath>`,
    # which pins the OLD bus path and would miss the device if it re-enumerated elsewhere.
    echo "[F407] flash_usb.py did not complete — checking whether the chip reached DFU anyway ..."
    local _i _dfu=0
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      lsusb 2>/dev/null | grep -qi "0483:df11" && { _dfu=1; break; }
      sleep 1
    done
    if [ "$_dfu" = 1 ] && [ -f "$KLIPPER_DIR/out/klipper.bin" ]; then
      echo "[F407] it did — flashing directly with dfu-util ..."
      out=$(sudo dfu-util -a 0 -s 0x8008000:leave -D "$KLIPPER_DIR/out/klipper.bin" 2>&1); echo "$out"
      if echo "$out" | grep -qiE "File downloaded successfully|Download[[:space:]]+done"; then
        echo "[F407] firmware WRITTEN OK.  ('can't detach' is expected — it stays in DFU until a POWER-CYCLE.)"
        NEED_POWERCYCLE=1
        echo "  (flashed via DFU — after the power-cycle, set the F407 serial: bash scripts/set-mcu-serial.sh)"
        return 0
      fi
    fi
    echo "[F407] FLASH FAILED — no 'File downloaded successfully' above (firmware was NOT written)."
    return 1
  fi
}

# ─────────────────────────────────────────
build_f103() {
  echo "[F103] building (Katapult offset 0x8002000)..."
  if [ ! -f "$KLIPPER_DIR/config.stm32f103" ]; then
    echo "  config.stm32f103 missing -> writing template"
    cat > "$KLIPPER_DIR/config.stm32f103" << 'EOF'
CONFIG_MACH_STM32=y
CONFIG_BOARD_DIRECTORY="stm32"
CONFIG_MCU="stm32f103xe"
CONFIG_CLOCK_FREQ=72000000
CONFIG_SERIAL=y
CONFIG_FLASH_SIZE=0x10000
CONFIG_FLASH_BOOT_ADDRESS=0x8000000
CONFIG_RAM_START=0x20000000
CONFIG_RAM_SIZE=0x5000
CONFIG_STACK_SIZE=512
CONFIG_FLASH_APPLICATION_ADDRESS=0x8002000
CONFIG_STM32_SELECT=y
CONFIG_MACH_STM32F103=y
CONFIG_MACH_STM32F1=y
CONFIG_HAVE_STM32_USBFS=y
CONFIG_STM32_USB_DOUBLE_BUFFER_TX=y
CONFIG_HAVE_STM32_CANBUS=y
CONFIG_STM32_DFU_ROM_ADDRESS=0
CONFIG_STM32_FLASH_START_2000=y
CONFIG_CLOCK_REF_FREQ=8000000
CONFIG_STM32F0_TRIM=16
CONFIG_STM32_SERIAL_USART1=y
CONFIG_SERIAL_BAUD=250000
CONFIG_USB_VENDOR_ID=0x1d50
CONFIG_USB_DEVICE_ID=0x614e
CONFIG_USB_SERIAL_NUMBER="12345"
CONFIG_WANT_ADC=y
CONFIG_WANT_SPI=y
CONFIG_WANT_SOFTWARE_SPI=y
CONFIG_WANT_I2C=y
CONFIG_WANT_SOFTWARE_I2C=y
CONFIG_WANT_HARD_PWM=y
CONFIG_WANT_BUTTONS=y
CONFIG_WANT_TMCUART=y
CONFIG_WANT_NEOPIXEL=y
CONFIG_WANT_PULSE_COUNTER=y
CONFIG_WANT_ST7920=y
CONFIG_WANT_HD44780=y
CONFIG_WANT_ADXL345=y
CONFIG_WANT_LIS2DW=y
CONFIG_WANT_BMI160=y
CONFIG_WANT_MPU9250=y
CONFIG_WANT_ICM20948=y
CONFIG_WANT_THERMOCOUPLE=y
CONFIG_WANT_HX71X=y
CONFIG_WANT_ADS131M0X=y
CONFIG_WANT_ADS1220=y
CONFIG_WANT_LDC1612=y
CONFIG_WANT_SENSOR_ANGLE=y
CONFIG_NEED_SENSOR_BULK=y
CONFIG_WANT_TRIGGER_ANALOG=y
CONFIG_NEED_SOS_FILTER=y
CONFIG_CANBUS_FREQUENCY=1000000
CONFIG_INLINE_STEPPER_HACK=y
CONFIG_HAVE_STEPPER_OPTIMIZED_BOTH_EDGE=y
CONFIG_WANT_STEPPER_OPTIMIZED_BOTH_EDGE=y
CONFIG_HAVE_GPIO=y
CONFIG_HAVE_GPIO_ADC=y
CONFIG_HAVE_GPIO_SPI=y
CONFIG_HAVE_GPIO_I2C=y
CONFIG_HAVE_GPIO_HARD_PWM=y
CONFIG_HAVE_STRICT_TIMING=y
CONFIG_HAVE_CHIPID=y
CONFIG_HAVE_BOOTLOADER_REQUEST=y
EOF
  else echo "  using existing config.stm32f103 (Katapult)"; fi
  make clean KCONFIG_CONFIG=config.stm32f103
  make olddefconfig KCONFIG_CONFIG=config.stm32f103
  make KCONFIG_CONFIG=config.stm32f103 -j4
}
flash_f103() {
  # Does THIS toolhead's F103 actually carry the Katapult bootloader? The katapult repo shipping with
  # the image is NOT proof. We AUTO-DETECT instead of asking the user to know their printer's history.
  # flashtool flags (per --help):
  #   -r  "request the bootloader AND exit"        -> kicks a running Klipper F103 into Katapult
  #   -s  "connect to bootloader and print status" -> answers ONLY if Katapult is actually present
  #   -f  write + verify                           -> the device must already be sitting in Katapult
  # -r is harmless on a board WITHOUT Katapult: the F103 just resets back to its own app.
  local FT="$KATAPULT_DIR/scripts/flashtool.py"
  local BIN="$KLIPPER_DIR/out/klipper.bin"

  if [ -f "$KATAPULT_MARK" ]; then
    echo "[F103] Katapult recorded on this toolhead -> requesting bootloader (F103 -> Katapult)..."
    python3 "$FT" -r -d /dev/ttyS0 -b 250000 || echo "       (request nonzero — may already be in Katapult)"
    sleep 2
  else
    echo "[F103] no Katapult record -> probing the toolhead (request bootloader, then ask its status)..."
    python3 "$FT" -r -d /dev/ttyS0 -b 250000 || true   # harmless if no Katapult: F103 just resets to its app
    sleep 2
    if python3 "$FT" -s -d /dev/ttyS0 -b 250000 >/dev/null 2>&1; then
      echo "[F103] Katapult DETECTED on this toolhead -> flashing."
    else
      echo "[F103] NO Katapult detected — this F103 still runs old/stock firmware (no bootloader)."
      # The old one-liner weighted these backwards: it warned about [s], which cannot break anything,
      # and made [i] sound trivial although it is the one needing a screwdriver and two covers off.
      echo "      [i] install Katapult — NEEDS THE TOOLHEAD OPEN: two covers off, BOOT and RESET"
      echo "          reachable, printer running. One-time; no button is needed for any flash after."
      echo "      [s] try flashing anyway — SAFE to attempt. flashtool speaks Katapult's protocol, so"
      echo "          without Katapult nothing answers and nothing is written; you just get an error."
      echo "          Use it if you think the probe above misread a toolhead that does have Katapult."
      read -rp "      [i]nstall / [s]kip the probe and try / [c]ancel: " a
      case "$a" in
        i|I|y|Y|j|J)
          # ARCO_KATAPULT_INLINE: tells the installer we are flashing the firmware straight after, so it
          # leaves Klipper stopped and the toolhead sitting in Katapult instead of starting Klipper and
          # forcing us to stop it again a line later. It also jumps into Katapult itself now (-g), so
          # the flash below connects on the first try rather than after a "flash didn't take" retry.
          ARCO_KATAPULT_INLINE=1 bash "$(dirname "$0")/install-katapult.sh"
          sudo systemctl stop klipper 2>/dev/null || true ;;   # belt and braces if it started anyway
        s|S)
          echo "      flashing anyway (a successful write will confirm Katapult)." ;;
        *)
          echo "      Cancelled — no F103 flash."; return 0 ;;
      esac
    fi
  fi

  # --- write + verify (the F103 should be sitting in Katapult now) ---
  echo "[F103] flashing Klipper via Katapult (writes + verifies)..."
  local f103ok=0
  python3 "$FT" -d /dev/ttyS0 -b 250000 -f "$BIN" && f103ok=1
  if [ "$f103ok" != 1 ]; then
    echo "  flash didn't take — tap RESET on the toolhead ONCE (no BOOT0) to drop into Katapult, then press ENTER..."
    read -r
    python3 "$FT" -d /dev/ttyS0 -b 250000 -f "$BIN" && f103ok=1
  fi
  if [ "$f103ok" != 1 ]; then
    echo "[F103] FLASH FAILED — firmware was NOT written. If Katapult is NOT on this F103 yet, run install-katapult (BOOT0)."
    return 1
  fi
  # a REAL flash succeeded -> record that Katapult is present on this F103 (self-heals migrated printers)
  mkdir -p "$(dirname "$KATAPULT_MARK")" && date > "$KATAPULT_MARK" 2>/dev/null || true
  echo "[F103] firmware WRITTEN OK (Katapult).  Needs a POWER-CYCLE to boot the new app cleanly"
  echo "       (otherwise Klipper races the toolhead reset and reports 'Serial connection closed')."
  NEED_POWERCYCLE=1
}

# ─────────────────────────────────────────
setup_host() {
  echo "[Host MCU] building + installing..."
  cat > "$KLIPPER_DIR/config.linux" << 'EOF'
CONFIG_MACH_LINUX=y
CONFIG_BOARD_DIRECTORY="linux"
CONFIG_CLOCK_FREQ=50000000
CONFIG_HAVE_GPIO=y
CONFIG_HAVE_GPIO_SPI=y
CONFIG_HAVE_GPIO_I2C=y
CONFIG_HAVE_GPIO_HARD_PWM=y
CONFIG_HAVE_GPIO_BITBANGING=y
EOF
  make clean KCONFIG_CONFIG=config.linux
  make olddefconfig KCONFIG_CONFIG=config.linux
  make KCONFIG_CONFIG=config.linux -j4
  make flash KCONFIG_CONFIG=config.linux   # installs /usr/local/bin/klipper_mcu (sudo used internally)
  # Service + IMPORTANT: remove '-r' (realtime sched_setscheduler fails on this kernel -> exit 255)
  sudo cp "$KLIPPER_DIR/scripts/klipper-mcu.service" /etc/systemd/system/
  sudo sed -i 's| -r -I| -I|' /etc/systemd/system/klipper-mcu.service
  sudo systemctl daemon-reload
  sudo systemctl enable klipper-mcu
  sudo systemctl restart klipper-mcu
  sleep 1
  ls -l /tmp/klipper_host_mcu && echo "  host MCU socket ok" || echo "  WARN: no socket — check status!"
}

# ---- run ----
[ "$DO_F407" = 1 ] && { build_f407; flash_f407 || echo "[F407] not flashed (see message above)"; }
[ "$DO_F103" = 1 ] && { build_f103; flash_f103 || echo "[F103] not flashed (see message above)"; }
[ "$DO_HOST" = 1 ] && { setup_host;             echo "[Host] done"; }

# The F407's chip id is read off the running board BEFORE it is put into DFU (it is burned into the chip and
# survives the flash), so flash_f407 normally writes it into printer_MCU.cfg by itself. That read is
# impossible in exactly one case: the board was ALREADY in DFU when we started, because a DFU device does not
# announce a Klipper serial. The placeholder then stays, Klipper cannot connect, and the reason is one line
# of scrollback nobody re-reads. Say it at the end, where it is the last thing on screen.
_cfg="$ARCO_HOME/printer_data/config/printer_MCU.cfg"
if [ "$DO_F407" = 1 ] && grep -q 'CHANGE-your-chip-id' "$_cfg" 2>/dev/null; then
  echo ""
  echo "############################################################################"
  echo "  !! printer_MCU.cfg still has the chip-id PLACEHOLDER — Klipper will NOT"
  echo "     connect to the F407 until this is fixed."
  echo ""
  echo "     Your board's id could not be read (it was already in DFU when this"
  echo "     started). After the power-cycle below, with the printer running, do:"
  echo ""
  echo "         bash $(dirname "$0")/set-mcu-serial.sh && sudo systemctl restart klipper"
  echo "############################################################################"
fi

if [ "$NEED_POWERCYCLE" = 1 ]; then
  echo ""
  echo "############################################################################"
  echo "  POWER-CYCLE THE PRINTER NOW  --  full power OFF (~10 s), then ON."
  echo ""
  echo "  The flashed MCU(s) only boot the new firmware after a hardware reset"
  echo "  (the F407 leaves DFU, the F103 leaves Katapult). Klipper auto-starts on"
  echo "  boot and will then connect -- check the 'Loaded MCU' lines in Mainsail."
  echo "  (Klipper is left STOPPED on purpose; the power-cycle starts it cleanly.)"
  echo "############################################################################"
else
  echo ">> Starting Klipper + display..."
  sudo systemctl start klipper
  sudo systemctl start KlipperScreen 2>/dev/null || true   # we stopped it above — put the display back
  sleep 3
  systemctl status klipper --no-pager | head -5
  echo ""
  echo "=== Done === Check the 'Loaded MCU' lines in Mainsail."
fi
