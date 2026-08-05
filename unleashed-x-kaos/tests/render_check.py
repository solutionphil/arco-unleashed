# Render the tool-change macros exactly as Klipper does and check the claims.
# Klipper builds its Jinja env as Environment('{%', '%}', '{', '}') - SINGLE braces
# for expressions - so a check using the jinja2 defaults would not be testing our file.
import re, sys
from jinja2 import Environment

BRIDGE = r"E:\Arco-Unleashed\unleashed-x-kaos\config\kaos-ams-bridge.cfg"
KIT    = r"E:\Arco-Unleashed\arco-unleashed\config-templates\AddOn.cfg.template"

env = Environment('{%', '%}', '{', '}')   # Klipper's exact delimiters

def body(path, macro):
    src = open(path, encoding='utf-8').read()
    m = re.search(r'^\[gcode_macro %s\]\n((?:(?!^\[).*\n)*)' % re.escape(macro), src, re.M)
    if not m: sys.exit("could not find [gcode_macro %s] in %s" % (macro, path))
    sec = m.group(1)
    g = re.search(r'^gcode:\n((?:(?!^\S).*\n)*)', sec, re.M)
    if not g: sys.exit("no gcode: block in %s" % macro)
    return re.sub(r'^    ', '', g.group(1), flags=re.M)

class Obj(dict):
    # attribute AND item access, like Klipper's status wrappers
    def __getattr__(self, k):
        try: return self[k]
        except KeyError: raise AttributeError(k)

def ctx(ams, stage, gp_temp=210.0, stock_defined=True, pending=None, now=135.0):
    # stage=None models a fresh install where magic_stage was never saved, so the macro's
    # own |default(...) decides. That is the path a new user actually takes.
    v = Obj(ams=ams) if stage is None else Obj(ams=ams, magic_stage=stage)
    p = Obj(
        save_variables=Obj(variables=v),
        extruder=Obj(target=205.0),
        toolhead=Obj(homed_axes='xyz'),
        print_stats=Obj(total_duration=now),   # the print clock the stale-handoff guard reads
    )
    p['gcode_macro GLOBAL_PARAM'] = Obj(g_extruder_temperature=gp_temp)
    p['gcode_macro PRZ_GEOMETRY'] = Obj(toolchange_z_lift=3)
    if pending is not None: p['gcode_macro _TOOLCHANGE_PENDING'] = Obj(**pending)
    if stock_defined:       p['gcode_macro _ARCO_SPITTING_END_STOCK'] = Obj()
    return p

def render(tpl_src, printer, params):
    return [l.strip() for l in env.from_string(tpl_src).render(
        printer=printer, params=Obj(**params), rawparams='').splitlines()
        if l.strip() and not l.strip().startswith('#')]

bridge_tc = body(BRIDGE, 'PHROZEN_TOOLCHANGE')
bridge_se = body(BRIDGE, 'PRZ_SPITTING_END')
kit_tc    = body(KIT,    'PHROZEN_TOOLCHANGE')

fails = []
def check(label, cond, detail=''):
    print(("  PASS  " if cond else "  FAIL  ") + label + (('\n         ' + detail) if detail and not cond else ''))
    if not cond: fails.append(label)

print("=" * 78)
print("1. STAGE 1 vs the KIT's stock path  (claim: identical except the temp write)")
print("=" * 78)
def strip_comment(l): return l.split(';')[0].strip()

# The DELIBERATE additions in stage 1, each touching only our own state or E-mode:
ADDED = ('_TOOLCHANGE_CLEAR',                       # clears our own pending container
         'M83',                                     # E-mode fix (no-op: Orca is already M83)
         'VARIABLE=g_extruder_temperature')         # the per-tool temperature - the point

# Exhaustive bucket-boundary sweep: the mapping MUST be identical to the kit's.
print("\n  bucket mapping across the full flush range (stage 1 vs kit stock):")
for flush in (0, 50, 110, 110.5, 220, 220.5, 330, 330.5, 440, 440.5, 550, 550.5, 1000):
    got  = render(bridge_tc, ctx(ams=1, stage=1), {'FLUSH': str(flush), 'TEMP': '240'})
    want = render(kit_tc,    ctx(ams=1, stage=1), {'FLUSH': str(flush)})
    g_p10 = [strip_comment(l) for l in got  if l.startswith('P10')]
    w_p10 = [strip_comment(l) for l in want if l.startswith('P10')]
    ok = g_p10 == w_p10
    print(f"     flush={flush:<7} kit={w_p10[0] if w_p10 else '-':<7} stage1={g_p10[0] if g_p10 else '-':<7} {'OK' if ok else 'MISMATCH'}")
    if not ok: fails.append(f"bucket mismatch at flush={flush}")

# Full-line equivalence once the deliberate additions are removed.
for flush, temp in ((150, 240), (500, 240), (60, None), (600, 210)):
    pa = {'FLUSH': str(flush)}
    if temp is not None: pa['TEMP'] = str(temp)
    got  = render(bridge_tc, ctx(ams=1, stage=1), pa)
    want = [strip_comment(l) for l in render(kit_tc, ctx(ams=1, stage=1), {'FLUSH': str(flush)})]
    core = [strip_comment(l) for l in got if not any(a in l for a in ADDED)]
    print(f"\n  flush={flush} temp={temp}")
    print(f"    kit stock        : {want}")
    print(f"    stage1 (core)    : {core}")
    check(f"stage1 core == kit stock (flush={flush})", core == want, f"core={core}")
    if temp:
        check(f"stage1 writes g_extruder_temperature={temp}",
              any('VARIABLE=g_extruder_temperature' in l and str(float(temp)) in l for l in got))
    check(f"stage1 fires NO ORCA_PURGE and arms nothing (flush={flush})",
          not any('ORCA_PURGE' in l or '_TOOLCHANGE_PENDING' in l for l in got))

print()
print("=" * 78)
print("1b. DEFAULT STAGE  (claim: a fresh install, magic_stage never saved, is stage 3)")
print("=" * 78)
dflt = render(bridge_tc, ctx(ams=1, stage=None), {'FLUSH': '150', 'TEMP': '240'})
for l in dflt: print("     ", l)
check("unsaved magic_stage -> full ORCA_PURGE path (arms + P10 S2)",
      'P10 S2' in dflt and any('VARIABLE=active' in l for l in dflt))
check("unsaved magic_stage -> NOT the stage-1 bucket path",
      not any(re.search(r'P10 S[13456]\b', l) for l in dflt))

print()
print("=" * 78)
print("2. STAGE 3  (claim: arms handoff + pins P10 S2)")
print("=" * 78)
got3 = render(bridge_tc, ctx(ams=1, stage=3), {'FLUSH': '150', 'TEMP': '240'})
for l in got3: print("     ", l)
check("stage3 pins P10 S2", 'P10 S2' in got3)
check("stage3 sets active=1", any('VARIABLE=active' in l and l.rstrip().endswith('1') for l in got3))
check("stage3 passes flush 150", any('VARIABLE=flush' in l and '150' in l for l in got3))
check("stage3 next_temp=240", any('VARIABLE=next_temp' in l and '240' in l for l in got3))
check("stage3 emits no stock bucket S1/S3..S6",
      not any(re.search(r'P10 S[13456]\b', l) for l in got3))

print()
print("=" * 78)
print("3. ams=0  (claim: manual swap, no AMS routing, no arm)")
print("=" * 78)
for st in (1, 3):
    g = render(bridge_tc, ctx(ams=0, stage=st), {'FLUSH': '150', 'TEMP': '240'})
    print(f"  stage={st}: {g}")
    check(f"ams=0 stage{st} -> M600", 'M600' in g)
    check(f"ams=0 stage{st} -> no P10", not any('P10' in l for l in g))
    check(f"ams=0 stage{st} -> no arm", not any('_TOOLCHANGE_PENDING' in l for l in g))

print()
print("=" * 78)
print("4. PRZ_SPITTING_END  (claim: armed -> ORCA_PURGE; idle -> stock; missing -> loud)")
print("=" * 78)
armed = render(bridge_se, ctx(1, 3, now=135.0,
               pending=dict(active=1, flush=150.0, retract=2.0, next_temp=240.0, lifted=0, armed_at=120.0)), {})
print("  armed :", armed)
check("armed fires ORCA_PURGE with the queued values",
      any('ORCA_PURGE' in l and '150' in l and '240' in l for l in armed))
check("armed clears active FIRST (before ORCA_PURGE)",
      next(i for i,l in enumerate(armed) if 'VARIABLE=active' in l) <
      next(i for i,l in enumerate(armed) if 'ORCA_PURGE' in l))
check("armed does NOT also run the stock tail",
      not any('_ARCO_SPITTING_END_STOCK' in l for l in armed))

idle = render(bridge_se, ctx(1, 3, pending=dict(active=0, flush=0, retract=0, next_temp=0, lifted=0, armed_at=0.0)), {})
print("  idle  :", idle)
check("idle runs the stock tail", idle == ['_ARCO_SPITTING_END_STOCK'])

miss = render(bridge_se, ctx(1, 3, stock_defined=False,
                             pending=dict(active=0, flush=0, retract=0, next_temp=0, lifted=0, armed_at=0.0)), {})
print("  miss  :", miss)
check("rename missing -> loud RESPOND, not silence", any('RESPOND' in l for l in miss))


print()
print("=" * 78)
print("5. STALE HANDOFF  (claim: a handoff from a cancelled print is refused)")
print("=" * 78)
def se(active, armed_at, now):
    return render(bridge_se, ctx(1, 3, now=now,
        pending=dict(active=active, flush=150.0, retract=2.0, next_temp=240.0,
                     lifted=0, armed_at=armed_at)), {})
def verdict(got):
    return (any('ORCA_PURGE' in l for l in got), any('_ARCO_SPITTING_END_STOCK' in l for l in got))
for label, (a, at, nw), want in [
    ("same change (armed 120s, spit 135s) -> purge",            (1, 120.0, 135.0), (True, False)),
    ("cancelled print (armed 600s), new print spit 40s -> stock",(1, 600.0,  40.0), (False, True)),
    ("stale by age (armed 100s, spit 500s) -> stock",            (1, 100.0, 500.0), (False, True)),
    ("armed at print start (0s), spit 45s -> purge",             (1,   0.0,  45.0), (True, False)),
]:
    got = se(a, at, nw)
    check(label, verdict(got) == want, str(got))

print()
print("=" * 78)
print(("ALL CHECKS PASSED" if not fails else "FAILURES: " + "; ".join(fails)))
print("=" * 78)
sys.exit(1 if fails else 0)
