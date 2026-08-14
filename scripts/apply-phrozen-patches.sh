#!/bin/bash
# apply-phrozen-patches.sh — apply the Arco Unleashed in-place patches: the 3 phrozen_dev v0.13 API
# edits, plus the auto-calibration handshake macros (SHAPER_END / BED_PROBE_END).
#
# This script contains ONLY the transformation rules (search/replace) — no Phrozen code.
# It edits YOUR own phrozen_dev (installed from USB via fetch-phrozen-fw.sh, or already on
# the printer). Idempotent: running it again is a no-op.
#
# The 3 fixes (Klipper v0.11 API -> v0.13):
#   1) base.py  MCU_adc.setup_minmax(...)            -> setup_adc_sample(report_time, sample_time=, sample_count=)
#                + setup_adc_callback loses its report_time argument
#   2) cmds.py  register_command("homing_override_end") -> "HOMING_OVERRIDE_END" (must be UPPERCASE)
#   3) base.py  ADC callback signature: (self, read_time, read_value) -> (self, samples) + samples[-1]
#   4) printer_gcode_macro.cfg  add SHAPER_END / BED_PROBE_END handshake macros (auto-cal completion)
#   5) printer_gcode_macro.cfg  fix the g_accel_to_decel capture for v0.13 (toolhead.max_accel_to_decel
#      was removed -> empty VALUE= -> "Unable to parse ''" on every T0 / colour change)
#
# Usage:  bash apply-phrozen-patches.sh [path-to-phrozen_dev]
set -e
# A guard that dies without saying why is worse than no guard. Under `set -e` any failing command below
# ends this script in silence -- and that is precisely what a tester saw on 2026-08-14: the script
# produced NO output at all where a healthy printer prints four lines, so nobody could tell whether the
# patches were applied, skipped, or half-done. (They were half-done.) Name the line and the exit code.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "apply-phrozen-patches: ABORTED at line $_arco_ln (exit $rc) — the patches below that point did NOT run." >&2' EXIT
trap '_arco_ln=$LINENO' ERR
_arco_ln="?"

PD="${1:-$HOME/klipper/klippy/extras/phrozen_dev}"
[ -f "$PD/base.py" ] && [ -f "$PD/cmds.py" ] || {
  echo "ERROR: phrozen_dev base.py/cmds.py not found in $PD"
  echo "Run  fetch-phrozen-fw.sh  first (or point this script at your module)."; exit 1; }

# Guard-safe: back up ONLY before an actual change — so running this as a per-boot ExecStartPre guard
# doesn't spam a timestamped .bak on every start. When all 3 python fixes are already present (the normal
# case) this block is skipped and the seds below are harmless no-ops.
TS=""
if ! grep -q "setup_adc_sample(TOOLHEAD_ADC_REPORT_TIME" "$PD/base.py" 2>/dev/null \
   || ! grep -q "def Base_ToolheadAdcCallback(self, samples):" "$PD/base.py" 2>/dev/null \
   || ! grep -q 'register_command("HOMING_OVERRIDE_END"' "$PD/cmds.py" 2>/dev/null; then
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$PD/base.py" "$PD/base.py.pre-patch-$TS.bak"
  cp "$PD/cmds.py" "$PD/cmds.py.pre-patch-$TS.bak"
fi

# --- Patch 1: MCU_adc API ---
sed -i 's/\.setup_minmax(TOOLHEAD_ADC_SAMPLE_TIME, TOOLHEAD_ADC_SAMPLE_COUNT)/.setup_adc_sample(TOOLHEAD_ADC_REPORT_TIME, sample_time=TOOLHEAD_ADC_SAMPLE_TIME, sample_count=TOOLHEAD_ADC_SAMPLE_COUNT)/' "$PD/base.py"
sed -i 's/\.setup_adc_callback(TOOLHEAD_ADC_REPORT_TIME, self\.Base_ToolheadAdcCallback)/.setup_adc_callback(self.Base_ToolheadAdcCallback)/' "$PD/base.py"

# --- Patch 3: ADC callback signature (insert the unpacking line right after the def) ---
sed -i 's/^\(    def Base_ToolheadAdcCallback(self, \)read_time, read_value):/\1samples):\n        read_time, read_value = samples[-1]/' "$PD/base.py"

# --- Patch 2: extended command name must be UPPERCASE ---
sed -i 's/register_command("homing_override_end"/register_command("HOMING_OVERRIDE_END"/' "$PD/cmds.py"

# --- Patches 4+5: printer_gcode_macro.cfg config edits (delegated to apply-config-patches.sh) ---
# 4) SHAPER_END / BED_PROBE_END auto-calibration handshake macros; 5) v0.13 g_accel_to_decel fix.
# These are CONFIG edits that a Phrozen update reverts, so they live in their own idempotent script that
# the ExecStartPre self-heal guard (17-arco-config-patches.conf) also runs before every klipper start —
# single source, auto-heals after an OTA (mirrors the mcu.py timing guard).
GM="$HOME/printer_data/config/printer_gcode_macro.cfg"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPTDIR/apply-config-patches.sh" ] && bash "$SCRIPTDIR/apply-config-patches.sh" "$GM" \
  || echo "NOTE: apply-config-patches.sh not found — SHAPER_END/BED_PROBE_END + accel_to_decel skipped."

# --- verify (passes whether we just patched or it was already patched) ---
ok=1
grep -q "setup_adc_sample(TOOLHEAD_ADC_REPORT_TIME" "$PD/base.py" || { echo "WARN: patch 1 (setup_adc_sample) not present"; ok=0; }
grep -q "def Base_ToolheadAdcCallback(self, samples):" "$PD/base.py" || { echo "WARN: patch 3 (callback signature) not present"; ok=0; }
grep -q 'register_command("HOMING_OVERRIDE_END"' "$PD/cmds.py" || { echo "WARN: patch 2 (HOMING_OVERRIDE_END) not present"; ok=0; }
[ ! -f "$GM" ] || grep -q "gcode_macro SHAPER_END" "$GM" || { echo "WARN: patch 4 (SHAPER_END handshake) not present"; ok=0; }
[ ! -f "$GM" ] || ! grep -q 'g_accel_to_decel VALUE={printer.toolhead.max_accel_to_decel}' "$GM" || { echo "WARN: patch 5 (accel_to_decel v0.13) not applied"; ok=0; }
rm -rf "$PD/__pycache__"

# `sed -i` rewrites base.py and cmds.py in place, and the rootfs is mounted commit=120 -- so for the
# next two minutes the only copy of an 800 KB source file Klipper cannot start without lives in page
# cache. Lose power in that window and it comes back short, NUL-padded, and fatal
# ("source code string cannot contain null bytes"). Only on a real change: syncing the whole filesystem
# on every klipper start would be a per-boot cost for nothing.
[ -z "$TS" ] || sync

if [ "$ok" = 1 ]; then
  [ -n "$TS" ] && echo "Applied Arco Unleashed v0.13 patches (backups: *.pre-patch-$TS.bak)." \
                || echo "All Arco Unleashed v0.13 patches already present (no change)."
else
  echo "Some patches missing — Phrozen may have changed the code; check the warnings above."
fi
# MCU host-timing is NO LONGER patched into klippy/mcu.py here. That edit hit a file Klipper tracks,
# which left the repo permanently dirty — and Moonraker refuses to update a dirty repo, so the printer
# could never take a Klipper update. The same three values now come from klippy/extras/arco_mcu_timing.py
# (installed by apply-arco-extras.sh, enabled by [arco_mcu_timing] in the config), which is untracked and
# leaves Klipper's tree pristine. Nothing to re-apply here after an update.
# ADXL accelerometer: re-convert software-SPI -> hardware SPI1 (a Phrozen firmware update restores the
# stock software-SPI printer.cfg). Hardware SPI offloads the F103 -> fewer 'Timer too close' at the shaper.
[ -f "$SCRIPTDIR/apply-adxl-hwspi.sh" ] && bash "$SCRIPTDIR/apply-adxl-hwspi.sh" || echo "NOTE: apply-adxl-hwspi.sh not found — ADXL SPI left as-is."
# TFT reprint bridge: ensure voronFDM's stdout redirect + the bridge are in place (a Phrozen update
# restores KlipperScreen-start.sh's /dev/null redirect, so this self-heals like the others).
[ -f "$SCRIPTDIR/apply-reprint-redirect.sh" ] && bash "$SCRIPTDIR/apply-reprint-redirect.sh" || echo "NOTE: apply-reprint-redirect.sh not found — reprint bridge redirect left as-is."

echo "Then: sudo systemctl restart klipper"
