#!/bin/bash
# apply-web-seeds.sh — the three web-interface seeds, in order, from ONE Type=simple unit.
#
# They used to be three ExecStart= lines of a Type=oneshot unit (arco-console-filters.service), because
# only oneshot allows more than one ExecStart. The price of that shape: multi-user.target is ordered
# after every service it wants, and a oneshot counts as "started" only when it has EXITED -- so the
# 20-odd seconds this spends polling for Moonraker held "Startup finished" for the whole boot, on every
# boot. Measured 2026-09-05: 22.9 s of the 82 s to multi-user.target, on a printer that had nothing to
# seed. A Type=simple unit is "started" the moment it forks, and its single ExecStart is this script.
#
# Same three steps, same order, same tolerance: the first seed decides the unit's result, the other two
# are best-effort exactly as their old `ExecStart=-` prefix said.
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/apply-console-filters.sh"; rc=$?
/usr/bin/python3 "$DIR/apply-macro-groups.py" || true
# The Fluidd card seed (--seed) refuses the moment a layout exists, so it only ever fills an untouched dashboard.
/usr/bin/python3 "$DIR/../fluidd-theme/show-runout-card.py" --seed || true
exit "$rc"
