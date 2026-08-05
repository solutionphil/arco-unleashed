# Arco Unleashed WiFi captive portal

A small, open-source first-boot WiFi onboarding — **no Phrozen software needed**. This is what lets
the public eMMC image stay 100% Phrozen-free: the user sets WiFi via a pretty phone page, the printer
reboots, and then installs Phrozen's software from a **USB stick the user provides** (no download).

## Flow
1. **No WiFi yet** → `arco-firstrun.service` runs `arco-firstrun.sh` → starts the AP
   **`Arco-Unleashed-Setup`** + captive portal (`wifi-portal.sh` → `portal.py`).
2. User connects a phone to that AP → the portal pops up (logo + network list + password).
3. On **Connect**: `portal.py` writes `wpa_supplicant-wlan0.conf` and **reboots**.
4. After reboot → `arco-firstrun.sh` sees `phrozen_dev` missing → waits for a FAT32 USB stick with
   `Arco_FW_V*.zip`, then runs `fetch-phrozen-fw.sh` (installs voronFDM + phrozen_dev from the stick,
   applies the v0.13 patches) → restarts Klipper/KlipperScreen → **disables itself**. Ready to go.

## Files
- `portal.py`   — the web server + the responsive page (logo, network dropdown, password, status)
- `wifi-portal.sh` — pre-scans WiFi, brings up hostapd + dnsmasq on `wlan0` 192.168.4.1, runs portal.py
- `../arco-firstrun.sh` + `../arco-firstrun.service` — the orchestrator (stages 1 & 2 above)

## Enabling it when building the image
```bash
sudo apt install -y hostapd dnsmasq unzip          # prerequisites baked into the image
sudo cp ~/arco-unleashed/scripts/arco-firstrun.service /etc/systemd/system/
sudo systemctl enable arco-firstrun.service
sudo systemctl disable hostapd dnsmasq             # we start them manually from wifi-portal.sh
```
Then sanitize + image as usual (the firstrun service fires on the recipient's first boot).

## ⚠️ Needs testing on real hardware
AP mode + the scan→AP handoff on the AP6212/brcmfmac, hostapd channel, and the captive-portal popup
behave differently per phone OS. Test the full cycle (AP up → portal → submit → reboot → USB install)
on an actual Arco before shipping an image.
