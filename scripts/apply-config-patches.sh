#!/bin/bash
# apply-config-patches.sh — idempotently (re)apply the Arco Unleashed edits to Phrozen's
# printer_gcode_macro.cfg. These are CONFIG edits (not the phrozen_dev module), so a Phrozen
# firmware update / OTA that ships its own printer_gcode_macro.cfg reverts them — exactly like a
# Klipper update reverts the mcu.py timing. This script is check-first (no backup spam), so it
# can run as an ExecStartPre self-heal before EVERY klipper start (klippy then reads the freshly
# re-patched config), and it is also called by apply-phrozen-patches.sh at install / manual re-patch.
#
#   Patch A: SHAPER_END / BED_PROBE_END auto-calibration handshake macros (voronFDM waits for the
#            M118 echo to advance shaper -> mesh -> SAVE_CONFIG -> home). Phrozen ships neither.
#   Patch B: g_accel_to_decel v0.13 compat — Klipper v0.13 removed toolhead.max_accel_to_decel, so
#            PG104's colour-change "capture globals" set an empty VALUE= -> "Unable to parse ''" on
#            every T0..T15 / colour change. Add a |default((max_accel/2)|int) fallback.
#
# Idempotent: each patch is grep-gated; a no-op in ms when already current.
#
# Usage:  bash apply-config-patches.sh [path-to-printer_gcode_macro.cfg]
set -e
GM="${1:-$HOME/printer_data/config/printer_gcode_macro.cfg}"
[ -f "$GM" ] || { echo "  config-patches: $GM not present yet (no phrozen install) — skipped"; exit 0; }
changed=0

# --- Patch A: auto-calibration handshake macros (append once) ---
if ! grep -q "gcode_macro SHAPER_END" "$GM"; then
  cat >> "$GM" <<'CFG'

[gcode_macro SHAPER_END]
# voronFDM calls this after SHAPER_CALIBRATE to advance to the bed mesh. Phrozen ships no such macro
# -> a clean M118 echo (deterministic handshake, no "Unknown command" log spam).
gcode:
    M118 SHAPER_END

[gcode_macro BED_PROBE_END]
# voronFDM calls this after the bed mesh and waits to see it echoed before SAVE_CONFIG. Undefined/no-op
# -> the display hangs at "Mesh 100%". The M118 echo lets it finish + return home.
gcode:
    M118 BED_PROBE_END
CFG
  echo "  config-patches: added SHAPER_END + BED_PROBE_END handshake macros."; changed=1
fi

# --- Patch B: v0.13 accel_to_decel compat (PG104 colour-change global capture) ---
if grep -q 'g_accel_to_decel VALUE={printer.toolhead.max_accel_to_decel}' "$GM"; then
  sed -i 's@g_accel_to_decel VALUE={printer.toolhead.max_accel_to_decel}@g_accel_to_decel VALUE={printer.toolhead.max_accel_to_decel|default((printer.toolhead.max_accel / 2)|int)}@' "$GM"
  echo "  config-patches: fixed g_accel_to_decel for Klipper v0.13 (max_accel_to_decel removed)."; changed=1
fi

# --- Patch C: guard the boot-time filament-sensor disable so it works without the AMS ---
# The call lives in [delayed_gcode KINEMATIC_POSITION] (initial_duration:0.2) -- NOT in [gcode_macro M84],
# despite the G_printer_position_z_init_M84 echo next to it; that block re-asserts the kinematic position
# shortly after klippy becomes ready. It runs SET_FILAMENT_SENSOR SENSOR=fila ENABLE=0 unconditionally,
# but the 'fila' sensor only exists when the AMS (Chroma Kit) is attached — it is declared NOWHERE in the
# stock config. On a printer without the AMS (the default until one is paired) the bare call therefore
# fails once per klippy start / RESTART, aborting the rest of that block. Wrapping it in `is defined`
# makes it correct with and without the AMS. This used to live only in the snapshotted config baked into
# the image, so a Phrozen firmware update that ships its own printer_gcode_macro.cfg silently dropped it;
# as a self-heal patch it survives that, like A and B.
# Grep-gated on the BARE line only (the guarded form starts with '{% if', so it never re-matches). The
# trailing [[:space:]]* in the sed captures the CRLF Phrozen ships and puts it back, so the line ending
# is preserved.
if grep -qE '^[[:space:]]*SET_FILAMENT_SENSOR SENSOR=fila ENABLE=0[[:space:]]*$' "$GM"; then
  sed -i -E "s@^([[:space:]]*)SET_FILAMENT_SENSOR SENSOR=fila ENABLE=0([[:space:]]*)\$@\1{% if printer['filament_switch_sensor fila'] is defined %}SET_FILAMENT_SENSOR SENSOR=fila ENABLE=0{% endif %}\2@" "$GM"
  echo "  config-patches: guarded the boot-time SET_FILAMENT_SENSOR (works without the AMS)."; changed=1
fi

# --- Patch D: Beacon mode survival (only on machines that enabled it) ---
# A Phrozen update replaces printer.cfg, not just printer_gcode_macro.cfg. Every other edit in this
# kit degrades gracefully when that happens — this one does not: the printer would come back
# believing it has a piezo probe on !PB9 while a Beacon sits on the toolhead, and the next G28 would
# drive Z down waiting for a trigger that cannot come. So it is re-applied here, before klippy
# parses anything. Gated on the marker file that beacon_toggle.sh writes, so it is a single
# file test on every machine that never enabled Beacon (i.e. all of them by default).
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${ARCO_CONFIG:-$HOME/printer_data/config}/.beacon-mode" ] && [ -f "$SELFDIR/beacon_toggle.sh" ]; then
  out=$(bash "$SELFDIR/beacon_toggle.sh" reapply 2>/dev/null) || true
  [ -n "$out" ] && { echo "$out"; changed=1; }
fi

# --- Patch E: sensorless XY homing survival (only on machines that enabled it) ---
# Same shape as D and the same reason: a Phrozen update ships its own printer.cfg, which restores
# endstop_pin to the microswitches and drops the sensorless include. That failure is quiet and
# asymmetric -- the machine still homes, on hardware the owner may have switched to sensorless
# BECAUSE the switch or its toolhead cable is broken. X's switch hangs off the toolhead MCU while
# its DIAG line goes to the main one, which is the whole point of offering this. So a config
# replacement would hand back exactly the endstop that does not work, and the first G28 would run
# into the rail.
# Marker-gated, so on every printer that never enabled it this is one file test.
if [ -f "${ARCO_CONFIG:-$HOME/printer_data/config}/.sensorless-mode" ] && [ -f "$SELFDIR/sensorless_toggle.sh" ]; then
  out=$(bash "$SELFDIR/sensorless_toggle.sh" reapply 2>/dev/null) || true
  [ -n "$out" ] && { echo "$out"; changed=1; }
fi

# --- Patch G: PhrozenGo stays disabled (only on machines that turned it off) ---
# Same shape as D and E, and the same reason -- but this one had already cost someone their Obico.
# Disabling PhrozenGo works by commenting lines OUT OF Phrozen's own start scripts, one of which
# deletes moonraker-obico on every boot. So the choice lives inside phrozen_dev, and everything that
# replaces that module undoes it silently: a Phrozen firmware update, or apply-phrozen-restore.sh
# putting the safety copy back. The owner's printer then phones home again AND removes Obico on the
# next boot, with nothing said. Beacon and sensorless were already protected this way; this was not.
# Marker-gated, so on every printer that left PhrozenGo alone this is one file test.
if [ -f "${ARCO_CONFIG:-$HOME/printer_data/config}/.phrozengo-off" ] && [ -f "$SELFDIR/phrozengo.sh" ]; then
  out=$(bash "$SELFDIR/phrozengo.sh" reapply 2>/dev/null) || true
  [ -n "$out" ] && { echo "$out"; changed=1; }
fi

# --- Patch F: don't load a bed mesh profile that does not exist yet ---
# PRINT_END, START_PRINT and G31 all end with a bare `BED_MESH_PROFILE LOAD=phrozen`. On a printer
# that has never saved a mesh under that name there is no such profile, so the call raises
# "bed_mesh: Unknown profile [phrozen]" and the display drops to its generic "an error occurred".
#
# That is not an edge case, it is what every freshly flashed printer does: the image deliberately
# ships no calibration, because another machine's numbers are worthless. Reported from a real print
# on 2026-07-30, where the failure landed at the END of an otherwise perfect job — the owner had
# printed with the adaptive-mesh Orca profile, which probes at the start and therefore never needs
# 'phrozen', but PRINT_END loads it regardless.
#
# Guarded, not removed: once the owner has calibrated, loading the saved mesh is exactly right.
# `printer.bed_mesh.profiles` is a dict of the saved names — verified against a running printer
# rather than assumed. Grep-gated on the BARE line, so the guarded form never re-matches, and the
# trailing whitespace capture preserves Phrozen's CRLF line endings.
if grep -qE '^[[:space:]]*BED_MESH_PROFILE LOAD=phrozen[[:space:]]*$' "$GM"; then
  n=$(grep -cE '^[[:space:]]*BED_MESH_PROFILE LOAD=phrozen[[:space:]]*$' "$GM")
  sed -i -E "s@^([[:space:]]*)BED_MESH_PROFILE LOAD=phrozen([[:space:]]*)\$@\1{% if 'phrozen' in printer.bed_mesh.profiles %}BED_MESH_PROFILE LOAD=phrozen{% endif %}\2@" "$GM"
  echo "  config-patches: guarded $n x BED_MESH_PROFILE LOAD=phrozen (no error before the first calibration)."; changed=1
fi

[ "$changed" = 0 ] && echo "  config-patches: already current." || true
