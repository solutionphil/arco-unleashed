#!/usr/bin/env python3
# addon_merge.py - bring NEW #@FEAT blocks from the kit template into an AddOn.cfg that already exists.
#
#   python3 addon_merge.py check [AddOn.cfg] [template]     report only, change nothing
#   python3 addon_merge.py apply [AddOn.cfg] [template]     append the blocks that are missing
#
# WHY THIS EXISTS. AddOn.cfg is the one file that holds the owner's own settings -- the #@FEAT toggles
# and whatever they added themselves -- so install-addon-cfg.sh only ever CREATES a missing one and
# never overwrites. Correct, and it has a cost nobody noticed until 2026-08-15: a feature added to the
# template reached fresh flashes only. The startup banner and the one-time welcome dialog shipped, and
# every existing printer silently did not get them, including the two testers' and the dev machine's.
#
# WHAT IT WILL NOT DO. It never edits a block that is present, never reorders, never removes, and never
# touches a toggle. Only whole blocks that are absent get appended. That is why the banner was split out
# of the `beeper` feature into one of its own: a change INSIDE an existing block cannot be delivered
# this way, and pretending otherwise would mean rewriting the owner's file.
#
# THE TWO HAZARDS, and what is actually done about them:
#
#  1. "absent" vs "deliberately deleted". Mostly a non-problem, and the reason is worth writing down:
#     turning a feature OFF does NOT remove its block -- addon_features.py prefixes every body line with
#     "#:off:" and leaves the block in place. So an absent block really does mean "the template is newer",
#     not "the owner said no". Only a hand-deletion is ambiguous, so every feature this script adds is
#     recorded, and a recorded feature is never added again. The residual case is one single re-add of a
#     block hand-deleted BEFORE this script first ran -- after that the record makes the removal stick.
#
#  2. Section-name collisions. This is the one that can halt a printer: two [gcode_macro FOO] sections
#     and klippy refuses the whole config with "Option ... in section ... must be specified" or a
#     duplicate-section error, on a machine that was working a moment ago. So every section header in an
#     incoming block is checked against every section already declared anywhere in the config directory,
#     INCLUDING ones currently switched off -- an "#:off:" section is one toggle away from being real.
#     A block that collides is skipped and reported, never merged and never silently renamed.
import sys, os, re, shutil, glob

FEAT = re.compile(r'^#@FEAT\s+(\S+)\s*\|\s*(.*)$')
END = "#@ENDFEAT"
OFF = "#:off:"
# Section headers sit at column 0 in these files; gcode bodies are indented, so this cannot mistake a
# Jinja expression or an array index inside a macro for a section.
SECTION = re.compile(r'^(?:' + re.escape(OFF) + r')?\[([^\]]+)\]\s*$')


def blocks(path):
    """[(feature_id, description, [lines including the #@FEAT and #@ENDFEAT])]"""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return []
    out, i = [], 0
    while i < len(lines):
        m = FEAT.match(lines[i])
        if m:
            j = i + 1
            while j < len(lines) and not lines[j].startswith(END):
                j += 1
            out.append((m.group(1), m.group(2).strip(), lines[i:min(j + 1, len(lines))]))
            i = j
        i += 1
    return out


def sections_in(lines):
    return {m.group(1).strip() for m in (SECTION.match(l) for l in lines) if m}


def declared_everywhere(cfg_dir):
    """Every section name declared by any .cfg in the config directory, switched off ones included."""
    found = {}
    for f in sorted(glob.glob(os.path.join(cfg_dir, "**", "*.cfg"), recursive=True)):
        try:
            for name in sections_in(open(f, encoding="utf-8", errors="replace").read().split("\n")):
                found.setdefault(name, os.path.basename(f))
        except OSError:
            pass
    return found


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else "check"
    if verb not in ("check", "apply"):
        sys.exit("usage: addon_merge.py check|apply [AddOn.cfg] [template]")
    home = os.path.expanduser("~")
    cfg = sys.argv[2] if len(sys.argv) > 2 else os.path.join(home, "printer_data/config/AddOn.cfg")
    here = os.path.dirname(os.path.abspath(__file__))
    tpl = sys.argv[3] if len(sys.argv) > 3 else os.path.join(here, "../config-templates/AddOn.cfg.template")
    state = os.path.join(home, ".arco-unleashed/addon-seeded-features")

    if not os.path.isfile(cfg):
        print("  AddOn.cfg not found (%s) — nothing to merge into." % cfg)
        return 0
    if not os.path.isfile(tpl):
        print("  template not found (%s) — nothing to merge from." % tpl)
        return 0

    have = {f for f, _, _ in blocks(cfg)}
    want = blocks(tpl)
    if not want:
        print("  the template carries no #@FEAT blocks — refusing to guess.")
        return 1
    try:
        seeded = {l.strip() for l in open(state, encoding="utf-8") if l.strip()}
    except OSError:
        seeded = set()

    missing = [(f, d, b) for f, d, b in want if f not in have]
    if not missing:
        print("  AddOn.cfg already carries all %d features — nothing to do." % len(want))
        return 0

    declared = declared_everywhere(os.path.dirname(cfg))
    add, skip = [], []
    for fid, desc, body in missing:
        if fid in seeded:
            skip.append((fid, "added once before and removed since — leaving it out"))
            continue
        clash = sorted(s for s in sections_in(body) if s in declared)
        if clash:
            skip.append((fid, "would redefine %s (already in %s) — klipper would refuse the config"
                         % (", ".join("[%s]" % c for c in clash), declared[clash[0]])))
            continue
        add.append((fid, desc, body))

    for fid, why in skip:
        print("  SKIP %-18s %s" % (fid, why))
    for fid, desc, _ in add:
        print("  %s %-18s %s" % ("would add" if verb == "check" else "adding   ", fid, desc))

    if verb == "check":
        print("  (check only — nothing written. Run with 'apply' to merge %d feature(s).)" % len(add))
        return 0
    if not add:
        print("  nothing to add.")
        return 0

    text = open(cfg, encoding="utf-8").read()
    shutil.copy2(cfg, cfg + ".pre-merge.bak")
    with open(cfg, "w", encoding="utf-8") as fh:
        fh.write(text.rstrip("\n") + "\n")
        for _, _, body in add:
            fh.write("\n" + "\n".join(body).rstrip("\n") + "\n")
    os.makedirs(os.path.dirname(state), exist_ok=True)
    with open(state, "a", encoding="utf-8") as fh:
        for fid, _, _ in add:
            fh.write(fid + "\n")
    # os.fsync on the directory as well: this runs immediately before selfupdate.sh asks for a
    # power-cycle, and the rootfs is mounted commit=120. See the sync in selfupdate.sh.
    print("  merged %d feature(s); previous file kept as %s" % (len(add), os.path.basename(cfg) + ".pre-merge.bak"))
    print("  They take effect when the klipper SERVICE restarts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
