#!/bin/bash
# install-katapult.sh — flash the Katapult bootloader onto the MKS_THR (STM32F103) ONCE.
# Permanently fixes the factory-firmware revert + allows future flashing WITHOUT BOOT0.
# Physically required: the BOOT0 button on the toolhead. On the printer:  bash scripts/install-katapult.sh
set -e
KATAPULT_DIR=/home/mks/katapult

echo "=== Prerequisites ==="
sudo apt install -y stm32flash python3-serial git build-essential >/dev/null
echo "  stm32flash / python3-serial / git / build-essential ok"

echo "=== 1) Get Katapult ==="
if [ ! -d "$KATAPULT_DIR" ]; then
  git clone https://github.com/Arksine/katapult "$KATAPULT_DIR"
else
  echo "  $KATAPULT_DIR already exists"
fi
cd "$KATAPULT_DIR"

echo "=== 2) Configure ==="
# The image ships a complete, correct .config for THIS toolhead, built from this same Katapult
# version. Opening menuconfig on top of it asked the owner to confirm six values that were already
# right — six chances to mistype, in a step whose mistakes only surface two steps later as
# "Error sending CONNECT", by which point nobody suspects a menu they clicked through.
#
# So: verify what is there, and only fall back to the menu if it is missing or wrong.
# The values are checked by SYMBOL, not by what the menu labels them. Note that Katapult's
# "8KiB offset" is CONFIG_STM32_APP_START_2000 / CONFIG_LAUNCH_APP_ADDRESS=0x8002000 --
# FLASH_APPLICATION_ADDRESS is 0x8000000 here, because that is where KATAPULT ITSELF lives. Reading
# that as the app offset is the obvious mistake, and it would fail a correct config.
WANT="CONFIG_MACH_STM32F103=y
CONFIG_STM32_CLOCK_REF_8M=y
CONFIG_STM32_APP_START_2000=y
CONFIG_STM32_SERIAL_USART1=y
CONFIG_SERIAL_BAUD=250000
CONFIG_LAUNCH_APP_ADDRESS=0x8002000"

# A freshly cloned katapult has no .config, and then the menu would open after all — which is exactly
# the case this is meant to remove. The kit carries the known-good one, so lay it down first.
SEED="$(cd "$(dirname "$0")/.." && pwd)/config-templates/katapult-f103.config"
if [ ! -f .config ] && [ -f "$SEED" ]; then
  cp "$SEED" .config
  echo "  no .config (fresh clone) — installed the kit's known-good one"
fi

need_menu=0
if [ ! -f .config ]; then
  echo "  no .config here and none in the kit — the menu is needed"
  need_menu=1
else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if grep -qxF "$line" .config; then
      printf '  ok       %s\n' "$line"
    else
      printf '  WRONG    %s   (found: %s)\n' "$line" "$(grep -E "^${line%%=*}=" .config || echo 'not set')"
      need_menu=1
    fi
  done <<< "$WANT"
fi

if [ "$need_menu" = 0 ]; then
  echo "  the shipped configuration is correct for this toolhead — skipping menuconfig."
  echo "  (to inspect or change it anyway: cd $KATAPULT_DIR && make menuconfig)"
  make clean
  make olddefconfig
else
  cat <<'TXT'
----------------------------------------------------------------------
 The configuration is missing or does not match this toolhead.
 In the menuconfig that follows, set EXACTLY:
   Micro-controller Architecture .... STMicroelectronics STM32
   Processor model .................. STM32F103
   Clock Reference .................. 8 MHz crystal
   Application start offset ......... 8KiB
   Communication interface .......... Serial (on USART1 PA10/PA9)
   Baud rate ........................ 250000
 Then save & exit (Q, then Y).
----------------------------------------------------------------------
TXT
  read -rp "   Press ENTER to open menuconfig..."
  make clean
  make menuconfig
fi
make
[ -f out/katapult.bin ] || { echo "ERROR: out/katapult.bin was not built."; exit 1; }

echo "=== 3) Stop Klipper + put toolhead into the ROM bootloader ==="
# Stop everything that can hold an MCU serial port, not just Klipper. flash_mcus.sh was fixed for
# exactly this and this script never got the same treatment: systemctl returns as soon as the unit
# reports stopped, but the kernel releases the fds a beat later, and a port that is still held is the
# most likely reason a flash silently does not take. Say so here rather than failing cryptically two
# steps later with "Error sending CONNECT", which reads as a hardware or timing problem and sends
# people back to the buttons.
echo "  stopping Klipper + display owners (frees the MCU serial ports)..."
# Stopping klippy is what frees /dev/ttyS0 — it is the process holding it for [mcu MKS_THR]. The
# fuser check below is what proves the port is actually free; that is the guard that matters.
# (An attempt to mask the unit as well was removed: systemd does not restart an explicitly stopped
# service, and klipper.service is a regular file in /etc/systemd/system, where mask wants to place
# its symlink, so it refuses outright.)
sudo systemctl stop klipper 2>/dev/null || true
sudo systemctl stop KlipperScreen 2>/dev/null || true
sudo pkill -x voronFDM 2>/dev/null || true
sleep 2
if systemctl is-active --quiet klipper 2>/dev/null; then
  echo "!! WARNING: Klipper is STILL running — 'sudo systemctl stop klipper' may have failed (sudo?)."
  echo "   The flash will likely fail. Stop it by hand, then re-run this script."
fi
if command -v fuser >/dev/null 2>&1 && fuser /dev/ttyS0 >/dev/null 2>&1; then
  echo "!! WARNING: something still holds /dev/ttyS0:"
  fuser -v /dev/ttyS0 2>&1 | sed 's/^/     /'
  echo "   Flashing with the port held will fail. Close it, then re-run."
fi
cat <<'TXT'
----------------------------------------------------------------------
 Put the MKS_THR into the ROM bootloader. The printer stays ON for this.

   1. Press and HOLD the BOOT button.
   2. Tap RESET  (press and release it) while BOOT is still held.
   3. Let go of BOOT.
   4. Press ENTER here.

 No hurry — once RESET is back up the chip stays in the bootloader.
----------------------------------------------------------------------
TXT
# No "immediately": the BOOT pins are latched on the fourth rising edge of SYSCLK after reset release
# (ST), so the boot mode is decided half a microsecond after RESET comes back up and the chip then
# stays in the ROM bootloader until something resets it again. Confirmed in practice on 2026-07-29 —
# the write that follows runs ~40 s at 9600 baud, which a three-second window could never have allowed.
read -rp "   Done? Press ENTER to erase and flash: "

echo "=== 4) MASS-ERASE @9600 (essential!) ==="
# Without mass-erase, Katapult jumps into MKS bootloader leftovers @0x8002000
# -> flashtool later reports 'Error sending CONNECT'. 9600 because of cable signal quality.
stm32flash -b 9600 -o /dev/ttyS0

echo "=== 5) Flash Katapult, then jump straight into it ==="
# -g 0x8000000 executes at Katapult's own start address the moment the write verifies, so the chip is
# sitting in Katapult when this returns. Without it the F103 stays in the ROM bootloader, the firmware
# flash that follows cannot connect, and the owner meets a "flash didn't take" message for a step that
# was never going to work -- which is exactly what happened to the first tester through this path.
#
# The previous version avoided -g deliberately ("without -g") but never recorded why, so this keeps the
# old route as the fallback rather than assuming the note was groundless: if the jump does not take, we
# ask for the one RESET tap, as before. Either way the chip ends up in Katapult before we return.
stm32flash -b 9600 -v -w out/katapult.bin -g 0x8000000 /dev/ttyS0
sleep 2

echo "=== 5b) Confirm Katapult is actually listening ==="
FT="$KATAPULT_DIR/scripts/flashtool.py"
if python3 "$FT" -s -d /dev/ttyS0 -b 250000 >/dev/null 2>&1; then
  echo "  Katapult answered — no RESET needed, the firmware flash can go straight ahead."
else
  echo "  Katapult did not answer after the jump (the -g route did not take on this board)."
  echo "  Tap RESET ONCE on the toolhead — NO BOOT this time — then press ENTER."
  read -r
  if python3 "$FT" -s -d /dev/ttyS0 -b 250000 >/dev/null 2>&1; then
    echo "  Katapult answered."
  else
    echo "  Still no answer. Katapult is written, but something else holds the port or the reset"
    echo "  did not take. Check with:  fuser -v /dev/ttyS0"
  fi
fi

# record that THIS toolhead's F103 now carries the Katapult bootloader (consumed by flash_mcus.sh).
# Written as the invoking user (not root) so flash_mcus can read/refresh it. Stripped at imaging time.
MARK="$HOME/.config/arco-unleashed/katapult-f103.done"
mkdir -p "$(dirname "$MARK")" && date > "$MARK" 2>/dev/null || true

echo ""
echo "=== Katapult installed ==="
echo " Future flashes need no BOOT button at all — flashtool.py -r asks the running"
echo " firmware to hand back to Katapult over the same serial line."
if [ "${ARCO_KATAPULT_INLINE:-0}" = 1 ]; then
  # Called from flash_mcus.sh, which flashes the firmware next. Do NOT start Klipper here: it would
  # open /dev/ttyS0 and reset the F103 straight back out of the Katapult we just jumped into, and the
  # caller would then have to stop it again — which is precisely the compensation flash_mcus.sh used
  # to carry. Leave the port free and the chip where it is.
  echo " Leaving Klipper stopped and the toolhead in Katapult — the firmware flash follows."
else
  echo " Now flash the Klipper firmware:  bash flash_mcus.sh f103"
  sudo systemctl start klipper
fi
