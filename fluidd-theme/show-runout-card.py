#!/usr/bin/env python3
# show-runout-card.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
# Licensed under the GNU AGPLv3 (see LICENSE).
#
# Switch Fluidd's "Runout sensors" card on, so the AMS and USB-stick indicators are visible there
# too.
#
# WHY IT IS NEEDED. The indicators are ordinary Klipper objects, so Fluidd picks them up by itself
# (getRunoutSensors) -- but it renders them in a card of their own, and that card ships DISABLED:
#
#     { id: 'runout-sensors-card', enabled: false, collapsed: false }
#       -- fluidd src/store/layout/state.ts, defaultState()
#
# So a kit that installs the indicators leaves them invisible on the second interface, and nothing
# says why. Mainsail has no equivalent problem: its Miscellaneous panel renders them inline.
#
# 🔴 IT EDITS SOMEBODY'S DASHBOARD, so it asks first and keeps a copy. --write is required, the
# previous value is saved next to the config, and --off puts it back. A layout is a personal
# arrangement; a kit may offer to change it, never just do it.
#
# HOW. Fluidd keeps its layouts in the Moonraker database (namespace 'fluidd', key 'layout.layouts')
# and reads them at load. Two properties of its own loader make a small edit safe:
#   * a stored layout is MERGED with the defaults -- cards missing from it are appended, so this
#     does not have to know about cards a newer Fluidd may add (mutations.ts, setInitLayout);
#   * cards in a stored layout that no longer exist are filtered out, so a stale entry cannot
#     resurrect a removed card.
# That is why only the one flag is touched and everything else is written back verbatim.
#
# Usage:
#   python3 show-runout-card.py            show what it would change
#   python3 show-runout-card.py --write    change it
#   python3 show-runout-card.py --off --write   hide the card again

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

NAMESPACE = 'fluidd'
KEY = 'layout.layouts'
CARD = 'runout-sensors-card'
# Where Fluidd's own default puts it: first container, right after the outputs card. Only used when
# the printer has no stored layout at all -- see below.
DEFAULT_CONTAINER = 'container1'
DEFAULT_AFTER = 'outputs-card'


def get(url):
    req = urllib.request.Request(url + '/server/database/item?namespace=%s&key=%s'
                                 % (NAMESPACE, KEY))
    try:
        with urllib.request.urlopen(req, timeout=10) as fh:
            return json.loads(fh.read().decode('utf-8'))['result']['value']
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None          # nothing stored: Fluidd is running on its defaults
        raise


def post(url, value):
    body = json.dumps({'namespace': NAMESPACE, 'key': KEY, 'value': value}).encode('utf-8')
    req = urllib.request.Request(url + '/server/database/item', data=body, method='POST',
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=10) as fh:
        fh.read()


def patch(layouts, enable=True):
    """Flip the card in every dashboard layout. Returns (layouts, list of what was done).

    Every key starting with 'dashboard' is treated, not just 'dashboard': Fluidd stores
    device-specific variants under that prefix, and changing only one of them would fix the card
    on the desktop and leave it missing on the tablet."""
    notes = []
    for name, containers in sorted(layouts.items()):
        if not name.startswith('dashboard') or not isinstance(containers, dict):
            continue
        found = False
        for container, cards in containers.items():
            if not isinstance(cards, list):
                continue
            for card in cards:
                if isinstance(card, dict) and card.get('id') == CARD:
                    found = True
                    if bool(card.get('enabled')) == enable:
                        notes.append('%s/%s: already %s'
                                     % (name, container, 'on' if enable else 'off'))
                    else:
                        card['enabled'] = enable
                        notes.append('%s/%s: switched %s'
                                     % (name, container, 'ON' if enable else 'OFF'))
        if not found and enable:
            # 🔴 Appending our own entry rather than leaving it to the merge: the merge would add
            # Fluidd's DEFAULT entry, which is exactly the disabled one we are trying to change.
            # Placed after the outputs card, where the default has it, so the dashboard keeps a
            # familiar shape instead of gaining a card at the top.
            # setdefault is not enough: a key that EXISTS holding null hands back None, and this
            # reads a database it does not own. An offline test caught exactly that.
            cards = containers.get(DEFAULT_CONTAINER)
            if not isinstance(cards, list):
                cards = []
                containers[DEFAULT_CONTAINER] = cards
            entry = {'id': CARD, 'enabled': True, 'collapsed': False}
            at = len(cards)
            for i, card in enumerate(cards):
                if isinstance(card, dict) and card.get('id') == DEFAULT_AFTER:
                    at = i + 1
                    break
            cards.insert(at, entry)
            notes.append('%s/%s: added it, switched ON' % (name, DEFAULT_CONTAINER))
    return layouts, notes


def fresh_layout():
    """The minimum to store when a printer has never saved a layout.

    Only the one card. Everything else is filled in by Fluidd's own merge at load, so this does not
    have to carry a copy of a default layout that would go stale."""
    return {'dashboard': {DEFAULT_CONTAINER: [{'id': CARD, 'enabled': True, 'collapsed': False}]}}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--moonraker', default='http://127.0.0.1:7125')
    ap.add_argument('--config', default=os.path.expanduser('~/printer_data/config'))
    ap.add_argument('--off', action='store_true', help='hide the card again')
    ap.add_argument('--write', action='store_true', help='apply (default: show only)')
    # Unattended first-run use, and the ONLY automatic path. The rule above still holds: this
    # refuses the moment a layout exists, so it can never edit an arrangement somebody made --
    # it only fills a dashboard nobody has touched, which is what the macro-group seeder next to
    # it already does. Without it the card stayed hidden on every printer whose owner never went
    # looking in the setup menu, which is the point of shipping the indicators at all.
    ap.add_argument('--seed', action='store_true',
                    help='write, but only when no layout is stored yet (first-run use)')
    args = ap.parse_args()
    enable = not args.off

    try:
        layouts = get(args.moonraker)
    except Exception as exc:
        print("Could not ask Moonraker at %s: %s" % (args.moonraker, exc))
        return 1

    if args.seed:
        args.write = True
        if layouts:
            print("Fluidd already has a stored layout — leaving it alone.")
            return 0

    created = False
    if not layouts:
        if not enable:
            print("Fluidd has no stored layout, so the card is already at its default (hidden).")
            return 0
        layouts, created = fresh_layout(), True
        notes = ['no stored layout yet — storing just this card; Fluidd fills in the rest']
    else:
        layouts, notes = patch(layouts, enable)

    if not notes:
        print("No dashboard layout found to change. Open Fluidd once, then run this again.")
        return 1
    print("Fluidd's %s card:" % CARD)
    for n in notes:
        print("  " + n)
    if all('already' in n for n in notes):
        print("\nNothing to do.")
        return 0
    if not args.write:
        print("\nShowing only. Add --write to apply.")
        return 0

    # A dashboard is somebody's arrangement of their own screen. Keep the previous value where they
    # can find it, and say where.
    if not created:
        bak = os.path.join(args.config, '.fluidd-layout.bak.json')
        try:
            with open(bak, 'w', encoding='utf-8') as fh:
                json.dump(get(args.moonraker), fh, indent=1)
            print("\nPrevious layout saved to %s" % bak)
        except Exception as exc:
            print("\nCould not write the backup (%s) — stopping rather than changing" % exc)
            return 1

    try:
        post(args.moonraker, layouts)
    except Exception as exc:
        print("Writing to Moonraker failed: %s" % exc)
        return 1
    print("Done. Reload Fluidd (F5) — the card is called 'Runout sensors' / 'Auslaufsensoren'.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
