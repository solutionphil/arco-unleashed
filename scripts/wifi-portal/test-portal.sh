#!/bin/bash
# test-portal.sh — SAFELY try the captive portal + display screen on a WORKING printer.
#
# It backs up your current WiFi and arms a one-shot "restore on next boot" service, so that
# whatever happens during the test, a reboot / power-cycle puts your original WiFi back.
# Then it opens the setup AP. NOTE: your SSH session WILL drop (wlan0 switches to AP) — normal.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
WPA=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
BK=/root/arco-wifi-test-backup.conf

[ -f "$WPA" ] || { echo "No $WPA found — nothing to back up. Aborting."; exit 1; }
sudo cp "$WPA" "$BK"

# safety net: restore the original WiFi on the next boot, then remove itself
sudo tee /etc/systemd/system/arco-wifi-restore.service >/dev/null <<EOF
[Unit]
Description=Restore original WiFi after Arco portal test (one-shot)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cp $BK $WPA; systemctl restart wpa_supplicant@wlan0.service 2>/dev/null || true; systemctl disable arco-wifi-restore.service; rm -f /etc/systemd/system/arco-wifi-restore.service $BK'
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable arco-wifi-restore.service >/dev/null 2>&1

cat <<'TXT'

============================================================
 Safety net ARMED — a reboot/power-cycle restores your WiFi.
 Opening the setup AP now. YOUR SSH WILL DROP (that's normal).

 On your phone:
   1) connect to WiFi  "Arco-Unleashed-Setup"
   2) the portal should pop up (logo + network list)
   3) check the printer DISPLAY shows the setup screen

 When you're done testing:  power-cycle the printer
 -> your original WiFi comes back automatically.
============================================================
TXT
sleep 4
sudo systemctl stop KlipperScreen 2>/dev/null || true
# run detached so it survives the SSH drop
sudo systemd-run --unit=arco-portal-test --collect /bin/bash "$DIR/wifi-portal.sh" >/dev/null 2>&1 || \
  sudo systemd-run --unit=arco-portal-test /bin/bash "$DIR/wifi-portal.sh"
echo "Portal launched as service 'arco-portal-test'. SSH may drop now — go to your phone."
