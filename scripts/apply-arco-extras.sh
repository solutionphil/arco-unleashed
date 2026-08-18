#!/bin/bash
# apply-arco-extras.sh — ensure Arco Unleashed first-party Klipper extras are present in
# klippy/extras/. Unlike the mcu.py patch (a tracked CORE file that Klipper updates revert),
# these are NEW untracked modules -> a normal `git pull` / `git reset --hard` leaves them
# alone. This install-if-missing is only a self-heal for a full Klipper re-clone / fresh
# install / `git clean`: it runs as an ExecStartPre before klipper starts (see optimize-boot.sh),
# so the module is in place BEFORE klippy parses its [arco_tool_gate] config section.
#
# Idempotent + check-first: copies only when the target is missing or differs from the kit
# copy (byte compare). A no-op in ms when already current.
#
# Usage:  bash apply-arco-extras.sh [path-to-klipper]
set -e
KL="${1:-$HOME/klipper}"
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$KL/klippy/extras"
[ -d "$DEST" ] || { echo "ERROR: $DEST not found (pass the klipper path as arg 1)."; exit 1; }

# gcode_shell_command.py is third-party (not ours), but the theme macros declare
# [gcode_shell_command switch_theme] — so without it klippy refuses the config outright:
# "Section 'gcode_shell_command switch_theme' is not a valid config section", printer halted.
# It is still needed after the AMS shell commands were retired: an AddOn.cfg out in the field
# can carry any number of shell-command sections we did not ship. It used to sit in mainsail-theme/ as if it were a theme
# asset, which is exactly why it was missed here; a Klipper "hard recover" (reset --hard + clean)
# deleted it and took the printer down with it (2026-07-21). It is a base dependency, so it is
# restored on every start like the rest.
# arco_mcu_timing.py replaces the old sed patch of klippy/mcu.py. Editing that TRACKED core file left
# Klipper's repo permanently dirty, and Moonraker refuses to update a dirty repo — so the printer
# could never take a Klipper update at all. Setting the same three values from an UNTRACKED extra
# keeps the tree pristine and the update button usable.
# arco_fila_status.py is read-only (it publishes phrozen_dev's filament state, which that module
# keeps to itself) — but it is restored like the rest, because the print-start warning it emits is
# the only signal a user gets that a print is running without runout protection.
# 🔴 A NEW EXTRA MUST BE ADDED HERE, and it is not optional: AddOn.cfg is delivered by addon_merge
# at the same update, so a config section can arrive whose module does not. klippy then refuses the
# WHOLE config -- "Section ... is not a valid config section" -- on a printer that worked a minute ago.
for f in arco_tool_gate.py arco_sdcard_select.py gcode_shell_command.py arco_mcu_timing.py \
         arco_fila_status.py arco_virtual_pins.py; do
  src="$SELFDIR/$f"; dst="$DEST/$f"
  [ -f "$src" ] || { echo "WARN: kit source $src missing — skipped"; continue; }
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst"; then
    install -Dm644 "$src" "$dst"
    echo "  installed/updated klippy/extras/$f"
  else
    echo "  klippy/extras/$f already current"
  fi
done

# --- the other half: the module must also be DECLARED, or installing it changes nothing -------------
#
# Installing arco_sdcard_select.py without an [arco_sdcard_select] section is a no-op: klippy never
# loads it, SDCARD_SELECT_FILE is never registered, and the TFT history-reprint fix is silently dead.
# That is not hypothetical — it shipped. The kit template carried the section, the DEPLOYED AddOn.cfg
# did not, and nothing reconciled the two: firstrun does not re-deploy AddOn.cfg, so a config written
# by an older kit keeps whatever sections it was born with, forever. The image build had a bespoke
# patch for exactly one section ([arco_mcu_timing]) and therefore could not catch the next one.
#
# Scope is deliberately narrow: only [arco_*] sections, which are OUR module declarations. User macros
# are left alone — someone may legitimately move or delete those, and appending a second copy of a
# section that lives in another file would break the config outright.
CFGDIR="${ARCO_CONFIG:-$HOME/printer_data/config}"
TPL="$SELFDIR/../config-templates/AddOn.cfg.template"
ADDON="$CFGDIR/AddOn.cfg"
if [ -f "$TPL" ] && [ -f "$ADDON" ]; then
  # 🔴 ONLY SECTIONS THAT SIT OUTSIDE EVERY #@FEAT BLOCK. Anything inside one belongs to
  # addon_merge, which delivers the whole block -- and this script runs FIRST (drop-in 16 against
  # 24). Appending such a section here would leave addon_merge to find it already declared, refuse
  # the block as a collision, and drop the rest of the feature on the floor without a word.
  for sec in $(awk '
      /^#@FEAT /   { inblk = 1; next }
      /^#@ENDFEAT/ { inblk = 0; next }
      !inblk && /^\[arco_[a-z_0-9]+\]/ { gsub(/[][]/, "", $0); print }
    ' "$TPL" | sort -u); do
    # present ANYWHERE in the config dir counts — never create a duplicate of a section the user moved
    if grep -qrE "^\[$sec\]" "$CFGDIR"/*.cfg 2>/dev/null; then continue; fi
    # lift the section from the template together with the comment block explaining it
    blk=$(awk -v s="[$sec]" '
      $0 == s { for (i = 1; i <= n; i++) print buf[i]; print; found = 1; next }
      found && /^\[/ { exit }
      found { print; next }
      /^#/ { buf[++n] = $0; next }
      { n = 0 }
    ' "$TPL")
    if [ -n "$blk" ]; then
      printf '\n%s\n' "$blk" >> "$ADDON"
      echo "  AddOn.cfg: declared [$sec] (the module was installed but never loaded without it)"
    fi
  done
fi

# --- the update console -----------------------------------------------------------------------------
#
# Same reconciliation problem, different shape. ARCO_UPDATE / ARCO_UPDATE_CHECK are macros, not
# [arco_*] declarations, so the loop above deliberately does not carry them: its narrow scope exists
# because a user may legitimately move or delete their OWN macros. These are not the user's. They are
# the kit's command surface -- the only way to update it without leaving Mainsail or Fluidd -- and a
# printer whose AddOn.cfg was written by an older kit would otherwise never get them, forever, which
# is precisely the failure this file's header describes.
#
# Gated on the shell-command section rather than the macros: it is the one piece here that cannot
# meaningfully live anywhere else, and a second copy of it would be a duplicate-section config error.
# Marker-delimited in the template so the block travels with its own explanation.
if [ -f "$TPL" ] && [ -f "$ADDON" ] \
   && grep -q '^\[gcode_shell_command arco_selfupdate\]' "$TPL" \
   && ! grep -qr '^\[gcode_shell_command arco_selfupdate\]' "$CFGDIR"/*.cfg 2>/dev/null; then
  blk=$(awk '/^# >>> arco-update-console/{f=1} f{print} /^# <<< arco-update-console/{exit}' "$TPL")
  if [ -n "$blk" ]; then
    printf '\n%s\n' "$blk" >> "$ADDON"
    echo "  AddOn.cfg: added the update console (ARCO_UPDATE / ARCO_UPDATE_CHECK)"
  fi
fi
