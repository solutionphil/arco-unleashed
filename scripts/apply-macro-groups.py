#!/usr/bin/env python3
# apply-macro-groups.py — sort the macro wall into groups, once, on a printer that has none.
#
# WHAT THE PROBLEM IS. A stock Arco running this kit exposes well over a hundred macros, and with KAOS
# switched on it is past two hundred. Mainsail and Fluidd both render that as one undifferentiated wall,
# in which PAUSE sits next to a calibration routine that homes the head. Grouping it is the difference
# between a control panel and a list.
#
# WHY IT IS NOT A CONFIG FILE. Both interfaces keep this in Moonraker's database, in their own namespace
# and in two different shapes: Mainsail a dict of groups keyed by id, Fluidd a flat list of macros plus a
# separate list of categories. So it has to be written through the HTTP API after Moonraker is up, which
# is why it is a service and not something the image can carry as a file.
#
# 🔴 SEEDS ONLY ON AN EMPTY WALL. If the owner has ANY group of their own, this does nothing at all and
# says so. Arranging your own macros is exactly the kind of work nobody should lose to an update, and the
# first version of this script -- written to set the dev printer up by hand -- began by assigning
# `macrogroups = {}`. That is correct for a one-off and would have been destructive as a shipped default.
#
# 🔴 IDS ARE REUSED, NEVER RE-ROLLED. Every Mainsail group becomes a dashboard panel called
# "macrogroup_<id>", and the widescreen/desktop/tablet/mobile layouts each reference that id. Re-running
# with fresh UUIDs tears up every arranged dashboard -- 24 references across four layouts, the first time
# this was measured. So a group whose NAME already exists keeps its old id.
#
# THE THREE VISIBILITY CLASSES are the point of the exercise, more than the grouping is:
#   always      harmless at any moment (queries, light, pause/resume)
#   pause_only  hidden while printing, wanted while paused (filament work)
#   idle_only   idle only -- homes, heats, calibrates, or restarts a service
# Anything that would disturb or destroy a running print is therefore out of reach while one is running,
# rather than one mis-tap away.
#
# Usage:  python3 apply-macro-groups.py [--force]
#         --force re-seeds even when groups exist (ids of same-named groups are still reused).
import json, sys, urllib.request, uuid

API = "http://127.0.0.1:7125"
FORCE = "--force" in sys.argv


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode())


def get(ns, key, default):
    try:
        return call("GET", "/server/database/item?namespace=%s&key=%s" % (ns, key))["result"]["value"]
    except Exception:
        return default


A, P, I = "always", "pause_only", "idle_only"

# Klipper hides macros whose name starts with "_", so only the visible ones are worth placing. Everything
# visible that is NOT named here is a call target rather than a button -- it gets hidden instead, which is
# what keeps the wall short.
GROUPS = [
    ("Printing", [("PAUSE", A), ("RESUME", A), ("CANCEL_PRINT", A),
                  ("M600", A), ("M601", A), ("M84", I)]),
    ("Filament & AMS", [("LOAD_FILAMENT", P), ("UNLOAD_FILAMENT", P),
                        ("AMS_ON", I), ("AMS_OFF", I), ("AMS_STATUS", A),
                        ("MAGIC_AMS_ON", I), ("MAGIC_AMS_OFF", I),
                        ("MAGIC_AMS_STAGE", I), ("MAGIC_AMS_STATUS", A)]),
    ("Calibration", [(m, I) for m in
                     ["G29", "G30", "G31", "G40", "bed_screw_adjust", "SCREWS_TILT_CALCULATE",
                      "Z_TILT_ADJUST", "SHAPER_CALIBRATE", "CALIBRATE_SHAPER_NEW", "PID_BED",
                      "PID_NOZZLE", "M303", "M304", "BELT_TENSION", "probe_off", "probe_up"]]),
    ("Maintenance", [("CLEAN_IDLERS", I), ("CLEAN_IDLERS_STOP", A),
                     ("BELT_WARMUP", I), ("TOGGLE_LIGHT", A), ("SWITCH_THEME", A)]),
    ("Kit & Updates", [("ARCO_UPDATE", I), ("ARCO_UPDATE_CHECK", A)]),
    # KAOS is one group rather than scattered through the others. It is a separate project the owner
    # switched on deliberately, and when it is off none of these macros exist -- the group then simply
    # does not appear, instead of leaving five half-empty groups behind.
    ("KAOS", [("KAOS_ON", I), ("KAOS_OFF", I), ("KAOS_UPDATE", I), ("KAOS_STATUS", A),
              ("KAOS_MENU", A), ("KAOS_MENU_TEXT", A), ("KAOS_HEALTH_CHECK", A),
              ("KAOS_PAUSE", A), ("KAOS_RESUME", A),
              ("KAOS_LIGHTS_ON", A), ("KAOS_LIGHTS_OFF", A), ("KAOS_LIGHTS_TOGGLE", A),
              ("KAOS_FILAMENT_LOAD", P), ("KAOS_FILAMENT_UNLOAD", P),
              ("TOOLCHANGE", I), ("ORCA_PURGE", I),
              ("BED_MESH_CALIBRATE", I), ("BED_MESH_CALIBRATE_CUSTOM", I),
              ("Z_TILT_ONCE", I), ("Z_TILT_CLEAR", I),
              ("KAOS_SET_BOARD_FAN_MODE", A), ("AUTHORIZE_POWER_LOSS_RECOVERY", A),
              ("M300", A), ("PRZ_GEOMETRY", A), ("PRZ_RUNTIME_STATE", A)]),
]
FLAGS = {A: (True, True), P: (False, True), I: (False, False)}   # (showInPrinting, showInPause)


def main():
    try:
        objs = call("GET", "/printer/objects/list")["result"]["objects"]
    except Exception as e:
        print("[macro-groups] Moonraker did not answer (%s) — nothing done." % e.__class__.__name__)
        return 0
    have = sorted({o.split("gcode_macro ", 1)[1] for o in objs if o.startswith("gcode_macro ")})
    if not have:
        print("[macro-groups] no macros reported — nothing done.")
        return 0
    visible = [m for m in have if not m.startswith("_")]

    ms = get("mainsail", "macros", {}) or {}
    fl = get("fluidd", "macros", {}) or {}
    ms_groups = ms.get("macrogroups") or {}
    fl_cats = fl.get("categories") or []
    if (ms_groups or fl_cats) and not FORCE:
        print("[macro-groups] this printer already has %d Mainsail group(s) and %d Fluidd "
              "categor(ies) — leaving them alone." % (len(ms_groups), len(fl_cats)))
        return 0

    grouped = {m for _, members in GROUPS for m, _ in members}
    hide = [m for m in visible if m not in grouped]
    placed = [(name, [(m, c) for m, c in members if m in have]) for name, members in GROUPS]
    placed = [(name, members) for name, members in placed if members]
    if not placed:
        print("[macro-groups] none of the known macros are on this printer — nothing done.")
        return 0

    # Mainsail: a dict of groups keyed by id, each carrying its own macro list.
    old_ids = {g.get("name"): gid for gid, g in ms_groups.items() if isinstance(g, dict)}
    ms["macrogroups"] = {}
    for name, members in placed:
        ms["macrogroups"][old_ids.get(name) or str(uuid.uuid4())] = {
            "name": name, "color": "primary", "colorCustom": "#fff",
            "showInStandby": True,
            "showInPause": any(FLAGS[c][1] for _, c in members),
            "showInPrinting": any(FLAGS[c][0] for _, c in members),
            "macros": [{"pos": i + 1, "name": m, "color": "group", "showInStandby": True,
                        "showInPrinting": FLAGS[c][0], "showInPause": FLAGS[c][1]}
                       for i, (m, c) in enumerate(members)],
        }
    call("POST", "/server/database/item",
         {"namespace": "mainsail", "key": "macros", "value": ms})

    # Fluidd: one flat list plus separate categories, and only a single flag -- it knows
    # disabledWhilePrinting but has no separate notion of "allowed while paused". pause_only therefore
    # collapses into "not while printing", which is the safe direction.
    old_cats = {c.get("name"): c.get("id") for c in fl_cats if isinstance(c, dict)}
    cats, stored = [], []
    for name, members in placed:
        cid = old_cats.get(name) or str(uuid.uuid4())
        cats.append({"id": cid, "name": name})
        for m, c in members:
            stored.append({"alias": "", "visible": True, "disabledWhilePrinting": c != A,
                           "color": "", "categoryId": cid, "name": m})
    for m in hide:
        stored.append({"alias": "", "visible": False, "disabledWhilePrinting": True,
                       "color": "", "categoryId": None, "name": m})
    fl["categories"], fl["stored"] = cats, stored
    fl.setdefault("expanded", [0])
    call("POST", "/server/database/item", {"namespace": "fluidd", "key": "macros", "value": fl})

    n = {A: 0, P: 0, I: 0}
    for _, members in placed:
        for _, c in members:
            n[c] += 1
    print("[macro-groups] %d group(s): %d always available, %d only outside a print, "
          "%d idle only, %d hidden call targets."
          % (len(placed), n[A], n[P], n[I], len(hide)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
