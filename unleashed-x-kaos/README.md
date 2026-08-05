# Unleashed × KAOS

A **sideload bridge** that lets the [KAOS](https://github.com/) config package run on top of an
Arco Unleashed printer — installable, activatable and removable from the Mainsail/Fluidd console.

```
KAOS_ON        fetch (if not cached), install, activate, restart
KAOS_OFF       deactivate and restart — files stay on disk for an instant re-activation
KAOS_UPDATE    pull the latest files from the repo (re-activates if it was on)
KAOS_STATUS    on/off, installed version, last action
```

> **Status: mechanism drafted, integration data pending.** The command surface, state model and
> safety guards below are settled. The per-module allowlist, the strip-list and the trust wiring
> come from a compatibility analysis that is still being finalised — see
> [docs/integration-spec.md](docs/integration-spec.md) once it lands.

---

## Why a bridge is needed at all

KAOS and Arco Unleashed are **sibling forks of the same ancestor** — our neighbouring repository
[solutionphil/PhrozenArco](https://github.com/solutionphil/PhrozenArco) (Nov 2025), which KAOS took and
extended massively into what it is now. They are not strangers, which is exactly why they collide: both
declare the *same inherited* Klipper sections. Dropping KAOS next to an Unleashed config makes klippy
refuse to start.

That also makes the fix tractable. It is an **ownership split**, not a rewrite:

> **Unleashed owns the shared base. KAOS keeps its own value-add and drops its copies of the base.**

The base Unleashed keeps: `[respond]`, `[exclude_object]`, `[save_variables]`,
`[pwm_cycle_time beeper]`, `[temperature_fan board_fan]`, `[screws_tilt_adjust]`, `[z_tilt]`,
`[delayed_gcode startup_beep]`, plus `Z_TILT_ADJUST` / `SCREWS_TILT_CALCULATE`.

KAOS keeps what it actually adds: the popup menu, translation and logging layers, the trusted-home
system, lights/fans/steppers logic, filament service, print features and tools.

Keeping our side of the base is deliberate, not territorial — those values are the evidence-backed
ones. Two examples: `screw_thread: CCW-M4` is what the shared ancestor has in all 47 of its
revisions and our line in all 212, while KAOS changed it to `CW-M4`; and our beeper is declared
`[pwm_cycle_time]`, the only section whose `SET_PIN` actually honours a runtime `CYCLE_TIME`
(KAOS's `[output_pin]` silently drops it, which is why its `M300` cannot change pitch anywhere).

## Three things activation must handle

Anything less and `KAOS_ON` leaves the printer worse than it found it.

1. **Strip the duplicate declarations.** KAOS's copies of the inherited sections and macros must be
   removed on install. Not optional — a duplicate `[section]` or `[gcode_macro NAME]` is a hard
   config-parse error and klippy will not start.
2. **Wire the Motion Guard's trust.** KAOS installs a guard that blocks every `G0`/`G1` carrying
   X/Y/Z until trust is granted, and only `_SET_TRUSTED_XYZ` grants it. An Unleashed
   `[homing_override]` never calls that, so without wiring, the first travel move after every home
   aborts — homing appears to work, then the printer refuses to move. `KAOS_ON` must either wire
   trust into homing or deliberately disarm the guard.
3. **Activate a curated module list, not the whole bundle.** At minimum `magic_ams` must stay off:
   it references state macros that exist only in KAOS's own rewritten `printer_gcode_macro.cfg`, and
   it would fight the hardware-proven Unleashed AMS flow.

## State model

| | |
|---|---|
| Files | `~/printer_data/config/kaos/` — kept after `KAOS_OFF` so re-activation needs no download |
| Switch | a single `[include]` line, commented / uncommented |
| State | marker file with on/off + installed version, so `KAOS_UPDATE` and the boot self-heal agree |
| Finish | `FIRMWARE_RESTART` — and a hard refusal while a print is running or paused |

## Independence

This directory is **self-contained at runtime**. It does not read from or write to the kit's own
files, and the printer keeps the two apart: the bake and `update-from-usb.sh` both extract it to
`~/unleashed-x-kaos`, *beside* `~/arco-unleashed`, never inside it. A printer that never types
`KAOS_ON` carries the files and nothing else — no include, no Python, no behaviour.

It lived in its own repository until 2026-08-05. That bought the separation at a price nobody was
paying attention to: the subtree had to be folded into the kit tarball by hand, which was forgotten
twice — two images shipped with no bridge at all, and every tester update package omitted it, so a
bridge could only ever be renewed by reflashing. One repository, one archive, nothing to remember.

> **This directory is PUBLIC.** The kit repository is published at release. Working material —
> assessments, integration notes, correspondence, runbooks that quote printer addresses — belongs in
> the private `arco-unleashed-dev/kaos-internal/`, never here. The old repository kept that split
> with `export-ignore`, which only ever governed `git archive` and would not have hidden a thing
> from a public repository.

## Layout

```
config/   Klipper-side bridge: the KAOS_* commands and their shell wiring
scripts/  the sideload worker (fetch / install / strip / activate / deactivate / update / status)
docs/     removal.md — how to take the bridge off a printer
```

## Safety

`KAOS_ON`, `KAOS_OFF` and `KAOS_UPDATE` all restart Klipper and all refuse to run while a print is
active or paused. `KAOS_ON` needs network access on first use; afterwards activation works offline
from the cached files.

## License

See `LICENSE`. KAOS itself is a separate project under its own terms — this repo contains only the
bridge, and fetches KAOS from its own source at install time rather than redistributing it.
