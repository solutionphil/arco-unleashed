# Arco Unleashed — Quick Start

From a stock Phrozen Arco to **Debian Bookworm · kernel 6.18 · Klipper v0.13**, without opening the
printer: it flashes its own eMMC from a USB stick.

Seven steps, about **90 minutes**, of which maybe 20 are hands-on — the rest is waiting for the printer.
Every screen is pictured in the **[MANUAL](MANUAL.md)**; the full reference is the **[README](README.md)**.

*The step numbers are the MANUAL's, so you can switch between the two at any point. The gaps — 5, 7, 9,
11 — are the steps this short path folds in or leaves out.*

> ⚠️ **Your risk, and probably your warranty.** Replacing the factory OS and firmware will very likely
> **void your Phrozen warranty**, and you do it entirely at your own risk — no guarantee of any kind, and
> nobody here is liable for a printer that ends up damaged or unusable.
>
> ℹ️ **Not affiliated with Phrozen.** Arco Unleashed is an independent, community-made project — not
> endorsed, supported or distributed by Phrozen, who cannot be asked for support on a printer running it.
> *Phrozen* and *Arco* are their trademarks, used only to say which machine this fits. **No Phrozen
> proprietary software is shipped or downloaded here** — you supply their firmware package yourself.

---

## Before you begin

**You need:** the printer on your network · a PC · one **empty, freshly formatted FAT32 stick** (≥ 4 GB,
plugged straight into the printer — **never through a USB hub**) ·
Phrozen's **`Arco_FW_V*.zip`** *(you download it from Phrozen)* · an SSH client (**PuTTY** on Windows) ·
a **2.5 mm hex key** for Step 6.

**Three things are irreversible, so decide now:**

1. The AMS server exists **only on your printer** and the flash erases it. **Step 1 saves it.** Skip that
   and AMS detection hangs afterwards, with no way to recover the files.
2. The eMMC is overwritten in place. If you may ever want to return to stock, the only way to keep that
   option is Step 2 below: it images the whole eMMC onto your stick, no teardown needed.
   Phrozen do not publish a stock image.
3. Once the write begins there is no undo — a failure needs the eMMC route to recover (MANUAL, Appendix A).

**Start from an empty stick.** The tools find their inputs by pattern (`Arco-Unleashed*.img.gz`,
`Arco_FW_V*.zip`) and take the **first** match, so an old firmware zip or a `(1)` re-download left on the
stick can win silently and install something you did not intend.

---

## Step 1 — Save what only your printer has

> 🛑 **Not a backup of your printer.** This rescues **two files** that exist nowhere else. Your
> calibration, your uploaded G-code and Phrozen's own system are **erased and gone**. If you want a way
> back, make one first — **Step 2** below images the whole eMMC onto your stick, without opening the
> printer.

On the **still-running original printer**. Insert the stick — it auto-mounts at
`~/printer_data/gcodes/USB` (check with `lsblk` if in doubt) — then SSH in (`mks` / `makerbase`, port 22)
and run **one** of:

`collect_data_arco.sh` is in the release zip, so **it is already on the stick** if you extracted that
first (*Fill the stick*, below). If you are using the printer's original Phrozen stick instead, copy the one file onto
it from your PC. Then:

```bash
bash ~/printer_data/gcodes/USB/collect_data_arco.sh ~/printer_data/gcodes/USB
```

Downloading it on the printer instead works only once this project's repository is public:

```bash
wget https://raw.githubusercontent.com/solutionphil/arco-unleashed/main/collect_data_arco.sh -O /tmp/collect.sh
bash /tmp/collect.sh ~/printer_data/gcodes/USB
```

While it is still private that URL answers **404 Not Found**, which looks like a broken link rather
than a permission problem — use the stick.

**Done when:** `arco-phrozen-ams.tar.gz` is on the stick — *check it on your PC*, not just on screen. If
it is missing, re-insert the stick and run the command again.

---

## Step 2 — *optional:* your way back

Phrozen publish no stock image, so once the eMMC is overwritten the machine you have today is gone unless
you copied it first. This copies **all of it** onto your stick as one file — no screws, no PC:

```bash
sh ~/printer_data/gcodes/USB/prepare_unleashed_self_flash.sh
sudo bash ~/selfflash/install-unleashed.sh --backup
```

It checks that the stick has room, then reboots and images the eMMC before the system starts, with a
progress bar on the display. When it is done it carries on booting by itself — nothing on the printer was
touched, so there is nothing to restart for. Pulling the stick cancels it at any point. Needs a **stick of
8 GB or more**; on a 32 GB eMMC it took about half an hour and produced a 2.3 GB file. It runs **once per
command**: run it again for another backup. Write one back later with `--arm --image <that file>`, or from
the setup menu under **i)**. Full details in the **[MANUAL](MANUAL.md)**.

**Keep the file private** — it is a byte-for-byte copy, so it holds your WiFi password and SSH keys.

**Done when:** `arco-emmc-backup-stock.img.gz` and its `.sha256` are on the stick.
(The name says which system it holds: `-stock` before migrating, `-unleashed` after. Each rotates on
its own, so a routine backup can never overwrite the one that takes you back to Phrozen's system.)

---

## Fill the stick

Extract **[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)** to the
**top level** of the stick. That supplies the image, its checksums, the self-flash tool and the guides.
Then add the two files only you can provide:

| On the stick | From |
|---|---|
| `Arco-Unleashed_bookworm_6.18.30.img.gz` + `.sha256` + `.rawsize` | the release zip |
| `unleashed-selfflash.tar.gz` + `prepare_unleashed_self_flash.sh` | the release zip |
| `Arco_FW_V*.zip` | you download it from Phrozen |
| `arco-phrozen-ams.tar.gz` | Step 1 |

**WiFi** — the printer must be online afterwards, because Step 6 runs over SSH. Pick one:

- **Nothing to do (default).** The flasher copies the network this printer is already using, region
  setting included.
- **A `wifi-seed.txt` you create** — plain text, no quotes, a **2.4 GHz** network (the Arco has no 5 GHz
  radio), and `COUNTRY` set to *your* two-letter region or it may not join:
  ```
  SSID=YourNetworkName
  PSK=YourWiFiPassword
  COUNTRY=US
  ```
- **A `no_wifi.txt`** — leaves WiFi empty on purpose, and the printer raises its own setup hotspot on
  first boot so you can pick the network from your phone.

**Done when:** all four rows above are on the stick, and no *older* image or firmware zip is.

---

## Step 3 — Flash

Put the filled stick back in the printer, then SSH in again and arm it:

```bash
sh ~/printer_data/gcodes/USB/prepare_unleashed_self_flash.sh
sudo bash ~/selfflash/install-unleashed.sh --arm
```

Type `yes` to the disclaimer, then the target device to confirm. Reboot the printer: the display shows a
progress bar and **DO NOT POWER OFF**, then it restarts by itself.

> 🚪 **If something goes wrong *before* the write starts** — missing image, checksum mismatch, a hang —
> **pull the stick and power-cycle.** With no image on the stick the flasher stands down and your existing
> system boots normally.
>
> It stays **armed**, which is how you retry: put a good image back and power-cycle. But if you stop here
> and keep using the old system, cancel it — otherwise the next boot with that stick in overwrites the
> eMMC without asking:
> ```bash
> sudo bash ~/selfflash/install-unleashed.sh --disarm
> ```
>
> 🔌 **A checksum mismatch is usually the stick, not the download.** Take it off any **USB hub** and plug
> it straight into the printer, then copy the image again. If you see **CRC or I/O errors**, the stick
> itself is failing or is one this printer cannot drive — use another, preferably a plain USB 2.0 one.

**Done when:** the printer has rebooted itself and the progress bar is gone.

---

## Step 4 — First boot

It installs Phrozen's firmware and your rescued AMS files on its own, restarts once more, and then settles on a
**"Notice — Error occurred"** screen.

**That error is expected and is not a fault.** Klipper cannot start until Step 6 flashes the MCUs, so the
display has nothing to recover to — restarting or power-cycling will not clear it. Do not set anything up
on the display, and do not skip ahead: wait for that screen to settle, which is how you know the automatic
restarts have finished.

**Allow up to five minutes per stage and do not power-cycle to hurry it.** The display is drawn once per
stage and then simply stays put; an unchanged screen is not a hung printer. Power-cycling in the middle
restarts the stage rather than speeding it up. If you used `no_wifi.txt`, this is where the
**Arco-Unleashed-Setup** hotspot appears — the full WiFi scan happens first, so give it time.

**Done when:** the display sits on the settled "Error occurred" screen and the printer answers on your
network. Remove the stick.

> **Printer never appears?** Put a `wifi-seed.txt` (as in the stick preparation) on the stick and power-cycle. The first
> boot re-reads the stick on every power-cycle until Phrozen's firmware is installed, applies the file
> once, and renames it `.applied` so you can see it was picked up. Each seed is used **once, by its
> contents**: to try again the details must actually differ — a corrected password, say. Writing out the
> identical file changes nothing, so if the details were right and it still did not join, use the setup
> portal instead.

---

## Step 6 — Flash the MCUs · **the one step that is not optional**

The host runs Klipper v0.13; your MCUs still carry the factory firmware and cannot talk to it. SSH in
(`mks` / `makerbase`) and open the menu:

```bash
unleashed
```

Take **1 — Flash MCUs**. The **F407 main board** and the **host MCU** flash over USB with no buttons. The
**toolhead F103** needs a one-time hands-on step: remove the front cover (unplug its fan), undo the four
screws of the back cover, and with the printer **running** and the script waiting at its prompt —
**hold BOOT → tap RESET while holding it → let go of BOOT → press ENTER.** There is no countdown: the
chip reads BOOT the instant RESET comes back up, and afterwards stays in its bootloader until
something resets it again.

The teardown is pictured step by step in the **[MANUAL](MANUAL.md)**. Power the printer off only while
the covers are coming off; the flash itself needs it switched on.

When the flash finishes, switch the printer fully **off for about 10 seconds** and back on. A reboot is
not enough, and Klipper is deliberately left stopped until you do it — so nothing works in between, and
that is not a failed flash.

**Done when:** after that power-cycle, Mainsail at `http://<printer-ip>/` comes up **ready** with no MCU
error, and the display's error popup is gone.

---

## Step 8 — Calibrate, then save it

Bed mesh, PID, input shaper and purge position are measured per machine and the image ships none — another
printer's numbers are worthless. Easiest is the display's **factory-reset auto-calibration**, which runs
input shaper, bed mesh and purge position back to back and returns to the home screen by itself. It does
**not** do PID: run `PID_BED` and `PID_NOZZLE` from Mainsail afterwards, then `SAVE_CONFIG`. There is **no
z-offset step** — the Arco probes with a load cell.

**Skip any "print test" it offers.** That bundled file was compiled for the old Klipper and cannot run, so
the flow stalls on it.

Then save what you just measured — setup menu → **2 — Backup / restore settings** → also **copy it to a
USB stick**, because the local copy lives on the very eMMC it is protecting.

**Done when:** calibration is back at the home screen, `SAVE_CONFIG` has restarted Klipper after the PID
runs, and your backup is on a stick.

---

## Step 10 — Print

OrcaSlicer already ships the official **Phrozen Arco** profile, so no fork is needed. To also get the
kit's AMS auto-mode, import one of the two profiles in [`orca/`](orca/) via *File → Import → Import
Configs…* — `(Unleashed)` loads your saved bed mesh at print start, `(Unleashed, adaptive mesh)` probes
the print area each time instead. Or paste the start G-code from the
**[README](README.md#orcaslicer--multicolor--ams-auto-mode)** into your own profile.

> ⚠️ **Own an AMS? It ships switched off.** Every image does, because most printers have no AMS and one
> that opens the port with nothing attached just waits and reports errors. Connected but not switched
> on, **the spools do not turn** — that is the setting, not a fault. Type `AMS_ON` once in the Mainsail
> console (or use the setup menu). See the MANUAL for what it changes.

Set AMS **on** or **off** once in the setup menu whenever you physically attach or remove it; Orca then
picks single-colour, multicolour or auto-refill by itself.

**Done when:** a sliced file prints.

---

## You're done

**Mainsail** is on `http://<printer-ip>/` (`:81` works too) and **Fluidd** on `:8808` — the same ports your
Arco used before. The theme is applied, AMS is off, PhrozenGo is on. Klipper is **not** pinned: it tracks
`master` and updates normally, and the guards on `klipper.service` re-apply this project's changes before
every start, so an update repairs itself.

Everything else is optional and lives in the setup menu. If something ever breaks, run **Emergency
repair** from it — one action, no diagnosis needed.

For remote access, prefer **Tailscale** or **WireGuard** over PhrozenGo's cloud.
