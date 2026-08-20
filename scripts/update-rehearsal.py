#!/usr/bin/env python3
# update-rehearsal.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
# Licensed under the GNU AGPLv3 (see LICENSE).
#
# Put this printer back to how it looked before a given kit commit, so the next update can be
# watched doing its work -- and put it back afterwards.
#
# WHY THIS EXISTS. "Switch to main, then switch back" looks like an update test and is not one.
# Every delivery path in this kit is install-if-missing-or-different: addon_merge only ADDS blocks
# that are absent, apply-arco-extras only copies a module that is missing or differs,
# apply-theme-variants only copies a variant that differs. Going down a channel removes none of
# that, so the way back up finds a printer that already has everything, reports success, and does
# nothing. The git half is exercised; the delivery half -- the half that has actually broken in
# this project, repeatedly -- is not touched at all.
#
# A real rehearsal has to start from a real "before". That is what `rewind` builds.
#
# 🔴 ORDER IS THE SAFETY RULE. A Klipper module whose config section is still declared is not a
# missing feature, it is a refused config: klippy stops with "Section ... is not a valid config
# section" and the printer is down. So blocks go first and modules second, and a module is NEVER
# removed while any .cfg in the config directory still declares its section -- it is reported and
# left alone instead. An incomplete rewind is a nuisance; an unbootable printer is not.
#
# 🔴 IT REFUSES TO TOUCH A PRINTING MACHINE, snapshots before it changes anything, and does nothing
# at all without --write.
#
# WHAT IT DOES NOT REWIND, on purpose: local.css, the panel order and Fluidd's card flag. Those are
# not delivered by an update -- they are things the owner ran once, by hand -- so removing them
# would test nothing and lose their work.
#
# Usage:
#   python3 update-rehearsal.py status
#   python3 update-rehearsal.py rewind --to <commit-ish>        # show the plan
#   python3 update-rehearsal.py rewind --to <commit-ish> --write
#     ... then update as usual (ARCO_UPDATE, then restart the klipper service) and watch
#   python3 update-rehearsal.py status                          # what came back
#   python3 update-rehearsal.py restore                         # undo the rehearsal

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

FEAT_RE = re.compile(r'^#@FEAT\s+(\S+)\s*\|', re.M)
END = '#@ENDFEAT'
SECTION_RE = re.compile(r'^\[([^\]]+)\]', re.M)
SNAPDIR = '.arco-rehearsal'


def kit_root(start):
    d = os.path.abspath(start)
    while d != os.path.dirname(d):
        if os.path.isdir(os.path.join(d, '.git')):
            return d
        d = os.path.dirname(d)
    return None


def git(kit, *args):
    return subprocess.run(['git', '-C', kit] + list(args), capture_output=True,
                          text=True, encoding='utf-8', errors='replace')


def at_ref(kit, ref, path):
    """A file's content at some commit, or None if it did not exist there."""
    r = git(kit, 'show', '%s:%s' % (ref, path))
    return r.stdout if r.returncode == 0 else None


def printing(url):
    """True only when we KNOW a job is running. Unreachable Moonraker is not a green light --
    it is reported and the run stops, because 'I could not ask' is not 'nothing is printing'."""
    with urllib.request.urlopen(
            url + '/printer/objects/query?print_stats', timeout=6) as fh:
        st = json.loads(fh.read().decode('utf-8'))
        return st['result']['status']['print_stats']['state'] in ('printing', 'paused')


def extras_list(text):
    """The module list out of apply-arco-extras.sh -- the `for f in ... ; do` line(s)."""
    if not text:
        return []
    m = re.search(r'^for f in (.*?);\s*do', text, re.M | re.S)
    if not m:
        return []
    return re.findall(r'([A-Za-z0-9_]+\.py)', m.group(1))


def feat_blocks(lines):
    """{feature id: (first line, last line)} over the deployed AddOn.cfg."""
    out, fid, start = {}, None, None
    for i, line in enumerate(lines):
        m = FEAT_RE.match(line)
        if m:
            fid, start = m.group(1), i
        elif line.startswith(END) and fid is not None:
            out[fid] = (start, i)
            fid, start = None, None
    return out


def declared_everywhere(cfgdir, skip=None):
    """{section name: file} across every .cfg, so a module is never orphaned by this script."""
    found = {}
    for name in sorted(os.listdir(cfgdir)):
        if not name.endswith('.cfg') or name == skip:
            continue
        try:
            with open(os.path.join(cfgdir, name), encoding='utf-8', errors='replace') as fh:
                for sec in SECTION_RE.findall(fh.read()):
                    found.setdefault(sec.split()[0], name)
        except OSError:
            continue
    return found


def snapshot(cfgdir, klipper, kit, note):
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    dest = os.path.join(cfgdir, SNAPDIR, stamp)
    os.makedirs(dest, exist_ok=True)
    for rel in ('AddOn.cfg', 'unleashed-theme.sh'):
        src = os.path.join(cfgdir, rel)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(dest, rel))
    for rel in ('.theme-variants', '.theme'):
        src = os.path.join(cfgdir, rel)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(dest, rel))
    ext = os.path.join(klipper, 'klippy', 'extras')
    keep = os.path.join(dest, 'extras')
    os.makedirs(keep, exist_ok=True)
    if os.path.isdir(ext):
        for name in sorted(os.listdir(ext)):
            if name.startswith('arco_') or name == 'gcode_shell_command.py':
                shutil.copy2(os.path.join(ext, name), os.path.join(keep, name))
    head = git(kit, 'rev-parse', 'HEAD').stdout.strip()
    with open(os.path.join(dest, 'about.json'), 'w', encoding='utf-8') as fh:
        json.dump({'stamp': stamp, 'kit_head': head, 'note': note,
                   'cfgdir': cfgdir, 'klipper': klipper}, fh, indent=1)
    return dest


def latest_snapshot(cfgdir):
    base = os.path.join(cfgdir, SNAPDIR)
    if not os.path.isdir(base):
        return None
    snaps = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    return os.path.join(base, snaps[-1]) if snaps else None


# ---------------------------------------------------------------- status
def cmd_status(args, kit, cfgdir, klipper):
    tpl = os.path.join(kit, 'config-templates', 'AddOn.cfg.template')
    addon = os.path.join(cfgdir, 'AddOn.cfg')
    if not os.path.isfile(addon):
        print("No %s — nothing deployed here." % addon)
        return 1
    want = set(FEAT_RE.findall(open(tpl, encoding='utf-8').read()))
    have = set(feat_blocks(open(addon, encoding='utf-8').read().splitlines()))
    print("Kit %s on branch %s" % (git(kit, 'rev-parse', '--short', 'HEAD').stdout.strip(),
                                   git(kit, 'rev-parse', '--abbrev-ref', 'HEAD').stdout.strip()))
    print("\nAddOn.cfg feature blocks:")
    print("  %d of %d present" % (len(want & have), len(want)))
    missing = sorted(want - have)
    print("  missing: %s" % (', '.join(missing) if missing else 'none'))

    print("\nKlipper extras the kit ships:")
    mods = extras_list(open(os.path.join(kit, 'scripts', 'apply-arco-extras.sh'),
                            encoding='utf-8').read())
    ext = os.path.join(klipper, 'klippy', 'extras')
    for m in mods:
        src, dst = os.path.join(kit, 'scripts', m), os.path.join(ext, m)
        if not os.path.isfile(dst):
            state = 'MISSING'
        elif open(src, 'rb').read() == open(dst, 'rb').read():
            state = 'current'
        else:
            state = 'differs from the kit'
        print("  %-26s %s" % (m, state))

    print("\nMainsail theme variants:")
    var = os.path.join(cfgdir, '.theme-variants')
    if not os.path.isdir(var):
        print("  not installed")
    else:
        diff = same = 0
        for d in ('shared', 'voron-light', 'voron-dark'):
            sd = os.path.join(kit, 'mainsail-theme', 'variants', d)
            if not os.path.isdir(sd):
                continue
            for f in sorted(os.listdir(sd)):
                a, b = os.path.join(sd, f), os.path.join(var, d, f)
                if os.path.isfile(b) and open(a, 'rb').read() == open(b, 'rb').read():
                    same += 1
                else:
                    diff += 1
                    print("  differs/missing: %s/%s" % (d, f))
        print("  %d current, %d to update" % (same, diff))

    snap = latest_snapshot(cfgdir)
    print("\nRehearsal snapshot: %s" % (snap or 'none'))
    return 0


# ---------------------------------------------------------------- rewind
def cmd_rewind(args, kit, cfgdir, klipper):
    ref = args.to
    if git(kit, 'rev-parse', '--verify', '--quiet', ref + '^{commit}').returncode != 0:
        print("Not a commit in this clone: %s" % ref)
        return 1
    old_tpl = at_ref(kit, ref, 'config-templates/AddOn.cfg.template')
    if old_tpl is None:
        print("No AddOn.cfg template at %s — cannot tell what was new since then." % ref)
        return 1
    old_extras = extras_list(at_ref(kit, ref, 'scripts/apply-arco-extras.sh'))

    addon = os.path.join(cfgdir, 'AddOn.cfg')
    lines = open(addon, encoding='utf-8').read().splitlines(True)
    blocks = feat_blocks([ln.rstrip('\n') for ln in lines])
    old_ids = set(FEAT_RE.findall(old_tpl))
    drop = sorted(fid for fid in blocks if fid not in old_ids)

    # What AddOn.cfg would look like afterwards. Built here rather than at write time, because the
    # module decision below has to be made against the config that will EXIST, not the one that
    # does.
    skip_lines = set()
    for fid in drop:
        a, b = blocks[fid]
        skip_lines.update(range(a, b + 1))
    new_addon = ''.join(ln for i, ln in enumerate(lines) if i not in skip_lines)

    # 🔴 "Does this block declare the section?" is the WRONG question, and an offline test caught me
    # asking it: the owner may have moved that declaration into a file of their own, in which case
    # removing the block takes nothing away and deleting the module orphans it. The right question
    # is what is still declared AFTER the removal -- across every .cfg, including the rewritten one.
    declared_after = declared_everywhere(cfgdir, skip='AddOn.cfg')
    for sec in SECTION_RE.findall(new_addon):
        declared_after.setdefault(sec.split()[0], 'AddOn.cfg')

    now_extras = extras_list(open(os.path.join(kit, 'scripts', 'apply-arco-extras.sh'),
                                  encoding='utf-8').read())
    ext = os.path.join(klipper, 'klippy', 'extras')
    remove_mods, keep_mods = [], []
    for m in now_extras:
        if m in old_extras or not os.path.isfile(os.path.join(ext, m)):
            continue
        sec = m[:-3]                       # arco_presence_sensor.py -> arco_presence_sensor
        where = declared_after.get(sec)
        # The rule this script exists to respect: a declared section with no module is a refused
        # config, not a missing feature.
        if where:
            keep_mods.append((m, where))
        else:
            remove_mods.append(m)

    var = os.path.join(cfgdir, '.theme-variants')
    theme = []
    if os.path.isdir(var):
        for d in ('shared', 'voron-light', 'voron-dark'):
            for name in sorted(os.listdir(os.path.join(kit, 'mainsail-theme', 'variants', d))
                               if os.path.isdir(os.path.join(kit, 'mainsail-theme', 'variants', d))
                               else []):
                rel = 'mainsail-theme/variants/%s/%s' % (d, name)
                old = at_ref(kit, ref, rel)
                dst = os.path.join(var, d, name)
                if old is None or not os.path.isfile(dst):
                    continue
                if open(dst, encoding='utf-8', errors='replace').read() != old:
                    theme.append((rel, dst, old))

    print("Rewinding to %s (%s)" % (ref, git(kit, 'log', '-1', '--format=%h %s', ref).stdout.strip()))
    print("\nAddOn.cfg blocks to remove (%d):" % len(drop))
    for fid in drop:
        print("  %s" % fid)
    print("\nKlipper extras to remove (%d):" % len(remove_mods))
    for m in remove_mods:
        print("  %s" % m)
    if keep_mods:
        print("\nKept, because a config section still declares them:")
        for m, where in keep_mods:
            print("  %-26s declared in %s" % (m, where))
    print("\nTheme variant files to put back (%d)" % len(theme))
    if not (drop or remove_mods or theme):
        print("\nNothing to rewind — this printer already looks like %s." % ref)
        return 0
    if not args.write:
        print("\nShowing only. Add --write to do it.")
        return 0

    snap = snapshot(cfgdir, klipper, kit, 'rewind to %s' % ref)
    print("\nSnapshot: %s" % snap)

    # Blocks first, modules second. Never the other way round: the modules were judged against the
    # config this line writes, so it has to exist before any of them go.
    with open(addon, 'w', encoding='utf-8') as fh:
        fh.write(new_addon)
    print("  AddOn.cfg: removed %d block(s)" % len(drop))

    for m in remove_mods:
        os.remove(os.path.join(ext, m))
        print("  removed klippy/extras/%s" % m)
    for rel, dst, old in theme:
        with open(dst, 'w', encoding='utf-8') as fh:
            fh.write(old)
        print("  restored %s" % rel)

    print("\nNow update the way a tester would:")
    print("  ARCO_UPDATE            (in the Mainsail/Fluidd console)")
    print("  sudo systemctl restart klipper")
    print("Then:  python3 %s status" % os.path.basename(__file__))
    print("Undo:  python3 %s restore" % os.path.basename(__file__))
    return 0


# ---------------------------------------------------------------- restore
def cmd_restore(args, kit, cfgdir, klipper):
    snap = args.From or latest_snapshot(cfgdir)
    if not snap or not os.path.isdir(snap):
        print("No snapshot to restore from.")
        return 1
    about = {}
    try:
        about = json.load(open(os.path.join(snap, 'about.json'), encoding='utf-8'))
    except Exception:
        pass
    print("Restoring %s%s" % (snap, (" (%s)" % about['note']) if about.get('note') else ''))
    if not args.write:
        print("Showing only. Add --write to do it.")
        return 0
    for rel in ('AddOn.cfg', 'unleashed-theme.sh'):
        src = os.path.join(snap, rel)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(cfgdir, rel))
            print("  %s" % rel)
    for rel in ('.theme-variants', '.theme'):
        src = os.path.join(snap, rel)
        if os.path.isdir(src):
            dst = os.path.join(cfgdir, rel)
            shutil.rmtree(dst, ignore_errors=True)
            shutil.copytree(src, dst)
            print("  %s/" % rel)
    ext = os.path.join(klipper, 'klippy', 'extras')
    keep = os.path.join(snap, 'extras')
    if os.path.isdir(keep) and os.path.isdir(ext):
        for name in sorted(os.listdir(keep)):
            shutil.copy2(os.path.join(keep, name), os.path.join(ext, name))
            print("  klippy/extras/%s" % name)
    print("\nRestored. It takes effect when the klipper SERVICE restarts:")
    print("  sudo systemctl restart klipper")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=['status', 'rewind', 'restore'])
    ap.add_argument('--to', help='rewind: the kit commit to look like')
    ap.add_argument('--from', dest='From', help='restore: a specific snapshot directory')
    ap.add_argument('--write', action='store_true', help='actually change something')
    ap.add_argument('--config', default=os.path.expanduser('~/printer_data/config'))
    ap.add_argument('--klipper', default=os.path.expanduser('~/klipper'))
    ap.add_argument('--kit', default=None)
    ap.add_argument('--moonraker', default='http://127.0.0.1:7125')
    args = ap.parse_args()

    kit = args.kit or kit_root(os.path.dirname(os.path.abspath(__file__)))
    if not kit:
        print("Not inside a git clone of the kit — this needs history to know what was new.")
        return 1
    if args.action == 'rewind' and not args.to:
        print("rewind needs --to <commit-ish>")
        return 1
    if args.action != 'status' and args.write:
        try:
            if printing(args.moonraker):
                print("A job is printing or paused. Not touching anything.")
                return 1
        except Exception as exc:
            print("Could not ask Moonraker whether a job is running (%s)." % exc)
            print("Refusing rather than guessing — start Klipper, or pass --moonraker.")
            return 1
    return {'status': cmd_status, 'rewind': cmd_rewind,
            'restore': cmd_restore}[args.action](args, kit, args.config, args.klipper)


if __name__ == '__main__':
    sys.exit(main())
