#!/bin/bash
# flash-buster-mcus.sh — reflash the Arco's MCUs back to Buster (Klipper v0.11) firmware, straight from
# the .bin files next to THIS script (e.g. a USB stick). Run it on the RUNNING Bookworm/Unleashed system —
# it has all the tools (katapult flashtool, dfu-util, modern Python). Do it as the LAST step here, then
# swap the eMMC to Buster. Klipper will NOT reconnect on Unleashed afterwards — that's expected (v0.13 host
# + v0.11 MCUs). Fully reversible: re-run scripts/flash_mcus.sh to go back to v0.13.
#
# Usage:  bash <path-to-stick>/flash-buster-mcus.sh            # menu
#         bash .../flash-buster-mcus.sh f103|f407|all          # non-interactive
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
F103_BIN=$(ls "$DIR"/arco-f103-*.bin 2>/dev/null | head -1)
F407_BIN=$(ls "$DIR"/arco-f407-*.bin 2>/dev/null | head -1)
KATAPULT="$HOME/katapult/scripts/flashtool.py"
TTY="${ARCO_F103_TTY:-/dev/ttyS0}"          # toolhead serial (F103)
BAUD="${ARCO_F103_BAUD:-250000}"            # must match the Buster printer.cfg [mcu ...] baud (default 250000)
F407_ADDR=0x8008000                         # F407 app offset (32 KiB) — matches Phrozen's bootloader layout
say(){ echo "  $*"; }

echo "== Buster (v0.11) MCU reflash — from $DIR =="
say "F103 firmware: ${F103_BIN:-NOT FOUND}"
say "F407 firmware: ${F407_BIN:-NOT FOUND}"
[ -n "$F103_BIN$F407_BIN" ] || { echo "No arco-f103-*.bin / arco-f407-*.bin next to this script."; exit 1; }

SEL="${1:-}"
if [ -z "$SEL" ]; then
  echo; echo "  Flash which?  [1] F103 (toolhead)  [2] F407 (mainboard)  [a] both  [c] cancel"
  read -rp "  > " k
  case "$k" in 1) SEL=f103;; 2) SEL=f407;; a|A) SEL=all;; *) echo "cancelled"; exit 0;; esac
fi
DO103=0; DO407=0
case "$SEL" in f103) DO103=1;; f407) DO407=1;; all) DO103=1; DO407=1;; *) echo "unknown: $SEL"; exit 2;; esac

# Every failure below used to be a printed line and nothing else, so the script exited 0 whatever
# happened -- the last statement is a say(). Read by a human that is fine; called from anything it is
# dangerous. The setup menu runs this and then arms the eMMC restore, and a silent success on a failed
# flash would arm it with the MCUs still on v0.13: Buster host, v0.13 chips, and no tooling left to
# reach them without opening the printer. So failures are collected and reported in the exit status.
FAILED=""
note_fail(){ FAILED="$FAILED $1"; }

echo; say "Stopping Klipper + display owners (frees the serial ports)..."
sudo systemctl stop klipper 2>/dev/null || true
sudo systemctl stop KlipperScreen 2>/dev/null || true
sudo pkill -x voronFDM 2>/dev/null || true
# systemctl returns as soon as the unit is 'stopped', but the kernel releases the MCU serial
# fds a beat later. The F407 1200-baud DFU touch and Katapult both need the port truly free,
# so settle before touching them. (A missing settle — or a klipper that never actually stopped —
# is the most likely reason an F407 flash silently doesn't take.)
sleep 2
if systemctl is-active --quiet klipper 2>/dev/null; then
  say "WARNING: Klipper is STILL running — 'sudo systemctl stop klipper' may have failed (sudo?)."
  say "         The flash will likely fail. Stop it manually, then re-run this script."
fi
command -v dfu-util   >/dev/null 2>&1 || sudo apt-get install -y dfu-util
python3 -c 'import serial' 2>/dev/null || sudo apt-get install -y python3-serial

if [ "$DO103" = 1 ]; then
  echo; echo "== F103 (toolhead) via Katapult =="
  if [ -z "$F103_BIN" ]; then say "no F103 .bin — skipped"; note_fail F103;
  elif [ ! -f "$KATAPULT" ]; then
    say "Katapult flashtool not found at $KATAPULT."
    say "Get it:  git clone https://github.com/Arksine/katapult ~/katapult   (or copy it from Unleashed)"
    note_fail F103
  else
    say "requesting bootloader (F103 -> Katapult, no button)..."
    python3 "$KATAPULT" -r -d "$TTY" -b "$BAUD" || say "(request nonzero — may already be in Katapult)"
    sleep 2
    say "flashing $(basename "$F103_BIN") ..."
    if python3 "$KATAPULT" -d "$TTY" -b "$BAUD" -f "$F103_BIN"; then say "F103 OK"; else
      say "didn't take — tap RESET on the toolhead ONCE (no BOOT0), then press ENTER..."; read -r
      python3 "$KATAPULT" -d "$TTY" -b "$BAUD" -f "$F103_BIN" && say "F103 OK" || { say "F103 FAILED"; note_fail F103; }
    fi
  fi
fi

# A *successful* DFU download still exits NON-ZERO on this board: dfu-util's auto-leave ('detach') fails
# with "can't detach", which is harmless — the F407 simply stays in DFU until the power-cycle. Judging by
# $? therefore reports FAILED on a flash that worked, and sends the user back through BOOT0 for nothing.
# Judge by the download message instead, exactly as scripts/flash_mcus.sh does.
dfu_ok() {
  local out; out=$("$@" 2>&1); echo "$out"
  echo "$out" | grep -qiE "File downloaded successfully|Download[[:space:]]+done"
}

if [ "$DO407" = 1 ]; then
  echo; echo "== F407 (mainboard) via USB-DFU =="
  FLASH_USB="$HOME/klipper/scripts/flash_usb.py"
  F407_SERIAL=$(ls /dev/serial/by-id/*[Kk]lipper*stm32f407* /dev/serial/by-id/*stm32f407* /dev/serial/by-id/*[Kk]lipper* 2>/dev/null | head -1)
  if [ -z "$F407_BIN" ]; then say "no F407 .bin — skipped"; note_fail F407;
  elif lsusb 2>/dev/null | grep -qi 0483:df11; then
    say "F407 already in DFU -> flashing $(basename "$F407_BIN") -> $F407_ADDR ..."
    if dfu_ok sudo dfu-util -a 0 -s "${F407_ADDR}:leave" -D "$F407_BIN"; then
      say "F407 OK  ('can't detach' above is expected — it stays in DFU until the power-cycle)"
    else say "F407 FAILED — no 'File downloaded successfully' above (nothing was written)."; note_fail F407; fi
  elif [ -f "$FLASH_USB" ] && [ -n "$F407_SERIAL" ]; then
    # No button: Klipper's flash_usb.py reboots the running F407 into DFU (1200-baud touch), then dfu-util
    # writes at the app address. Same path 'make flash' uses.
    say "reboot-to-DFU (no button) + flash via flash_usb.py: $F407_SERIAL"
    if ( cd "$HOME/klipper" && dfu_ok python3 "$FLASH_USB" -t stm32f407xx -d "$F407_SERIAL" -s "$F407_ADDR" "$F407_BIN" ); then
      say "F407 OK  ('can't detach' above is expected — it stays in DFU until the power-cycle)"
    else say "F407 FAILED — no 'File downloaded successfully' above. Try again, or use BOOT0+RESET + dfu-util."; note_fail F407; fi
  else
    say "flash_usb.py or the F407 serial not found -> manual DFU: hold BOOT0 + tap RESET, then press ENTER..."
    read -r
    if lsusb 2>/dev/null | grep -qi 0483:df11; then
      if dfu_ok sudo dfu-util -a 0 -s "${F407_ADDR}:leave" -D "$F407_BIN"; then
        say "F407 OK  ('can't detach' above is expected — it stays in DFU until the power-cycle)"
      else say "F407 FAILED — no 'File downloaded successfully' above (nothing was written)."; note_fail F407; fi
    else say "no DFU device (0483:df11) — F407 NOT flashed."; note_fail F407; fi
  fi
fi

echo
if [ -n "$FAILED" ]; then
  echo "== NOT DONE =="
  say "FAILED:$FAILED — read the messages above; nothing else should be attempted yet."
  say "Do NOT put the Buster image on the eMMC now. A Buster system (Klipper v0.11)"
  say "cannot talk to an MCU still running v0.13, and once the eMMC is swapped the"
  say "tools that reach these chips are gone — only opening the printer would help."
  say "This printer is unchanged apart from the chips named above. Fix the cause and"
  say "run this again; it is safe to repeat."
  exit 1
fi
echo "== DONE =="
say "POWER-CYCLE the printer, then swap the eMMC to Buster and boot it."
say "(Klipper won't reconnect on Unleashed now — expected. To undo: scripts/flash_mcus.sh -> v0.13.)"
exit 0
