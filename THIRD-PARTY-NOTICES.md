# Third-party notices

**Arco Unleashed — Bookworm Edition** (the scripts, configs, docs and the captive portal) is licensed
under **AGPL-3.0** — see [`LICENSE`](LICENSE).

This repository also bundles or relies on third-party components that keep **their own** licenses:

| Component | What | License / source |
|---|---|---|
| `rk3328-mkspi.dtb` — **image only**, not in this repo | the device tree (modified for SDIO/WiFi + UART1 display + rk805 edge fix) | derived from the Linux kernel / Armbian device tree — **GPL-2.0-or-later / MIT** (kernel DTS). Source: kernel.org / armbian |
| AP6212 / BCM43430 WiFi firmware + nvram — **image only**, not in this repo | `cyfmac43430` firmware and its nvram (xtalfreq=26000) | **Broadcom/Cypress** firmware redistribution license (as shipped in `linux-firmware`). Redistributed in the image with this notice. |
| `phrozen_dev` Python module (NOT in this repo) | Phrozen's Klipper extension (`base.py`, `cmds.py`, …) | **NOT redistributed or downloaded here.** Installed at runtime from a **USB stick the user provides** (Phrozen's official `Arco_FW_V*.zip`) by `scripts/fetch-phrozen-fw.sh`; the module is **GPL-3.0** in <https://github.com/phrozen3d/klipper>. Our `apply-phrozen-patches.sh` only contains the change *rules* (no Phrozen code). |
| `voronFDM` display binary (NOT in this repo) | Phrozen's compiled serial-display driver, shipped inside the module | **Phrozen proprietary, closed-source — NOT GPL.** Despite the name it is Phrozen's own C++ program (no GPL libraries linked; communicates with Klipper only over Moonraker JSON-RPC, an arm's-length IPC boundary), so it is **not** a GPL-derived work. Not redistributed here — provided by the user on USB. |
| Display `.tft` UI + AMS `.bin` firmware (NOT in this repo) | Phrozen's serial-display UI project and AMS MCU firmware | **Phrozen proprietary.** Not redistributed here — provided by the user on USB (from Phrozen's official package). |
| PhrozenGo / ThroughTek (TUTK) | Phrozen's remote app + ThroughTek Kalay SDK | **NOT redistributed here** (third-party proprietary). Comes only from Phrozen's official package on the user's own device. |
| Klipper, Moonraker, Mainsail, KlipperScreen, Crowsnest | the printer stack — **not in this repo**, *except* the two prebuilt MCU firmware binaries in the row below; installed on the printer via KIAUH | GPL-3.0 / respective upstream licenses |
| `revert-to-buster/arco-f407-buster-v0.11.bin` and `arco-f103-buster-v0.11.bin` — **these ARE in this repo** | prebuilt Klipper **v0.11** MCU firmware, so a printer already on Unleashed can flash back to stock Buster (a v0.13 host cannot build v0.11) | **GPL-3.0.** Built from Phrozen's Klipper fork <https://github.com/phrozen3d/klipper> at commit `e6ef48cd` (`git describe`: v0.11.0-122-ge6ef48cd) — F407 at application offset 0x8008000, F103 at 0x8002000 (Katapult). No proprietary Phrozen code. Full licence text: [`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt), shipped beside the binaries. |
| `scripts/gcode_shell_command.py` — **in this repo** | lets a Klipper macro run a shell command; several kit macros depend on it | **GPL-3.0**, © 2019 Eric Callahan (Arksine). Vendored verbatim with its header intact, from <https://github.com/dw-0/kiauh> / the klipper community extension. Full licence text: [`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt). |
| KAOS (NOT in this repo) | optional third-party add-on by *sanders.chris*, fetched onto the printer only when the owner types `KAOS_ON` | **Not redistributed here.** Fetched at runtime from the author's own repository <https://gitlab.com/sanders.chris/phrozenarco>; its licence is the author's. Our bridge (`unleashed-x-kaos/`) is our own AGPL-3.0 code and contains none of KAOS's payload — the bake **refuses** if a `dev.py` or `kaos_*.py` is found in it. |
| Fluidd | the second web interface, alongside Mainsail — **not in this repo**; `scripts/install-fluidd.sh` fetches the official release zip from <https://github.com/fluidd-core/fluidd/releases> onto the printer | **GPL-3.0**. Restores what the stock Arco ships: Phrozen's Buster serves Fluidd on :8808, and that nginx site survived the migration while the files did not. |
| Beacon `beacon.py` (NOT in this repo) | the eddy-current probe's Klipper module, for the optional experimental Beacon probing mode — **not in this repo and not in the image**; `scripts/beacon_toggle.sh` asks first, then clones <https://github.com/beacon3d/beacon_klipper> onto the printer and copies **only** `beacon.py` into `klippy/extras/` | **GPL-3.0** (compatible with this project's AGPL-3.0; the two are explicitly interoperable). Nothing from that repository is redistributed here. Our `config-templates/beacon.cfg.template` is our own text and our own starting values — written from the writeup **Philippe Humeau (unPhrozen)** shared with this project, with thanks. |
| *(distributable image only)* | the full `.img.gz` is captured from a working printer, so it **does** contain the stack above as installed — Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, Crowsnest | all GPL-3.0 / upstream licenses, redistributed unmodified with this notice. The rows above describe **this repository**; the image is a different artifact and bundles them. Beacon is **not** among them — it is only ever fetched later, on the user's own machine, if they enable it. |

## Trademarks
**"Phrozen", "Arco" and "PhrozenGo" are trademarks of Phrozen Tech Co., Ltd.** "ThroughTek",
"Kalay" and "TUTK" are trademarks of ThroughTek Co., Ltd. **"Beacon" is a trademark of Beacon3D.**
All product names, logos and brands are
the property of their respective owners and are used here **only for identification and
descriptive purposes** (nominative fair use). Use of these names does **not** imply any affiliation
with, sponsorship by, or endorsement from their owners.

**Arco Unleashed — Bookworm Edition is an independent, community-made project. It is not developed,
supported, sponsored, endorsed by, or affiliated with Phrozen Tech Co., Ltd. or ThroughTek Co., Ltd.
No proprietary Phrozen/ThroughTek software is bundled, hosted or mirrored by this project.** Phrozen's
parts are installed on the owner's own printer either from the `Arco_FW_V*.zip` the owner obtains from
official Phrozen sources and provides on a USB stick, or — **only after the owner explicitly confirms**
— by downloading the `phrozen_dev` module from **Phrozen's own public repository**
([phrozen3d/klipper](https://github.com/phrozen3d/klipper), GPL-3.0), pinned to a fixed commit and
verified by checksum before installation. That route deliberately does **not** bring PhrozenGo, the
display `.tft` or the AMS firmware; those exist only in Phrozen's own package. No copy of any Phrozen
file is stored, cached or redistributed here.

## Copyright
- All copyright, trademark and other intellectual-property rights in Phrozen's and ThroughTek's
  software, firmware, branding and assets **remain with Phrozen and ThroughTek respectively.**
- This project claims **no** ownership over any third-party component. Copyright in the original
  scripts, configs, docs and the captive portal of *Arco Unleashed* belongs to its contributors and
  is licensed under AGPL-3.0.

## Notes
- AGPL-3.0 is compatible with the GPL-3.0 `phrozen_dev` **Python module** and with the AGPL-3.0
  Phrozen Arco configs the templates derive from ([phrozen3d/Phrozen_ARCO](https://github.com/phrozen3d/Phrozen_ARCO)).
- The four first-party Klipper extras in `scripts/` (`arco_mcu_timing.py`, `arco_fila_status.py`,
  `arco_sdcard_select.py`, `arco_tool_gate.py`) are AGPL-3.0 and are loaded into Klipper, which is
  GPL-3.0. **GPL-3.0 section 13** expressly permits combining a covered work with an AGPL-3.0 work;
  the AGPL's network clause then applies to the combination. One exception is marked in the file
  itself: the command body of `arco_sdcard_select.py` is adapted from Klipper's `virtual_sdcard.py`
  (Kevin O'Connor, GPL-3.0) and that portion stays GPL-3.0.
- Only the `phrozen_dev` Python module is GPL-3.0. The `voronFDM` binary, the display `.tft`, the AMS
  firmware and PhrozenGo/TUTK are **Phrozen/ThroughTek proprietary** — none of them are redistributed
  by this project; the user obtains Phrozen's official package and provides it on a USB stick.
- No Phrozen software is stored in this repository **and this project downloads none**. Phrozen's
  parts are supplied by the user (on USB) at install time and patched in place.
