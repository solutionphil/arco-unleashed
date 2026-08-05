#!/bin/bash
# apply-adxl-hwspi.sh — bring the [adxl345] section in printer.cfg to the Arco Unleashed tuning:
#   1) HARDWARE SPI1 instead of Phrozen's bit-banged software SPI. The accelerometer is wired to
#      PA4/PA5/PA6/PA7 = the STM32F103 SPI1 pins, so hardware SPI works and offloads the slow 72MHz
#      F103 (no bit-banging).
#   2) rate: 800  instead of the ADXL default 3200 Hz. 800 Hz covers the shaper range (to ~400 Hz)
#      with 4x LESS data over the SPI/UART -> much lighter host/MCU load during the resonance sweep.
# Both together fight "MCU shutdown: Timer too close" at the toolhead accelerometer during the shaper.
#
# SURGICAL + idempotent: only rewrites the [adxl345] section (keeps cs_pin, axes_map, ...), drops the
# spi_software_* lines, ensures `spi_bus: spi1` + `rate: 800`. No-op once both are set. A Phrozen
# firmware update restores the stock software-SPI/3200 config -> RE-RUN this (apply-phrozen-patches.sh
# delegates to it, like the mcu.py timing patch).
#
# Usage:  bash apply-adxl-hwspi.sh [path-to-printer.cfg]
set -e
CFG="${1:-$HOME/printer_data/config/printer.cfg}"
[ -f "$CFG" ] || { echo "ERROR: $CFG not found (pass the printer.cfg path as the first arg)."; exit 1; }

python3 - "$CFG" <<'PY'
import sys, shutil, time
p = sys.argv[1]
lines = open(p).read().split('\n')

# locate the [adxl345] section bounds
start = None; end = len(lines)
for i, ln in enumerate(lines):
    if ln.strip() == '[adxl345]':
        start = i
    elif start is not None and i > start and ln.strip().startswith('['):
        end = i; break
if start is None:
    print("apply-adxl-hwspi: no [adxl345] section found — nothing to do."); sys.exit(0)

old = lines[start:end]
txt = '\n'.join(old)
if 'spi_software_' not in txt and 'spi_bus' in txt and 'rate' in txt:
    print("apply-adxl-hwspi: [adxl345] already hardware-SPI + rate set — no change."); sys.exit(0)

shutil.copy(p, p + '.pre-hwspi.' + time.strftime('%Y%m%d%H%M%S') + '.bak')
new = ['[adxl345]']
for ln in old[1:]:                       # keep cs_pin / axes_map / blanks; drop spi_software/spi_bus/rate
    s = ln.strip()
    if 'spi_software_' in ln: continue
    if s.startswith('spi_bus') or s.startswith('rate'): continue
    new.append(ln)
new.insert(1, 'rate: 800')               # canonical, after the header
new.insert(1, 'spi_bus: spi1')
res = lines[:start] + new + lines[end:]
open(p, 'w').write('\n'.join(res))
print("apply-adxl-hwspi: [adxl345] -> hardware spi_bus: spi1 + rate: 800.")
PY
