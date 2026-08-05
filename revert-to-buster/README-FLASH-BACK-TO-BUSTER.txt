Arco — flash the MCUs back to Buster (Klipper v0.11) firmware, from USB
======================================================================

WHAT THIS IS
  Two pre-built MCU firmware files + a flasher, so you can put a stock-Buster-compatible
  firmware back on the printer's MCUs WITHOUT building anything:

    arco-f407-buster-v0.11.bin   Mainboard  STM32F407  (exact stock, from a working pre-Unleashed Arco)
    arco-f103-buster-v0.11.bin   Toolhead   STM32F103  (built from the same Klipper v0.11.0-122 source)
    flash-buster-mcus.sh         the flasher
    SHA256SUMS.txt               checksums

WHY DO THIS ON UNLEASHED (Bookworm), NOT ON BUSTER
  The MCU firmware lives on the STM32 chips, NOT on the eMMC — swapping the eMMC to Buster does
  not change it. The MCUs must be put on v0.11 to match a Buster host. Do it here on the running
  Unleashed system: it already has the flasher tools (katapult, dfu-util) and a modern Python.
  Building v0.11 on Buster's old toolchain is painful; flashing these ready .bin files is not.

STEPS
  1. Copy this whole folder onto a FAT32 USB stick.
  2. Plug the stick into the RUNNING Unleashed printer (it auto-mounts at ~/printer_data/gcodes/USB).
  3. SSH in as mks and run the flasher from the stick, e.g.:

        bash ~/printer_data/gcodes/USB/flash-buster-mcus.sh          # menu: F103 / F407 / both

     - F103 flashes through its Katapult bootloader — NO button.
     - F407 flashes via USB-DFU, also NO button: the script uses Klipper's flash_usb.py to
       reboot the running F407 into DFU (a 1200-baud touch) and then dfu-util writes it. Only if
       flash_usb.py / the F407 serial can't be found does it fall back to asking for BOOT0 + RESET.
  4. POWER-CYCLE the printer.
  5. Now swap the eMMC to Buster and boot it. v0.11 host + v0.11 MCUs = they connect.

NOTES
  - After flashing, Klipper on Unleashed will NOT reconnect (v0.13 host + v0.11 MCUs). That is
    expected — do this as the LAST step here, right before the eMMC swap.
  - Fully reversible: to go back to Unleashed/v0.13, re-run  ~/arco-unleashed/scripts/flash_mcus.sh.
  - The F103 uses serial baud 250000 (Klipper default, and the value the Arco uses). If the F103
    does not connect on Buster, check the [mcu ...] baud in your Buster printer.cfg.
  - Firmware version is v0.11.0-122; it matches the stock Buster host.

SOURCE & LICENSE
  The MCU firmware is Klipper (GPL-3.0), built from Phrozen's Klipper fork at
  https://github.com/phrozen3d/klipper (tag v0.11.0-122-ge6ef48cd) — F407 with the stock
  application offset 0x8008000, F103 with 0x8002000 (Katapult). No proprietary Phrozen software
  is included. flash-buster-mcus.sh is part of Arco Unleashed (AGPL-3.0).

  The two .bin files are GPL-3.0. The full licence text is beside them in
  COPYING-GPL-3.0.txt — GPL-3.0 requires that you receive it along with the
  binaries, and this project's own LICENSE is the AGPL, which is a different
  document. The corresponding source is the fork and commit named above.

RISK, WARRANTY & AFFILIATION
  - Flashing MCU firmware is done ENTIRELY AT YOUR OWN RISK. There is no guarantee of any kind,
    and nobody here is liable for a printer that ends up damaged or unusable.
  - Replacing the factory OS/firmware will very likely VOID YOUR PHROZEN WARRANTY, and reverting
    to stock may not restore it.
  - Arco Unleashed is an independent, community-made project — NOT developed, supported,
    sponsored, endorsed by, or affiliated with Phrozen Tech Co., Ltd. This is not an official
    Phrozen procedure, and Phrozen cannot be asked for support on a printer running it.
  - "Phrozen" and "Arco" are trademarks of their respective owners, used here only for
    identification.
