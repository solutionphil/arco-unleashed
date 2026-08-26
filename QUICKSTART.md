# Arco Unleashed — Quick Start

From a stock Phrozen Arco to **Debian Bookworm · kernel 6.18 · Klipper v0.13**, without opening the
printer: it flashes its own eMMC from a USB stick.

Five steps, about **30 minutes** — or **an hour** if you also take the backup the installer offers. Much
of that is the printer working while you wait, not you typing.
Every screen of the install is pictured in the **[MANUAL](MANUAL.md)**; the full reference is the
**[README](README.md)**.

*This is the short path: five steps where the MANUAL has ten. Each heading names the MANUAL step it
corresponds to, so you can switch between the two documents at any point.*

> ⚠️ **Your risk, and probably your warranty.** Replacing the factory OS and firmware will very likely
> **void your Phrozen warranty**, and you do it entirely at your own risk — no guarantee of any kind, and
> nobody here is liable for a printer that ends up damaged or unusable.
>
> ℹ️ **Not affiliated with Phrozen.** Arco Unleashed is an independent, community-made project — not
> endorsed, supported or distributed by Phrozen. Do not ask Phrozen for support on a printer running
> it.
> *Phrozen* and *Arco* are their trademarks, used only to say which machine this fits. **No Phrozen
> proprietary software is bundled, hosted or mirrored here.** Phrozen's parts come from the zip you
> supply, or from Phrozen's own public repository — and from the repository only after you confirm.

---

## Before you begin

**You need:** the printer on your network · a PC with an SSH client (**PuTTY** on Windows) · one
**empty, freshly formatted FAT32 stick** — **≥ 8 GB** if you will take the backup, 4 GB is enough
without it · **2.0 mm and 2.5 mm hex keys** for Step 3. Plug the stick straight into the printer,
**never through a USB hub**.

**Optional: Phrozen's `Arco_FW_V*.zip`**, which you download from Phrozen. Bring it only if the printer
will have **no internet** during setup, or if you want **PhrozenGo**, their cloud app. Otherwise the
printer offers to fetch the display module from Phrozen's own public repository, once you confirm.

**Three things are irreversible, so decide now:**

1. Phrozen's gateway — what the display talks to, and where the AMS work mode lives — exists **only
   on your printer**, and the flash erases it. The installer saves it for you and refuses to write if
   it cannot.
2. The eMMC is overwritten in place. If you may ever want to return to stock, take the backup the
   installer offers as **menu item 2**, and take it *before* you flash. Phrozen do not publish a stock
   image for download, although their support has supplied one on
request. And once Unleashed is installed, a backup can only ever capture Unleashed.
3. Once the write begins there is no undo. If it fails, recovery means opening the printer and
taking the eMMC module out (MANUAL, Appendix A).

**Start from an empty stick.** The tools find their inputs by pattern (`Arco-Unleashed*.img.gz`,
`Arco_FW_V*.zip`) and take the **first** match. So an old firmware zip or a `(1)` re-download left
on the stick can win silently, and install something you did not intend.

**Taking the eMMC out instead?** Then the installer never runs, and the installer is what rescues the
gateway and images the old system. Do both yourself first, while the printer is still running
Phrozen's original system — the commands are in **[MANUAL › FAQ](MANUAL.md#appendix-c)**.

---

## Fill the stick

Extract **[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)** to the
**top level** of the stick. That supplies the image, its checksums, the self-flash tool and the guides.
Then add Phrozen's firmware zip if you want it:

| On the stick | From |
|---|---|
| `Arco-Unleashed_bookworm_6.18.30.img.gz` + `.sha256` + `.rawsize` | the release zip |
| `unleashed-selfflash.tar.gz` + `prepare_unleashed_self_flash.sh` | the release zip |
| `Arco_FW_V*.zip` | you download it from Phrozen |
| `arco-phrozen-ams.tar.gz` | collected for you while flashing — by hand only if you pull the eMMC |

**WiFi** — the printer must be online afterwards, because Step 3 runs over SSH. Pick one:

- **Nothing to do (default).** The flasher copies the network this printer is already using, region
  setting included.
- **A `wifi-seed.txt` you create** — plain text, no quotes, and a **2.4 GHz** network (the Arco has
no 5 GHz radio). Set `COUNTRY` to *your* two-letter region, or the printer may not join:
  ```
  SSID=YourNetworkName
  PSK=YourWiFiPassword
  COUNTRY=US
  ```
- **A `no_wifi.txt`** — leaves WiFi empty on purpose, and the printer raises its own setup hotspot on
  first boot so you can pick the network from your phone.

**Done when:** the *release zip* rows are on the stick, plus the firmware zip if you want it — and
no *older* image or firmware zip is left on it.

---

## Step 1 — Flash  ·  *MANUAL [Step 2](MANUAL.md#step-2)*

Put the filled stick back in the printer and SSH in as **`mks`** / **`makerbase`**. The address is
the printer's **IP** — look it up on your router or on the Phrozen display, because
`unleashed.local` only exists after the flash:

```bash
sh ~/printer_data/gcodes/USB/prepare_unleashed_self_flash.sh
```

It unpacks the flasher fresh from the stick and asks whether to start it. Answer **y**, give your
password, and a menu opens — **1** check only, **2** back up first, **3** install, **4** cancel
something already armed. Choose **3**.

Type `yes` to the disclaimer, then the target device to confirm. Reboot the printer. The display
shows a progress bar and the words **DO NOT POWER OFF**; when it is done the printer restarts by
itself.

> 🚪 **If something goes wrong *before* the write starts** — missing image, checksum mismatch, a hang —
> **pull the stick and power-cycle.** With no image on the stick the flasher stands down and your existing
> system boots normally.
>
> The flasher stays **armed**, which is how you retry: put a good image back and power-cycle. But if
> you stop here and keep using the old system, disarm the flasher — otherwise the next boot with
> that stick in overwrites the eMMC without asking:
> ```bash
> sudo bash ~/selfflash/install-unleashed.sh --disarm
> ```
>
> 🔌 **A checksum mismatch is usually the stick, not the download.** Take it off any **USB hub** and plug
> it straight into the printer, then copy the image again. If you see **CRC or I/O errors**, the stick
> itself is failing or is one this printer cannot drive — use another, preferably a plain USB 2.0 one.

**Done when:** the printer has rebooted itself and the progress bar is gone.

---

## Step 2 — First boot  ·  *MANUAL [Step 3](MANUAL.md#step-3)*

On this first boot the printer installs Phrozen's firmware and the rescued gateway files on its own,
restarts once more, and then settles on a **"Notice — Error occurred"** screen.

**That error is expected and is not a fault.** Klipper cannot start until Step 3 flashes the MCUs, so the
display has nothing to recover to — restarting or power-cycling will not clear it. Do not set
anything up on the display, and do not skip ahead. Wait for that screen to settle — a settled screen
is how you know the automatic restarts have finished.

> 🛑 **Do not power-cycle until it is finished.** Allow up to five minutes per stage. The display is
> drawn once per stage and then simply stays put, so an unchanged screen is **not** a hung printer —
> it is the normal picture. Cutting power in the middle does not speed anything up: it throws away
> the stage that was running and starts it again. Worse, a stage interrupted while it writes can
> leave the install half-done.

If you used `no_wifi.txt`, this is where the **Arco-Unleashed-Setup** hotspot appears — the full WiFi
scan happens first, so give it time.

**Done when:** the display sits on the settled "Error occurred" screen and the printer answers on your
network. Remove the stick.

> **Printer never appears?** Put a `wifi-seed.txt` (as in the stick preparation) on the stick and
> power-cycle. Until
> Phrozen's firmware is installed, the printer re-reads the stick on every power-cycle. It applies
> the file once, then renames it `.applied` so you can see it was picked up. Each seed is used
> **once**, and it is the contents that count. To try again, the details must actually differ — a
> corrected password, say. Writing out the
> identical file changes nothing, so if the details were right and it still did not join, use the setup
> portal instead.

---

## Step 3 — Flash the MCUs · **the one step that is not optional**  ·  *MANUAL [Step 5](MANUAL.md#step-5)*

The host runs Klipper v0.13; your MCUs still carry the factory firmware and cannot talk to it. SSH in
(`mks` / `makerbase`) and open the menu:

```bash
unleashed
```

Take **1 — Flash MCUs**. Only two chips are actually flashed: the **F407 main board** and the
**toolhead F103**. Klipper's **Linux host MCU** is not a chip at all — it is a process on the host
that reports CPU temperature.
Take **`a` — All three** and everything is done in one pass. The F407 goes over USB with no buttons.
The **toolhead F103** needs a one-time hands-on step. Remove the front cover (unplug its fan) and
undo the four screws of the back cover. Then, with the printer **running** and the script waiting at
its prompt: **hold BOOT → tap RESET while holding it → let go of BOOT → press ENTER.** There is no
countdown: the
chip reads BOOT the instant RESET comes back up, and afterwards stays in its bootloader until
something resets it again.

The teardown is pictured step by step in the **[MANUAL](MANUAL.md)**. Power the printer **off and unplug
it** before the covers come off; the flash itself then needs it switched on again.

When the flash finishes, switch the printer fully **off for about 10 seconds** and back on. A reboot
is not enough. Klipper is deliberately left stopped until you switch the printer off and
on, so nothing works in between — that is normal, not a failed flash.

**Done when:** after that power-cycle, Mainsail at `http://unleashed.local/` comes up **ready** with no MCU
error, and the display's error popup is gone.

---

## Step 4 — Calibrate, then save it  ·  *MANUAL [Step 7](MANUAL.md#step-7)*

Bed mesh, PID, input shaper and purge position are measured per machine and the image ships none — another
printer's numbers are worthless. Easiest is the display's **factory-reset auto-calibration**, which runs
input shaper, bed mesh and purge position back to back and returns to the home screen by itself. It does
**not** do PID: run `PID_BED` and `PID_NOZZLE` from Mainsail afterwards, then `SAVE_CONFIG`. There is **no
z-offset step** — the Arco probes with a load cell.

**Decline the "print test" the display offers.** Not because the file is bad — this kit replaces both
built-in test prints with its own. It is Phrozen's factory-reset print flow *on the display* that is
untested and used to stall here. Want the test print? Start `FDM_TEST.gcode` **from Mainsail**
instead; that route is verified. Or go straight to your own first print in Step 5.

Then save what you just measured: setup menu → **2 — Save / restore SETTINGS**. Also **copy it to a
USB stick** — the local copy lives on the very eMMC it is protecting.

**Done when:** calibration is back at the home screen, `SAVE_CONFIG` has restarted Klipper after the PID
runs, and your backup is on a stick.

---

## Step 5 — Print  ·  *MANUAL [Step 9](MANUAL.md#step-9)*

OrcaSlicer already ships the official **Phrozen Arco** profile, so no fork is needed. To also get the
kit's AMS auto-mode, import one of the two profiles from this project's `orca/` folder. OrcaSlicer runs
on your PC and the kit lives on the printer, so fetch them first — from
[GitHub](https://github.com/solutionphil/arco-unleashed/tree/main/orca) (*Download raw file*), or with
WinSCP from `~/arco-unleashed/orca/` on the printer. Then use *File → Import → Import Configs…*.
`(Unleashed)` loads your saved bed mesh at print start; `(Unleashed, adaptive mesh)` probes the
print area each time instead. Or paste the start G-code from the
**[README](README.md#orcaslicer--multicolor--ams-auto-mode)** into your own profile.

> **Own an AMS? There is nothing to switch on.** Plug it in and print. The printer detects the unit and
> sets its own flag within seconds, so `T1`–`T15` and the right print mode appear on their own.
>
> Two things you *can* set, both in one dialog — run **`AMS_SETUP`** in the Mainsail console: which
> slot serves which tool (for when the colours went in in a different order than you sliced), and
> **refeed**, which lets a single-colour print carry on from another slot when one runs out. The MANUAL
> has both in full.

Attach or remove the AMS whenever you like; Orca then picks single-colour, multicolour or auto-refill
by itself, decided at print start.

**Done when:** a sliced file prints.

---

## You're done

**Mainsail** is on `http://unleashed.local/` (`:81` works too) and **Fluidd** on
`http://unleashed.local:8808/` — the same ports your Arco used before, and the printer's IP works for
both if your network blocks mDNS. The theme is applied, the AMS is detected automatically, PhrozenGo is
on. Klipper is **not** pinned: it tracks
`master` and updates normally, and the guards on `klipper.service` re-apply this project's changes before
every start, so an update repairs itself.

Everything else is optional and lives in the setup menu. If something ever breaks, run **Emergency
repair** from it — one action, no diagnosis needed.

For remote access, prefer **Tailscale** or **WireGuard** over PhrozenGo's cloud.
