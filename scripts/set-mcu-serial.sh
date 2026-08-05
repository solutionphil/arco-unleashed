#!/bin/bash
# set-mcu-serial.sh — automatically writes THIS printer's actual F407 serial into printer_MCU.cfg.
# So nobody has to look up the chip id by hand.
#
# Background: every STM32F407 has a unique USB serial (chip id, because built with
# CONFIG_USB_SERIAL_NUMBER_CHIPID=y). The by-id path therefore differs per device.
# Phrozen's stock config only contains their build board's chip id (matches nobody else).
#
# Flow:  flash the F407 (flash_mcus.sh f407) -> printer powered on -> run this script.
set -e
CFG="$HOME/printer_data/config/printer_MCU.cfg"
[ -f "$CFG" ] || { echo "ERROR: $CFG not found."; exit 1; }

DEV=$(ls /dev/serial/by-id/usb-Klipper_stm32f407xx_* 2>/dev/null | head -1)
if [ -z "$DEV" ]; then
  echo "ERROR: no F407 found under /dev/serial/by-id/."
  echo "  -> flash the F407 first (bash flash_mcus.sh f407) and leave the printer powered on."
  echo "  -> check with:  ls /dev/serial/by-id/"
  exit 1
fi

cp "$CFG" "$CFG.bak"
# replace only the F407 serial line in [mcu] (MKS_THR=/dev/ttyS0 and rpi stay untouched)
sed -i -E "s#^serial:.*stm32f407xx_.*#serial: $DEV#" "$CFG"

echo "F407 serial set to:"
grep -nE "^\[mcu|^serial:" "$CFG" || true
echo ""
echo "Now run:  sudo systemctl restart klipper   (or RESTART in Mainsail)"
echo ""
echo "ALTERNATIVE (for fleet distribution): build the F407 with a FIXED serial"
echo "(CONFIG_USB_SERIAL_NUMBER_CHIPID=n + CONFIG_USB_SERIAL_NUMBER=\"12345\") -> then the"
echo "by-id path is identical on EVERY Arco and the config never needs adjusting."
