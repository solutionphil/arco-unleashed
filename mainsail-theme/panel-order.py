#!/usr/bin/env python3
# panel-order.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
# Licensed under the GNU AGPLv3 (see LICENSE).
#
# Put the Miscellaneous panel in a sensible order -- on ANY printer, not just the one it was
# written on.
#
# THE PROBLEM. Mainsail renders that panel as fixed groups in a fixed order (fans and output pins,
# then lights, then filament sensors, then sensors) and sorts the first group by
# type=='fan' -> pwm -> controllable -> name. So the AMS and USB-stick indicators always land
# BELOW every fan and switch, and a switch can never appear above a slider. Nothing on the Klipper
# side can change that: renaming only moves the last tiebreaker, and the groups are template order.
#
# What CAN change it is CSS. Every row is a sibling in one container, so a flex column plus `order:`
# rearranges them freely, across group boundaries.
#
# WHY THIS IS A SCRIPT AND NOT A STYLESHEET. The rows carry no name in the DOM -- the panel renders
# them from a v-for keyed by index -- so a rule can only address a row by POSITION. A hand-written
# stylesheet is therefore correct on exactly one printer: turn the beeper feature off, add a fan,
# install KAOS, and every number below the change is wrong, silently. Shipping such a file would
# hand most owners a scrambled panel.
#
# So the positions are computed here, per printer, from what Moonraker actually reports, by
# replaying Mainsail's own sort. The desired order is expressed by NAME, which is stable; the
# numbers are derived.
#
# 🔴 IT PRINTS BEFORE IT WRITES, and that is the safety. This file replicates behaviour that lives
# in someone else's codebase, so it can be wrong -- a Mainsail release may sort differently one day.
# A dry run shows the order it believes the panel currently has; if that does not match the screen,
# nothing below it is trustworthy and the run should be abandoned rather than applied. Verified
# against a real panel on 19.08.2026 (see tests/test-panel-order.sh, which pins the sort down with
# that printer's objects).
#
# Usage:
#   python3 panel-order.py                 show what it would do, change nothing
#   python3 panel-order.py --write         write the block into .theme-variants/local.css
#   python3 panel-order.py --write --rebuild   ... and rebuild .theme/ so it takes effect
#   python3 panel-order.py --order a,b,c   use this order instead of the default
#
# The desired order can also live in .theme-variants/panel-order.txt, one object name per line
# (blank lines and #-comments ignored). Names that this printer does not have are skipped; objects
# not named at all keep their relative order at the end. That is what makes one order shippable to
# printers that are not identical.

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request

# The order this kit prefers, by object name: the indicators and the light first, then the switch
# that belongs to the AMS, then the fans, then the things nobody touches. Names that a given printer
# does not have simply drop out.
DEFAULT_ORDER = [
    'chamber_light',
    'AMS', 'USB_Stick',
    'AMS_Refeed',
    'Fan0',
    'Chamber_fan', 'cooling_fan', 'fan_assist',
    'beeper',
    'probe_pin',
]

# Mainsail: getMiscellaneous (src/store/printer/getters.ts)
MISC_TYPES = ['controller_fan', 'heater_fan', 'fan_generic', 'fan', 'output_pin',
              'pwm_tool', 'pwm_cycle_time']
CONTROLLABLE_FANS = ['fan_generic', 'fan']
PWM_ALWAYS = ['pwm_tool', 'pwm_cycle_time']
# Mainsail: components/mixins/miscellaneous.ts -- rendered in printer-object order, not sorted
LIGHT_TYPES = ['dotstar', 'led', 'neopixel', 'pca9533', 'pca9632']
# Mainsail: getFilamentSensors
SENSOR_TYPES = ['filament_switch_sensor', 'filament_motion_sensor', 'hall_filament_width_sensor']
# Mainsail: getMiscellaneousSensors
MISC_SENSOR_TYPES = ['load_cell']

BEGIN = '/* >>> arco panel-order >>> */'
END = '/* <<< arco panel-order <<< */'


def moonraker(url, path):
    with urllib.request.urlopen(url + path, timeout=10) as fh:
        return json.loads(fh.read().decode('utf-8'))['result']


def split_key(key):
    parts = key.split(' ', 1)
    return (parts[0], parts[1] if len(parts) > 1 else parts[0])


def rows(objects, settings):
    """The rows Mainsail renders, in the order it renders them.

    Group order is the panel template's; the sort inside the first group is getMiscellaneous's."""
    misc, lights, sensors, misc_sensors = [], [], [], []
    for key in objects:
        typ, name = split_key(key)
        if name.startswith('_'):
            continue                      # hidden from every group by name
        if typ in MISC_TYPES:
            cfg = settings.get(key.lower(), {})
            controllable = typ in CONTROLLABLE_FANS
            pwm = controllable
            if typ in ('output_pin', 'pwm_tool', 'pwm_cycle_time'):
                controllable = True
                pwm = bool(cfg.get('pwm', False))
                if typ in PWM_ALWAYS:
                    pwm = True
            misc.append((typ, name, pwm, controllable))
        elif typ in LIGHT_TYPES:
            lights.append(name)
        elif typ in SENSOR_TYPES:
            sensors.append(name)
        elif typ in MISC_SENSOR_TYPES:
            misc_sensors.append(name)
    # fan first, then pwm, then controllable, then name -- exactly the comparator in getters.ts
    misc.sort(key=lambda r: (0 if r[0] == 'fan' else 1, 0 if r[2] else 1,
                             0 if r[3] else 1, r[1].upper()))
    return ([r[1] for r in misc] + lights
            + sorted(sensors, key=lambda n: n.lower())
            + sorted(misc_sensors, key=lambda n: n.lower()))


def norm(name):
    # Match forgivingly: the owner writes 'chamber light', the config says 'chamber_light'.
    return re.sub(r'[^a-z0-9]', '', name.lower())


def arrange(current, wanted):
    """Desired order -> (row name, 1-based DOM position, 1-based visual position).

    Named-but-absent is skipped; present-but-unnamed keeps its relative order at the end, so an
    order written for one printer still does something sensible on another."""
    index = {norm(n): i for i, n in enumerate(current)}
    placed, missing = [], []
    for name in wanted:
        i = index.get(norm(name))
        if i is None:
            missing.append(name)
        elif i not in [p[1] for p in placed]:
            placed.append((current[i], i))
    rest = [(n, i) for i, n in enumerate(current) if i not in [p[1] for p in placed]]
    ordered = placed + rest
    return [(n, i + 1, pos + 1) for pos, (n, i) in enumerate(ordered)], missing, [n for n, _ in rest]


def css_block(plan, container='.miscellaneous-panel > div:last-child'):
    width = max((len(n) for n, _, _ in plan), default=0)
    out = [BEGIN,
           '/* Written by mainsail-theme/panel-order.py -- do not edit by hand: the numbers are',
           '   positions in THIS printer\'s panel and are recomputed when the config changes.',
           '   Re-run  python3 ~/arco-unleashed/mainsail-theme/panel-order.py --write --rebuild',
           '   after adding or removing a fan, an output_pin or a feature.',
           '   display:flex deliberately without !important: collapsing the panel uses an inline',
           '   display:none, and inline beats a stylesheet -- with !important it would break. */',
           '%s{ display:flex; flex-direction:column; }' % container]
    for name, dom, visual in plan:
        out.append('%s > div:nth-child(%d){ order:%d; }%s /* %s */'
                   % (container, dom, visual, ' ' * (3 - len(str(visual))), name))
    if plan:
        last_dom = plan[-1][1]
        out += [
            '/* Mainsail puts its divider at the TOP of every row but the first, which lands in the',
            '   wrong place once the rows move. Replaced by a bottom border, which does not care',
            '   about order. NOT :not(:last-child) -- that counts DOM order, not visual order, so',
            '   the row actually shown last is named explicitly. */',
            '%s > div > hr.v-divider{ display:none; }' % container,
            '%s > div{ border-bottom:1px solid rgba(255,255,255,.08); }' % container,
            '%s > div:nth-child(%d){ border-bottom:none; }' % (container, last_dom)]
    out.append(END)
    return '\n'.join(out) + '\n'


def splice(existing, block):
    """Replace our block, leave every other line of the owner's file alone."""
    if BEGIN in existing and END in existing:
        head = existing.split(BEGIN)[0]
        tail = existing.split(END, 1)[1]
        return head.rstrip('\n') + ('\n\n' if head.strip() else '') + block + tail.lstrip('\n')
    return (existing.rstrip('\n') + '\n\n' if existing.strip() else '') + block


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--config', default=os.path.expanduser('~/printer_data/config'))
    ap.add_argument('--moonraker', default='http://127.0.0.1:7125')
    ap.add_argument('--order', help='comma-separated object names, overrides every other source')
    ap.add_argument('--write', action='store_true', help='write the block (default: dry run)')
    ap.add_argument('--rebuild', action='store_true', help='rebuild .theme/ afterwards')
    args = ap.parse_args()

    var = os.path.join(args.config, '.theme-variants')
    if not os.path.isdir(var):
        print("No %s -- the Arco Mainsail theme is not installed, so there is nothing to style."
              % (var,))
        return 1
    try:
        objects = moonraker(args.moonraker, '/printer/objects/list')['objects']
        settings = moonraker(args.moonraker,
                             '/printer/objects/query?configfile')['status']['configfile']['settings']
    except Exception as exc:
        print("Could not ask Moonraker at %s: %s" % (args.moonraker, exc))
        print("Klipper has to be up for this -- the panel is built from what it reports.")
        return 1

    current = rows(objects, settings)
    if not current:
        print("Moonraker reports nothing the Miscellaneous panel would show.")
        return 1

    if args.order:
        wanted = [w.strip() for w in args.order.split(',') if w.strip()]
        source = '--order'
    else:
        pref = os.path.join(var, 'panel-order.txt')
        if os.path.isfile(pref):
            with open(pref) as fh:
                wanted = [ln.strip() for ln in fh
                          if ln.strip() and not ln.lstrip().startswith('#')]
            source = pref
        else:
            wanted, source = DEFAULT_ORDER, 'the kit default'

    plan, missing, extra = arrange(current, wanted)

    print("The panel as Mainsail builds it today (%d rows):" % len(current))
    for i, name in enumerate(current, 1):
        print("  %2d. %s" % (i, name))
    print("\n🔴 Compare that with the panel on screen. If it does not match, STOP: this script")
    print("   replays Mainsail's own sorting, and a mismatch means that sorting has changed.")
    print("\nOrder from %s:" % (source,))
    for name, dom, visual in plan:
        print("  %2d. %-16s (row %d today)" % (visual, name, dom))
    if missing:
        print("\nNamed but not on this printer, skipped: %s" % ', '.join(missing))
    if extra:
        print("Not named, left at the end: %s" % ', '.join(extra))

    local = os.path.join(var, 'local.css')
    block = css_block(plan)
    if not args.write:
        print("\nDry run. Add --write to put this into %s" % (local,))
        return 0

    existing = ''
    if os.path.isfile(local):
        with open(local, encoding='utf-8') as fh:
            existing = fh.read()
    with open(local, 'w', encoding='utf-8') as fh:
        fh.write(splice(existing, block))
    print("\nWritten to %s (only the marked block; anything else in that file is untouched)."
          % (local,))

    if args.rebuild:
        state = 'light'
        sf = os.path.join(args.config, '.theme-state')
        if os.path.isfile(sf):
            state = open(sf).read().strip() or 'light'
        if state in ('light', 'dark'):
            subprocess.call(['sh', os.path.join(args.config, 'unleashed-theme.sh'), state])
        else:
            print("Theme is set to '%s', so .theme/ was not rebuilt." % (state,))
    else:
        print("Rebuild the theme to see it:  sh %s/unleashed-theme.sh light"
              % (args.config,))
    print("Then hard-reload Mainsail (Ctrl+F5).")
    return 0


if __name__ == '__main__':
    sys.exit(main())
