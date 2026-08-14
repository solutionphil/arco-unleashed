#!/bin/bash
# apply-console-filters.sh — seed one console filter into Mainsail and Fluidd: Phrozen's log noise.
#
# WHY. phrozen_dev narrates itself into the Klipper console on every boot and every print: Chinese status
# lines, +AMSERROR on a printer with no AMS (expected, see the AMS notes), and raw fragments of its own
# Python source -- `self.…`, `json_data…`, `try`, `with open`. None of it is actionable and all of it
# buries the messages that are. Both web interfaces can filter it; nobody finds that setting on their own.
#
# WHERE IT LIVES. Not in a config file -- both clients keep their settings in Moonraker's database, in
# their own namespace, and write them through Moonraker's HTTP API. Hence a service rather than a file we
# could drop into place at bake time.
#
# ADDITIVE, NEVER DESTRUCTIVE. The value read back is the owner's whole filter list. We merge ours in and
# write the merged list, keying on OUR id so a second run changes nothing -- and so an owner who edits or
# deletes it is not overruled on the next boot. Anything they added themselves is carried through
# untouched. If a filter with our id is already there, the script exits without writing at all.
#
# ONE REGEX FOR BOTH. The two interfaces had grown separate copies that had already drifted (one matched
# `+AMSERROR:2` literally, the other `\d+`; one spelled out 串口1 and 串口2, the other used a class). Two
# copies of the same intent is the failure mode this project keeps meeting, so there is one pattern here
# and both clients get it.
#
# TIGHTER THAN THE HAND-MADE ONES, deliberately. Console filters match anywhere in the message, so bare
# alternatives like `try`, `with open`, `self\.` and `json_data` also swallow any line that merely
# CONTAINS them -- "please try again" among them. On the machine they were written on that is a nuisance;
# shipped to strangers it hides messages someone is debugging by. Those four are anchored to the start of
# the line here, which is where the Python fragments actually appear.
set -uo pipefail

API=http://127.0.0.1:7125
ID=arco-unleashed-phrozen-noise
NAME='Arco Unleashed: Phrozen noise'

read -r -d '' RE <<'REGEX'
(^\s*(try:?|with open|self\.|json_data)|串口[12]第1次打开失败|没有连接任何AMS多色，连接AMS失败|未能打开(任何)?tty.*|\+AMSERROR:\d+|current_directory=/home/mks/klipper|\((dev|cmds|base)\.python\)|Lo_PauseStatus\['is_paused'\]='False'|当前暂停状态-Lo_PauseStatus='\{'is_paused': False\}'|当前模式|未暂停状态|/etc/ImageId\.json|镜像Id==\d+：ARCO300-MKS-RK3328-STM32F407VET6-I\d+)
REGEX

# Wait for Moonraker the same way arco-update-refresh does. Two minutes is generous; on a first boot
# Moonraker is up long before that, and if it never comes we simply leave the filters unset rather than
# hang around -- a missing filter costs nothing but noise.
for _ in $(seq 1 60); do
  curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 3 "$API/server/info" >/dev/null 2>&1 || {
  echo "[console-filters] Moonraker did not answer — nothing seeded"; exit 0; }

python3 - "$API" "$ID" "$NAME" "$RE" <<'PY'
import json, sys, urllib.request

api, fid, name, regex = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].strip()

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(api + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())

def get(ns, key):
    try:
        return call("GET", "/server/database/item?namespace=%s&key=%s" % (ns, key))["result"]["value"]
    except Exception:
        return None

def put(ns, key, value):
    call("POST", "/server/database/item", {"namespace": ns, "key": key, "value": value})

# Mainsail keeps a dict keyed by id: {id: {name, bool, regex}}
cur = get("mainsail", "console.consolefilters")
if isinstance(cur, dict) and fid in cur:
    print("[console-filters] mainsail: already present")
else:
    merged = dict(cur) if isinstance(cur, dict) else {}
    merged[fid] = {"name": name, "bool": True, "regex": regex}
    put("mainsail", "console.consolefilters", merged)
    print("[console-filters] mainsail: seeded (%d filter(s) total)" % len(merged))

# Fluidd keeps a list: [{id, enabled, name, type, value}]
cur = get("fluidd", "console.consoleFilters")
if isinstance(cur, list) and any(isinstance(f, dict) and f.get("id") == fid for f in cur):
    print("[console-filters] fluidd: already present")
else:
    merged = list(cur) if isinstance(cur, list) else []
    merged.append({"id": fid, "enabled": True, "name": name, "type": "expression", "value": regex})
    put("fluidd", "console.consoleFilters", merged)
    print("[console-filters] fluidd: seeded (%d filter(s) total)" % len(merged))
PY
exit 0
