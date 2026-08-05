#!/bin/bash
# f103-remove-katapult.sh — put the toolhead F103 back to a NO-BOOTLOADER state.
#
#   bash scripts/f103-remove-katapult.sh
#
# WHY THIS EXISTS. It is a TEST tool, not a repair tool. Once Katapult is on a toolhead it stays, and
# the install path — the BOOT/RESET sequence, the mass-erase, the jump into Katapult — can then never
# be exercised again on that machine. That path is the one a recipient with a factory-fresh printer
# walks, it is the fiddliest thing in the whole kit, and until now it could only be tested by finding
# an un-migrated printer. This undoes it so the path can be walked again on a machine you already have.
#
# WHAT IT DOES. Mass-erases the F103 (which removes Katapult at 0x8000000 AND the application at
# 0x8002000), then writes Klipper straight to 0x8000000 so the toolhead works normally afterwards —
# just without a bootloader. Finally it removes the marker flash_mcus.sh uses to remember that this
# toolhead has Katapult, so the next run genuinely takes the install path rather than assuming.
#
# THE OFFSET IS THE WHOLE POINT. flash_mcus.sh builds the F103 for 0x8002000 because Katapult occupies
# the first 8 KiB. With no bootloader the application must start at 0x8000000, so this builds its own
# variant. It does that by copying the config flash_mcus.sh writes and changing ONE line, rather than
# carrying a second full config: every other option in there (sensors, steppers, ADC, the lot) has to
# match what printer.cfg expects, and two hand-maintained copies would drift.
#
# AFTERWARDS you need the BOOT button again for any F103 flash, until Katapult is reinstalled —
# which is exactly the state you asked to get back to.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KLIPPER_DIR="${KLIPPER_DIR:-$HOME/klipper}"
KATAPULT_MARK="$HOME/.config/arco-unleashed/katapult-f103.done"
CFG_KAT="$KLIPPER_DIR/config.stm32f103"
CFG_NOBL="$KLIPPER_DIR/config.stm32f103.nobl"

command -v stm32flash >/dev/null || { echo "stm32flash is not installed (sudo apt install stm32flash)"; exit 1; }
[ -d "$KLIPPER_DIR" ] || { echo "no klipper tree at $KLIPPER_DIR"; exit 1; }

cat <<'TXT'
======================================================================
 REMOVE KATAPULT FROM THE TOOLHEAD F103   (test tool)

 After this the toolhead runs Klipper directly, with NO bootloader:
   * every future F103 flash needs the BOOT button again,
   * until you reinstall Katapult (flash_mcus.sh offers it).

 You will need the toolhead open and the BOOT + RESET buttons reachable,
 with the printer RUNNING. Same access as the original install.
======================================================================
TXT
printf "   Type 'remove' to continue, anything else to abort: "
read -r ans
[ "$ans" = remove ] || { echo "   Aborted — nothing was changed."; exit 0; }

echo "=== 1) Free the serial port ==="
# klippy is what holds /dev/ttyS0 -- verified on the machine, not assumed: its open descriptors carry
# ttyS0 for [mcu MKS_THR], alongside ttyACM0 for the F407. So stopping it is what frees the toolhead
# line, and the fuser check below is what proves it actually happened.
#
# An earlier version masked the unit as well, reasoning that Restart=always could bring Klipper back
# mid-write. That was wrong twice over and is gone. systemd does not restart a unit that was stopped
# explicitly -- Restart= governs unexpected exits of a running service, and a stopped service has
# nothing to exit. And masking cannot work here anyway: klipper.service is a regular file in
# /etc/systemd/system, which is exactly where mask wants to put its symlink, so systemd refuses.
#
# Moonraker is deliberately NOT touched: it holds no tty at all, it talks to klippy over a unix socket.
# voronFDM and the PhrozenGo processes sit on ttyS1 (the display), not on the toolhead line, but
# voronFDM is stopped anyway because it is cheap and it keeps this in step with flash_mcus.sh.
sudo systemctl stop klipper 2>/dev/null || true
sudo systemctl stop KlipperScreen 2>/dev/null || true
sudo pkill -x voronFDM 2>/dev/null || true
sleep 2
if command -v fuser >/dev/null 2>&1 && fuser /dev/ttyS0 >/dev/null 2>&1; then
  echo "!! something still holds /dev/ttyS0:"; fuser -v /dev/ttyS0 2>&1 | sed 's/^/     /'
  echo "   Close it and re-run; flashing with the port held will fail."; exit 1
fi
echo "  port free"

echo "=== 2) Build Klipper for 0x8000000 (no bootloader) ==="
if [ ! -f "$CFG_KAT" ]; then
  echo "  $CFG_KAT is missing — run 'flash_mcus.sh f103' once first so it writes the base config."
  exit 1
fi
# Set the CHOICE, not the address. CONFIG_FLASH_APPLICATION_ADDRESS is a derived symbol
# (src/stm32/Kconfig: "default 0x8002000 if STM32_FLASH_START_2000"), so writing it directly achieves
# nothing -- olddefconfig recomputes it from the choice and puts 0x8002000 straight back. The first
# version of this script did exactly that, built cleanly, and produced a binary still linked for
# 0x8002000. Written to 0x8000000 after a mass-erase that is a dead toolhead: wrong vector table,
# nothing to jump to, and no bootloader left to retry with. Caught by checking the built ELF rather
# than trusting the config edit.
sed -e 's|^CONFIG_STM32_FLASH_START_2000=y|# CONFIG_STM32_FLASH_START_2000 is not set|' \
    -e 's|^# CONFIG_STM32_FLASH_START_0000 is not set|CONFIG_STM32_FLASH_START_0000=y|' \
    "$CFG_KAT" > "$CFG_NOBL"
( cd "$KLIPPER_DIR" \
  && make clean KCONFIG_CONFIG=config.stm32f103.nobl >/dev/null \
  && make olddefconfig KCONFIG_CONFIG=config.stm32f103.nobl >/dev/null ) \
  || { echo "  configure FAILED"; exit 1; }
# Check the DERIVED value, after olddefconfig has had its say.
ADDR=$(grep -E '^CONFIG_FLASH_APPLICATION_ADDRESS=' "$CFG_NOBL" | cut -d= -f2)
if [ "$ADDR" != "0x8000000" ]; then
  echo "  REFUSING: the config still resolves to application address ${ADDR:-unset}, not 0x8000000."
  echo "  Erasing now and writing that would leave the toolhead with no working firmware."
  exit 1
fi
echo "  application address resolves to 0x8000000"
( cd "$KLIPPER_DIR" && make KCONFIG_CONFIG=config.stm32f103.nobl -j4 >/dev/null ) \
  || { echo "  build FAILED"; exit 1; }
[ -f "$KLIPPER_DIR/out/klipper.bin" ] || { echo "  no out/klipper.bin after the build"; exit 1; }
# Belt and braces: ask the ELF where it will actually live. This is the check that caught the bug.
VMA=$(arm-none-eabi-objdump -h "$KLIPPER_DIR/out/klipper.elf" 2>/dev/null \
        | awk '/[[:space:]]\.text[[:space:]]/{print $4; exit}')
if [ -n "$VMA" ] && [ "0x$VMA" != "0x08000000" ]; then
  echo "  REFUSING: the built firmware is linked for 0x$VMA, not 0x08000000."
  exit 1
fi
echo "  built: $(stat -c%s "$KLIPPER_DIR/out/klipper.bin") bytes, .text at 0x${VMA:-unknown}"

cat <<'TXT'

=== 3) Put the toolhead into the ROM bootloader ===
 Katapult cannot help here — it is what we are removing — so this needs the
 ROM bootloader and therefore the BOOT button. The printer stays ON.

   1. Press and HOLD BOOT.
   2. Tap RESET (press and release) while BOOT is still held.
   3. Let go of BOOT.
   4. Press ENTER.

 No hurry — once RESET is back up the chip stays in the bootloader.
TXT
printf "   Done? Press ENTER to erase and write: "
read -r

echo "=== 4) Mass-erase (this is what removes Katapult) ==="
stm32flash -b 9600 -o /dev/ttyS0 || { echo "  erase FAILED — was the chip in the ROM bootloader?"; exit 1; }

echo "=== 5) Write Klipper at 0x8000000 and start it ==="
stm32flash -b 9600 -v -w "$KLIPPER_DIR/out/klipper.bin" -g 0x8000000 /dev/ttyS0 \
  || { echo "  write FAILED — the toolhead now has NO firmware. Repeat the BOOT/RESET sequence and re-run."; exit 1; }

echo "=== 6) Forget that this toolhead ever had Katapult ==="
# Without this, flash_mcus.sh trusts the marker, tries to request a bootloader that is no longer
# there, and never offers the install path — which is the path we are trying to test.
if [ -f "$KATAPULT_MARK" ]; then rm -f "$KATAPULT_MARK" && echo "  removed $KATAPULT_MARK"
else echo "  no marker present"; fi

cat <<'TXT'

=== Done ===
 The toolhead runs Klipper directly now, with no bootloader.

 POWER-CYCLE the printer (full off ~10 s, then on) — the F103 only boots the
 new firmware after a hardware reset, and Klipper starts cleanly with it.

 To test the install path afterwards:
     bash ~/arco-unleashed/scripts/flash_mcus.sh f103
 It will find no Katapult, offer to install it, and that run exercises the
 BOOT/RESET sequence, the mass-erase and the jump into Katapult (-g).
TXT
