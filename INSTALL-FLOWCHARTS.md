# Arco Unleashed — every install path as a flowchart

The same procedure as [QUICKSTART](QUICKSTART.md) (checklist), [MANUAL](MANUAL.md) (pictures) and
[README](README.md) (reference) — drawn. Nothing here is new information: every box maps to a step in
those documents or to a script in this kit, named at the top of each section.

Diagrams render on GitHub, in VS Code and in any Markdown viewer with Mermaid.

**Reading the diagrams**

| Shape | Meaning |
|---|---|
| Rounded box | start / end state |
| Rectangle | you do something, or a script does |
| Diamond | a decision — every outgoing edge is a real option |
| Red box | **irreversible** — no undo past this point |
| Green box | a checkpoint: the "done when" of that step |

---

## 1. Which path is yours?

Four ways in and out. **A** and **B** install Unleashed and meet again at the first boot; **C** builds the
stack yourself from the Klipper-less base image; **D** takes the printer back to stock.

```mermaid
flowchart TD
    S(["Start"]) --> G{"What do you want to do?"}

    G -->|"Install Unleashed"| H{"Does the printer still boot<br/>a system of its own?"}
    G -->|"Build the Klipper stack myself<br/>no ready-made image"| C["Path C — base image + KIAUH"]
    G -->|"Undo it — back to<br/>Phrozen's Buster"| D["Path D — revert to Buster"]

    H -->|"Yes — stock Buster,<br/>or Unleashed already"| I{"Is opening the printer<br/>acceptable, and do you have<br/>an eMMC-to-USB adapter?"}
    H -->|"No — dead eMMC, a failed<br/>self-flash, or a fresh<br/>spare eMMC module"| B["Path B — eMMC swap on a PC"]

    I -->|"No teardown, no adapter"| A["Path A — self-flash<br/>the printer overwrites its own eMMC"]
    I -->|"Yes — and I want the stock<br/>eMMC kept as my way back"| B

    A --> M["Both paths meet here:<br/>first boot, then flash the MCUs"]
    B --> M
    C --> M2["Manual menu does the same<br/>steps by hand"]

    classDef path fill:#e8eeff,stroke:#3355bb,color:#000
    class A,B,C,D path
```

> **A pre-flashed spare eMMC** (someone hands you a module with the image already on it) is path B from
> "put the eMMC back in" onwards — skip the balenaEtcher step.

**Path A vs path B in one line:** A needs no screwdriver but is one shot with no net once the write
begins; B costs a teardown and is also the recovery route for a failed A.

---

## 2. Before anything is flashed — the two things you cannot get back later

`collect_data_arco.sh` · `install-unleashed.sh --backup` — QUICKSTART Step 0 and 0b.

```mermaid
flowchart TD
    P(["Printer still running its<br/>original Phrozen system"]) --> S0["Step 0 — rescue the AMS server<br/>bash collect_data_arco.sh ~/printer_data/gcodes/USB"]
    S0 --> S0C{"arco-phrozen-ams.tar.gz<br/>really on the stick?<br/>check it on your PC"}
    S0C -->|"No"| S0R["Re-insert the stick,<br/>run it again"] --> S0C
    S0C -->|"Yes"| W{"Do you ever want to go<br/>back to the factory system?"}

    W -->|"No"| GO(["Ready to install — section 3"])
    W -->|"Yes, and I take path A"| B1["Step 0b — image the whole eMMC to the stick<br/>sudo bash ~/selfflash/install-unleashed.sh --backup<br/>needs a stick of 8 GB or more, about 30 min"]
    W -->|"Yes, and I take path B"| B2["Dump the eMMC on the PC<br/>while it is out — section 5"]

    B1 --> B1D{"arco-emmc-backup.img.gz<br/>plus .sha256 on the stick?"}
    B1D -->|"No"| B1
    B1D -->|"Yes — keep it private,<br/>it holds your WiFi password<br/>and SSH keys"| GO
    B2 --> GO

    N["Not rescued by any of this:<br/>calibration, uploaded G-code,<br/>Phrozen's own system"]

    classDef danger fill:#ffe3e3,stroke:#cc0000,color:#000
    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class N danger
    class GO okay
```

> Phrozen publish **no** stock image. Step 0b is the only way to make one, and only *before* the flash —
> from Unleashed you can only ever image Unleashed.

---

## 3. What goes on the USB stick

One **FAT32** stick, ≥ 4 GB (≥ 8 GB if you also take the Step 0b image), plugged **straight into the
printer** — never through a hub. Start from an **empty** stick: the tools take the *first* pattern match,
so an old image or a `(1)` re-download can win silently.

```mermaid
flowchart LR
    subgraph SA["Path A — self-flash: the stick carries the image"]
        A1["Arco-Unleashed_bookworm_6.18.30.img.gz"]
        A2[".img.gz.sha256 — verified before any write"]
        A3[".img.gz.rawsize — drives the on-display percentage"]
        A4["unleashed-selfflash.tar.gz"]
        A5["prepare_unleashed_self_flash.sh"]
        A6["arco-phrozen-ams.tar.gz — from Step 0"]
        A7["Arco_FW_V zip — optional, see section 8"]
        A8["wifi-seed.txt or no_wifi.txt — optional, see section 7"]
    end

    subgraph SB["Path B — eMMC swap: the image goes on the eMMC, not the stick"]
        B6["arco-phrozen-ams.tar.gz — from Step 0"]
        B7["Arco_FW_V zip — optional, see section 8"]
    end

    Z["Arco-Unleashed-USB.zip<br/>extract to the top level of the stick"]
    S0["collect_data_arco.sh<br/>run on the original printer"]
    PH["You download Phrozen's<br/>firmware zip yourself"]

    Z --> A1
    Z --> A2
    Z --> A3
    Z --> A4
    Z --> A5
    S0 --> A6
    S0 --> B6
    PH --> A7
    PH --> B7
```

---

## 4. Path A — self-flash from the running printer

`prepare_unleashed_self_flash.sh` · `selfflash/install-unleashed.sh` — MANUAL "Path A",
[`selfflash/README.md`](selfflash/README.md). Works from stock Buster **and** from an Unleashed system
(that is also how you re-install or move to a newer image).

```mermaid
flowchart TD
    A0(["SSH in as mks — stick plugged in,<br/>auto-mounted at ~/printer_data/gcodes/USB"])
    A0 --> A1["sh prepare_unleashed_self_flash.sh<br/>unpacks the tool to ~/selfflash"]
    A1 --> A2["sudo bash ~/selfflash/install-unleashed.sh<br/>INSPECT — changes nothing"]
    A2 --> A3{"Image found, sha256 valid,<br/>target eMMC is the right one?"}
    A3 -->|"No"| AF["Fix the stick and repeat<br/>a mismatch is usually the stick itself:<br/>no hub, or try a plain USB 2.0 one"] --> A2
    A3 -->|"Yes"| A4["sudo bash ~/selfflash/install-unleashed.sh --arm"]

    A4 --> A5["Disclaimer — type yes"]
    A5 --> A6["Type the exact target device, e.g. /dev/mmcblk1"]
    A6 --> A7{"First-boot files on the stick?<br/>arco-phrozen-ams.tar.gz"}
    A7 -->|"Missing"| AX["Aborts — nothing written"] --> AF
    A7 -->|"Present"| A8{"Confirm the WiFi it will use<br/>live-captured or from wifi-seed.txt"}
    A8 -->|"Decline"| A9["Fall through to the<br/>first-boot phone portal"]
    A8 -->|"Confirm"| A10
    A9 --> A10["Initramfs rebuilt — ARMED"]
    A10 --> A11{"Reboot now?"}
    A11 -->|"No — --no-reboot"| A12["Stays armed until the next boot"] --> A13
    A11 -->|"Yes"| A13["Reboot — the SSH session drops,<br/>that is the reboot, not a fault"]

    A13 --> F1["Display step 1 of 3 — checking the image<br/>nothing written yet"]
    F1 --> F2["Display step 2 of 3 — WRITING the eMMC<br/>DO NOT POWER OFF"]
    F2 --> F3["Display step 3 of 3 — verifying<br/>first 512 MiB against the image"]
    F3 --> F4["Done — restarts itself<br/>LEAVE THE STICK IN"]
    F4 --> DONE(["Continue at section 6 — first boot"])

    A13 -.->|"image missing, checksum<br/>mismatch, or it hangs"| E1["ESCAPE HATCH — only before the write:<br/>pull the stick, power-cycle<br/>the old system boots normally"]
    E1 --> E2{"Retry?"}
    E2 -->|"Yes"| E3["Put a good image back,<br/>power-cycle — it is still armed"] --> A13
    E2 -->|"No, keep using the old system"| E4["sudo bash ~/selfflash/install-unleashed.sh --disarm<br/>otherwise the next boot with that stick<br/>overwrites the eMMC without asking"]

    F2 -.->|"failure after the write began"| R["No escape hatch left —<br/>recover with path B"]

    classDef danger fill:#ffe3e3,stroke:#cc0000,color:#000
    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class F2,R danger
    class DONE okay
```

**Extra switches:** `--image PATH` (flash a specific file — this is also how a backup is restored) ·
`--usb DIR` · `--yes` (skips the typed confirmations, discouraged) · `--no-reboot` ·
`--backup` (section 13) · `--disarm` (cancels a pending flash *or* a pending backup).

---

## 5. Path B — eMMC replacement and recovery

MANUAL Steps 1–3. Also the recovery route when a path-A write fails.

```mermaid
flowchart TD
    B0(["Printer off, hex keys, small Phillips,<br/>eMMC-to-USB adapter, PC with balenaEtcher"])
    B0 --> B1["Open the lower housing cover,<br/>unscrew and pull the eMMC module"]
    B1 --> B2{"Want a way back to the<br/>factory system?"}
    B2 -->|"Yes"| B3["Dump the eMMC to a file on the PC<br/>this is your only chance"]
    B2 -->|"No"| B4
    B3 --> B4["Write Arco-Unleashed_bookworm_6.18.30.img.gz<br/>onto the eMMC with balenaEtcher"]
    B4 --> B5["eMMC back in, close the housing"]
    B5 --> B6["Put the stick in — it needs at least<br/>arco-phrozen-ams.tar.gz"]
    B6 --> B7(["Power on — continue at section 6"])

    RE["Recovering a failed path-A flash?<br/>Same steps — the printer will not boot<br/>until the eMMC is written here"] --> B1

    classDef danger fill:#ffe3e3,stroke:#cc0000,color:#000
    class B4 danger
```

---

## 6. First boot — shared by path A and path B

`scripts/arco-firstrun.sh`, run once by `arco-firstrun.service`. Everything here is automatic; the
diagram exists so you can tell "still working" from "stuck".

```mermaid
flowchart TD
    S(["First boot of the new system"])
    S --> G0["Stage 0a — generate SSH host keys<br/>one identity per printer, not per release"]
    G0 --> G1["Stage 0b — grow the rootfs to the full eMMC"]
    G1 --> G2["Stage 0b2 — install the USB automount<br/>and replay the coldplug, so a stick that<br/>was already in gets mounted"]
    G2 --> G3["Stage 0b3 — align the self-heal guards<br/>with the kit actually in this image"]
    G3 --> G4["Stage 0c — headless onboarding:<br/>seed WiFi from the stick if the<br/>self-flash left markers"]
    G4 --> W{"Stage 1 — does the printer<br/>actually come ONLINE?<br/>real connectivity, not just a config"}

    W -->|"Yes"| P{"Stage 2 — is phrozen_dev installed?"}
    W -->|"No — up to ~150 s,<br/>see section 7"| PORTAL["Setup hotspot Arco-Unleashed-Setup<br/>join it from a phone, 192.168.4.1,<br/>pick network + country, tick consent"]
    PORTAL --> REB["Reboot onto your WiFi"] --> W

    P -->|"Yes"| FIN
    P -->|"No"| SRC["Install Phrozen's parts — section 8"]
    SRC --> AMS["Re-install the rescued AMS files<br/>from arco-phrozen-ams.tar.gz"]
    AMS --> PATCH["Apply the Unleashed v0.13 patches,<br/>defuse Phrozen's first-run wizard"]
    PATCH --> R2["Display: Update complete —<br/>wait for restart, then it restarts itself<br/>DO NOT power off here"]
    R2 --> FIN(["Display settles on<br/>Notice — Error occurred"])

    FIN --> NOTE["EXPECTED, not a fault: Klipper cannot start<br/>until the MCUs are flashed. Restarting does<br/>not clear it. Now remove the stick and<br/>continue at section 9"]

    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class FIN okay
```

> Allow up to five minutes per stage. The display is drawn once per stage and then stays put — an
> unchanged screen is not a hung printer, and power-cycling restarts the stage rather than speeding it up.

---

## 7. WiFi — every possibility

`scripts/wifi-portal/` · `install-unleashed.sh` (capture) · `arco-firstrun.sh` (`wait_online`).
The printer's radio is **2.4 GHz only**, and `COUNTRY` must be *your* region or it may not join.

```mermaid
flowchart TD
    W0(["How will the new system get online?"]) --> W1{"Which path?"}

    W1 -->|"Path A"| C1{"What is on the stick?"}
    C1 -->|"Nothing — recommended"| L["Live capture: copies the network<br/>this printer already uses,<br/>including its country"]
    C1 -->|"wifi-seed.txt"| SD["SSID= / PSK= / COUNTRY=<br/>plain text, no quotes, 2.4 GHz"]
    C1 -->|"no_wifi.txt"| NW["Leave WiFi empty on purpose"]
    L --> CONF{"--arm shows the SSID<br/>and asks you to confirm"}
    SD --> CONF
    CONF -->|"Confirm"| TRY
    CONF -->|"Decline"| NW

    W1 -->|"Path B"| NW

    TRY{"First boot: does it associate<br/>and get an address?"}
    TRY -->|"Yes, usually in a second or two"| OK(["Online — SSH in for section 9"])
    TRY -->|"No, and the SSID is on the air"| WAIT["Keep waiting, up to ~150 s —<br/>progress pushes the deadline out"] --> TRY
    TRY -->|"No, and the SSID is not in a scan"| NW

    NW --> PORTAL["Setup hotspot Arco-Unleashed-Setup<br/>appears — join from a phone,<br/>192.168.4.1"]
    PORTAL --> PSEL{"Portal reachable?"}
    PSEL -->|"Yes"| PDO["Pick network + country,<br/>tick the consent box, Connect"] --> OK
    PSEL -->|"No — nothing appears"| RESCUE["Rescue from the stick:<br/>drop a wifi-seed.txt on it<br/>and power-cycle"]
    RESCUE --> RN["Applied once, then renamed<br/>wifi-seed.txt.applied.<br/>To retry, the details must differ —<br/>or rename it back"]
    RN --> TRY

    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class OK okay
```

> The stick is re-read on **every** power-cycle until Phrozen's firmware is installed — after that, the
> printer's normal display WiFi screen takes over.

---

## 8. Phrozen's own software — where it comes from

`scripts/fetch-phrozen-fw.sh`. Nothing proprietary is shipped or mirrored by this project; you supply it,
or the printer fetches it from the vendor with your say-so.

```mermaid
flowchart TD
    F0(["phrozen_dev is missing"]) --> F1{"Arco_FW_V zip on the stick?"}
    F1 -->|"Yes — always wins,<br/>nothing is downloaded"| U["Install from your zip.<br/>Only this route also carries PhrozenGo,<br/>the display firmware .tft and the AMS firmware"]
    F1 -->|"No"| F2{"Consent on file?<br/>portal checkbox, or asked here<br/>if you have a terminal"}
    F2 -->|"Yes"| DL["Download from Phrozen's own public<br/>repository, pinned to a fixed commit<br/>and checksum-verified"]
    F2 -->|"No terminal, no consent"| STOP["Aborts — nothing installed"]
    U --> P["Apply the v0.13 patches"]
    DL --> P
    P --> DONE(["Display, AMS server and<br/>Phrozen macros in place"])

    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class DONE okay
```

**Put the zip on the stick if** the printer will have no internet during setup, **or** you want
PhrozenGo, a display-firmware (`.tft`) update, or the AMS firmware.

---

## 9. Flash the MCUs — the one step that is not optional

Setup menu item **1** → `scripts/flash_mcus.sh` (also `all` / `f407` / `f103` / `host` on the command
line). The host runs Klipper v0.13; the MCUs still carry factory firmware and cannot talk to it.

```mermaid
flowchart TD
    M0(["SSH in as mks<br/>bash ~/arco-unleashed/scripts/unleashed_setup.sh<br/>choose 1 — Flash MCUs"])
    M0 --> SEL{"What to flash?"}
    SEL -->|"F407 main board"| F407["USB DFU, no buttons —<br/>also auto-writes its serial<br/>into printer_MCU.cfg"]
    SEL -->|"Host MCU"| HOST["Rebuilt on the host itself —<br/>Klipper's CPU-temperature process,<br/>not a chip: no USB, no buttons"]
    SEL -->|"F103 toolhead"| K{"Katapult bootloader<br/>already on this toolhead?"}
    SEL -->|"all — the normal choice"| F407

    K -->|"Yes"| FL["Flashes through Katapult —<br/>no buttons any more"]
    K -->|"No — once per printer"| TD["Teardown: front cover off<br/>unplug its fan, four screws<br/>of the back cover"]
    TD --> BTN["Printer ON, script waiting at its prompt:<br/>hold BOOT — tap RESET while holding —<br/>release BOOT — press ENTER"]
    BTN --> FL

    F407 --> PC
    FL --> PC["Power the printer fully OFF for ~10 s,<br/>then on. A reboot is not enough —<br/>Klipper is deliberately left stopped"]
    PC --> CHK{"Mainsail on http://printer-ip/<br/>comes up ready, display popup gone?"}
    HOST --> CHK
    CHK -->|"No — mcu: Unable to connect<br/>or Command format mismatch"| RETRY["Repeat the flash for the MCU that failed"] --> SEL
    CHK -->|"Yes"| OK(["Printer is alive — calibrate next"])

    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class OK okay
```

---

## 10. Calibrate, save it, print

QUICKSTART Steps 5–6. The image ships **no** calibration on purpose — another printer's numbers are
worthless. There is **no z-offset step**: the Arco probes with a load cell.

```mermaid
flowchart TD
    C0(["Printer ready"]) --> C1{"How do you want to calibrate?"}
    C1 -->|"Easiest — from the display"| C2["Factory-reset auto-calibration:<br/>input shaper, bed mesh and purge<br/>position back to back"]
    C1 -->|"One at a time"| C3["The display's individual<br/>calibration routines"]
    C1 -->|"By hand"| C4["Mainsail: SHAPER_CALIBRATE,<br/>bed mesh, purge position"]
    C2 --> SKIP["Decline the display's print test —<br/>that flow is untested and stalls.<br/>Start FDM_TEST.gcode from Mainsail instead"]
    C3 --> SKIP
    C4 --> SKIP
    SKIP --> PID["PID is not covered by any of them:<br/>run PID_BED and PID_NOZZLE<br/>in Mainsail, then SAVE_CONFIG"]
    PID --> SAVE["Setup menu 2 — back up your settings,<br/>and copy it to a USB stick: the local<br/>copy sits on the eMMC it protects"]
    SAVE --> ORCA{"Slicer setup"}
    ORCA -->|"Stock profile is enough"| O1["OrcaSlicer already ships the<br/>official Phrozen Arco profile"]
    ORCA -->|"Want the kit's AMS auto-mode"| O2["Import orca/ presets:<br/>Unleashed loads your saved mesh,<br/>Unleashed adaptive mesh probes<br/>the print area each time"]
    ORCA -->|"Own profile"| O3["Paste the start G-code<br/>from the README"]
    O1 --> AMS["Set AMS on/off once in the setup menu<br/>whenever you attach or remove it"]
    O2 --> AMS
    O3 --> AMS
    AMS --> P(["A sliced file prints"])

    classDef okay fill:#e7f6e7,stroke:#22aa22,color:#000
    class P okay
```

---

## 11. The setup menu — everything it can do

`scripts/unleashed_setup.sh` (image path). Run it any time with
`bash ~/arco-unleashed/scripts/unleashed_setup.sh`.

```mermaid
flowchart LR
    MENU(["unleashed_setup.sh"])
    MENU --> E["ESSENTIAL"]
    MENU --> MN["MAINTENANCE"]
    MENU --> BR["SOMETHING BROKE"]
    MENU --> EX["EXTRAS"]
    MENU --> UP["UPDATE"]

    E --> E1["1 — Flash MCUs<br/>section 9"]

    MN --> M1["2 — Save / restore SETTINGS<br/>config, calibration, web-UI settings,<br/>WiFi, phrozen_dev — local or USB, no reboot"]
    MN --> M2["i — Save the WHOLE SYSTEM<br/>section 13"]
    MN --> M3["3 — Check self-heal guards<br/>are all of them wired? a kit update adds none"]

    BR --> B1["r — Emergency repair<br/>runs every repair in order, idempotent,<br/>then reports what actually needed fixing"]

    EX --> X2["4 — AddOn.cfg + features<br/>Mainsail theme, Fluidd"]
    EX --> X3["5 — PhrozenGo / Cloud<br/>privacy tunnel, OTA, disable<br/>turn OFF before installing Obico"]
    EX --> X4["b — Beacon probe<br/>EXPERIMENTAL, not hardware-tested"]
    EX --> X5["s — Sensorless XY homing<br/>alternative, for a failed switch"]

    UP --> U1["6 — Check for updates<br/>section 15"]
```

---

## 12. Path C — base image + KIAUH, the manual build

`unleashed` bootstrap → `scripts/unleashed_setup_manual.sh`. The base image is Armbian plus the Arco
hardware enablement — **no Klipper, no phrozen_dev**. Choose this if you want to assemble the stack
yourself.

```mermaid
flowchart TD
    C0(["Arco-Unleashed-Base_*.img.xz"]) --> C1["Flash it to the eMMC<br/>balenaEtcher, same as path B"]
    C1 --> C2["WiFi: edit /boot/arco-wifi.txt on the<br/>FAT partition from your PC"]
    C2 --> C3["Boot, then SSH in"]
    C3 --> C4["Install the Klipper stack with KIAUH:<br/>Klipper, Moonraker, Mainsail,<br/>KlipperScreen, Crowsnest"]
    C4 --> C5["~/klippy-env/bin/pip install numpy"]
    C5 --> C6["Run the unleashed command —<br/>fetches this kit from GitHub"]
    C6 --> MM(["Manual menu — unleashed_setup_manual.sh"])

    MM --> N1["1 — System prep<br/>apt-hold, governor, boot tweaks"]
    MM --> N2["2 — Install phrozen_dev<br/>from your USB: Arco_FW zip + AMS files"]
    MM --> N3["3 — Flash MCUs — section 9"]
    MM --> N4["4 — AddOn.cfg + features"]
    MM --> N5["5 — PhrozenGo / Cloud"]
    MM --> N6["b — Beacon probe, experimental"]
    MM --> N7["6 — Phrozen-update protection<br/>backup / pre-patch / restore"]
    MM --> N8["7 — Check for kit updates"]

    N3 --> CAL(["Then calibrate — section 10"])
```

---

## 13. Whole-system backup and restore

Setup menu **i** → `selfflash/install-unleashed.sh --backup` / `--arm --image`. This is the disk-image
kind: every file, the partition table, the bootloader. Menu **2** is the other kind — your settings only,
a few MB, quick, and it cannot revive a printer that no longer boots.

```mermaid
flowchart TD
    I(["Setup menu — i"]) --> Q{"Which action?"}

    Q -->|"s — save an image now"| S1["Checks the stick has room,<br/>then reboots"]
    S1 --> S2["Images the eMMC before the system<br/>starts, progress bar on the display"]
    S2 --> S3["Carries on booting by itself —<br/>nothing on the printer was touched"]
    S3 --> S4(["arco-emmc-backup.img.gz + .sha256<br/>on the stick, about 2 GB, ~30 min"])
    S4 --> S5["Keep it private — byte-for-byte,<br/>so it holds WiFi password and SSH keys"]

    Q -->|"r — restore from an image"| R1{"arco-emmc-backup.img.gz<br/>plus its .sha256 on the stick?"}
    R1 -->|"No"| RX["Refuses — the checksum is not optional"]
    R1 -->|"Yes"| R2["Hands over to install-unleashed.sh:<br/>type the target device in full"]
    R2 --> R3["Same three display steps as a flash —<br/>check, write, verify"]

    Q -->|"b — going back to Buster"| D(["Path D — section 14"])

    Q -->|"Cancel at any point"| C["Pull the stick —<br/>the run stands down"]

    classDef danger fill:#ffe3e3,stroke:#cc0000,color:#000
    class R3 danger
```

> An image taken from Unleashed **restores Unleashed**. The one that puts the printer back on Phrozen's
> system has to be made *before* the migration (section 2) — afterwards it cannot be produced at all.

---

## 14. Path D — back to Buster

Setup menu **i → b**, or `revert-to-buster/flash-buster-mcus.sh` by hand. **Swapping the eMMC is not
enough:** the MCU firmware sits on the STM32 chips, so a Buster host (v0.11) would boot and then fail to
find its own hardware.

```mermaid
flowchart TD
    D0(["Running Unleashed printer"]) --> D1{"Do you have an image of the<br/>ORIGINAL system, made before<br/>Unleashed was installed?"}
    D1 -->|"No"| DX["End of the road from here.<br/>Phrozen's firmware zip is an update<br/>package, not a system. The only<br/>remaining option is a stock eMMC<br/>from elsewhere — path B"]
    D1 -->|"Yes, on the stick as .img.gz + .sha256"| D2["Menu i → b, confirm the image is<br/>the original, then type REMOVE UNLEASHED"]

    D2 --> D3["1 of 2 — flash both MCUs back to v0.11<br/>F103 through Katapult, F407 via USB DFU,<br/>BOOT0 + RESET only as a fallback"]
    D3 --> D3C{"MCU flash succeeded?"}
    D3C -->|"No"| D3S["Stops — and that is the good outcome:<br/>nothing armed, eMMC untouched,<br/>this system still works"]
    D3C -->|"Yes — Klipper stops connecting<br/>immediately, that is expected"| D4["2 of 2 — arms the eMMC restore,<br/>reboots into it"]
    D4 --> D5["Power-cycle"]
    D5 --> D6(["v0.11 host + v0.11 MCUs — stock Buster"])

    ALT["Doing it by hand instead:<br/>copy revert-to-buster/ onto a stick,<br/>run flash-buster-mcus.sh on the running<br/>Unleashed system, power-cycle,<br/>then swap the eMMC to Buster"] --> D6

    BACK["Changed your mind? Re-run<br/>scripts/flash_mcus.sh to go back to v0.13"]

    classDef danger fill:#ffe3e3,stroke:#cc0000,color:#000
    class D3,D4 danger
```

Gone afterwards: the v0.13 stack, the self-heal guards, sensorless homing, the AddOn macros, Fluidd, the
theme, the WiFi portal, and the backup feature itself. Your prints, Orca profiles and the AMS keep working.

---

## 15. Updates and self-healing

`scripts/selfupdate.sh` · `scripts/update-from-usb.sh` · `scripts/check-guards.sh` ·
`scripts/emergency-repair.sh`.

```mermaid
flowchart TD
    subgraph KIT["Updating the kit itself"]
        K0{"Is the kit a git clone?"}
        K0 -->|"Yes"| K1["selfupdate.sh check / update<br/>menu item 6"]
        K0 -->|"No — the image ships a flat copy"| K2["selfupdate.sh adopt<br/>one time, keeps your files"] --> K1
        K0 -->|"No network at all"| K3["update-from-usb.sh /path/kit.tar<br/>unpacks beside the live kit and<br/>renames, never extracts over it"]
        K1 --> K4["selfupdate.sh auto on|off —<br/>optional daily systemd timer"]
    end

    subgraph HEAL["Surviving other people's updates"]
        H1["klipper.service runs seven ExecStartPre<br/>guards before klippy loads — the restart<br/>after any update puts things back"]
        H2["Menu 3 — check the guards are all wired.<br/>They are installed when the image is built,<br/>so an older printer can be missing one"]
        H3{"Moonraker's three buttons"}
        H3 -->|"Update"| H3a["Refuses on a modified repo,<br/>otherwise just pulls"]
        H3 -->|"Soft recover"| H3b["Resets tracked files,<br/>leaves untracked alone"]
        H3 -->|"Hard recover"| H3c["reset --hard + clean: deletes<br/>phrozen_dev and our modules.<br/>The guards put them back"]
    end

    subgraph PHR["Phrozen firmware updates"]
        P1["Back up once, right after setup —<br/>the golden snapshot"]
        P1 --> P2["Pre-patch the USB stick before EVERY<br/>Phrozen update: the update installs<br/>your fixes along with itself"]
        P2 --> P3["Restore — only if one ever<br/>slips through un-patched"]
    end

    BROKE(["Something is broken and you<br/>do not know what"]) --> ER["Menu r — Emergency repair:<br/>every repair in order, no diagnosis<br/>needed, no-op on a healthy printer"]
```

---

## 16. When it goes wrong — where to look

```mermaid
flowchart TD
    T(["Symptom"]) --> T1{"When did it happen?"}

    T1 -->|"While flashing, before the write"| S1["Pull the stick, power-cycle —<br/>the old system boots.<br/>Checksum mismatch is usually the stick:<br/>no hub, try a plain USB 2.0 one.<br/>Still armed — --disarm to cancel"]
    T1 -->|"While flashing, after the write began"| S2["Recover with path B —<br/>section 5"]

    T1 -->|"First boot"| B{"What do you see?"}
    B -->|"Never appears on the network"| B1["Wait ~90-150 s, then look for the<br/>Arco-Unleashed-Setup hotspot.<br/>Neither? wifi-seed.txt rescue — section 7"]
    B -->|"Notice — Error occurred"| B2["Expected until the MCUs are flashed —<br/>section 9"]
    B -->|"A Phrozen first-time setup wizard"| B3["Do not work through it —<br/>power-cycle once or twice, it clears"]
    B -->|"Screen has not changed in minutes"| B4["Allow five minutes per stage.<br/>Power-cycling restarts the stage"]

    T1 -->|"After the MCU flash"| M{"Klipper connects?"}
    M -->|"mcu: Unable to connect"| M1["Full power-off for ~10 s —<br/>a reboot is not enough"]
    M -->|"Command format mismatch"| M2["One MCU still has old firmware —<br/>re-run that one"]

    T1 -->|"After an update, or the printer halted"| U1["Menu r — Emergency repair.<br/>Then menu 3 to check the guards"]
    T1 -->|"Calibration will not finish"| C1["Decline the display's print test —<br/>run FDM_TEST.gcode from Mainsail"]
```

---

## Where each diagram comes from

| Section | Source in this repo |
|---|---|
| 1, 3 | [README](README.md) "Two ways to install", [QUICKSTART](QUICKSTART.md) Step 1 |
| 2 | `collect_data_arco.sh`, [QUICKSTART](QUICKSTART.md) Steps 0 / 0b |
| 4 | [`selfflash/install-unleashed.sh`](selfflash/install-unleashed.sh), [`selfflash/README.md`](selfflash/README.md) |
| 5 | [MANUAL](MANUAL.md) Steps 1–3 |
| 6, 7, 8 | [`scripts/arco-firstrun.sh`](scripts/arco-firstrun.sh), [`scripts/wifi-portal/`](scripts/wifi-portal), [`scripts/fetch-phrozen-fw.sh`](scripts/fetch-phrozen-fw.sh) |
| 9 | [`scripts/flash_mcus.sh`](scripts/flash_mcus.sh), [MANUAL](MANUAL.md) Step 5 |
| 10 | [QUICKSTART](QUICKSTART.md) Steps 5–6, [`orca/`](orca) |
| 11 | [`scripts/unleashed_setup.sh`](scripts/unleashed_setup.sh) |
| 12 | [`scripts/unleashed_setup_manual.sh`](scripts/unleashed_setup_manual.sh) |
| 13, 14 | [`scripts/_arco-lib.sh`](scripts/_arco-lib.sh), [`revert-to-buster/`](revert-to-buster) |
| 15 | [`scripts/selfupdate.sh`](scripts/selfupdate.sh), [`scripts/update-from-usb.sh`](scripts/update-from-usb.sh), [`scripts/check-guards.sh`](scripts/check-guards.sh), [`scripts/emergency-repair.sh`](scripts/emergency-repair.sh) |
| 16 | [MANUAL](MANUAL.md) Troubleshooting |
