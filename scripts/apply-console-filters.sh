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
(^\s*(try:?|with open|self\.|json_data)|串口[12]第1次打开失败|没有连接任何AMS多色，连接AMS失败|未能打开(任何)?tty.*|\+AMSERROR:\d+|current_directory=/home/mks/klipper|\((dev|cmds|base)\.(py|python)\)|Lo_PauseStatus\['is_paused'\]='False'|当前暂停状态-Lo_PauseStatus='\{'is_paused': False\}'|当前模式|未暂停状态|/etc/ImageId\.json|镜像Id==\d+：ARCO300-MKS-RK3328-STM32F407VET6-I\d+|(重新初始化|重新注册)串口[12]|串口[12](清空|读取数据|发送命令|-AMS结束计时)|Lo_SerialRx|字节个数|字节流|AMS第[0-9]台异步返回|tty[0-9]串口接收|有几台AMS已经打开串口|重复P28串口[0-9]已经打开|^\+Mode:[0-9]|^\{\"dev_id\"|self\.G_|json_data\[|^外部宏命令|^命令[=：]|^PRZ_[A-Z_]+$|吐料次数|换料次数|换料首次|自动换料|首层打印|未在暂停中状态|串口[0-9]已打开|写入json文件|打印中跳过P114查询|返回return|^延时[0-9]|AMS固件版本|AMS段码屏烘干第[0-9]台固件版本|^V-H[0-9]+-I[0-9]+-F[0-9]+$|filename=/home/mks/hdlDat|^chan=[0-9]|^gcmd is not None|^SD$|^[0-9]+(,[0-9]+)+$|^\+P[0-9][^:]*:|^\+T[0-9]+:|^\+C:|^extruder_temp = |^g_extruder_|^fan\*[0-9]|^=====record|^PG[0-9]+|command_string=|^g_[a-z_0-9]+=|^P[0-9]+成功)
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
import hashlib, json, os, sys, urllib.request

api, fid, name, regex = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].strip()

# Every regex this script has ever written, by sha256[:12]. A stored filter whose regex is one of
# these is OURS AND UNTOUCHED, so a corrected version may replace it; anything else is the owner's
# edit and is left exactly where it is.
#
# 🔴 WITHOUT THIS A FIX REACHES NOBODY. The script used to exit the moment it found its own id, so
# the regex a printer was seeded with was the regex it kept for good. That is how "(cmds.py)" lines
# kept appearing in the console for weeks while the shipped pattern already looked correct -- it
# matched "(cmds.python)", and phrozen_dev writes both spellings.
#
# Append the outgoing hash here whenever the regex changes; never remove one.
SHIPPED = {
    "d2a164bb2a99",   # first, seeded from 2026-08-09
    "1eff88c845ac",   # 2026-08-23, the (cmds.py) and serial-narration pass
}

# 🔴 AND A MARKER, because the list above is maintained by hand and I already forgot it once -- one
# commit after writing "append the outgoing hash whenever the regex changes" the regex changed and
# the hash did not, so the guard correctly refused to touch a filter it had written itself and the
# fix reached nobody. The list still matters: it is the only way to recognise a printer seeded before
# markers existed. From here on the marker carries it, so nothing has to be remembered.
MARK = os.path.expanduser("~/.arco-unleashed/console-filter.regex")

def _marked():
    try:
        with open(MARK, encoding="utf-8") as fh:
            return fh.read().strip()
    except Exception:
        return None

def _mark(value):
    try:
        os.makedirs(os.path.dirname(MARK), exist_ok=True)
        with open(MARK, "w", encoding="utf-8") as fh:
            fh.write(value)
    except Exception:
        pass          # a filter that cannot be re-updated later is better than a failed boot seed

def ours(stored):
    stored = (stored or "").strip()
    if stored and stored == _marked():
        return True
    return hashlib.sha256(stored.encode("utf-8")).hexdigest()[:12] in SHIPPED

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

# 🔴 ONE MARK, AT THE END. Writing it inside the Mainsail branch moved the goalposts before the
# Fluidd branch had been asked: the second interface then compared its own, older, perfectly
# legitimate regex against a marker that already said the new one, decided it was somebody
# else's edit, and left it behind. Mainsail updated, Fluidd did not. The test caught it.
wrote = False

# Mainsail keeps a dict keyed by id: {id: {name, bool, regex}}
cur = get("mainsail", "console.consolefilters")
# 🔴 "already current" IS TESTED FIRST, and the order is not cosmetic. What we are about to write is
# ours by definition, but its hash is not in SHIPPED until the NEXT version adds it -- so asking
# "is this ours?" first would classify our own freshly written regex as somebody's edit and refuse to
# touch it ever again. The fix would have disabled itself one version later. Caught by the test.
if isinstance(cur, dict) and fid in cur and cur[fid].get("regex", "").strip() == regex:
    print("[console-filters] mainsail: already current")
elif isinstance(cur, dict) and fid in cur and not ours(cur[fid].get("regex")):
    print("[console-filters] mainsail: left alone (the filter has been edited here)")
else:
    merged = dict(cur) if isinstance(cur, dict) else {}
    # Keep whatever switch position is already there. Somebody who turned our filter OFF meant it,
    # and handing them a corrected regex is no reason to turn it back on behind their back.
    was = merged.get(fid) if isinstance(merged.get(fid), dict) else None
    merged[fid] = {"name": name, "bool": True if was is None else bool(was.get("bool", True)),
                   "regex": regex}
    put("mainsail", "console.consolefilters", merged)
    wrote = True
    print("[console-filters] mainsail: %s" % ("updated" if was else "seeded"))

# Fluidd keeps a list: [{id, enabled, name, type, value}]
cur = get("fluidd", "console.consoleFilters")
_mine = next((f for f in cur if isinstance(f, dict) and f.get("id") == fid), None)         if isinstance(cur, list) else None
if _mine is not None and (_mine.get("value") or "").strip() == regex:
    print("[console-filters] fluidd: already current")
elif _mine is not None and not ours(_mine.get("value")):
    print("[console-filters] fluidd: left alone (the filter has been edited here)")
else:
    merged = [f for f in cur if not (isinstance(f, dict) and f.get("id") == fid)]              if isinstance(cur, list) else []
    merged.append({"id": fid, "name": name, "type": "expression", "value": regex,
                   "enabled": True if _mine is None else bool(_mine.get("enabled", True))})
    put("fluidd", "console.consoleFilters", merged)
    wrote = True
    print("[console-filters] fluidd: %s" % ("updated" if _mine else "seeded"))

if wrote:
    _mark(regex)
PY
exit 0
