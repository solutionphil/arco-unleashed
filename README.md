<p align="center">
  <img src="assets/logo.png" alt="Arco Unleashed — Bookworm Edition" width="680">
</p>

# Arco Unleashed — Bookworm Edition

Take the **Phrozen Arco** off the stock **Debian Buster / Klipper v0.11** stack — frozen at the factory
version, with Buster now end-of-life — and onto a modern, fully self-hosted setup:
**armbian-mkspi (Debian Bookworm, kernel 6.18) · Klipper v0.13**. All your factory hardware and features
carry over — the serial touch display, both MCUs, chamber light, input shaper, the optional AMS and the
PhrozenGo app — now running on a current, maintained and fully open system.

### Why move off Buster + Klipper v0.11?
- **Security & longevity** — Debian Buster is **end-of-life** (no more security updates). Bookworm is the
  current, supported Debian with modern Python and packages.
- **Klipper v0.13** — years of fixes and features over the frozen factory v0.11 (improved input shaper,
  `exclude_object`, `danger_options`, faster) — and, crucially, **you can keep updating it** instead of
  being locked to the version Phrozen shipped.
- **Modern add-on ecosystem** — current Klipper / Moonraker / Python means today's tools just work:
  **Spoolman** (filament tracking), **Obico** (remote monitoring) — neither of which runs on the frozen
  factory stack. Adaptive bed meshing you already have: it is built into this Klipper
  (`BED_MESH_CALIBRATE ADAPTIVE=1`), so no add-on is needed for it.
- **Both web interfaces, like the stock printer** — **Mainsail** on `http://<printer-ip>/` (and `:81`) and
  **Fluidd** on `:8808`, the ports your Arco came with. Both current, both themed.
- **It's your printer** — full SSH / root access, Obico-ready, no cloud lock-in.

### What the AddOn layer adds — all toggleable from the setup menu
- **AMS auto-mode — one OrcaSlicer profile for everything.** Slice single-colour or multicolour with the
  same profile; the printer works out which AMS mode to start in, at print start, on its own. No second
  profile, no switching in the slicer, no hand-edited G-code. What you *do* set is the **AMS flag on the
  printer** — once, with `AMS_ON` or `AMS_OFF`, whenever you physically attach or remove the unit. That
  flag plus what you sliced is all it needs. See [OrcaSlicer](#orcaslicer--multicolor--ams-auto-mode).
- **The mesh fix** — `G30` reliably loads your saved bed mesh (the factory behaviour that never stuck).
- **Levelling and calibration** — `Z_TILT_ADJUST` for the dual Z, `SCREWS_TILT_CALCULATE` for the manual
  screws, custom bed mesh, and `PID_NOZZLE` / `PID_BED`. Each **homes first**, which the factory
  equivalents do not: a calibration run from an assumed position measures the wrong thing.
  `CALIBRATE_SHAPER_NEW` does the same for the input shaper, and sweeps to **130 Hz** rather than the
  stock macro's 150.
- **Belt tension and idler cleaning** — `BELT_TENSION` homes and parks the toolhead where both belt spans
  are equal, so you tension against a known geometry instead of by feel; `BELT_WARMUP` loosens belts and
  steppers first; `CLEAN_IDLERS` turns the idlers in fixed steps so the pulleys can be wiped.
  [Details](#belts-and-idlers).
- **Filament handling** — `LOAD_FILAMENT` / `UNLOAD_FILAMENT` with priming, `M600` change, `M601` pause,
  and `FILA_STATUS`, which reports what the stock firmware keeps to itself: whether filament is present
  and whether runout protection is actually armed.
- **Quality-of-life** — chamber-light toggle, PID board-fan, piezo chime, `exclude_object` + `[respond]`,
  and a branded **Mainsail theme** (light / dark).
- **Updating the kit itself** — `ARCO_UPDATE` from the Mainsail console, and an entry in Moonraker's
  update manager so Arco Unleashed appears beside Klipper and Moonraker.
- **Privacy** — one switch turns **PhrozenGo / the cloud tunnel off** (run Obico instead).
- **Optional: Unleashed × KAOS.** Chris Sanders' [KAOS](https://gitlab.com/sanders.chris/phrozenarco) —
  a motion-safety and multicolour layer for the Arco — is supported through a **sideloader that ships
  dormant in the kit**. Nothing to download or install: `KAOS_ON` fetches and applies it, `KAOS_OFF`
  puts the printer back exactly as it was, and `KAOS_STATUS` says where you stand. The bridge exists
  because KAOS and this kit each replace some of Phrozen's macros, and running them naively together
  breaks homing; it wires the two so both keep working. See
  [MANUAL › Step 11](MANUAL.md#step-11).

Install the **easy way**: flash the pre-built image, set Wi-Fi, flash your MCUs — running in minutes.

> **Disclaimer.** Arco Unleashed is an independent, community-made project. It is **not** developed,
> supported, sponsored, endorsed by, or affiliated with Phrozen Tech Co., Ltd. or ThroughTek Co., Ltd.
> **No proprietary Phrozen/ThroughTek software is bundled, hosted or mirrored** by this project.
> Phrozen's parts reach the printer either from the owner's own `Arco_FW_V*.zip`, obtained from
> official Phrozen sources and provided on a USB stick, or — only after the owner confirms — by
> downloading the `phrozen_dev` module from **Phrozen's own public repository**
> ([phrozen3d/klipper](https://github.com/phrozen3d/klipper), GPL-3.0), pinned to a fixed commit and
> checksum-verified. *Phrozen*, *Arco* and *PhrozenGo* are trademarks of their
> respective owners, used here only for identification (nominative fair use).
>
> 
> ⚠️ **Hardware-specific:** Phrozen Arco with MKS board (RK3328, STM32F407 + MKS_THR STM32F103),
> AP6212 WiFi. Not a generic Klipper kit.
>
> ⚠️ **Warranty:** replacing the factory OS/firmware and opening the printer will very likely **void your
> Phrozen warranty**. You do this to your own machine at your own risk. Keep a backup of the original eMMC
> (or the stock image) so you can restore it if you ever need to return the printer to stock.

---

# 🟢 Flash & Run — the pre-built image

You get a finished image (a `.img.gz`, or a pre-flashed spare eMMC module). The whole software stack is
already on it — you only need to flash it, set WiFi, and flash your printer's MCUs.

> 🛑 **Before you flash anything, rescue the AMS server.** On the **still-running original printer**:
>
> ```bash
> bash ~/printer_data/gcodes/USB/collect_data_arco.sh ~/printer_data/gcodes/USB
> ```
>
> That writes `arco-phrozen-ams.tar.gz` onto your stick, and the new system re-installs it by itself on
> first boot. It saves **two files** — `phrozen_master` and `~/hdlDat` — which live only in Phrozen's
> original OS. They are in no download and in none of Phrozen's packages, and the flash erases them for
> good. Without them AMS detection hangs and the display will not return home after calibration.
>
> It is **not** a backup of the printer. For a way back to the factory system, image the whole eMMC onto
> the stick first — [MANUAL › Step 2](MANUAL.md#step-2), no teardown needed.
>
> Full walkthrough with the SSH details: [MANUAL › Step 1](MANUAL.md#step-1).

## Installing

**The printer flashes itself.** You put the image on a USB stick, run one command over SSH, and the
printer overwrites its own eMMC on the next boot. No teardown, no PC, nothing to unplug.

Taking the eMMC module out is **not** part of that. It is there for recovery if a flash ever fails, for
setting up a spare module, or for keeping an untouched copy of the factory system —
[MANUAL › Appendix A](MANUAL.md#appendix-a).

### Which guide

| | |
|---|---|
| **[QUICKSTART](QUICKSTART.md)** | the condensed checklist — start here if you have done this kind of thing before |
| **[MANUAL](MANUAL.md)** | every screen and screwdriver step pictured, 1 → 11 in order |
| **[INSTALL-FLOWCHARTS](INSTALL-FLOWCHARTS.md)** | the same paths as diagrams, including the base-image and revert routes |

Those three are the install instructions. Everything below on this page is **reference** — the menu, the
slicer profile, the optional features — not a fourth copy of the procedure.

### The three things people miss

**Bring the printer to Phrozen V199 first.** That firmware carries the touch-panel firmware this project
expects, and the panel is the one part Arco Unleashed never touches or ships. Start from something older
and the display can misbehave, on a machine where the display is how you follow the install.

**`arco-phrozen-ams.tar.gz` exists nowhere else.** `collect_data_arco.sh` makes it on your
*still-running* printer, and the flash erases the original for good. It is in no download and in none of
Phrozen's packages. Everything else on the stick comes out of
**[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)** — extract it to
the top level and you are done.

**Flashing the MCUs is not optional.** It is the one step that opens the printer (two buttons inside the
toolhead), and until it is done Klipper cannot start and the display sits on an error screen. That is
expected, not a fault.

### In short

```bash
cd ~/printer_data/gcodes/USB
sh prepare_unleashed_self_flash.sh
sudo bash ~/selfflash/install-unleashed.sh          # inspect only — changes nothing
sudo bash ~/selfflash/install-unleashed.sh --arm    # then reboot; it writes on the way up
```

Afterwards the printer answers to **`unleashed.local`** — `ssh mks@unleashed.local`, or
`http://unleashed.local/` for the web interface. If your network blocks mDNS, the address is also written
to **`ip.txt`** on the USB stick at every boot.

## Menu reference
The setup menu runs an update check on start (if the kit is a git clone) and only prompts y/n when an
update exists.
```
   ESSENTIAL:     Flash MCUs
   MAINTENANCE:   Backup / restore YOUR settings (local or USB) · Check self-heal guards
   SOMETHING BROKE: Emergency repair — one action, no diagnosis required
   EXTRAS:        AMS on/off · PhrozenGo/Cloud · AddOn.cfg · Beacon probe (experimental)
   UPDATE:        check GitHub for a newer version
```
- **Phrozen-update protection** — pressing *Update* on the Phrozen display overwrites the Klipper core +
  `printer.cfg` and halts the printer (Katapult keeps the F103 safe). The smart way is to **stay ahead of
  it** — this option has three parts:
  - **Back up once, right after setup** *(recommended)* — a "golden" snapshot of your patched stack + config.
  - **Pre-patch USB — before *every* Phrozen update** *(recommended)* — it bakes your fixes (from that
    backup) onto the update stick, so Phrozen's update **installs them along with itself**. Each new update
    incrementally carries the fixes — nothing gets clobbered and **you never need to recover**.
  - **Restore** — the fallback *only* if an update ever slips through un-patched: one click puts back the
    v0.13 core, patched module and your config (calibration preserved) and the printer comes back up.
- **Backup / restore settings** — the guards restore the Klipper core and the phrozen_dev module on
  their own, so the software needs no preparation any more. What no guard can do is give back the
  numbers **your** machine measured. `Backup` captures your printer configuration and calibration, the
  web interface's own settings (theme, presets, macro groups, history — none of it in `printer.cfg`),
  your WiFi and the phrozen_dev module; `Restore` puts them back. It can also write the backup to a
  **USB stick**, which is the copy that survives a reflash — the local one lives on the very eMMC it is
  protecting. `Pre-patch` additionally writes your config onto a Phrozen update stick, so the installer
  deploys *your* `printer.cfg` instead of Phrozen's.
- **Emergency repair** — the one to reach for when the printer halted, the display is dead, or an update
  button keeps failing. It runs every repair in order without asking what went wrong, because at that
  moment nobody knows whether Phrozen's firmware, a Klipper update, a Moonraker update or a "hard recover"
  caused it. Every step is idempotent, so it is a no-op on a healthy printer, and it reports what actually
  needed fixing. It also covers two things no automatic guard catches: an `AddOn.cfg` that lost its
  `[arco_mcu_timing]` section (the MCU timing would silently stop being applied), and root-owned files in
  `~/klipper` or `~/moonraker`, which make Moonraker's update button fail with a git error that points
  nowhere near the actual cause.
- **Check self-heal guards** — the entry that replaced *"Re-apply Klipper patches"*, which had become
  redundant: those patches are re-applied by a guard on every Klipper start and by Emergency repair. What
  nothing checked is whether the guards are wired at all. They are installed when the image is built, not
  when the kit updates itself, so a printer that has been running a while can be missing a guard the
  current kit assumes — with no symptom until the failure it exists to catch. This compares
  `klipper.service` against what the kit's own installer writes, so the expected list cannot drift, and
  offers to install anything missing.
  **You do not have to do anything about that:** `klipper.service` runs seven `ExecStartPre` guards before
  klippy loads, so the restart that follows any update puts everything straight back. This menu option is
  the manual equivalent, idempotent and safe anytime.
  > **Moonraker's three actions are not equally harmless.** *Update* refuses outright on a modified repo
  > and otherwise just pulls. *Soft recover* resets tracked files and leaves untracked ones alone.
  > **Hard recover** runs `git reset --hard` + `git clean -d -f`, so everything untracked is deleted —
  > `phrozen_dev` and our modules with it. Slow and unnecessary, but not fatal: the guards put our modules
  > back automatically, and a copy of *your* phrozen_dev is kept outside the Klipper tree for exactly this
  > case. If it ever does go wrong, **Emergency repair** above is the one action to run.
  > Klipper is **not** pinned: it sits on `master` with HEAD attached, the repository is clean and valid,
  > and Moonraker offers new versions normally — nothing is greyed out or held back.
  > (`scripts/pin-klipper-updates.sh` can hold a version deliberately, if you want that.)
- **PhrozenGo / Cloud** (`scripts/phrozengo.sh`) — *Privacy* closes the frpc **SSH tunnel** to the
  vendor's server (app still works via TUTK); *OTA* toggles Phrozen's auto-update — turn it **OFF** to
  protect your v0.13 from a hostile Phrozen firmware update; *Disable* stops the cloud app entirely
  (no phone-home), frees the webcam + resources, and stops Phrozen from deleting **Obico** on boot.
  Defaults are as Phrozen ships (all on); local display + light always stay.
  > ⚠️ **Installing Obico? Turn PhrozenGo off first.** Phrozen's own KlipperScreen launcher runs
  > `rm -rf ~/moonraker-obico` and `~/moonraker-obico-env` on **every boot**, and PhrozenGo ships
  > **on**, so those lines are live on a fresh printer. Obico installs cleanly, works until the next
  > restart, and is then simply gone — with nothing in any log to explain it. *Disable* here comments
  > the lines out. Other Moonraker add-ons (Spoolman, Mobileraker) are not touched.
- **AMS** (`scripts/ams_toggle.sh on|off`) — toggles AMS / "Chroma Kit" mode (flips `auto_connect` + the
  `~/hdlDat/Phrozen_Dev.json` work-mode; the runtime lever is the `P0` gcode). `AddOn.cfg` provides
  clickable `AMS_ON`/`AMS_OFF`/`AMS_STATUS` macros for Mainsail (needs the `gcode_shell_command`
  extension). It also writes a macro-readable `ams` flag that **steers OrcaSlicer** automatically
  (P0 M1/M2/M3 picked at print start — see [OrcaSlicer](#orcaslicer--multicolor--ams-auto-mode)).
  Note: a factory-NEW AMS additionally needs one-time provisioning (firmware flash/pairing).

<a id="beacon-as-new-probing-device-for-meshing--experimental"></a>

## Beacon as new probing device for meshing 🧪 *experimental*
`scripts/beacon_toggle.sh status|on|off` · setup menu → **b**

Swaps Phrozen's piezo probe for a **Beacon** eddy-current probe: Z is homed by a virtual endstop, the
bed mesh is *scanned* instead of poked, and a 15×15 mesh costs less time than the stock 6×6 did. The
config comes from a real conversion contributed by **Philippe Humeau** (unPhrozen) — including the
gotchas he paid for, which are written into `beacon.cfg` where you need them.

Toggling is reversible: `off` restores `printer.cfg` byte-for-byte (verified) and keeps your calibrated
`beacon.cfg`. `on` walks five gates before it changes anything, and each one aborts cleanly:

1. **Not mid-print** — switching restarts Klipper. Checked, not asked.
2. **Is the machine physically ready?** — Beacon mounted, wired and plugged in; rigid mount; bed clear.
   Asked *before* anything is downloaded, so declining leaves no half-finished conversion.
3. **Is a Beacon actually on USB?** — the one thing the script can verify by itself. No probe, no change.
4. **The module.** Klipper does **not** ship one: mainline v0.13 has generic eddy-current support
   (`probe_eddy_current` + `ldc1612`, for LDC1612 probes like BTT Eddy), but Beacon speaks its own
   protocol over its own MCU, so it needs the vendor's out-of-tree module. If it is missing, you are told
   what will be downloaded, from where, under which licence and to which path — and asked. Nothing is
   redistributed by this kit.
5. **The config change** — type `BEACON`. A backup is written, and it rolls back if Klipper does not
   come up.

> ### ⚠️ Read this before switching
> **1. It is experimental in the literal sense.** No Arco Unleashed developer has run it on a machine.
> Every number in `beacon.cfg` — `y_offset`, `z_positions`, mesh bounds — is *one other printer's*
> value, not an Arco constant. Treat them as a starting point and verify each one.
>
> **2. Do not use the Arco display for anything Z-related afterwards.** Not Z-calibration, not
> auto-levelling, not "probe" or mesh from the touchscreen. Its calibration flow was written for the
> piezo probe: it declares Z positions instead of measuring them (`SET_KINEMATIC_POSITION`), and it
> loads a stored mesh that was probed against a different Z reference. On a Beacon machine that can
> drive Z out of safe bounds — it was tested, and it did. **Use Mainsail or Fluidd** for homing,
> probing, mesh and Z-offset. Printing from the display is unaffected.
>
> **3. Verify `z_positions` before you trust `Z_TILT_ADJUST`.** The order must match the *physical* Z
> motors, not the order of the config sections. Swapped, z_tilt **diverges** instead of converging and
> the retries make it worse. Check with `STEPPER_BUZZ STEPPER=stepper_z` / `stepper_z1` and watch which
> side of the gantry moves.

## Sensorless XY homing — a repair option, not an upgrade
`scripts/sensorless_toggle.sh status|on|off` · setup menu → **s**

X and Y stop by detecting motor load (Trinamic StallGuard) instead of by a microswitch. Z is untouched
and keeps its load-cell probe.

**The microswitches remain the default and the recommendation.** They stop at the same physical place
every time, for free, with nothing to tune. If your switches work, leave this off.

What makes it worth shipping is one specific failure: X's microswitch hangs off the **toolhead** MCU
while the driver's DIAG line goes to the **main** MCU. A broken toolhead cable therefore kills the
switch but not the sensorless path — the printer homes again without waiting for a spare part.

Proven on hardware here: `G28 X`, `G28 Y` and a full `G28` all home on StallGuard, and the
disconnected switches still **click** at the end of the move. The click is the point — the stall
happens *at* the mechanical stop, so the zero does not shift and the filament cutter (X=319), the wipe
position (Y=322) and any saved mesh stay valid.

`on` equalises the two homing speeds (levelling *down*, never up — StallGuard's reading is
velocity-dependent, so two axes at different speeds cannot share one sensitivity), installs a
`sensorless.cfg` that gates StallGuard by velocity, and rolls everything back if Klipper does not come
up. `off` restores `printer.cfg` byte-for-byte, homing speed included — verified against the toggle's
own backup. A Phrozen update replaces `printer.cfg`; the kit re-applies sensorless mode before every
Klipper start while it is enabled, because handing back a dead switch is exactly the wrong failure.

> ### ⚠️ Read this before switching
> **1. Watch the first few homings, with `M112` in reach.** Wrong sensitivity means the carriage grinds
> into the rail instead of stopping, and on CoreXY that drags the other axis along. Listen for the
> switch to click: Klipper reports position `0` whether it reached the wall or tripped 2 mm in, so the
> sound is the only honest signal you have.
>
> **2. Sensitivity is `driver_SGT`, and the scale is backwards from intuition — LOWER is MORE
> sensitive.** Grinds without stopping → lower it. Stops early with no click → raise it. The shipped
> `1` is what this hardware wanted at 30 mm/s and 1.2 A.
>
> **3. Calibrate at your running current.** A value found at a reduced current does not transfer. With
> too little current the motor *slips* instead of building the load StallGuard measures, so nothing
> triggers at all — which looks exactly like "sensorless does not work on this machine".

**What it changes.** Four things have to *disappear* from `printer.cfg`, which no include can do —
`[probe]` (claims the same `!PB9`), `[homing_override]` (claims `G28` and drives Z against the piezo),
`stepper_z`'s `position_endstop` (Klipper rejects it as unused once the endstop is virtual) and
`stepper_z1`'s `endstop_pin` (a second endstop on a probe-homed rail). Each is commented with a
`#:beacon:` marker, so `off` is a prefix strip. Everything additive lives in `beacon.cfg`, included
**last** so its section merges win.

**Update safety.** The Beacon module is untracked in Klipper's tree, so Klipper updates leave it alone;
Moonraker is not involved. A **Phrozen update is the dangerous one** — it replaces `printer.cfg`
wholesale, which would put the piezo config back while a Beacon sits on the toolhead, and the next
`G28` would drive Z down waiting for a trigger that cannot come. So Beacon mode is re-applied by the
`ExecStartPre` config guard on every Klipper start, keyed off a marker file, before klippy parses
anything. A copy of your `beacon.cfg` is kept outside `printer_data/` for the same reason.

**First steps after switching** (in Mainsail/Fluidd, not on the display):
`STEPPER_BUZZ` both Z steppers → `G28` → `Z_TILT_ADJUST` → `BEACON_CAL` (contact auto-calibration) →
`BEACON_MESH` (re-scan the mesh — the saved one was probed with the piezo).

## Themes (optional)
An electric-cobalt comic theme matching the Arco Unleashed branding — navy glass panels, halftone-burst
background, the bookworm logo + a Burst "U" favicon.

- **Mainsail** — [`mainsail-theme/`](mainsail-theme/), light / dark + a switcher. Full details in its
  [README](mainsail-theme/README.md).
- **Fluidd** — [`fluidd-theme/`](fluidd-theme/), the same look ported (both apps are Vuetify, so it is the
  same design, not a lookalike). Install with `bash fluidd-theme/setup-fluidd-theme.sh`, then reload with
  **Ctrl+F5** and pick the dark theme. Fluidd has no hook for a custom logo or favicon, so those stay its own.

Mainsail can't add *named* themes to its dropdown (that needs a Mainsail fork/rebuild, which breaks on
every update), so the kit ships **two `.theme` variants + a switcher** instead — update-safe:

| Variant | Base |
|---|---|
| **Voron Light** | navy `#070E1F` (default) |
| **Voron Dark** | near-black `#02050c` (same accents / logo / favicon) |
| **Stock** | theme off (plain Mainsail) |

Switch over SSH — `sh ~/printer_data/config/unleashed-theme.sh next` (cycles light → dark → stock) — or
one-click in the **Macros panel** via `SWITCH_THEME` (needs the `gcode_shell_command` extension;
`setup-theme-macros.sh` wires it up). Hard-reload after switching (**Ctrl+F5**). The active state is kept
in `.theme-state` and survives reboots. Note: the `.theme` overlay is global, so it also tints the
built-in themes — keeping those pristine would need a Mainsail fork (out of scope, not update-safe).

<a id="orcaslicer--multicolor--ams-auto-mode"></a>

## OrcaSlicer — multicolor & AMS auto-mode
The Arco is a single-nozzle multicolor printer (filament-swap, like a Bambu AMS).

**You need exactly one OrcaSlicer profile.** Not one for AMS and one without, and nothing to switch
before you slice. Slice single-colour or multicolour as the model needs, send it, and the printer picks
the right AMS mode at print start by itself.

That works because the decision is made on the printer, not in the slicer, from two things: **what you
sliced** (one filament or several — the start G-code passes that through) and **whether an AMS is
attached**, which the printer remembers.

**The one thing you set, and only when the hardware changes.** Attaching or removing the AMS is a
physical toolhead conversion, so the printer has to be told — once, not per print:

```
AMS_ON     # after fitting the AMS
AMS_OFF    # after removing it
AMS_STATUS # what it thinks right now
```

From the Mainsail Macros panel, or the SSH setup menu. It writes a persistent `ams` flag
(`[save_variables]`) that survives reboots and updates. Forget it and the symptom is unmistakable: with
the AMS fitted but the flag off, the tool commands `T1`–`T15` are not even registered, so a multicolour
print stops at the first colour change.

**Profile.** Stock OrcaSlicer already ships the official **Phrozen Arco** profile (vendor `Phrozen`, no
fork needed). The kit adds an enhanced variant in [`orca/`](orca/) carrying the start-gcode below —
import it via *File → Import → Import Configs…*, or paste that block into your own profile.

The macro `PHROZEN_AMS_START` is what reads the flag and decides:

| AMS flag | Slice | Print starts in |
|---|---|---|
| **on** | multicolor | `P0 M1` (color changes via `Tn`) |
| **on** | single-color | `P0 M2` (auto-refill / endless spool — load the **same** color) |
| **off** | single-color | `P0 M3` (standalone, toolhead runout protection) |
| **off** | multicolor | aborts with an error (multicolor needs the AMS) |

**Complete Machine start G-code** (already in the kit profile — paste this whole block into Orca's
*Machine start G-code* field if you set up your own printer):
```gcode
M107
G90
M104 S140 ; nozzle warm-up (stays cool = no ooze during probe)
M140 S[bed_temperature_initial_layer_single] ; bed straight to print temp (no 65C detour)
M109 S140
M190 S[bed_temperature_initial_layer_single] ; heat-soak at target temp
PG28
;AUTO_LEVELING_2
G30
G21
M83
M104 S[nozzle_temperature_initial_layer] ; nozzle up to print temp
M109 S[nozzle_temperature_initial_layer]
{if size(filament_diameter) > 1}PHROZEN_AMS_START MULTI=1{else}PHROZEN_AMS_START MULTI=0{endif}
{if size(filament_diameter) == 1}
T0
{endif}
```
Above heats the **bed straight to your print temperature** (no wasteful 65 °C-then-cool-down wait) and
keeps the **nozzle at a probe-safe 140 °C** during `PG28` home + probe (so it can't ooze onto the
load-cell), then raises the nozzle to print temp. **`G30`** loads your saved `phrozen` bed mesh instantly
(and calibrates + saves it the first time if none exists yet). The **`PHROZEN_AMS_START`** line is the AMS auto-mode; the closing
`{if size(filament_diameter)…}` selects `T0` for single-color prints. Needs the `auto_mode` + `ams` features
in `AddOn.cfg` (on by default) and the `gcode_shell_command` extension; homing is automatic.

**Set the other Machine G-code fields too** (the imported profile already has them; set them if you paste
into your own): **End G-code** = `PRINT_END` · **Pause** = `M601` (→ `PAUSE` alias) · **Change filament** =
`PHROZEN_TOOLCHANGE FLUSH=[flush_length]`. In **Others**, tick **Label objects** (`gcode_label_objects`) — required for the adaptive
bed mesh (per-object bounding boxes via `EXCLUDE_OBJECT_DEFINE`) and it enables Mainsail per-object
exclusion. (The AMS `ams` flag is separate — set once via SSH, see *The flag* above.) Pause /
filament-change adapt automatically to the `ams` flag — see *Pause &amp; filament change* below.

### Adaptive bed mesh (optional)
Rather than loading the saved full-bed mesh, Klipper can probe **only the print area** on each print.
Replace the **`G30`** line above with:
```gcode
M106 S255
BED_MESH_CALIBRATE ADAPTIVE=1 ADAPTIVE_MARGIN=5
M106 S0
```
The `M106 S255`/`M106 S0` runs the part fan during probing to keep the nozzle tip clean (Phrozen wraps its
mesh probe the same way; the `G30` load doesn't probe, so it needs no fan). Also **enable OrcaSlicer's
*Label objects* checkbox** (*Others → Label objects*). Adaptive meshing reads
the object bounding boxes from the `EXCLUDE_OBJECT_DEFINE` lines that checkbox emits — **without it Klipper
falls back to probing the whole bed**. After one test slice, confirm the `EXCLUDE_OBJECT_DEFINE` lines sit
**before** `BED_MESH_CALIBRATE` in the sliced G-code; if not, set Moonraker
`[file_manager] enable_object_processing: True`. Adaptive meshes are transient (`adaptive-XXXX`) and never
overwrite your saved `phrozen` profile. Trade-off: probes each print (~30–60 s) vs. the instant `G30` load.

### Pause & filament change (handled automatically for AMS and standalone)
You don't need mode-specific *Pause* / *Change filament* G-code — the printer-side macros adapt to the
`ams` flag automatically:
- **Color / filament change:** Orca's `change_filament_gcode` is **`PHROZEN_TOOLCHANGE FLUSH=[flush_length]`**,
  which is AMS-aware. With the AMS it retracts and purges the slice's flush volume (a sized `P10` spit) while
  Orca's `Tn` drives the actual cut / load / purge. Without the AMS it retracts and calls the **`M600`** macro
  — a full manual retract → load → purge → resume. (`M600` also reads the `ams` flag: full manual flow when
  off, a no-op when on since changes go via `Tn`.)
- **Pause:** Orca's stock `machine_pause_gcode` is **`M601`**, which is *not* a Klipper command — the kit
  ships an **`M601` → `PAUSE`** alias (in `AddOn.cfg`) so an Orca pause-at-layer works instead of hitting
  "Unknown command". `PAUSE` behaves the same with or without the AMS. (Keep the profile's
  `machine_pause_gcode` as `M601` — the alias handles it — or set it to `PAUSE` directly.)
- **Runout:** the toolhead sensor is watched by Phrozen's own module — but only after the print mode has
  been set, which is what `PHROZEN_AMS_START` does. A start G-code without it prints **unprotected**, and
  stock says nothing. `[arco_fila_status]` reports it: a console warning once the job is past its start
  G-code, `FILA_STATUS` on demand, and `printer['arco_fila_status']`
  (`filament_present`, `adc`, `threshold`, `protection_active`)
  for your own macros. It is read-only — detection and pausing stay with Phrozen's module.

## Belts and idlers

Three macros for the mechanics, all of them in `AddOn.cfg` and all toggleable from the setup menu.
They derive their limits from your own configuration rather than carrying hard-coded coordinates, so a
different bed or a different mesh does not silently inherit numbers chosen for one machine.

**`BELT_TENSION`** — homes, then parks where **both belt spans are equal**, which is where you pluck them.
That is not the middle of the bed and not the middle of the travel: behind the Y rail there is a further
60 mm of belt to the idler (measured on this machine), so the middle of the *span* is Y190 where the middle
of the travel would be Y160. Park at the wrong place and two perfectly matched belts read as mismatched.
Aim for **equal pitch** between the two, not for any particular frequency — the absolute number depends on
span length. Leave the steppers energised; `M84` lets the belts go slack and the reading is void.

**`BELT_WARMUP`** — runs the gantry through its range to loosen cold, stiff belts.
`BELT_WARMUP ACCEL=5000 MARGIN=40 SPEED=200 CYCLES=10`. It bounds its own acceleration rather than
inheriting the machine's 40000 ceiling, keeps `MARGIN` off the frame at the low end, and stays clear of the
purge/wipe unit at the high end — those two ends are not symmetric, which is why it derives them separately.
Previous limits are restored, and it re-homes at the end rather than trusting the step count, because a
cold-belt warm-up at speed is precisely what can lose steps.

**`CLEAN_IDLERS`** — turns the idler pulleys a measured amount so you can wipe the deposits off them.
Run it with no arguments and it opens a dialog in Mainsail or Fluidd: pick the **left** or **right**
pulleys, and the toolhead parks at the opposite end so it is not travelling past the hand holding the
cotton bud. A second dialog with a **Stop** button replaces it while it runs.

One turn of a 20-tooth GT2 pulley is 40 mm of belt, so the default 1.5 turns is 60 mm — and on CoreXY that
is also 60 mm of carriage travel, with no ratio to correct for. Everything is adjustable:
`CLEAN_IDLERS SIDE=left TURNS=1.5 TEETH=20 SPEED=45 PAUSE=3 PAUSE_TURN=1`. It pauses **before** each
forward pass — that is when you hold the bud against the pulley, not while it moves — and only briefly at
the far end. It refuses while a print is running, and refuses if the requested turns would carry Y past the
purge unit.

## Layout
```
config-templates/    printer.cfg + includes + AddOn.cfg + wpa  (templates; secrets/serial removed)
scripts/  unleashed_setup.sh   the setup MENU; _arco-lib.sh = shared helpers/actions
          fetch-phrozen-fw · usb-fw   <- installs Phrozen's module: user's USB zip first, else a confirmed fetch from Phrozen's own repo)
          apply-phrozen-patches  (3 v0.13 sed fixes + the SHAPER_END/BED_PROBE_END cal-handshake macros — only our rules)
          apply-phrozen-restore  (keeps a copy of YOUR phrozen_dev outside the Klipper tree; puts it back if an update deleted it)
          emergency-repair  (one action for "something broke" — runs every repair, reports what was wrong)
          apt-hold (mask auto-apt/unattended-upgrades + hold kernel/DTB/fw) · fix-gpio-led · resize-emmc · optimize-fs (noatime)
          optimize-boot  -> 40k real-time tuning: performance governor · klippy CPU3 + F407-IRQ affinity · numpy=1 · F407 USB no-suspend · ImageId
          flash_mcus [f407|f103|host] · install-katapult · set-mcu-serial
          phrozengo · ams_toggle · addon-toggle · addon-features · phrozen-recover · selfupdate
          beacon_toggle  (EXPERIMENTAL: piezo probe <-> Beacon; reversible printer.cfg surgery)
          arco_*.py  own Klipper extras, untracked + self-healed by apply-arco-extras (ExecStartPre):
                     mcu_timing (MCU timing without patching mcu.py) · tool_gate (hide T1-T15 without an AMS)
                     sdcard_select (SDCARD_SELECT_FILE for the display) · fila_status (filament state, read-only)
          arco-firstrun (portal→fetch→install) · wifi-portal/ · tft.sh (boot progress screen)
          arco-splash (loading-screen branding)
system/                   USB automount (udev rule + mount service) for the gcodes/USB stick path
collect_data_arco.sh      grab phrozen_master + ~/hdlDat (AMS server, NOT in Arco_FW_V*.zip) from YOUR printer -> USB
mainsail-theme/           optional Arco Unleashed Mainsail theme (Voron Light/Dark + switcher + mainsail-seed)
orca/                     OrcaSlicer profile (flag-driven AMS auto-mode; import or copy the start-gcode line)
```

## Credits & notes
- **No Phrozen software is redistributed, hosted or mirrored here.** Everything Phrozen ships as its own
  reaches the printer either from a **USB stick you provide** (their official `Arco_FW_V*.zip`, obtained
  by you from Phrozen) or, after you confirm, straight from **Phrozen's own public repository**: the
  **`phrozen_dev` Python module** (GPL-3.0,
  [phrozen3d/klipper](https://github.com/phrozen3d/klipper)) and the proprietary parts — the `voronFDM`
  display binary (Phrozen's own closed-source C++, *not* GPL despite the name), the display `.tft` and
  the AMS firmware. This repository ships the patch *rules* and its own scripts; the DTB and the WiFi
  firmware are in the **image**, not here. The config templates under `config-templates/` do derive from
  Phrozen's own Arco configuration, which they publish under **AGPL-3.0**
  ([phrozen3d/Phrozen_ARCO](https://github.com/phrozen3d/Phrozen_ARCO)) — the same licence as this
  project, which is what makes that legitimate. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- For privacy, prefer **Tailscale/WireGuard** over PhrozenGo's cloud for remote access.
- No personal data is shipped — WiFi, SSH keys and calibration are per-printer (templates/placeholders).

## Trademarks & disclaimer
*Phrozen*, *Arco* and *PhrozenGo* are trademarks of **Phrozen Tech Co., Ltd.**; *ThroughTek*, *Kalay*
and *TUTK* of **ThroughTek Co., Ltd.** They are used here only for identification/description
(nominative fair use). All trademarks and copyrights remain with their respective owners.
**Arco Unleashed is an independent, community-made project — not developed, supported, sponsored,
endorsed by, or affiliated with Phrozen or ThroughTek. No proprietary Phrozen/ThroughTek software is
bundled, hosted or mirrored; Phrozen's parts come either from the official package the owner obtains
from Phrozen and provides on a USB stick, or — only after the owner confirms — from Phrozen's own
public repository.** See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).


## License

**Arco Unleashed — Copyright © 2026 solutionphil.** Licensed under the **GNU Affero General Public
License v3.0** (AGPL-3.0) — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

If you redistribute or build on Arco Unleashed, AGPL-3.0 requires you to **keep it open** (publish your
complete source, including for any networked/hosted use), **state your changes**, and **preserve the
copyright notice and the "Arco Unleashed" attribution** ([github.com/solutionphil/arco-unleashed](https://github.com/solutionphil/arco-unleashed))
— this attribution is a stated additional term under **AGPL §7(b)**, in the source and in any user-facing
"About"/documentation of your derivative.

Bundled third-party components keep their own licenses (the Klipper MCU firmware is GPL-3.0) — see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).


> [!CAUTION]
> Working with electricity and electronic components can be dangerous. Always ensure you take the necessary safety precautions when handling electrical devices.
>
> This software and associated documentation are provided "as is" without warranty of any kind, either express or implied, including but not limited to the implied warranties of merchantability and fitness for a particular purpose. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.
>
> Use this software at your own risk. The authors are not responsible for any damage to your equipment, personal injury, or any other consequences resulting from the use of this software.
