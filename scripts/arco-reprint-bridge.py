#!/usr/bin/env python3
# arco-reprint-bridge
# -----------------------------------------------------------------------------
# Make the TFT History reprint actually print. On the migrated stack voronFDM's
# history-reprint branch validates the file (checkFile passes) and builds the
# full path, but never sends printer.print.start -- so the printer homes and
# stops. voronFDM does NOT put the chosen filename on the moonraker websocket in
# this flow, but it DOES print it to its own stdout ("check_file:<abs path>" +
# "<path> exists"). This watcher tails that log and issues the print.start that
# voronFDM omitted, for the exact file it selected.
#
# Trigger: arm on 'check_file:<path>' + the '<path> exists' confirmation, then
# fire on 'PRZ_PRINTING_START' (the print-start macro voronFDM emits). Guarded:
# file must exist, not already printing, debounced, one-shot per selection.
# Orca / Mainsail (direct print.start) unaffected -- if a print is already
# active the injection is skipped.
#
# INTEROPERABILITY NOTE: the three markers this matches -- "check_file:", the
# file-exists line, and PRZ_PRINTING_START -- are voronFDM's OWN runtime stdout
# output plus a public config macro. They are OBSERVED by capturing the running
# binary's log; nothing here is obtained by decompiling voronFDM, and no Phrozen
# code is reproduced. This is an interoperability shim, not a derivative work.
# If a firmware update changes those log strings the watcher simply stops arming
# and degrades gracefully -- reprint falls back to homing-then-idle (the stock
# migrated behaviour) and Orca / Mainsail are never affected.
import re, os, time, json, urllib.request
from urllib.parse import quote

LOG = os.environ.get("ARCO_VFDM_LOG", "/home/mks/vfdm-capture.log")
GCODES = "/home/mks/printer_data/gcodes/"
MOONRAKER = "http://127.0.0.1:7125"
ARM_TTL = 45.0        # seconds a captured check_file stays valid
DEBOUNCE = 30.0       # min seconds between two injected starts

CHECK_RE = re.compile(r'check_file:(/home/\S+\.gcode)')
EXIST_RE = re.compile(r'文件:\s*(/home/\S+\.gcode)\s*存在')   # "文件: <path> 存在"
START_RE = re.compile(r'PRZ_PRINTING_START')


def log(msg):
    print("[arco-reprint-bridge] %s" % msg, flush=True)


def _get(path):
    try:
        with urllib.request.urlopen(MOONRAKER + path, timeout=5) as r:
            return json.load(r)
    except Exception:
        return None


def _post(path):
    # print.start blocks until the job is queued (~10 s incl. initial homing hand-off),
    # so give it room; a slow response is not an error and the job still starts.
    try:
        req = urllib.request.Request(MOONRAKER + path, method="POST", data=b"")
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except Exception as e:
        return {"error": str(e)}


def is_printing():
    d = _get("/printer/objects/query?print_stats")
    try:
        return d["result"]["status"]["print_stats"]["state"] in ("printing", "paused")
    except Exception:
        return False


def follow(path):
    while not os.path.exists(path):
        time.sleep(1)
    f = open(path, "r", errors="replace")
    f.seek(0, os.SEEK_END)
    while True:
        line = f.readline()
        if line:
            yield line
            continue
        time.sleep(0.2)
        try:                                   # tolerate truncation / rotation
            if os.stat(path).st_size < f.tell():
                f.seek(0)
        except OSError:
            pass


def main():
    armed = None      # absolute path
    armed_ts = 0.0
    exists = False
    last_inject = 0.0
    log("watching %s" % LOG)
    for line in follow(LOG):
        try:
            now = time.time()
            m = CHECK_RE.search(line)
            if m:
                armed, armed_ts, exists = m.group(1), now, False
                log("armed: %s" % armed)
                continue
            m = EXIST_RE.search(line)
            if m and armed and m.group(1) == armed:
                exists = True
                continue
            if START_RE.search(line) and armed:
                ok = (exists and (now - armed_ts < ARM_TTL)
                      and (now - last_inject > DEBOUNCE) and not is_printing())
                if not ok:
                    log("PRZ_PRINTING_START but skip (exists=%s ttl_ok=%s printing=%s)"
                        % (exists, (now - armed_ts < ARM_TTL), is_printing()))
                    continue
                rel = armed[len(GCODES):] if armed.startswith(GCODES) else armed
                res = _post("/printer/print/start?filename=" + quote(rel))
                log("INJECT print.start filename=%s -> %s" % (rel, res))
                last_inject = now
                armed, exists = None, False
        except Exception as e:               # a daemon must never die on one bad line
            log("loop error: %s" % e)


if __name__ == "__main__":
    main()
