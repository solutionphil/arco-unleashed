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
# 🔴 IT DOES NOT TOUCH .theme-variants/local.css EITHER, and that is load-bearing rather than
# incidental. This script is the reason that file has to exist: editing a variant's custom.css by
# hand used to stick forever, and refreshing from the kit made it volatile. local.css sits BESIDE
# the variants, and the loop below only ever copies out of the kit's variants/ subfolders, so it is
# out of reach here by construction. unleashed-theme.sh appends it last when it builds .theme/.
#
# Idempotent and cheap: a byte compare per file, a no-op in milliseconds when already current.
#
# Usage:  bash apply-theme-variants.sh [config-dir]
set -u
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
CFG="${1:-${ARCO_CONFIG:-$HOME/printer_data/config}}"
SRC="$SELFDIR/../mainsail-theme"
VAR="$CFG/.theme-variants"

# 🔴 SILENT ON A BOOT, TALKATIVE IN A SHELL. This runs before every klipper start, so a line per
# boot would be journal noise for a script that usually has nothing to do -- but the same silence
# made a hand run useless: on 19.08.2026 an owner ran it to find out why the theme had not arrived
# and got back nothing at all, which is indistinguishable from a script that bailed out on its
# first line. Whoever is watching a terminal wants the reasoning; the journal does not.
say() { if [ -t 1 ]; then echo "$@"; fi; return 0; }

# Nothing to copy from (older kit layout) or nothing to copy into (theme not installed).
if [ ! -d "$SRC/variants" ]; then
  say "  theme: no $SRC/variants in this kit — nothing to copy from."
  exit 0
fi
if [ ! -d "$VAR" ]; then
  say "  theme: $VAR does not exist, so the Arco theme is not installed here."
  say "  theme: install it first:  bash $SELFDIR/../mainsail-theme/setup-theme-macros.sh"
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

if [ "$changed" != 1 ]; then
  # The commonest outcome by far, and the one that has to be legible when somebody is asking
  # "why has my theme not changed?" -- the answer is here, not in a missing message.
  say "  theme: the installed variants already match the kit; nothing to do."
  say "  theme: active variant: $(cat "$CFG/.theme-state" 2>/dev/null || echo unknown)"
  exit 0
fi

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
