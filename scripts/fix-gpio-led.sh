#!/bin/bash
# fix-gpio-led.sh — chamber light: voronFDM toggles the LED via libgpiod on /dev/gpiochip2
# but gets EACCES (gpiochips are root:root 0600). Fix: gpio group + udev rule.
# On the printer:  sudo bash scripts/fix-gpio-led.sh
set -e
[ "$EUID" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
USER_NAME="${SUDO_USER:-mks}"

groupadd -f gpio
usermod -aG gpio "$USER_NAME"
echo 'SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"' \
  > /etc/udev/rules.d/99-gpio.rules
udevadm control --reload-rules && udevadm trigger
# udev trigger often misses already-present gpiochips -> set them directly now:
chown root:gpio /dev/gpiochip{0,1,2,3} 2>/dev/null || true
chmod 660 /dev/gpiochip{0,1,2,3} 2>/dev/null || true
systemctl restart KlipperScreen 2>/dev/null || true

echo ""
echo "Done. Test the display light button. The udev rule persists across reboots."
ls -l /dev/gpiochip2 || true
