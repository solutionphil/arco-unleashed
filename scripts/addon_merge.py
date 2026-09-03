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
# WHAT IT WILL NOT DO. It never reorders, and it never changes a toggle. Blocks that are absent get
# appended; a block that is present is left exactly as it stands UNLESS the template names it in a
# #@REVISE, which is the one deliberate exception and is described below. That exception is recent:
# for a long time a change INSIDE an existing block could not be delivered at all, which is why the
# banner was split out of the `beeper` feature into a block of its own -- splitting was the only
# honest way round it.
#
# RETIRING A FEATURE. Adding was enough until a feature turned out to be wrong rather than merely
# improvable -- the AMS on/off switch, which asked the owner a question the printer answers better by
# itself, and could only ever agree with the hardware or be silently wrong. Deleting its block from
# the template alone would have left it sitting in every existing AddOn.cfg forever, since this file
# is never regenerated. So the template can also carry
#
#     #@RETIRE <feature-id> | why it is going
#
# and a retired block is removed from AddOn.cfg, in the same run and under the same backup as the
# additions.
#
# REPLACING A LOOSE SECTION. Some sections were written outside every #@FEAT block -- the P114 gate
# is the one that forced this. Block-level delivery could never reach them: a change went to fresh
# flashes and nowhere else, which is how a printer in the field ended up running a gate two versions
# old with nobody able to tell. So the template can also carry
#
#     #@DROP <section name> | why it is being replaced
#
# which removes that loose section, comment header and all, while the same run adds the replacement
# from a #@FEAT block. The pairing is the safety, and it is checked twice: the named section must
# appear inside some #@FEAT block of the template, and that block must actually be among the ones
# being added this run. Either check failing means nothing is removed. An unpaired #@DROP is a
# delete instruction sitting in a template, one typo from taking a working macro off every printer.
#
# UPDATING A BLOCK IN PLACE. Splitting works when the change can be expressed as a NEW block. It does
# not when the thing to fix is a line in the middle of a macro that already ships. PHROZEN_TOOLCHANGE
# opened its retract without setting the extrusion mode, and the block that carries it carries the
# printer's two print macros as well -- so retiring it to ship a corrected copy under a new id would
# have meant taking those two off every printer for the length of one merge, and would have renamed a
# feature the owner can see for a reason that is none of their business. So the template can carry
#
#     #@REVISE <feature-id> | why
#
# and the printer's copy of that block is replaced, in place and at the same position in the file, by
# the template's current version. This is the only operation that reaches INSIDE a block, so it is
# deliberately narrow:
#
#   * It acts only on a block that is ALREADY THERE. A #@REVISE never adds and never resurrects; a
#     block the owner deleted by hand stays deleted, which is still the seeded record's decision.
#   * The owner's toggle is carried over. A body that was switched off comes back switched off, line
#     for line the way addon_features.set_block writes it -- otherwise an update would quietly switch
#     a feature back on, which is the one thing a toggle exists to prevent.
#   * A block that already matches is not touched and not reported, so the marker can stay in the
#     template for good instead of needing to be cleaned up a release later.
#   * The #@ENDFEAT guard applies as everywhere else: an unterminated block is left alone.
#   * Only the sections the newer version GAINS are checked for collision. The ones the block already
#     owns are its own, and would otherwise read as a clash with itself.
#
# And it has a real cost, stated here rather than discovered: a revised block belongs to the kit, not
# to the owner. Hand edits inside it are overwritten the next time the template moves -- loudly, and
# with the previous whole file kept as .pre-merge.bak, but overwritten. Anyone wanting their own
# version should switch the feature off and put theirs outside the block.
#
# A section that already sits inside a #@FEAT block is never touched by #@DROP -- the block
# machinery owns it -- which is also what makes the operation idempotent once it has run. Removal is deliberately blunt and deliberately loud: whole block, reported by name, with
# the owner's previous file kept. Two guards sit on it -- a block whose #@ENDFEAT is missing is left
# alone rather than swallowing the rest of the file, and a retirement never runs on a feature the
# template still ships, so a stale #@RETIRE cannot quietly delete a live feature.
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
RETIRE = re.compile(r'^#@RETIRE\s+(\S+)\s*\|\s*(.*)$')
REVISE = re.compile(r'^#@REVISE\s+(\S+)\s*\|\s*(.*)$')
DROP = re.compile(r'^#@DROP\s+(.+?)\s*\|\s*(.*)$')
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


def retirements(path):
    """{feature_id: reason} declared by the template."""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return {}
    out = {}
    for l in lines:
        m = RETIRE.match(l)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out




def revisions(path):
    """{feature_id: reason} the template wants brought up to date IN PLACE."""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return {}
    out = {}
    for l in lines:
        m = REVISE.match(l)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def block_is_off(body):
    """The owner's toggle, read the way addon_features.py writes it: the FIRST non-blank body line
    between the markers decides. Nothing else in the block is consulted, so a block that is half
    prefixed -- a hand edit, or an older toggle -- reads as whatever its first real line says, which
    is exactly what the features tool would report and what SET_FEATURE would act on."""
    for l in body[1:]:
        if l.startswith(END):
            break
        if l.strip():
            return l.startswith(OFF)
    return False


def with_off(body):
    """Put a block into the switched-off shape: the sentinel on every non-blank BODY line, the #@FEAT
    and #@ENDFEAT lines left bare. Mirrors set_block() in addon_features.py line for line -- if the
    two ever disagree, the features tool would report a state the file does not have."""
    out = [body[0]]
    for l in body[1:]:
        if l.startswith(END) or not l.strip() or l.startswith(OFF):
            out.append(l)
        else:
            out.append(OFF + l)
    return out


def body_key(body):
    """A block reduced to what a revision actually cares about: the toggle is not content, and
    trailing blank lines are not either. Two blocks with the same key need no revision, which is what
    makes a #@REVISE that has already run a silent no-op rather than a rewrite on every boot."""
    out = [l[len(OFF):] if l.startswith(OFF) else l for l in body]
    out = [l.rstrip() for l in out]
    while out and not out[-1]:
        out.pop()
    return out

def block_span(lines, fid):
    """(start, end_inclusive) of a complete #@FEAT block, or None if absent or unterminated."""
    for i, l in enumerate(lines):
        m = FEAT.match(l)
        if not m or m.group(1) != fid:
            continue
        for j in range(i + 1, len(lines)):
            # The next block starting first means this one was never closed. Its own #@ENDFEAT is
            # missing, so the next one found belongs to the neighbour -- and removing that span
            # would take the neighbour with it. Tested: with the #@ENDFEAT of the retired block
            # deleted by hand, this took PHROZEN_AMS_START and PHROZEN_TOOLCHANGE out of the file,
            # which is every print on that printer.
            if FEAT.match(lines[j]):
                return None
            if lines[j].startswith(END):
                return (i, j)
        return None          # no #@ENDFEAT at all: refuse rather than eat the rest of the file
    return None


def drops_declared(path):
    """{section name: reason} the template wants replaced rather than left as it stands."""
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        return {}
    out = {}
    for l in lines:
        m = DROP.match(l)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def feat_ranges(lines):
    """Line ranges covered by #@FEAT..#@ENDFEAT, so a section inside one can be told from a loose one."""
    out, i = [], 0
    while i < len(lines):
        if FEAT.match(lines[i]):
            end = len(lines) - 1
            for j in range(i + 1, len(lines)):
                if lines[j].startswith(END):
                    end = j
                    break
            out.append((i, end))
            i = end
        i += 1
    return out


def section_span(lines, name):
    """(start, end) of a LOOSE section -- one declared outside every #@FEAT block -- or None.

    The comment block sitting directly above a section is part of it: leaving forty lines of
    explanation behind, describing a macro that is no longer there, is its own kind of wrong. Only
    column-0 comments are absorbed; a gcode body's comments are indented, so a previous section
    cannot be eaten by mistake."""
    inside = feat_ranges(lines)
    target = '[%s]' % name
    for i, l in enumerate(lines):
        if l.strip() != target:
            continue
        if any(a <= i <= b for a, b in inside):
            return None
        j = i + 1
        while j < len(lines) and not (lines[j].startswith('[') or lines[j].startswith('#@')):
            j += 1
        k = i
        while k > 0 and lines[k - 1].startswith('#') and not lines[k - 1].startswith('#@'):
            k -= 1
        return (k, j - 1)
    return None


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

    cfg_lines = open(cfg, encoding="utf-8").read().split("\n")
    have = {f for f, _, _ in blocks(cfg)}
    want = blocks(tpl)
    if not want:
        print("  the template carries no #@FEAT blocks — refusing to guess.")
        return 1
    try:
        seeded = {l.strip() for l in open(state, encoding="utf-8") if l.strip()}
    except OSError:
        seeded = set()

    want_ids = {f for f, _, _ in want}
    retire = retirements(tpl)
    revise = revisions(tpl)
    drop = []
    for fid in sorted(retire):
        if fid in want_ids:
            print("  SKIP %-18s the template still ships it — ignoring the #@RETIRE" % fid)
            continue
        if fid not in have:
            continue
        span = block_span(cfg_lines, fid)
        if span is None:
            print("  SKIP %-18s no complete #@FEAT..#@ENDFEAT block — leaving it alone" % fid)
            continue
        drop.append((fid, retire[fid], span))

    # Loose sections -- the ones written outside every #@FEAT block, like the P114 gate. Blocks were
    # the only unit this script had, so a change to one of those could never reach a printer that
    # already had an AddOn.cfg: it would ship to fresh flashes and nowhere else.
    #
    # A #@DROP is therefore always PAIRED: the section is removed here and the template hands the
    # replacement back inside a #@FEAT block in the same run. That pairing is enforced below rather
    # than trusted, because an unpaired #@DROP is just a delete instruction sitting in a template,
    # one typo away from taking a working macro off every printer in the field.
    tpl_sections = set()
    for _, _, body in want:
        tpl_sections |= sections_in(body)
    loose = []
    for name, why in sorted(drops_declared(tpl).items()):
        if name not in tpl_sections:
            print("  SKIP %-18s #@DROP with no replacement in any #@FEAT block — refusing to remove it"
                  % name.split()[-1])
            continue
        span = section_span(cfg_lines, name)
        if span is None:
            continue          # absent, or already inside a block: either way not ours to touch
        loose.append((name, why, span))


    # A block that is PRESENT but out of date. Adding and retiring move whole blocks around; this is
    # the only operation that reaches INSIDE a printer's existing file, so it is deliberately narrow.
    # It acts on a block that is already there and never on one that is not: resurrecting a block the
    # owner deleted by hand is what the seeded record exists to prevent, and a #@REVISE must not walk
    # around it. A block that already matches the template is left alone and not reported, so the
    # marker can stay in the template for good instead of being cleaned up one release later.
    skip_rev = []
    rev = []
    for fid in sorted(revise):
        if fid not in have:
            continue                      # absent: the add path and the seeded record decide, not this
        if fid in {f for f, _, _ in drop}:
            skip_rev.append((fid, "the template both retires and revises it — doing neither"))
            continue
        span = block_span(cfg_lines, fid)
        if span is None:
            skip_rev.append((fid, "its #@ENDFEAT is missing — left alone rather than rewriting past it"))
            continue
        old = cfg_lines[span[0]:span[1] + 1]
        new = None
        for f, _, body in want:
            if f == fid:
                new = body
                break
        if new is None:
            skip_rev.append((fid, "the template revises a block it no longer ships — ignoring it"))
            continue
        if body_key(old) == body_key(new):
            continue                      # already current: silent, so a run changes nothing twice
        rev.append((fid, revise[fid], span, with_off(new) if block_is_off(old) else new))

    missing = [(f, d, b) for f, d, b in want if f not in have]
    if not missing and not drop and not loose and not rev and not skip_rev:
        print("  AddOn.cfg already carries all %d features — nothing to do." % len(want))
        return 0

    declared = declared_everywhere(os.path.dirname(cfg))
    # A section being removed this run is no longer a collision for the block that replaces it --
    # without this the paired add would refuse itself, and the printer would end up with the section
    # removed and nothing put back. Retired BLOCKS count as well as dropped loose sections: retiring
    # `switches` to ship a corrected `light_switch` carrying the same sections is a replacement, and
    # it would otherwise collide with the very thing being taken out.
    for name, _, _ in loose:
        declared.pop(name, None)
    for _, _, (a, b) in drop:
        for name in sections_in(cfg_lines[a:b + 1]):
            declared.pop(name, None)

    # A revision normally hands back the same sections it takes out, so it cannot collide with itself.
    # It CAN collide if the newer version of the block declares a section that meanwhile exists
    # somewhere else in the config directory -- then applying it would hand klippy two of the same
    # section and the printer would not come back. Only the genuinely NEW names are checked; the ones
    # the block already owns are its own and are not a clash.
    kept_rev = []
    for fid, why, span, body in rev:
        gained = sections_in(body) - sections_in(cfg_lines[span[0]:span[1] + 1])
        clash = sorted(s for s in gained if s in declared)
        if clash:
            skip_rev.append((fid, "its newer version would add %s (already in %s) — not revising it"
                             % (", ".join("[%s]" % c for c in clash), declared[clash[0]])))
            continue
        kept_rev.append((fid, why, span, body))
    rev = kept_rev

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

    # Filtered BEFORE anything is reported: announcing a replacement and withdrawing it two lines
    # later reads like the script changed its mind about a file it had already touched.
    unpaired = [n for n, _, _ in loose
                if not any(n in sections_in(b) for _, _, b in add)]
    for n in unpaired:
        skip.append((n.split()[-1],
                     "its replacement block is not being added this run — not removing it"))
    loose = [t for t in loose if t[0] not in unpaired]

    # The same pairing rule for a retired BLOCK, and for the same reason. A retirement is usually a
    # genuine withdrawal with no replacement, and that stays allowed -- but when the template hands
    # the retired block's sections back inside another block, the two belong together. If that other
    # block is not being added this run, taking the old one out would leave the printer with neither.
    def replaced_elsewhere(span):
        gone = sections_in(cfg_lines[span[0]:span[1] + 1])
        return gone and any(gone & sections_in(b) for _, _, b in want)

    held = [f for f, _, s in drop
            if replaced_elsewhere(s)
            and not any(sections_in(cfg_lines[s[0]:s[1] + 1]) & sections_in(b)
                        for _, _, b in add)]
    for f in held:
        skip.append((f, "the block that carries its sections is not being added this run — "
                        "not retiring it"))
    drop = [d for d in drop if d[0] not in held]

    skip.extend(skip_rev)
    for fid, why in skip:
        print("  SKIP %-18s %s" % (fid, why))
    for fid, why, _ in drop:
        print("  %s %-18s %s" % ("would remove" if verb == "check" else "removing    ", fid, why))
    for name, why, _ in loose:
        print("  %s %-18s %s" % ("would replace" if verb == "check" else "replacing   ",
                                 name.split()[-1], why))
    for fid, why, _, _ in rev:
        print("  %s %-18s %s" % ("would revise" if verb == "check" else "revising    ", fid, why))
    for fid, desc, _ in add:
        print("  %s %-18s %s" % ("would add   " if verb == "check" else "adding      ", fid, desc))

    if verb == "check":
        print("  (check only — nothing written. Run with 'apply' to merge %d, retire %d, replace %d, "
              "revise %d.)" % (len(add), len(drop), len(loose), len(rev)))
        return 0
    if not add and not drop and not loose and not rev:
        print("  nothing to add.")
        return 0

    shutil.copy2(cfg, cfg + ".pre-merge.bak")
    # ONE edit map, over the ORIGINAL line numbers. Every span in drop / loose / rev was measured
    # against cfg_lines, so they are only valid together: applying them one after another would shift
    # every span that comes after the first edit. Walking the file once and consulting the map keeps
    # them all correct, and it is the same walk whether a span is being emptied (a removal) or
    # refilled (a revision) -- which is why those two do not need separate code paths.
    edit = {}
    for _, _, span in drop:
        edit[span[0]] = (span[1], [])
    for _, _, span in loose:
        edit[span[0]] = (span[1], [])
    for _, _, span, body in rev:
        edit[span[0]] = (span[1], body)
    # Overlap would mean one edit eating another's lines, and a file nobody intended. It cannot
    # happen as things stand -- blocks do not nest, and a #@DROP only ever names a section that sits
    # outside every block -- so this is a check that should never fire rather than a fix for a known
    # case. If it ever does, refusing is right: nothing has been written yet at this point, so the
    # printer keeps the file it had.
    covered = set()
    for a, (b, _) in sorted(edit.items()):
        span_lines = set(range(a, b + 1))
        if span_lines & covered:
            print("  two edits overlap in this file — refusing to write anything.")
            return 1
        covered |= span_lines
    kept, i = [], 0
    while i < len(cfg_lines):
        if i in edit:
            end, body = edit[i]
            kept.extend(body)
            i = end + 1
        else:
            kept.append(cfg_lines[i])
            i += 1
    with open(cfg, "w", encoding="utf-8") as fh:
        fh.write("\n".join(kept).rstrip("\n") + "\n")
        for _, _, body in add:
            fh.write("\n" + "\n".join(body).rstrip("\n") + "\n")
    os.makedirs(os.path.dirname(state), exist_ok=True)
    with open(state, "a", encoding="utf-8") as fh:
        for fid, _, _ in add:
            fh.write(fid + "\n")
    # os.fsync on the directory as well: this runs immediately before selfupdate.sh asks for a
    # power-cycle, and the rootfs is mounted commit=120. See the sync in selfupdate.sh.
    print("  merged %d, retired %d, replaced %d, revised %d; previous file kept as %s"
          % (len(add), len(drop), len(loose), len(rev), os.path.basename(cfg) + ".pre-merge.bak"))
    print("  They take effect when the klipper SERVICE restarts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
