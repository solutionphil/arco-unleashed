#!/bin/bash
# mainsail-seed.sh — snapshot/restore Mainsail macro-groups + console-filters.
# These live in the MOONRAKER DB (namespace 'mainsail'), NOT in Mainsail's app files, so they
# already survive a Mainsail update. This tool re-applies them on a fresh install, or as
# insurance if a big Mainsail update ever changes the schema.
#
#   capture  -> read the current groups/filters from THIS running printer into mainsail-seed.json
#               (run once after you've set up the groups + console filters in the Mainsail UI)
#   apply    -> POST the saved groups/filters back to the printer (then hard-reload Mainsail)
#   show     -> print what's currently saved in the seed
#
# Mainsail v2.17 DB keys: 'macrogroups' (macro groups) + the console custom filters.
set -uo pipefail
MR="http://127.0.0.1:7125"
DIR="$(cd "$(dirname "$0")" && pwd)"
SEED="$DIR/mainsail-seed.json"
NS="mainsail"
# mainsail-namespace keys we manage. Add the console-filter key here once confirmed in the UI
# (capture it first, then list it so 'apply' restores it too).
KEYS=("macrogroups")

get(){ curl -s "$MR/server/database/item?namespace=$NS&key=$1"; }

capture(){
  echo "{}" > "$SEED.tmp"
  for k in "${KEYS[@]}"; do
    get "$k" | python3 -c "
import sys,json
try: val=json.load(sys.stdin)['result']['value']
except Exception: print('  (no value): $k'); sys.exit(0)
seed=json.load(open('$SEED.tmp'))
seed['$k']=val
json.dump(seed,open('$SEED.tmp','w'),indent=1)
print('  captured: $k')
"
  done
  mv "$SEED.tmp" "$SEED"
  echo "Saved -> $SEED"
}

apply(){
  [ -f "$SEED" ] || { echo "No $SEED yet — run 'capture' on a configured printer first."; exit 1; }
  python3 -c "
import json,subprocess
seed=json.load(open('$SEED'))
for k,v in seed.items():
    body=json.dumps({'namespace':'$NS','key':k,'value':v})
    subprocess.run(['curl','-s','-X','POST','$MR/server/database/item',
                    '-H','Content-Type: application/json','-d',body],stdout=subprocess.DEVNULL)
    print('  applied:',k)
"
  echo "Applied. Hard-reload Mainsail (Ctrl+F5)."
}

case "${1:-}" in
  capture) capture;;
  apply)   apply;;
  show)    [ -f "$SEED" ] && python3 -m json.tool "$SEED" || echo "(no seed yet)";;
  *) echo "Usage: bash mainsail-seed.sh capture|apply|show";;
esac
