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

# --- Patch J: the ten accel restores must not restore a zero -------------------------------------
# Ten macros -- PG102 and PG111..PG119, the AMS spit and purge moves -- do the same three things:
# crank the limit to ACCEL=10000, do the work, then put it back from GLOBAL_PARAM.g_accel. That
# variable is DECLARED 0 (printer_gcode_macro.cfg line 12) and filled only by PG104.
#
# Klipper reads the parameter as get_float('ACCEL', None, above=0.), so a zero is not a quiet zero:
# it is a G-code error, the macro aborts on that line, and in a print the print goes with it -- after
# the toolhead has already been moved to the purge area and with the limit still at 10000.
#
# HOW OFTEN. Measured from six klippy logs, counting RUNTIME output (the macros announce themselves
# via action_respond_info, so an executed PG104 is a line with no leading tab -- the config dump is
# indented, and conflating the two is how this looked both worse and better than it is): the real
# order in every print is PG103 -> PG104 -> PG11x, so a normal multi-colour print fills the variable
# first and never hits it. `must be above 0` appears 0 times in any log. What is exposed is a purge
# with no PG104 before it in that session -- a spit started from the display or by hand, or an abort
# sequence. On the dev printer GLOBAL_PARAM.g_accel reads 0 right now, hours into an uptime, so the
# machine sits in the vulnerable state whenever nobody has done a filament change.
#
# WHY `or` AND NOT `|default()`. default() only fires on UNDEFINED, and 0 is defined -- verified
# against Klipper's own Jinja: `{(0|default(40000))}` renders 0, while `{(0 or 40000)}` renders 40000.
# And why not simply declare a non-zero default: the restore would then put back a CONSTANT. On a
# machine whose max_accel is 40000, restoring a hardcoded 2500 after the first purge would quietly
# cripple the rest of the print -- worse than the error, because nothing would say so. The fallback
# has to be the live limit, which makes the never-saved case a no-op.
#
# Patch B above touches the same macro three lines from the setter and is a DIFFERENT fix (the
# max_accel_to_decel attribute removed in v0.13). Easy to mistake for this one.
#
# ACCEL_TO_DECEL is deliberately left alone: the parameter no longer exists in this Klipper
# (0 hits in toolhead.py), so a zero there is ignored rather than rejected. Touching it would be risk
# for no gain. All ten lines are byte-identical, so one sed reaches them all.
if grep -q 'ACCEL={(printer\["gcode_macro GLOBAL_PARAM"\]\.g_accel)}' "$GM"; then
  _n=$(grep -c 'ACCEL={(printer\["gcode_macro GLOBAL_PARAM"\]\.g_accel)}' "$GM")
  sed -i 's@SET_VELOCITY_LIMIT ACCEL={(printer\["gcode_macro GLOBAL_PARAM"\]\.g_accel)}@SET_VELOCITY_LIMIT ACCEL={(printer["gcode_macro GLOBAL_PARAM"].g_accel or printer.toolhead.max_accel)}@' "$GM"
  echo "  config-patches: guarded $_n accel restores against a never-saved zero (SET_VELOCITY_LIMIT ACCEL=0 is a G-code error)."; changed=1
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

# --- Patch H: `G28 X` must not skip the Y-first homing order ---------------------------------
# Reported from a printer on 2026-08-08: toolhead parked at the back (Y above ~310), firmware
# restart, then `G28 X` -- and the head crashes on its way across.
#
# Two things combine. First, Phrozen's [homing_override] carries `axes: z`, so Klipper routes only
# Z-involving homes through it; `G28 X` and `G28 Y` go straight to plain homing and never see the
# body's own `G28 Y0` -> `G1 Y50` -> `G28 X0` order. Second, a firmware restart does not leave the
# machine unhomed: M84 and [delayed_gcode KINEMATIC_POSITION] both call SET_KINEMATIC_POSITION, so
# Klipper reports homed_axes xyz at 150/150/150 while the head is physically wherever it was left.
# Nothing refuses the move, and homing X is a straight X travel at the real Y -- at the back, that
# is through the wipe/purge area.
#
# The fix is not a new safety, it is the existing one applied to the case that bypassed it: widen
# `axes:` to xyz and branch the body so `G28` and `G28 Z` keep the identical full path (probe and
# all), while X/Y-only homes get Z lifted, Y homed and moved clear, then X.
#
# Homing Y rather than nudging it forward by a fixed amount is deliberate. A homing move watches the
# endstop DURING the move; a plain G1 never looks at it, and no fixed distance can know how far back
# the head started. (Reading the switch instead -- QUERY_ENDSTOPS plus printer.query_endstops -- does
# not work inside one macro either: Klipper renders the whole template to a string before the first
# command runs, so the value read is the previous query's.)
#
# This edits printer.cfg, which a Phrozen update replaces wholesale -- hence a self-heal patch here
# rather than a template change, exactly like D and E. Skipped while KAOS's own homing_override is
# swapped in (that section is axis-aware and carries no `axes:` line at all); if the owner later runs
# KAOS_OFF, the vendor section comes back and the next klipper start re-applies this.
PC="$(dirname "$GM")/printer.cfg"
H_MARK='arco-unleashed: single-axis home guard'
if [ -f "$PC" ] \
   && ! grep -qF "$H_MARK" "$PC" \
   && ! grep -qF 'unleashed-x-kaos: homing_override replaced with KAOS' "$PC" \
   && grep -qE '^axes:[[:space:]]*z[[:space:]]*$' "$PC"; then
  h_open=$(mktemp); h_else=$(mktemp); h_out=$(mktemp)
  cat > "$h_open" <<'CFG'
    # >>> arco-unleashed: single-axis home guard >>>
    # Full body for `G28` and anything with Z -- what `axes: z` used to select on its own.
    # `G28 X` / `G28 Y` / `G28 X Y` take the short branch before `axes:` below.
    {% if params.Z is defined or not (params.X is defined or params.Y is defined) %}
CFG
  cat > "$h_else" <<'CFG'
    {% else %}
    # X/Y-only home. Same order as the full body above: Y reaches its endstop and moves
    # clear BEFORE X travels, so a toolhead left at the back is out of the way first.
    G4 P200
    {% if (printer.gcode_move.position.z+5) < 295 %}
    G91
    G1 Z5 F600
    {% else %}
    G91
    G1 Z-5 F600
    {% endif %}
    G4 P500
    G90
    G28 Y0
    G4 P200
    {% if params.X is defined %}
    G1 Y50 F2000
    G4 P200
    G28 X0
    G4 P200
    {% endif %}
    {% endif %}
    # <<< arco-unleashed: single-axis home guard <<<
CFG
  # One pass, section-scoped: never guess at a `gcode:` or `axes:` line outside
  # [homing_override]. Bails out (exit 3) unless BOTH edits landed, so a config whose override
  # does not have the expected shape is left completely untouched rather than half-edited.
  if awk -v OPEN="$h_open" -v ELSE="$h_else" '
        /^\[homing_override\]/            { inblk=1; print; next }
        /^\[[a-zA-Z_]/                    { inblk=0 }
        inblk && !opened && /^gcode:[ \t]*\r?$/ {
            print; while ((getline l < OPEN) > 0) print l; close(OPEN); opened=1; next }
        inblk && opened && /^axes:[ \t]*z[ \t]*\r?$/ {
            while ((getline l < ELSE) > 0) print l; close(ELSE); print "axes: xyz"; closed=1; next }
        { print }
        END { if (!(opened && closed)) exit 3 }
     ' "$PC" > "$h_out" && [ -s "$h_out" ]; then
    cat "$h_out" > "$PC"
    echo "  config-patches: homing_override is now axis-aware (G28 X homes Y clear first)."; changed=1
  else
    echo "  config-patches: homing_override has an unexpected shape -- single-axis home guard NOT applied."
  fi
  rm -f "$h_open" "$h_else" "$h_out"
fi

# --- Patch I: the assumed boot position must not hide 155 mm of downward Z travel ------------
# [delayed_gcode KINEMATIC_POSITION] declares X=150 Y=150 Z=150 at 0.2 s after every klippy start, so
# Klipper reports homed_axes xyz while the toolhead is physically wherever it was left. That is not an
# oversight and it cannot simply be deleted: [homing_override] lifts Z BEFORE it homes anything, so if
# Z were not marked homed, `G28` would fail on its own first move. The declaration is load-bearing.
#
# The VALUE is free, though, and it decides how far a later absolute Z move gets before Klipper's own
# limit check refuses it. With position_min -5 (axis_minimum.z on a running printer):
#
#     declared Z=150  ->  up to 155 mm of downward travel, i.e. the nozzle through the bed
#     declared Z=0    ->  5 mm, and the rest is refused as out of range
#
# So this is one number, and it converts the dangerous direction into the harmless one. Nothing else
# reads the value in a way that flips: every read of position.z in the whole config
# (printer.cfg 2x, printer_gcode_macro.cfg 3x) is a "do I have room to lift?" gate whose move is
# relative (G91 G1 Zn G90), and all of them answer the same at 0 as at 150. Our own absolute Z moves
# in AddOn.cfg are preceded by G28.
#
# What this does NOT do: make Z true. Only a real home does that. It also leaves UP as the unbounded
# direction (303 mm from a declared 0), so a large absolute Z on a machine parked high can still grind
# the screws at the top -- a deliberately accepted trade, because the travel is 308 mm and no declared
# origin can bound both directions at once.
#
# Scoped to the section by a range address rather than a global replace: the bare
# SET_KINEMATIC_POSITION in [gcode_macro M84] re-asserts the CURRENT position and must not be touched,
# and a declared 150 elsewhere might be someone measuring rather than assuming. The trailing
# whitespace capture preserves Phrozen's CRLF, and the leading capture preserves the tab this line
# happens to start with.
if grep -qE '^[[:space:]]*SET_KINEMATIC_POSITION Z=150[[:space:]]*$' "$GM"; then
  sed -i -E '/^\[delayed_gcode KINEMATIC_POSITION\]/,/^\[/ s@^([[:space:]]*)SET_KINEMATIC_POSITION Z=150([[:space:]]*)$@\1SET_KINEMATIC_POSITION Z=0\2@' "$GM"
  if grep -qE '^[[:space:]]*SET_KINEMATIC_POSITION Z=0[[:space:]]*$' "$GM"; then
    echo "  config-patches: boot position declares Z=0, not Z=150 (caps unhomed downward travel at 5 mm)."; changed=1
  else
    echo "  config-patches: SET_KINEMATIC_POSITION Z=150 is outside [delayed_gcode KINEMATIC_POSITION] -- left alone."
  fi
fi

[ "$changed" = 0 ] && echo "  config-patches: already current." || true
