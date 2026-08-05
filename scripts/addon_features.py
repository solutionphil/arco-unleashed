#!/usr/bin/env python3
# addon_features.py - parse / toggle the #@FEAT ... #@ENDFEAT blocks in AddOn.cfg, and keep the
# board_fan <-> printer.cfg [output_pin board_fan] coupling consistent. Driven by addon-features.sh.
#
#   python3 addon_features.py --list  <AddOn.cfg>
#       -> one line per feature:  id<TAB>ON|OFF<TAB>description
#   python3 addon_features.py --apply <AddOn.cfg> <printer.cfg> "id1 id2 ..."
#       -> the listed ids are ON, all others OFF; board_fan also (un)comments printer.cfg.
#
# OFF = every non-blank body line of a feature block is prefixed with the sentinel "#:off:".
import sys, re, shutil, os

OFF = "#:off:"
FEAT = re.compile(r'^#@FEAT\s+(\S+)\s*\|\s*(.*)$')

def parse(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    feats, i = [], 0
    while i < len(lines):
        m = FEAT.match(lines[i])
        if m:
            fid, desc, start = m.group(1), m.group(2).strip(), i
            j, body_off = i + 1, None
            while j < len(lines) and not lines[j].startswith("#@ENDFEAT"):
                if body_off is None and lines[j].strip():
                    body_off = lines[j].startswith(OFF)
                j += 1
            feats.append((fid, desc, "OFF" if body_off else "ON", start, j))
            i = j
        i += 1
    return lines, feats

def set_block(lines, start, end, on):
    for k in range(start + 1, end):          # body = between #@FEAT and #@ENDFEAT
        ln = lines[k]
        if on:
            if ln.startswith(OFF):
                lines[k] = ln[len(OFF):]
        elif ln.strip() and not ln.startswith(OFF):
            lines[k] = OFF + ln

def board_fan_printer(ppath, commented):
    # commented=True  -> ensure Phrozen's [output_pin board_fan] block is commented (AddOn fan active)
    # commented=False -> uncomment it (AddOn fan off, so the pin drives the fan as plain on/off)
    if not os.path.isfile(ppath):
        return
    lines = open(ppath, encoding="utf-8").read().split("\n")
    out, blk, changed = [], False, False
    def setc(ln):
        nonlocal changed
        if commented and not ln.startswith("#"):
            changed = True; return "#" + ln
        if not commented and ln.startswith("#"):
            changed = True; return ln[1:]
        return ln
    for ln in lines:
        if ln.lstrip("#").strip() == "[output_pin board_fan]":
            blk = True; out.append(setc(ln)); continue
        if blk:
            bare = ln.lstrip("#").strip()
            if bare == "" or bare.startswith("["):
                blk = False; out.append(ln)
            else:
                out.append(setc(ln))
        else:
            out.append(ln)
    if changed:
        shutil.copy2(ppath, ppath + ".addon.bak")
        open(ppath, "w", encoding="utf-8").write("\n".join(out))

def cmd_apply(apath, ppath, selected):
    sel = set(selected.split())
    lines, feats = parse(apath)
    shutil.copy2(apath, apath + ".addon.bak")
    for fid, desc, state, start, end in feats:
        on = fid in sel
        set_block(lines, start, end, on)
        if fid == "board_fan":
            board_fan_printer(ppath, commented=on)
    open(apath, "w", encoding="utf-8").write("\n".join(lines))

if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--list":
        for fid, desc, state, *_ in parse(sys.argv[2])[1]:
            print(f"{fid}\t{state}\t{desc}")
    elif len(sys.argv) >= 4 and sys.argv[1] == "--apply":
        cmd_apply(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    else:
        sys.exit("usage: addon_features.py --list <AddOn.cfg> | --apply <AddOn.cfg> <printer.cfg> \"ids\"")
