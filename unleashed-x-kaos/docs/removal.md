# Getting KAOS out again

The point of the sideload model: **the printer is always one command away from a plain Unleashed
machine.** Phase 0 proved it on hardware — after `KAOS_OFF`, `printer.cfg` and `dev.py` are
byte-identical to the pre-KAOS baseline.

> **Use a command, not a hand-edit.** Removal touches three files that must stay consistent with each
> other, and the script does them in one pass, in the right order. Hand-editing is the last resort,
> not the default — an earlier version of this document got the order wrong and would have bricked
> prints. If you only read one line: **run `kaos-sideload.sh off`.**

---

## 1. Normal — from the console

```
KAOS_OFF
```

There is no macro for removing just the purge feature any more -- it covered a case nobody asked
for. From a shell, `KAOS_MAGIC_AMS=0 bash kaos-sideload.sh on` reinstalls KAOS without it.
KAOS_OFF refuses to run mid-print.

## 2. Klipper down, or the macro unavailable — over SSH

The same code path, without needing Klipper to accept a macro:

```bash
bash ~/arco-unleashed/unleashed-x-kaos/scripts/kaos-sideload.sh off
```

This is the answer for almost every "it is wedged" case. It restores the vendor `dev.py`, removes the
includes, reverts the spit-patch rename, clears the state and restarts Klipper — atomically and in the
order the code intends.

It **refuses** if KAOS's `dev.py` is installed and `.cache/backup/dev.py` is missing, because removing
the trust wiring in that state arms the motion guard with nothing able to grant trust. Restore a vendor
`dev.py` first (kit `scripts/apply-phrozen-restore.sh`, or your own `Arco_FW_V*.zip`), then re-run.

Verify:

```bash
bash ~/arco-unleashed/unleashed-x-kaos/scripts/phase0.sh compare      # PASS = byte-identical to baseline
```

---

## What KAOS touches

| # | What | Where | Removed by `off`? |
|---|---|---|---|
| 1 | 4 include lines | `printer.cfg` | ✅ |
| 2 | `PRZ_SPITTING_END` renamed → `_ARCO_SPITTING_END_STOCK` | `printer_gcode_macro.cfg` | ✅ byte-identical |
| 3 | `dev.py` replaced by KAOS's fork | `klippy/extras/phrozen_dev/` | ✅ **if** `.cache/backup/dev.py` exists — otherwise `off` refuses rather than proceed |
| 4 | `active=` / `magic_ams=` | `.cache/state` | ✅ set to 0 |
| 5 | `kaos_logging.py`, `kaos_motion_guard.py`, `kaos_translations.py`, `lang/` | `klippy/extras/phrozen_dev/` | ❌ left — inert, the vendor `dev.py` never imports them |
| 6 | `kaos.cfg`, `kaos/*.cfg`, `kaos-unleashed-shims.cfg`, `kaos-trust-wiring.cfg`, `kaos-ams-bridge.cfg` | `printer_data/config/` | ❌ left — inert once the includes are gone |
| 7 | **`kaos-bridge.cfg`** + its include | `printer_data/config/` | ❌ left — **NOT inert**: this is the console front door (`KAOS_ON`, `KAOS_OFF`, the shell command). Deliberate — it is how you switch KAOS back on |
| 8 | payload cache, backups, phase0 baseline | `~/arco-unleashed/unleashed-x-kaos/.cache/` | ❌ left — this is what makes re-activation instant and offline |
| 9 | `kaos_*` keys, `magic_stage` | `variables.cfg` | ❌ left — inert |
| 10 | boot guard `21-kaos-guard.conf` | `/etc/systemd/system/klipper.service.d/` | ❌ left — **leave it**, see below |

Rows 5–10 are deliberate. None of them changes how the printer prints while the includes are gone.
A printer in that state *is* a normal Unleashed printer.

---

## The boot guard: leave it installed

It is the thing that repairs a half-finished removal on the next start — it reconciles the
`PRZ_SPITTING_END` rename against whether `kaos-ams-bridge.cfg` is included, on every boot, before
every exit path. With KAOS off it only ensures the vendor `dev.py` is in place and that
`PRZ_SPITTING_END` resolves.

Two consequences, both important:

* **The guard's script lives in `~/arco-unleashed/unleashed-x-kaos/scripts/`.** Deleting that directory does not
  remove the guard — it turns it into a silent no-op. Keep the directory, or remove the drop-in too.
* **It can only restore `dev.py` while `.cache/backup/dev.py` exists.** That backup is the single most
  valuable file in the tree. Do not delete it casually.

To remove the guard entirely (root, one-time — do this **before** deleting the repo, never after):

```bash
sudo bash ~/arco-unleashed/unleashed-x-kaos/scripts/kaos-sideload.sh uninstall-boot-guard
```

---

## 3. Last resort — by hand

Only when `kaos-sideload.sh off` itself cannot run. Run it as **one block**, without restarting Klipper
in between: between the include removal and the rename revert there is a moment where nothing declares
`PRZ_SPITTING_END`, and a start in that window would fail prints.

```bash
cd ~/arco-unleashed/unleashed-x-kaos

# Refuse to continue if the vendor dev.py cannot be restored (see §2).
test -f .cache/backup/dev.py || { echo "NO dev.py BACKUP — stop, restore a vendor dev.py first"; exit 1; }

cp -f .cache/backup/dev.py ~/klipper/klippy/extras/phrozen_dev/dev.py && \
rm -rf ~/klipper/klippy/extras/phrozen_dev/__pycache__ && \
sed -i -E '/^[[:space:]]*\[include (kaos\.cfg|kaos-unleashed-shims\.cfg|kaos-trust-wiring\.cfg|kaos-ams-bridge\.cfg)\][[:space:]]*$/d' \
    ~/printer_data/config/printer.cfg && \
bash scripts/kaos-spit-patch.sh revert ~/printer_data/config/printer_gcode_macro.cfg && \
sed -i 's/^active=.*/active=0/' .cache/state
```

`active=0` matters: leave it at `1` and a later `KAOS_UPDATE` silently re-installs and re-activates
everything you just removed.

Check before restarting — both must hold:

```bash
grep -c '^\[gcode_macro PRZ_SPITTING_END\]' ~/printer_data/config/printer_gcode_macro.cfg   # exactly 1
grep -cE '\[include kaos-(ams-bridge|trust-wiring|unleashed-shims)\.cfg\]|\[include kaos\.cfg\]' \
     ~/printer_data/config/printer.cfg                                                       # 0
```

Then restart (no root needed — Moonraker holds the privilege):

```bash
curl -s -X POST "http://localhost:7125/machine/services/restart?service=klipper"
```

---

## Symptom → fix

**`Unknown command: PRZ_SPITTING_END` (a print dies mid-spit).** The rename is applied but nothing
declares the macro. Decide by the include, not by eye — note it is `kaos-ams-bridge.cfg`, **not**
`kaos-bridge.cfg`:

```bash
grep -c 'kaos-ams-bridge' ~/printer_data/config/printer.cfg
#   0 -> bash ~/arco-unleashed/unleashed-x-kaos/scripts/kaos-spit-patch.sh revert ~/printer_data/config/printer_gcode_macro.cfg
#   1 -> bash ~/arco-unleashed/unleashed-x-kaos/scripts/kaos-spit-patch.sh apply  ~/printer_data/config/printer_gcode_macro.cfg
curl -s -X POST "http://localhost:7125/machine/services/restart?service=klipper"
```

Or just reboot with the boot guard installed — reconciling this is precisely its job.

**Homing works, every jog is then refused ("KAOS blocked").** KAOS's motion guard is armed but the
trust wiring is gone. Restore the vendor `dev.py` (§2), or re-add `[include kaos-trust-wiring.cfg]`.

**Klipper will not start after a config error.** A `[include]` pointing at a file that no longer exists
is a hard config error — check that first. The bridge keeps a one-shot pre-KAOS copy:

```bash
cp -f ~/arco-unleashed/unleashed-x-kaos/.cache/backup/printer.cfg.pre-kaos ~/printer_data/config/printer.cfg
```

If that is gone too, the kit's own `scripts/phrozen-recover.sh` restores `printer.cfg` wholesale.

---

## Removing every trace

Rarely worth it — rows 5–10 are inert and make re-activation instant. If you do want it, the order is
what matters, because two of the steps disarm the safety net:

1. Run `kaos-sideload.sh off` and confirm `phase0.sh compare` reports **PASS**.
2. Confirm the vendor `dev.py` is really in place:
   `grep -c 'kaos_motion_guard' ~/klipper/klippy/extras/phrozen_dev/dev.py` → **0**.
3. Remove `[include kaos-bridge.cfg]` from `printer.cfg` **before** deleting the file it points at —
   a dangling include stops Klipper from starting.
4. Then the files:
   ```bash
   rm -f ~/printer_data/config/kaos.cfg ~/printer_data/config/kaos-bridge.cfg \
         ~/printer_data/config/kaos-unleashed-shims.cfg ~/printer_data/config/kaos-trust-wiring.cfg \
         ~/printer_data/config/kaos-ams-bridge.cfg
   rm -rf ~/printer_data/config/kaos
   rm -f  ~/klipper/klippy/extras/phrozen_dev/kaos_{logging,motion_guard,translations}.py
   rm -rf ~/klipper/klippy/extras/phrozen_dev/lang
   ```
5. `variables.cfg` — only with **klippy stopped**, or it will rewrite the file from memory:
   `sed -i '/^kaos_/d; /^magic_stage/d' ~/printer_data/config/variables.cfg`
6. Boot guard (root), **before** the repo goes:
   `sudo bash ~/arco-unleashed/unleashed-x-kaos/scripts/kaos-sideload.sh uninstall-boot-guard`
7. Last, and only now: `rm -rf ~/arco-unleashed/unleashed-x-kaos`
   — this destroys `.cache/backup/dev.py` and `printer.cfg.pre-kaos`, your last-resort restores.
   Copy them somewhere else first if you want to keep a safety net.
