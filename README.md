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
- **Bed-leveling helpers** — Z-tilt dual-Z alignment, custom bed mesh, manual screw-tilt.
- **Quality-of-life** — chamber-light toggle, PID board-fan, M600 filament change, piezo chime,
  `exclude_object` + `[respond]`, and a branded **Mainsail theme** (light / dark).
- **Filament runout, finally visible** — `FILA_STATUS` reports what the stock firmware keeps to itself:
  whether filament is present and whether runout protection is actually armed.
- **Privacy** — one switch turns **PhrozenGo / the cloud tunnel off** (run Obico instead).

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

> 📖 **Two guides, same install — pick your style:**
> - **[QUICKSTART](QUICKSTART.md)** *(or the [printable version](https://raw.githack.com/solutionphil/arco-unleashed/main/QUICKSTART.html))* — the condensed checklist, both paths, no pictures.
> - **[Illustrated MANUAL](MANUAL.md)** — every screen and screwdriver step pictured, both paths end to end.
> - **[INSTALL-FLOWCHARTS](INSTALL-FLOWCHARTS.md)** — the same paths as diagrams: every branch, every option, including the base-image and revert routes.
>
> The sections below are the same procedure in reference form.

You get a finished image (a `.img.gz`, or a pre-flashed spare eMMC module). The whole software stack
is already on it — you only need to flash it, set WiFi, and flash your printer's MCUs.

> **⚠️ Do this FIRST — rescue the AMS server (needed for BOTH paths below).** This is **not** a backup of
> the printer: it saves two files and nothing else. Everything else — calibration, uploaded G-code,
> Phrozen's system — is erased by the flash. For a way back, image the whole eMMC onto your stick first
> (MANUAL, Step 0b); it needs no teardown. The AMS server
> (**`phrozen_master` + `~/hdlDat`**) lives only in the original base OS — it is **not** in Phrozen's
> `Arco_FW_V*.zip`, so the flash wipes it, and without it AMS detection hangs and the display won't return
> home after calibration. To save it, **on the still-running original Arco**:
>
> 1. Copy **`collect_data_arco.sh`** (from this repo) onto the FAT32 USB stick and plug it into the printer.
> 2. **Connect via SSH** with a tool like **PuTTY** (Windows) or `ssh` (Mac/Linux): *Host Name* = the
>    printer's **IP** (from your router's device list or the Phrozen display), *Port* `22`, login
>    **`mks`** / password **`makerbase`**.
> 3. Run: **`bash ~/printer_data/gcodes/USB/collect_data_arco.sh ~/printer_data/gcodes/USB`**
>    *(that `~/printer_data/gcodes/USB` is where the Arco auto-mounts the stick).*
> 4. The script syncs the stick (and unmounts it if it had to mount it). **On your PC, confirm
>    `arco-phrozen-ams.tar.gz` is really on the stick** — if it's missing, re-insert it in the printer
>    and run the command again.
>
> It writes **`arco-phrozen-ams.tar.gz`** onto the stick; the new system re-installs it automatically on
> first boot.

## Two ways to install
| | **A) Easy direct flash** *(self-flash)* | **B) eMMC replacement / recovery** |
|---|---|---|
| How | Run **`install-unleashed.sh`** on the printer — it overwrites its **own** eMMC, streaming the image from a USB stick | Pull the eMMC, write it on a PC with **balenaEtcher**, put it back |
| Teardown | **None** | Open the housing + unscrew the eMMC |
| Best for | A quick in-place install / update | Swapping to a fresh eMMC, or **recovering** a bricked one |
| Status | ✅ **Proven on hardware** (full end-to-end run, 2026-07-10). Still **one shot, no net**: once the write begins, a failure needs **path B** to recover. *Before* it begins, pulling the stick + a power-cycle stands it down. | ✅ **Proven** — and the recovery path for A |

- **Path A** *(easy)* → on the printer, from where the stick auto-mounts: `cd ~/printer_data/gcodes/USB` → `sh prepare_unleashed_self_flash.sh` → `sudo bash ~/selfflash/install-unleashed.sh --arm`. Details: [`selfflash/`](selfflash/README.md).
- **Path B** *(eMMC replacement / recovery)* → the detailed steps below, also in the illustrated **[MANUAL](MANUAL.md)**.

### What goes on the USB stick
One **FAT32** stick, ≥ 4 GB. **The two paths need different files** — the big difference is that **path A
carries the image on the stick**, while **path B writes the image straight to the eMMC** on your PC, so its
stick only carries the first-boot files.

| File | Path A (self-flash) | Path B (eMMC swap) | What it is |
|---|:---:|:---:|---|
| `Arco-Unleashed_bookworm_6.18.30.img.gz` | ✅ | — *(goes on the eMMC via balenaEtcher)* | the image |
| `…img.gz.sha256` | ✅ | — | checksum — verified before any write |
| `…img.gz.rawsize` | ✅ | — | drives the on-display progress % |
| `unleashed-selfflash.tar.gz` | ✅ | — | the self-flash tool |
| `prepare_unleashed_self_flash.sh` | ✅ | — | unpacks the tool |
| `Arco_FW_V*.zip` *(optional — see below)* | ( ✅ ) | ( ✅ ) | Phrozen's official firmware package |
| **`arco-phrozen-ams.tar.gz`** *(from Step 0)* | ✅ | ✅ | the rescued AMS files — re-installed on first boot |
| *optional* `wifi-seed.txt` **or** `no_wifi.txt` | ✅ | — | path-A WiFi (else live-captured) — see the WiFi note below |

The first five all live inside one archive — **[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)** — extract it to the top level of the stick.
`arco-phrozen-ams.tar.gz` is produced by `collect_data_arco.sh` on your still-running printer (see
*Rescue the AMS server* below) and is the one file you **must** bring: it exists nowhere else.

> **`Arco_FW_V*.zip` is normally not needed.** Phrozen publishes the display module in their own
> public repository, and the first boot offers to fetch it from there — you confirm once, and the
> checksum is verified before anything is installed. Put the zip on the stick if **either** applies:
> the printer will have **no internet** while you set it up, or you want **PhrozenGo**, which is only
> in Phrozen's own package. (Display and AMS firmware are not a reason — those come through Phrozen's
> own USB firmware update.) A zip on the stick always wins: nothing is downloaded then.

> **WiFi (path A).** Recommended: add **nothing** → the tool **live-captures** the network the printer
> already uses — and it **carries over that printer's own WiFi country**, so the region is correct
> automatically. **Or** a **`wifi-seed.txt`** — plain lines `SSID=YourNetworkName`, `PSK=YourWiFiPassword`,
> and `COUNTRY=US` — **your 2-letter WiFi region code** (US, CA, GB, AU, …). No quotes, a **2.4 GHz** network.
> **Set the country to yours** — the regulatory region must match your router, or the printer may not join.
> `no_wifi.txt` leaves WiFi to the first-boot portal, where you pick your network **and your country** from
> dropdowns. A wrong or **non-connecting** WiFi falls back to that phone portal on first boot after about 90
> seconds; and if the portal itself fails to appear, a `wifi-seed.txt` dropped on the stick rescues the printer
> after the flash too. (Full detail: [`selfflash/`](selfflash/README.md).)

> **Where the stick appears:** on both a stock printer and Unleashed the USB stick auto-mounts at
> **`~/printer_data/gcodes/USB`**. If that folder is empty, mount it there **yourself** — same place, so
> every command below then works unchanged:
> ```bash
> ls ~/printer_data/gcodes/USB/     # stick usually here already
> lsblk                             # if not: find your stick's partition (e.g. sda1)
> sudo mkdir -p /home/mks/printer_data/gcodes/USB
> sudo mount /dev/sda1 /home/mks/printer_data/gcodes/USB
> ```

> 📖 **Prefer pictures?** The illustrated **[step-by-step install manual](MANUAL.md)** covers **both paths**
> end to end — the self-flash, eMMC removal, balenaEtcher, the WiFi portal, the USB install, and the MCU
> flash — every screen pictured. A condensed checklist is in **[QUICKSTART](QUICKSTART.md)**.

## Path B — eMMC replacement / recovery (detailed)
*(For **path A**, the easy in-place self-flash, see [`selfflash/`](selfflash/README.md) instead — the
steps below are the PC-based eMMC flash, and the way to recover if a self-flash ever fails.)*

### What you need
**Tools:** **Allen / hex keys** (to remove the toolhead's rear extruder cover and open the printer's
lower housing cover), a **small Phillips screwdriver** (for the eMMC's screw on the mainboard), and a
**USB-to-eMMC adapter**.
**Media:** a **FAT32 USB stick, ≥ 4 GB** (ideally the original Phrozen one from the printer),
**Phrozen's official `Arco_FW_V199.zip`** (download it yourself), and a PC with **balenaEtcher**.

### 1. Flash the image to the eMMC
Take **`Arco-Unleashed_bookworm_6.18.30.img.gz`** out of **[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)** (the release ships that one archive), then: eMMC out → USB adapter → PC →
write it with **balenaEtcher** (GUI, no WSL) → eMMC back in.

### 2. First boot — WiFi portal + USB install (on your phone, no PC needed)
The public image ships **without** Phrozen's software, so the first boot opens a **WiFi setup portal**.
Put the `arco-phrozen-ams.tar.gz` from the pre-flash step above onto a **FAT32 USB stick** — and, only
if you need it (no internet at setup, or you want PhrozenGo), Phrozen's
own [`Arco_FW_V*.zip`](https://fs.phrozen3d.com/arco/Arco_199/Arco_FW_V199.zip) beside it. Then
**insert that stick into the printer's USB port — before you connect.** Now on your phone, join the
**`Arco-Unleashed-Setup`** Wi-Fi → the page pops up — pick your network, enter the password, tick the
consent box → press **Connect**. The printer reboots onto your WiFi and, with the stick already in, the
**display shows a progress bar** (Reading → Installing → Patching).
At 100 % the display shows **"Update complete — wait for restart…"** and the printer **restarts itself once** a
few seconds later. **Let it — don't switch it off** (the filesystem batches writes for up to two minutes, so
pulling the power here can cost you the install). Remove the stick. *(The full-card rootfs resize happens here
too; SSH host keys are generated on the first boot.)* From then on the normal Phrozen display WiFi screen
works for future network changes.

> **You'll then see "Error occurred" — that's expected.** After that restart the display settles on a
> **"Notice — Error occurred"** screen: Klipper can't start yet because your **MCUs still carry the old
> firmware**. Restarting/power-cycling won't clear it. **Wait for this screen** (it means the automatic
> restart is done), then SSH in and **flash the MCUs** (next step). Don't try to set up on the display, and
> don't SSH *before* this — the auto-restart would just drop the session.

> **Why USB and not a download?** Arco Unleashed never downloads or ships Phrozen's software. You
> obtain Phrozen's official package yourself and provide it — nothing proprietary is redistributed.

> **Display firmware (.tft) — applies to both install paths.** The image installs Phrozen's module *incl.
> This project never updates the touch panel itself. Phrozen's zip happens to carry the panel firmware
> (`FW_Arco-HMI_*.tft`) and their own updater may flash it when versions differ; the download route
> carries none. **If your printer was on an older Phrozen firmware** and the display looks off, just **run
> one official Phrozen USB firmware update once** — that is how panel firmware is meant to be updated.
> That's safe: the **self-heal guards re-apply the v0.13 Klipper patches automatically** on the next boot,
> so a Phrozen update never breaks the migration (see [Menu reference](#menu-reference)).

### 3. Connect via SSH with PuTTY
1. Find the printer's **IP** (your router's device list, or it shows on the display).
2. Open **PuTTY** → *Host Name* = that IP, *Port* `22`, *Connection type* **SSH** → **Open**
   (accept the host-key warning on first connect).
3. Login: **`mks`** / password **`makerbase`** (stays default).

### 4. Run the setup menu
```bash
bash ~/arco-unleashed/scripts/unleashed_setup.sh
```

### 5. Essential steps — without these it won't run ⚠️
First boot did everything else automatically (step 2): WiFi onboarding, installing Phrozen's module
**from your USB stick or, with your confirmation, from Phrozen's own repository** and patching it for
v0.13, the rootfs resize, and SSH host keys.

The one thing you **must** still do by hand: the image's host runs Klipper **v0.13**, but **your
printer's MCUs still have the old firmware** — flash them or Klipper can't talk to them. In the menu:

| Menu item | Why it's essential |
|---|---|
| **Flash MCUs** | The **F407 (main board) and the host MCU flash automatically** over USB — no buttons. **Only the toolhead F103 needs a hands-on step** — its **BOOT + RESET** buttons — and only once, for the **one-time Katapult install**: on the toolhead board, **hold BOOT → tap RESET (keep BOOT held) → keep holding ~2 s → release**, then **start the flash within ~3 s** (or its ROM bootloader drops out again). Flashing the F407 also **auto-writes its serial** into `printer_MCU.cfg`. |

> Without the MCU flash you'll see `mcu: Unable to connect` / `Command format mismatch`.

### 6. Calibrate
Bed mesh, z-offset, PID, input shaper and purge position are per-printer and must be redone after the
migration. Three ways, easiest first:
- **Factory-reset auto-calibration** *(from the display)* — runs input shaper, bed mesh and purge position
  end-to-end and returns to the home screen by itself.
- **Arco display calibration functions** — run the individual routines (input shaper, bed mesh, purge
  position, …) one at a time from the display's calibration menu.
- **Manual** — do it all yourself in Mainsail (`SHAPER_CALIBRATE`, bed mesh, purge position, PID, z-offset).

> **Skip any built-in "print test"** the first-time setup or a factory reset offers — the bundled test
> file was compiled for the old Klipper and can't run on v0.13, so the flow stalls on it. Just skip it;
> your first print comes from **OrcaSlicer** (§6) once you're set up.

That's it. Optional extras (AMS, PhrozenGo/Cloud, AddOn.cfg, recovery) live in the same menu — see
[Menu reference](#menu-reference) below.

---

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
