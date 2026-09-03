#!/usr/bin/env python3
"""Every marker in AddOn.cfg.template does something, or the build stops.

addon_merge.py guards itself well at RUN time: an unpaired #@DROP is refused, a #@RETIRE for a
feature the template still ships is ignored, a #@REVISE naming a block that is not there is skipped.
Each of those is the right thing to do on a printer -- and each is silent to whoever wrote the
marker, because the message is printed on a machine in somebody's workshop rather than in the pull
request that got it wrong. The P114 gate ran two versions out of date for months for exactly this
kind of reason: the delivery looked like it was working.

So the same rules are checked here, where a typo is still cheap.
"""
import re
import sys
import os

TPL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                   "config-templates", "AddOn.cfg.template")

FEAT = re.compile(r'^#@FEAT\s+(\S+)\s*\|\s*(.*)$')
RETIRE = re.compile(r'^#@RETIRE\s+(\S+)\s*\|\s*(.*)$')
REVISE = re.compile(r'^#@REVISE\s+(\S+)\s*\|\s*(.*)$')
DROP = re.compile(r'^#@DROP\s+(.+?)\s*\|\s*(.*)$')
END = "#@ENDFEAT"
OFF = "#:off:"
SECTION = re.compile(r'^(?:' + re.escape(OFF) + r')?\[([^\]]+)\]\s*$')


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else TPL
    lines = open(path, encoding="utf-8").read().split("\n")
    bad = []

    # 1. Every block is closed, and closed before the next one opens. addon_merge refuses to touch an
    #    unterminated block precisely because removing it would swallow the neighbour -- which in this
    #    file means the two print macros.
    feats, open_at, ids = {}, None, []
    for n, l in enumerate(lines, 1):
        m = FEAT.match(l)
        if m:
            if open_at is not None:
                bad.append("line %d: #@FEAT %s opens while %s is still open (a missing #@ENDFEAT)"
                           % (n, m.group(1), open_at[1]))
            open_at = (n, m.group(1))
            ids.append(m.group(1))
            feats[m.group(1)] = [n, None]
        elif l.startswith(END):
            if open_at is None:
                bad.append("line %d: #@ENDFEAT with no #@FEAT above it" % n)
            else:
                feats[open_at[1]][1] = n
                open_at = None
    if open_at is not None:
        bad.append("line %d: #@FEAT %s is never closed" % (open_at[0], open_at[1]))

    dupes = sorted({f for f in ids if ids.count(f) > 1})
    for d in dupes:
        bad.append("#@FEAT %s is declared more than once — the merge would only ever see the first" % d)

    shipped = set(feats)

    # 2. A #@RETIRE for a feature the template still ships is ignored at run time (addon_merge line
    #    ~231). Silently: the block stays on every printer and the author believes it went.
    for n, l in enumerate(lines, 1):
        m = RETIRE.match(l)
        if m and m.group(1) in shipped:
            bad.append("line %d: #@RETIRE %s, but the template still ships that #@FEAT — "
                       "the retirement would be ignored" % (n, m.group(1)))

    # 3. A #@REVISE is the mirror image: it can only act on a block the template also ships, because
    #    the replacement body comes from that block.
    revised = set()
    for n, l in enumerate(lines, 1):
        m = REVISE.match(l)
        if not m:
            continue
        revised.add(m.group(1))
        if m.group(1) not in shipped:
            bad.append("line %d: #@REVISE %s, but no #@FEAT %s in this template — "
                       "there is nothing to revise it to" % (n, m.group(1), m.group(1)))
    for f in sorted(revised & {m.group(1) for m in (RETIRE.match(l) for l in lines) if m}):
        bad.append("#@REVISE and #@RETIRE both name %s — the merge would do neither" % f)

    # 4. A #@DROP must be paired with a block that hands the section back, or it is a delete
    #    instruction with nothing behind it.
    in_block = set()
    for fid, (a, b) in feats.items():
        if b is None:
            continue
        for l in lines[a - 1:b]:
            m = SECTION.match(l)
            if m:
                in_block.add(m.group(1).strip())
    for n, l in enumerate(lines, 1):
        m = DROP.match(l)
        if m and m.group(1) not in in_block:
            bad.append("line %d: #@DROP %s, but no #@FEAT block in this template declares that "
                       "section — the merge would refuse to remove it" % (n, m.group(1)))

    # 5. Two sections of the same name in one template is a config klippy refuses, and it would be
    #    delivered to every fresh install.
    seen = {}
    for n, l in enumerate(lines, 1):
        m = SECTION.match(l)
        if not m:
            continue
        name = m.group(1).strip()
        if name in seen:
            bad.append("line %d: [%s] is declared twice (first at line %d)" % (n, name, seen[name]))
        seen[name] = n

    if bad:
        print("AddOn.cfg.template markers:")
        for b in bad:
            print("  ERROR %s" % b)
        return 1
    print("AddOn.cfg.template: %d features, %d revisions, every marker resolves."
          % (len(shipped), len(revised)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
