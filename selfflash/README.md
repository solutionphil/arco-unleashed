# Install Unleashed from the running printer — quickstart

> ✅ **Proven on real hardware** — a full end-to-end run on a printer's own main eMMC (2026-07-10):
> flash → verify → reboot → headless WiFi onboarding → firmware install, without opening the printer.
>
> ⚠️ **Still one shot, no net.** Once the write has begun, a failure leaves the printer unbootable until you
> recover it — which means **pulling the eMMC and re-flashing it on a PC (path B)**. If you already own an
> eMMC adapter, **path B stays the safer default**.
>
> 🚪 **Escape hatch** — *before* the write begins (image missing, checksum mismatch, or the flasher hangs):
> **pull the USB stick and power-cycle.** With no image on the stick the flasher stands down and your
> existing system boots normally, even while still armed. Once the write has started, this no longer helps.
>
> ⚠️ **Your risk, and probably your warranty.** Replacing the factory OS and firmware will very likely
> **void your Phrozen warranty**, and you do it **entirely at your own risk** — there is no guarantee of
> any kind, and nobody here is liable for a printer that ends up damaged or unbootable. Keep the original
> eMMC, or a stock image, so you can go back.
>
> ℹ️ **This project is not affiliated with Phrozen.** Arco Unleashed is an independent, community-made
> project. It is not endorsed, supported or distributed by Phrozen, and **Phrozen cannot be asked for
> support on a printer running it.** *Phrozen* and *Arco* are the manufacturer's trademarks, used here
> only to say which machine this fits.

The running printer (Buster **or** Bookworm) overwrites its **own eMMC** with the full image from the
**external USB stick** — no teardown, no PC.

## 1) Prepare the USB stick (FAT32)

> 📦 The release ships **one archive** —
> **[`Arco-Unleashed-USB.zip`](https://github.com/solutionphil/arco-unleashed/releases)**. Extract it to the
> **top level of the stick** and everything this project provides is already in place (image, checksums,
> this tool, the guides). You then add the two files only you can supply: Phrozen's firmware and your own
> AMS backup.

Put **all** of these on one stick:
- `Arco-Unleashed_bookworm_6.18.30.img.gz` **+ `.sha256`**  ← the sha256 is verified before any write
- `Arco-Unleashed_bookworm_6.18.30.img.gz.rawsize`  ← drives the on-display progress %
- `unleashed-selfflash.tar.gz` **+ `prepare_unleashed_self_flash.sh`**  ← this tool (no kit/clone needed)
- `Arco_FW_V*.zip`            (Phrozen's official firmware — you provide it yourself)
- `arco-phrozen-ams.tar.gz`   (AMS backup, from `collect_data_arco.sh` on the printer)
- **WiFi (optional, precedence). Use one of the first two — they get the printer online without the display:**
  - **nothing → live capture** *(recommended)* — copies the network the printer is **already using**, so it's
    known-good and reconnects reliably on the new system.
  - **`wifi-seed.txt`** *(recommended)* — a small file you create, exactly:
    ```
    SSID=YourNetworkName
    PSK=YourWiFiPassword
    COUNTRY=US
    ```
    (plain text, one `KEY=value` per line, no quotes; a **2.4 GHz** network — the Arco's radio is 2.4 GHz).
    **`COUNTRY`** is your 2-letter WiFi region code (`US`, `GB`, `CA`, `DE`, …). **Set it** — a wrong/missing region
    can stop the printer joining your network (the regulatory domain must match your router). *Live capture*
    keeps the source printer's own country automatically, so `COUNTRY=` is only needed for `wifi-seed.txt`.
  - `no_wifi.txt` → leave WiFi empty → the **first-boot setup portal** comes up, so WiFi is set **from a phone**
    (not the display). Fine as a fallback, but you then set WiFi by hand at first boot.

> Whatever you choose, an empty/declined/**non-connecting** WiFi falls through to the first-boot portal
> after about **90 seconds**: the portal decision is made on real connectivity, so a wrong password or a
> changed network still brings it up. And if the portal itself fails to appear, the printer is still not a
> dead end — you can hand it the right network from the stick afterwards, see
> [First boot](#5-first-boot-of-the-new-system) below.

> **Coming from Buster:** the MCUs still carry the old firmware and must be flashed over SSH after the flash,
> so the printer **must reach WiFi** — prefer *live capture* or `wifi-seed.txt`. Until the MCUs are flashed the
> display shows an MCU error and its WiFi screen can't be used; the setup portal is the way in.

When you arm the flash, the installer **shows the Wi-Fi it will use** (captured or seeded SSID) and asks you
to confirm — decline, and it asks whether to fall through to the first-boot portal instead. So you always
see, and confirm, how the printer will get online before anything is written.

## 2) Log in + unpack the tool
SSH in as `mks`. The stick auto-mounts at `~/printer_data/gcodes/USB` (stock printer *and* Unleashed);
unpack the tool straight from there:
```bash
cd ~/printer_data/gcodes/USB          # where the stick auto-mounts
sh prepare_unleashed_self_flash.sh    # extracts install-unleashed.sh + initramfs/ to ~/selfflash
```
> If `~/printer_data/gcodes/USB` is empty, the stick didn't auto-mount. Mount it **to that same path** so
> the `cd` above still works (`lsblk` shows the partition):
> ```bash
> sudo mkdir -p /home/mks/printer_data/gcodes/USB
> sudo mount /dev/sda1 /home/mks/printer_data/gcodes/USB
> ```

## 3) Inspect (writes nothing)
```bash
sudo bash ~/selfflash/install-unleashed.sh
```
Finds the image, verifies the sha256, shows the target **eMMC** + size. Refuses if source==target, if the
checksum sidecar is missing, or if the target is removable.

## 4) Arm + flash
```bash
sudo bash ~/selfflash/install-unleashed.sh --arm      # disclaimer + consent, verify, confirm, arm, reboot
sudo bash ~/selfflash/install-unleashed.sh --disarm   # cancel a pending flash before the reboot
```
`--arm` prints the Phrozen non-affiliation disclaimer and asks you to type `yes`, then the target device
name. It then checks the stick for the first-boot files (`Arco_FW_V*.zip` + `arco-phrozen-ams.tar.gz`) —
**if either is missing it aborts before anything is written.**

**After the reboot** the initramfs flashes the eMMC and the display walks you through three named steps:

1. **Checking the image on the USB stick** — reads and hashes it. Nothing is written yet, so this step does
   *not* tell you to keep the power on.
2. **Writing the image to the internal eMMC** — progress bar in 5 % steps, and *now* the amber
   **DO NOT POWER OFF** warning. (The % needs the `.gz.rawsize` sidecar that ships with the image.)
3. **Verifying what was written** — compares the first 512 MiB against the image.

It then **reboots itself** into the new system. **Do not power off or pull the USB during steps 2 and 3.**

Options: `--image PATH` · `--usb DIR` · `--yes` (skip the typed confirmations — discouraged) · `--no-reboot`.

## 5) First boot of the new system
**Leave the USB stick plugged in.** The fresh system seeds its WiFi from the stick (no captive portal) and
installs the Phrozen firmware from it, rebooting once more on its own. Remove the stick once it settles,
then calibrate.

**If it never appears on your network:** wait **~90 s** first — that is how long it tries the seeded WiFi
before giving up and raising its own `Arco-Unleashed-Setup` hotspot for your phone. If neither shows up,
rescue it from the same stick: put a **`wifi-seed.txt`** in the stick's top-level folder —

```
SSID=YourNetworkName
PSK=YourWiFiPassword
COUNTRY=US
```

— then **power-cycle** the printer. One file, nothing else: this stage re-runs on every boot until the
Phrozen install completes, so it picks the file up, joins the network, and renames it to
`wifi-seed.txt.applied` to show it was used (applied once, so a later boot cannot overwrite a network you
set through the portal meanwhile — rename it back to re-arm).

> Watch out for Notepad saving it as `wifi-seed.txt.txt` (enable *View → File name extensions*). A UTF-8
> BOM and Windows line endings are handled. The network must be **2.4 GHz**.
>
> Older images that predate this only accept the two-file form: an empty `.arco-skip-portal` plus an
> `.arco-wifi.conf` holding a full `wpa_supplicant` config. That route still works on current images.

## Recovery if it ever bricks
**Pull the eMMC and re-flash it on a PC — this is exactly [path B](../MANUAL.md).** Open the housing, take
the eMMC out, write the image onto it with balenaEtcher, put it back. The external USB port cannot recover
the printer, and the SoC itself is unbrickable (mask ROM) — so nothing you do here can permanently kill the
board; the worst case is the eMMC re-flash you'd do for path B anyway.

---
### Known limits
- **One printer, one run.** It has been proven end-to-end once, on a Bookworm system flashing itself.
  Buster is supported by design (same bootloader chain, same initramfs tooling) but has not been run.
- **The write is not resumable.** There is no A/B slot and no rollback: the image is streamed straight onto
  the eMMC. That is inherent — the board has ~1 GB of RAM and the image is ~5.5 GB uncompressed, so it
  cannot be staged anywhere first.
- **The external USB port cannot recover the printer.** It is a host port; the Rockchip mask-ROM loader
  lives on the *internal* USB-C. Recovery therefore always opens the housing.
