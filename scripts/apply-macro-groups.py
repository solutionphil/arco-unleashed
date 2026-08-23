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
import json, os, sys, urllib.request, uuid

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


def wrapped_macros():
    """Macro names Mainsail will not render, however they are grouped.

    🔴 MAINSAIL SKIPS EVERY gcode_macro CARRYING rename_existing. Not a bug and not configurable --
    its getMacros reads `if ("rename_existing" in f) return`, because such a macro overrides a native
    command and would otherwise appear twice. Placing one in a group produces an entry that renders
    nowhere: Settings shows it as "Deleted macro" with no group control, and the panel simply omits
    it. Seven of ours were in that state, which is how this was found.

    FLUIDD HAS NO SUCH RULE and draws them perfectly well, so this is deliberately asymmetric: the
    names come out of the Mainsail groups and stay in the Fluidd categories. Taking them from both
    would remove working buttons for no reason.

    Read from configfile.settings rather than kept as a list here, because that is where the truth
    is and it follows whatever the owner's config does -- including KAOS, which wraps the same two.
    An unreachable Moonraker means an empty set, so nothing is pruned on a guess.
    """
    try:
        st = call("GET", "/printer/objects/query?configfile=settings")
        cfg = st["result"]["status"]["configfile"]["settings"]
    except Exception:
        return set()
    pre = "gcode_macro "
    return {k[len(pre):].lower() for k, v in cfg.items()
            if k.startswith(pre) and isinstance(v, dict) and "rename_existing" in v}


A, P, I = "always", "pause_only", "idle_only"

# Klipper hides macros whose name starts with "_", so only the visible ones are worth placing. Everything
# visible that is NOT named here is a call target rather than a button -- it gets hidden instead, which is
# what keeps the wall short.
# Macros the kit used to ship and has since withdrawn. They are removed from whatever group or
# category they were sorted into, on both interfaces -- otherwise a printer that has been running for
# a while keeps a button for a macro that no longer exists, and the button does nothing when pressed.
# Add to this list when a macro is retired, never as a way of hiding one that still exists.
RETIRED = ("AMS_ON", "AMS_OFF", "AMS_STATUS", "MAGIC_AMS_ON", "MAGIC_AMS_OFF", "MAGIC_AMS_STAGE")

# Macros that still EXIST and still work, but no longer belong on the wall. Kept separate from
# RETIRED on purpose, because the two mean different things and the message says which happened.
#
#   TOGGLE_LIGHT              the chamber light is a switch in Miscellaneous now, and two controls
#                             for one lamp is one too many
#   AMS_SLOTS, AMS_REFEED     both live inside the AMS_SETUP dialog. They stay as commands for
#                             anyone who prefers typing, but three buttons for one dialog is what
#                             the dialog was built to avoid.
#
# 🔴 Being absent from GROUPS is not enough. Top-up only ever ADDS, so a macro sorted into a group
# by an earlier version stays there forever unless it is named here. That is how AMS_REFEED came to
# sit next to AMS_SETUP on the dev printer after the dialog landed.
UNGROUPED = ("TOGGLE_LIGHT", "AMS_SLOTS", "AMS_REFEED")

GROUPS = [
    ("Printing", [("PAUSE", A), ("RESUME", A), ("CANCEL_PRINT", A),
                  ("M600", A), ("M601", A), ("M84", I)]),
    ("Filament & AMS", [("LOAD_FILAMENT", P), ("UNLOAD_FILAMENT", P),
                        ("FILA_STATUS", A), ("ARCO_FILA_EMPTY", I),
                        ("AMS_SETUP", I),
                        ("MAGIC_AMS_STATUS", A)]),
    ("Calibration", [(m, I) for m in
                     ["G29", "G30", "G31", "G40", "bed_screw_adjust", "Z_TILT_LEVEL",
                      "SCREWS_TILT_CALCULATE",
                      "Z_TILT_ADJUST", "SHAPER_CALIBRATE", "CALIBRATE_SHAPER_NEW", "PID_BED",
                      "PID_NOZZLE", "M303", "M304", "BELT_TENSION", "probe_off", "probe_up"]]),
    ("Maintenance", [("CLEAN_IDLERS", I), ("CLEAN_IDLERS_STOP", A),
                     ("BELT_WARMUP", I), ("SWITCH_THEME", A)]),
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


def topup(have, ms, fl, ms_groups, fl_cats):
    """Place macros that appeared AFTER the groups were made, without touching anything arranged.

    The seed runs once, on an empty wall, and then never again -- which is what protects an owner's own
    arrangement. The cost showed up the moment KAOS was switched on: 21 macros appeared that no group
    claimed, so they sat outside the grouping entirely, and in Fluidd they were not even hidden, because
    the hidden list had been computed at seed time. A Phrozen firmware update that adds a macro does the
    same thing.

    🔴 THE RULE IS "UNPLACED ONLY". A macro is added only if it is in no group at all. Somebody who moved
    KAOS_PAUSE into a group of their own keeps it there and gets no duplicate; somebody who deleted a
    macro from a group on purpose does not get it pushed back. Nothing is ever removed, reordered, or
    renamed here -- this only fills holes that nobody has an opinion about yet.
    """
    wrapped = wrapped_macros()
    known = {m: c for _, members in GROUPS for m, c in members}

    # Macros the KIT withdrew, cleared out of the groups they were sorted into. A named list rather
    # than "everything that is not registered right now", which looks equivalent and is not: switch
    # KAOS off and twenty-five of its macros stop being registered, and pruning by that rule would
    # empty their group and re-append them in a different order the next time it is switched on.
    # Only the kit can know that a macro is gone for good rather than gone for now.
    dropped_ms = dropped_fl = 0
    for g in ms_groups.values():
        if not isinstance(g, dict):
            continue
        lst = g.get("macros")
        if not isinstance(lst, list):
            continue
        keep = [e for e in lst
                if not (isinstance(e, dict)
                        and (e.get("name") in RETIRED + UNGROUPED
                             or (e.get("name") or "").lower() in wrapped))]
        if len(keep) != len(lst):
            dropped_ms += len(lst) - len(keep)
            for i, e in enumerate(keep):     # pos is 1-based and Mainsail sorts by it
                e["pos"] = i + 1
            g["macros"] = keep
    ms_by_name = {g.get("name"): g for g in ms_groups.values() if isinstance(g, dict)}
    ms_placed = {e.get("name") for g in ms_groups.values() if isinstance(g, dict)
                 for e in g.get("macros", []) if isinstance(e, dict)}
    added_ms = 0
    for name, members in GROUPS:
        g = ms_by_name.get(name)
        if not g:
            continue                      # a group we never made, or one KAOS never created -- leave it
        lst = g.setdefault("macros", [])
        for m, c in members:
            if m.lower() in wrapped:
                continue          # Mainsail cannot draw it; Fluidd gets it below
            if m in have and m not in ms_placed:
                lst.append({"pos": len(lst) + 1, "name": m, "color": "group", "showInStandby": True,
                            "showInPrinting": FLAGS[c][0], "showInPause": FLAGS[c][1]})
                ms_placed.add(m)
                added_ms += 1
        # A group's own panel flags have to widen with it: a KAOS group that held only always-safe
        # macros was marked "show while printing", and the filament ones arriving now must not drag the
        # whole panel into a print.
        g["showInPause"] = any(e.get("showInPause") for e in lst) or g.get("showInPause", False)
        g["showInPrinting"] = any(e.get("showInPrinting") for e in lst) or g.get("showInPrinting", False)
    # 🔴 AND THE MODE, in the top-up path too. Setting it only while seeding was right until an image
    # that had already seeded its groups took an update: the groups were all there, "Simple" hid every
    # one of them, and top-up cheerfully added macros to a panel nobody could see. Reported from a
    # printer flashed from an older image and updated through Mainsail (2026-08-21).
    #
    # Mainsail shows "Simple" both for an explicit "simple" and for no key at all, so the earlier
    # reasoning -- absence means nobody chose, an explicit value means somebody did -- cannot be relied
    # on from the outside. Instead: set it ONCE, record that we did, and never touch it again. Somebody
    # who switches back to Simple afterwards keeps it, because the marker stops us from fighting them
    # at every boot.
    mode_set = False
    ours = {name for name, _ in GROUPS}
    have_ours = any(isinstance(g, dict) and g.get("name") in ours for g in ms_groups.values())
    mark = os.path.expanduser("~/.arco-unleashed/mainsail-expert-set")
    if have_ours and ms.get("mode") != "expert" and not os.path.exists(mark):
        ms["mode"] = "expert"
        mode_set = True
        try:
            os.makedirs(os.path.dirname(mark), exist_ok=True)
            open(mark, "w").close()
        except OSError:
            pass
        print("[macro-groups] Mainsail was on Simple, which hides groups entirely — switched to Expert "
              "once. Switch it back in the macro settings if you prefer the flat list.")
    if added_ms or dropped_ms or mode_set:
        call("POST", "/server/database/item", {"namespace": "mainsail", "key": "macros", "value": ms})

    # Fluidd: one flat list. "Placed" means it carries a categoryId; anything else is fair game.
    stored = fl.get("stored") or []
    keep = [e for e in stored
            if not (isinstance(e, dict) and e.get("name") in RETIRED + UNGROUPED)]
    dropped_fl = len(stored) - len(keep)
    stored = keep
    cat_id = {c.get("name"): c.get("id") for c in fl_cats if isinstance(c, dict)}
    by_name = {e.get("name"): e for e in stored if isinstance(e, dict)}
    added_fl = 0
    for name, members in GROUPS:
        cid = cat_id.get(name)
        if not cid:
            continue
        for m, c in members:
            if m not in have:
                continue
            e = by_name.get(m)
            if e is not None and e.get("categoryId"):
                continue                  # already somewhere, including a category of the owner's
            new = {"alias": "", "visible": True, "disabledWhilePrinting": c != A,
                   "color": "", "categoryId": cid, "name": m}
            if e is None:
                stored.append(new); by_name[m] = new
            else:
                e.update(new)
            added_fl += 1
    # Macros that are new AND unknown to us are call targets by elimination -- hide them, which is what
    # keeps the wall from growing back.
    hidden_fl = 0
    for m in have:
        if m.startswith("_") or m in known or m in by_name:
            continue
        stored.append({"alias": "", "visible": False, "disabledWhilePrinting": True,
                       "color": "", "categoryId": None, "name": m})
        hidden_fl += 1
    if added_fl or hidden_fl or dropped_fl:
        fl["stored"] = stored
        call("POST", "/server/database/item", {"namespace": "fluidd", "key": "macros", "value": fl})

    if dropped_ms or dropped_fl:
        print("[macro-groups] cleared %d entr(ies) from Mainsail groups and %d from Fluidd — "
              "withdrawn: %s; still available but ungrouped: %s"
              % (dropped_ms, dropped_fl, ", ".join(sorted(RETIRED)), ", ".join(sorted(UNGROUPED))))
    if added_ms or added_fl or hidden_fl:
        print("[macro-groups] filled in what appeared since: %d into Mainsail groups, %d into Fluidd "
              "categories, %d newly hidden." % (added_ms, added_fl, hidden_fl))
    elif not (dropped_ms or dropped_fl):
        print("[macro-groups] groups are already in place and nothing new to sort — unchanged.")
    return 0


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
        return topup(have, ms, fl, ms_groups, fl_cats)

    grouped = {m for _, members in GROUPS for m, _ in members}
    hide = [m for m in visible if m not in grouped]
    placed = [(name, [(m, c) for m, c in members if m in have]) for name, members in GROUPS]
    placed = [(name, members) for name, members in placed if members]
    if not placed:
        print("[macro-groups] none of the known macros are on this printer — nothing done.")
        return 0

    # Mainsail: a dict of groups keyed by id, each carrying its own macro list.
    #
    # 🔴 AND THE MODE, or none of it is visible. Mainsail's macro settings have a Management switch with
    # two positions, and the default -- "Simple" -- renders a flat list of toggles and ignores groups
    # entirely. The first version of this seeded six groups onto a fresh printer and the owner saw no
    # change at all, in either the settings or the dashboard, while the database held exactly what it
    # was supposed to. Fluidd showed the same data immediately, which is what made it look like a
    # Mainsail fault rather than a missing field.
    #
    # The default is the ABSENCE of the key, not the string "simple" -- so there is nothing to read and
    # compare, and writing it is the only way to be in the mode the groups need. Written only here,
    # inside the branch that has already established the owner has no groups of their own, so somebody
    # who chose Simple deliberately keeps it.
    old_ids = {g.get("name"): gid for gid, g in ms_groups.items() if isinstance(g, dict)}
    ms["mode"] = "expert"
    wrapped = wrapped_macros()
    ms["macrogroups"] = {}
    for name, members in placed:
        ms["macrogroups"][old_ids.get(name) or str(uuid.uuid4())] = {
            "name": name, "color": "primary", "colorCustom": "#fff",
            "showInStandby": True,
            "showInPause": any(FLAGS[c][1] for _, c in members),
            "showInPrinting": any(FLAGS[c][0] for _, c in members),
            "macros": [{"pos": i + 1, "name": m, "color": "group", "showInStandby": True,
                        "showInPrinting": FLAGS[c][0], "showInPause": FLAGS[c][1]}
                       for i, (m, c) in enumerate(
                           [mc for mc in members if mc[0].lower() not in wrapped])],
        }
    call("POST", "/server/database/item",
         {"namespace": "mainsail", "key": "macros", "value": ms})

    # ── the dashboard, which is where the groups actually become visible ──────────────────────────
    # Seeding groups is only half of it. Every Mainsail group is a dashboard panel named
    # "macrogroup_<id>", and a panel that no layout mentions is not shown -- so a fresh printer had six
    # correct groups and a dashboard that looked exactly as before.
    #
    # The arrangement below is not invented here: it is the one worked out on the dev printer and read
    # back out of its database, so it is a considered layout rather than a default nobody chose. Groups
    # are named rather than numbered, and resolved to THIS printer's ids at write time -- shipping the
    # dev printer's uuids would produce a layout that references panels no other machine has.
    #
    # A group that does not exist here is dropped from the layout rather than left dangling: with KAOS
    # switched off that group is never created, and its panel would be a reference to nothing.
    if not (get("mainsail", "dashboard", {}) or {}):
        by_name = {g["name"]: gid for gid, g in ms["macrogroups"].items()}

        def panels(*names):
            out = []
            for n in names:
                vis = True
                if isinstance(n, tuple):
                    n, vis = n
                if n.startswith("@"):           # @Group name -> macrogroup_<id>, dropped if absent
                    gid = by_name.get(n[1:])
                    if not gid:
                        continue
                    n = "macrogroup_" + gid
                out.append({"name": n, "visible": vis})
            return out

        C1 = ("@Calibration", "@Maintenance", "@Kit & Updates")
        C2 = ("@Printing", "@Filament & AMS", "@KAOS")
        call("POST", "/server/database/item", {"namespace": "mainsail", "key": "dashboard", "value": {
            "nonExpandPanels": {"widescreen": []},
            # Widescreen has three columns; desktop and tablet two, with the third column's panels
            # folded into the first.
            "widescreenLayout1": panels("toolhead-control", "extruder-control", *C1),
            "widescreenLayout2": panels("temperature", "machine-settings", *C2),
            "widescreenLayout3": panels("webcam", "miniconsole", "miscellaneous"),
            "desktopLayout1": panels("webcam", "toolhead-control", "extruder-control",
                                     "machine-settings", "miscellaneous", *C1),
            "desktopLayout2": panels("temperature", "miniconsole", *C2),
            "tabletLayout1": panels("webcam", "toolhead-control", "extruder-control",
                                    "machine-settings", "miscellaneous", *C1),
            "tabletLayout2": panels("temperature", "miniconsole", *C2),
            # Mobile is one column, so everything competes for the same scroll. The webcam and the mini
            # console are the two that cost the most room for the least use on a phone.
            "mobileLayout": panels(("webcam", False), "toolhead-control", "extruder-control",
                                   "machine-settings", "miscellaneous", "temperature",
                                   ("miniconsole", False),
                                   "@Printing", "@Filament & AMS", "@Calibration", "@KAOS",
                                   "@Maintenance", "@Kit & Updates"),
        }})
        print("[macro-groups] dashboard arranged (4 layouts).")

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
