#!/bin/bash
# apply-theme-variants.sh — carry Mainsail-theme changes from the kit into an installed theme.
#
# WHY THIS EXISTS. The theme is deliberately not a Mainsail fork: Mainsail reads
# printer_data/config/.theme/, so the styling survives every Mainsail update. What nobody wired up
# is the other direction — the theme is COPIED into the config directory once, at install, and
# nothing ever refreshed it. A kit update changed mainsail-theme/variants/ in the clone and the
# printer went on serving its months-old copy, with the update reporting success. That is the same
# shape as the [arco_sdcard_select] section that was installed but never declared, and as the P114
# gate that ran two versions old in the field: delivery that stops one step short of the machine.
#
# WHAT IT DOES. Before every klipper start (ExecStartPre, drop-in 26), compare the kit's variant
# tree with the installed one and copy what differs. If anything changed AND a variant is currently
# active, rebuild .theme/ through the kit's own switcher, so the change is actually on screen after
# a hard reload rather than merely on disk.
#
# 🔴 IT NEVER INSTALLS. A missing .theme-variants/ means the owner has not set the theme up (or
# chose stock Mainsail and removed it), and that is an answer, not a gap. Installing it from here
# would hand a theme to someone who did not ask for one, at a boot they were not watching.
#
# 🔴 IT NEVER DELETES. Only add-or-update, exactly like apply-arco-extras.sh. A file that
# disappeared from the kit leaves a stale copy behind, which is the cheap failure; mirroring
# deletions would let a kit change remove a variant somebody added by hand.
#
# 🔴 IT DOES NOT TOUCH unleashed-theme-macros.cfg. That is a Klipper config file included by
# printer.cfg, so rewriting it before klippy parses it could halt the printer — and config files
# belong to the owner. Only AddOn.cfg is delivered to, and only through addon_merge's block
# machinery.
#
# 🔴 IT DOES NOT TOUCH .theme-state. Which variant is active is the owner's choice; this only
# refreshes what that choice renders.
#
# Idempotent and cheap: a byte compare per file, a no-op in milliseconds when already current.
#
# Usage:  bash apply-theme-variants.sh [config-dir]
set -u
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
CFG="${1:-${ARCO_CONFIG:-$HOME/printer_data/config}}"
SRC="$SELFDIR/../mainsail-theme"
VAR="$CFG/.theme-variants"

# Nothing to copy from (older kit layout) or nothing to copy into (theme not installed).
[ -d "$SRC/variants" ] || exit 0
if [ ! -d "$VAR" ]; then
  exit 0
fi

# The switcher runs as a separate script and resolves the config dir through $HOME. systemd does
# set HOME for a User= unit, but this script can also be run by hand from a shell that does not —
# so the value is derived from the config path we were actually given rather than assumed.
AHOME="$(cd "$CFG/../.." 2>/dev/null && pwd)"
[ -n "$AHOME" ] || AHOME="${HOME:-}"

changed=0
for d in shared voron-light voron-dark; do
  [ -d "$SRC/variants/$d" ] || continue
  for f in "$SRC/variants/$d"/*; do
    [ -f "$f" ] || continue
    dst="$VAR/$d/$(basename "$f")"
    if [ ! -f "$dst" ] || ! cmp -s "$f" "$dst"; then
      install -Dm644 "$f" "$dst" && changed=1
      echo "  theme: updated $d/$(basename "$f")"
    fi
  done
done

# The switcher itself is ours too, and it went stale the same way.
if [ -f "$SRC/unleashed-theme.sh" ]; then
  dst="$CFG/unleashed-theme.sh"
  if [ ! -f "$dst" ] || ! cmp -s "$SRC/unleashed-theme.sh" "$dst"; then
    install -Dm755 "$SRC/unleashed-theme.sh" "$dst" && changed=1
    echo "  theme: updated unleashed-theme.sh"
  fi
fi

[ "$changed" = 1 ] || exit 0

# Rebuilding is what makes the update visible. Only for a variant that is actually active: 'stock'
# means the owner turned the theme off, and .theme/ does not exist — recreating it here would turn
# their theme back on behind their back.
state="$(cat "$CFG/.theme-state" 2>/dev/null || echo stock)"
case "$state" in
  light|dark)
    if HOME="$AHOME" sh "$CFG/unleashed-theme.sh" "$state" >/dev/null 2>&1; then
      echo "  theme: rebuilt .theme/ ($state) — hard-reload Mainsail (Ctrl+F5) to see it"
    else
      echo "  theme: WARN could not rebuild .theme/ ($state); the variants are updated, run"
      echo "  theme:      sh $CFG/unleashed-theme.sh $state"
    fi
    ;;
  *)
    echo "  theme: variants updated; stock Mainsail is active, so nothing was rebuilt"
    ;;
esac
exit 0
