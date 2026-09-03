#!/bin/bash
# apply-addon-merge.sh — guard wrapper around addon_merge.py: deliver new #@FEAT blocks to AddOn.cfg
# no matter how the update arrived.
#
# WHY A GUARD AND NOT ONLY selfupdate.sh. The merge was first wired into after_update(), which is what
# the setup menu and ARCO_UPDATE run. Moonraker's update manager does not go through it -- a web
# interface update is a plain `git pull` -- so the most convenient route, the button in the browser,
# delivered the scripts and silently skipped the config. A tester took a whole night's work that way on
# 2026-08-15 and still had no startup banner and no welcome dialog, with nothing to indicate why. A
# delivery mechanism that the most-used path does not trigger is not a delivery mechanism.
#
# WHY THE SHAPE IS CAREFUL, and how this differs from the other guards. The rest of them RESTORE: they
# know the correct content of a file and put it back after something destroyed it. This one ADDS to a
# file that belongs to the owner, which is a one-time migration rather than a repair -- and a migration
# that runs on every boot would repeat any mistake on every boot. Getting it wrong once during an update
# costs an update; getting it wrong here costs a printer that will not start again. Hence the rule the
# tool already enforces: append whole blocks from the kit's own template, never edit a block that is
# present, refuse anything that would redefine a section already declared anywhere in the config
# directory, and record every block added so a hand-deletion stays deleted.
#
# CHEAP EXIT FIRST. The steady state is "nothing to do", and reaching that answer costs two greps and a
# comm -- no python start at all. Python is only invoked when a feature in the template is genuinely
# absent here AND has not been merged before.
#
# Usage:  bash apply-addon-merge.sh          (ExecStartPre guard; also fine by hand)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# ${HOME:-} rather than $HOME: this runs from systemd, and with `set -u` an unset HOME would abort the
# script -- which is how optimize-boot.sh once died under systemd.
ARCO_HOME="${HOME:-/home/mks}"
CFG="$ARCO_HOME/printer_data/config/AddOn.cfg"
TPL="$DIR/../config-templates/AddOn.cfg.template"
STATE="$ARCO_HOME/.arco-unleashed/addon-seeded-features"

# Nothing to merge into, or nothing to merge from. Not an error: a base-image install has no AddOn.cfg
# until install-addon-cfg.sh creates one, and that path already writes the full template.
[ -f "$CFG" ] || exit 0
[ -f "$TPL" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

feats(){ grep -oE '^#@FEAT[[:space:]]+[^[:space:]]+' "$1" 2>/dev/null | awk '{print $2}' | sort -u; }

want="$(feats "$TPL")"
[ -n "$want" ] || exit 0          # a template with no blocks is a broken template, not a reason to act

# "known" is what must NOT be offered again: what the config already carries, plus everything ever
# merged. The second half matters — without it a block the owner deleted by hand would look missing
# forever and start python on every single boot to be told no.
known="$( { feats "$CFG"; sort -u "$STATE" 2>/dev/null; } | sort -u )"
missing="$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$known") 2>/dev/null)"

# A #@REVISE names a block the printer ALREADY has, so it adds no feature id and the comparison above
# cannot see it -- without this the merge would never be started for one. Compare the block itself,
# with the off-sentinel stripped so a feature the owner switched off is not mistaken for a stale one.
# POSIX character classes are avoided inside awk on purpose: mawk 1.3.3 does not have them, and this
# script is expected to keep working on a stock printer as well as an Unleashed one.
blk(){ awk -v id="$2" 'BEGIN{ re = "^#@FEAT[ \t]+" id "[ \t]*[|]" }
                       $0 ~ re { f=1 }
                       f { sub(/^#:off:/, ""); print }
                       f && /^#@ENDFEAT/ { exit }' "$1" 2>/dev/null; }
stale=""
for id in $(grep -oE '^#@REVISE[[:space:]]+[^[:space:]]+' "$TPL" 2>/dev/null | awk '{print $2}' | sort -u); do
  here="$(blk "$CFG" "$id")"
  [ -n "$here" ] || continue      # not in this file: the add path and the seeded record decide
  [ "$here" = "$(blk "$TPL" "$id")" ] || { stale="$id"; break; }
done


[ -n "$missing" ] || [ -n "$stale" ] || exit 0

if [ -n "$missing" ]; then
  echo "  AddOn.cfg: $(printf '%s\n' "$missing" | grep -c .) new feature(s) in the template — merging"
else
  echo "  AddOn.cfg: the template carries a newer '$stale' — merging"
fi
python3 "$DIR/addon_merge.py" apply "$CFG" "$TPL" 2>&1 | sed 's/^/  /'

# Never fail the unit. The '-' prefix on the ExecStartPre already covers this, but a guard that returns
# non-zero also writes a failure line into the journal for something that is not a failure — a skipped
# block is a correct outcome, not a fault.
exit 0
