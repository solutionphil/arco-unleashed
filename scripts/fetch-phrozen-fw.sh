#!/bin/bash
# fetch-phrozen-fw.sh — install Phrozen's parts, then apply the Arco Unleashed v0.13 patches.
#
# TWO SOURCES, and the user's own zip always wins:
#   1. Arco_FW_V*.zip on a FAT32 USB stick — the offline route, and the only one that also carries
#      PhrozenGo. (The display and AMS firmware also ride along, but those are updated through
#      Phrozen's own USB firmware update, so they are not a reason to bring the zip.)
#   2. otherwise, on the user's say-so, Phrozen's own public repository (github.com/phrozen3d/klipper,
#      GPL-3.0), pinned to a fixed commit and verified by checksum.
#
# This project still stores and mirrors NOTHING of Phrozen's. Route 2 points at the vendor's own
# server and downloads onto the owner's printer; no copy is ever hosted, cached or redistributed here.
# See THIRD-PARTY-NOTICES.md.
#
# Usage:  bash fetch-phrozen-fw.sh                 # USB zip if present, else offer the download
#         FW_ZIP=/path/Arco_FW_V199.zip bash …     # use an explicit path (arco-firstrun passes this)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PD="$HOME/klipper/klippy/extras/phrozen_dev"
CONSENT=/var/lib/arco-unleashed/phrozen-consent   # written by the portal or by an interactive confirm here

# Using Phrozen's software is the user's own, informed choice. If consent wasn't already given (via the
# WiFi portal) and we have an interactive terminal, show the notice and ask once. Non-interactive
# callers (firstrun) rely on the portal having recorded consent, so they pass through silently.
if [ ! -f "$CONSENT" ]; then
  if [ -t 0 ]; then
    echo "This installs Phrozen's OFFICIAL software onto your printer — either from the"
    echo "Arco_FW_V*.zip you put on a USB stick, or, if there is none, downloaded from Phrozen's"
    echo "own public repository (you are asked again before anything is downloaded)."
    echo "PhrozenGo / ThroughTek (TUTK) cloud parts are subject to Phrozen's own license & privacy terms,"
    echo "which you accept at your own responsibility."
    read -rp "Proceed installing Phrozen's software? [y/N] " a
    [[ "$a" =~ ^[yYjJ]$ ]] || { echo "Cancelled."; exit 0; }
    sudo mkdir -p "$(dirname "$CONSENT")"
    echo "phrozen-use acknowledged via fetch-phrozen-fw.sh at $(date -Is)" | sudo tee "$CONSENT" >/dev/null
  else
    echo "ERROR: no Phrozen-use consent on file and no interactive terminal — aborting."; exit 1
  fi
fi

command -v unzip >/dev/null 2>&1 || sudo apt install -y unzip
WORK="$(mktemp -d)"

# optional first-boot progress screen on the TFT (no-op stubs if tft.sh is missing or voronFDM is up)
if [ -f "$DIR/tft.sh" ]; then source "$DIR/tft.sh"; else tft_init(){ :; }; tft_status(){ :; }; tft_done(){ :; }; tft_hint(){ :; }; fi

# ---- where Phrozen's module comes from -----------------------------------------------------------
# Phrozen publishes phrozen_dev themselves, in their own public Klipper fork, so it can be fetched
# from THEM instead of demanding a firmware zip from every recipient. Nothing changes about what this
# project distributes: we still store and mirror nothing, we only point at the vendor's own server.
#
# PINNED TO A COMMIT, never to the branch. What has to stay in step is voronFDM against the display
# firmware already on the panel, and this commit's voronFDM is byte-identical to the one V199
# installs (sha256 below, checked against a printer that has run it for months). Following the branch
# would silently hand a recipient a display binary nobody here has ever booted.
PHROZEN_PIN=c1289f07b0a00e2bf126643544e3e48fc31fbc79
PHROZEN_TARBALL="https://codeload.github.com/phrozen3d/klipper/tar.gz/$PHROZEN_PIN"
PHROZEN_VORONFDM_SHA=b7f827fbcef26e1836357d1c466f9b57fe73bf2a84904438c5e8d4acac74faea

GH_MOD=""
fetch_from_github(){
  command -v curl >/dev/null 2>&1 || { echo "   curl is not installed."; return 1; }
  command -v tar  >/dev/null 2>&1 || return 1
  mkdir -p "$WORK/gh"
  echo ">> Downloading Phrozen's module from Phrozen's own repository:"
  echo "   $PHROZEN_TARBALL"
  tft_status "Downloading Phrozen module..." 30
  # Streamed straight into tar with a path filter, so only klippy/extras/phrozen_dev is ever written
  # and the rest of the Klipper tree never touches the disk. connect-timeout keeps a printer with an
  # IP but no route to the internet from hanging here for minutes -- that is the LAN-without-internet
  # case, which wait_online in arco-firstrun cannot detect (it only checks for an address).
  curl -fsSL --connect-timeout 15 --max-time 900 "$PHROZEN_TARBALL" \
    | tar -xz -C "$WORK/gh" --wildcards '*/klippy/extras/phrozen_dev/*' 2>/dev/null \
    || { echo "   download failed (no internet, or the repository moved)."; return 1; }
  local m got
  m="$(dirname "$(find "$WORK/gh" -name base.py 2>/dev/null | head -1)")"
  [ -n "$m" ] && [ -f "$m/cmds.py" ] || { echo "   the download did not contain the module."; return 1; }
  # Integrity is checked by HASH, not by "curl did not error": a captive portal, a proxy or a
  # truncated stream all produce a tar that extracts and a printer that then will not display.
  got="$(sha256sum "$m/serial-screen/voronFDM" 2>/dev/null | cut -d' ' -f1)" || true
  [ "$got" = "$PHROZEN_VORONFDM_SHA" ] || {
    echo "   CHECKSUM MISMATCH on voronFDM (got: ${got:-nothing}) — refusing this download."; return 1; }
  echo "   verified: voronFDM matches the expected build."
  GH_MOD="$m"; return 0
}

# The user's own zip always wins: it is the offline route, it is what an owner already has, and it
# carries PhrozenGo, which the public repository does not.
# Only when there is none do we go to the network.
SELF_MOUNTED=0
SRC=""
FWZIP="${FW_ZIP:-}"
if [ -z "$FWZIP" ] || [ ! -f "$FWZIP" ]; then
  source "$DIR/usb-fw.sh"
  echo ">> Looking for Arco_FW_V*.zip on a FAT32 USB stick..."
  if FWZIP="$(find_fw_zip)" && [ -n "$FWZIP" ]; then SELF_MOUNTED=1; else FWZIP=""; fi
fi
trap '[ "$SELF_MOUNTED" = 1 ] && cleanup_fw_mount 2>/dev/null; rm -rf "$WORK"' EXIT

if [ -n "$FWZIP" ]; then
  SRC=zip
  echo ">> Using firmware package from USB: $FWZIP"
  tft_status "Reading firmware from USB..." 30
  unzip -q -o "$FWZIP" -d "$WORK/x"
  tft_status "Extracting package..." 55
  # In V199 the package layout is  Arco_FW_V199/phrozen_dev/{phrozen_dev.zip, *.tft, FW_Arco-AMS*, …}
  # The Klipper module (base.py/cmds.py/voronFDM) is inside the NESTED phrozen_dev.zip — extract that.
  NESTED="$(find "$WORK/x" -iname 'phrozen_dev.zip' 2>/dev/null | head -1)"
  [ -n "$NESTED" ] || { echo "ERROR: phrozen_dev.zip not found in the package."; exit 1; }
  unzip -q -o "$NESTED" -d "$WORK/mod"
  MOD="$(dirname "$(find "$WORK/mod" -name base.py 2>/dev/null | head -1)")"
  [ -n "$MOD" ] && [ -f "$MOD/cmds.py" ] || { echo "ERROR: module (base.py/cmds.py) not found inside phrozen_dev.zip."; exit 1; }
else
  echo ">> No Arco_FW_V*.zip on USB."
  # Interactive: the download is the user's act, so it is their decision, named and sourced. Callers
  # without a terminal (arco-firstrun) rely on the consent the portal already recorded.
  if [ -t 0 ]; then
    echo
    echo "   Phrozen's display module can be downloaded from Phrozen's own public repository"
    echo "   (github.com/phrozen3d/klipper, GPL-3.0, pinned to a fixed, verified commit)."
    echo "   It gives you the display, the AMS support and the Klipper module — everything a"
    echo "   working printer needs. The one thing it does not carry is PhrozenGo, Phrozen's cloud"
    echo "   app, which lives only in their own package."
    echo
    read -rp "   Download it now? [Y/n] " a
    [[ "$a" =~ ^[nN]$ ]] && { echo "Cancelled — put Arco_FW_V*.zip on the stick and run this again."; exit 0; }
  fi
  if fetch_from_github; then
    SRC=github
    MOD="$GH_MOD"
  else
    echo
    echo "ERROR: could not get Phrozen's module — no USB package and the download did not work."
    echo "  Offline route, works without any internet on the printer:"
    echo "    1. on your PC, download Arco_FW_V*.zip from Phrozen's website"
    echo "    2. copy it, still zipped, to the TOP LEVEL of a FAT32 USB stick"
    echo "    3. plug the stick into the printer and run this again:"
    echo "       bash ~/arco-unleashed/scripts/fetch-phrozen-fw.sh"
    tft_status "No internet and no USB package - see the manual" 10
    exit 1
  fi
fi

# Stops after the source decision without touching the printer. Used by the test harness, and useful
# in support: "which source would THIS printer take, and is the download actually reachable from it?"
if [ "${ARCO_FETCH_DRYRUN:-0}" = 1 ]; then
  echo "DRY RUN — source=$SRC  module=$MOD"
  exit 0
fi

# cp cannot overwrite a RUNNING executable — the kernel returns ETXTBSY ("Text file busy"). On a
# printer that is already up, voronFDM and ota_control are live, so `cp -r` failed on exactly those
# two files AFTER replacing everything else, and set -e then aborted the run BEFORE the v0.13 patches.
# The result was a printer carrying an unpatched module on a v0.13 Klipper, still running only because
# nothing had restarted klippy yet. A first boot never hits this (voronFDM is not started until the
# install is done), which is why it survived until the first manual re-run — the setup menu's "fetch
# from USB", or switching between the zip and the download.
# rename(2) has no such restriction: the running process keeps the old inode and the new file takes
# the name. So every file is staged beside its target and moved into place.
install_tree(){
  local src="$1" dst="$2" rel fails=0
  while IFS= read -r -d '' rel; do mkdir -p "$dst/$rel"; done \
    < <( cd "$src" && find . -mindepth 1 -type d -printf '%P\0' )
  while IFS= read -r -d '' rel; do
    if ! { cp -f "$src/$rel" "$dst/$rel.arco-new" && mv -f "$dst/$rel.arco-new" "$dst/$rel"; }; then
      echo "   FAILED to install $rel" >&2; rm -f "$dst/$rel.arco-new" 2>/dev/null; fails=1
    fi
  done < <( cd "$src" && find . -type f -printf '%P\0' )
  [ "$fails" = 0 ]
}

echo ">> Installing phrozen_dev module -> $PD  (source: $SRC)"
tft_status "Installing display + module..." 80
mkdir -p "$PD"
install_tree "$MOD" "$PD" || { echo "ERROR: could not install every file of the module — stopping before the patches."; exit 1; }
# Neither unzip nor a GitHub tarball preserves the executable bit the way we need it -> restore it on
# the start scripts + display/cloud binaries, otherwise KlipperScreen.service fails with
# status=203/EXEC and the display stays blank.
find "$PD" -type f \( -name '*.sh' -o -name 'voronFDM*' -o -name 'frpc' -o -name 'ota_control' \) -exec chmod +x {} \; 2>/dev/null || true
# The display .tft + AMS firmware sit NEXT TO the nested zip (not inside it) -> copy from the outer
# tree. Zip route only: Phrozen does not publish either of them, and neither is needed to print.
if [ "$SRC" = zip ]; then
  find "$WORK/x" -maxdepth 4 \( -name "*.tft" -o -name "FW_Arco-AMS*" \) -exec cp -f {} "$PD"/ \; 2>/dev/null || true
fi

# ---- AMS server (phrozen_master + ~/hdlDat): these are Phrozen BASE-OS files, NOT inside the
# Arco_FW_V*.zip. The user collects them from their own printer with collect_data_arco.sh and puts
# the resulting arco-phrozen-ams.tar.gz on the same USB. Without them voronFDM hangs ~60s on the AMS
# unix socket (/tmp/UNIX.domain) + spams "connect to server fail", and page-home after auto-cal
# breaks. arco-firstrun passes AMS_TARBALL; standalone runs search the stick.
AMS_TAR="${AMS_TARBALL:-}"
[ -n "$AMS_TAR" ] && [ -f "$AMS_TAR" ] || \
  AMS_TAR="$(find "$(dirname "$FWZIP")" /media /mnt -maxdepth 4 -iname 'arco-phrozen-ams.tar.gz' 2>/dev/null | head -1)"
if [ -n "$AMS_TAR" ] && [ -f "$AMS_TAR" ]; then
  echo ">> Installing Phrozen AMS server (phrozen_master + hdlDat) from $AMS_TAR"
  mkdir -p "$WORK/ams" "$PD/frp-oms" "$HOME/hdlDat"
  tar -xzf "$AMS_TAR" -C "$WORK/ams"
  cp -rf "$WORK/ams/frp-oms/." "$PD/frp-oms/" 2>/dev/null || true
  cp -af "$WORK/ams/hdlDat/." "$HOME/hdlDat/" 2>/dev/null || true
  # 32-bit ARM static binary; runs on our aarch64 via CONFIG_COMPAT. tar kept the exec bit, re-set anyway.
  chmod +x "$PD/frp-oms/phrozen_master" "$PD/frp-oms/phrozen_slave_ota" 2>/dev/null || true
  echo "   AMS server installed (KlipperScreen-start.sh launches phrozen_master at boot)."
else
  echo "   WARN: arco-phrozen-ams.tar.gz not found on USB -> phrozen_master/hdlDat NOT installed."
  echo "         Run collect_data_arco.sh on your ORIGINAL Arco first, otherwise AMS detection and"
  echo "         post-calibration page-home will misbehave (60s UDS wait + spam)."
fi

# Snapshot the PRISTINE v0.13 Klipper core files that Phrozen's voronFDM clobbers, into a dedicated
# backup matching THIS install. We do NOT rely on the live ~/klipper tree at the moment of need (a
# Phrozen OTA update may itself overwrite it). Prefer `git show HEAD:` (always the clean committed
# version, even if the working tree is already clobbered); fall back to the working tree. Taken once.
CORE_BK="$HOME/.arco-unleashed/klipper-core-v0.13"
mkdir -p "$CORE_BK"
for rel in klippy/mcu.py klippy/serialhdl.py klippy/extras/virtual_sdcard.py; do
  bn="$(basename "$rel")"
  [ -f "$CORE_BK/$bn" ] && continue          # keep the first (pristine) snapshot, never overwrite
  if git -C "$HOME/klipper" show "HEAD:$rel" > "$CORE_BK/$bn" 2>/dev/null && [ -s "$CORE_BK/$bn" ]; then
    :
  elif [ -f "$HOME/klipper/$rel" ]; then
    cp -f "$HOME/klipper/$rel" "$CORE_BK/$bn"
  else
    rm -f "$CORE_BK/$bn"
  fi
done

# --- crowsnest.conf: everything Phrozen's copy gets wrong on this kernel ---------------------------
# Resolve the camera ONCE. Phrozen hardcodes `device: /dev/video4`, which was the capture node on their
# Buster kernel. On ours the rockchip codecs (rga, iep, rkvdec, vpu-dec) claim more /dev/video* slots, so
# the camera shifts -- and a UVC camera registers TWO nodes, of which only *-video-index0 delivers frames
# (index1 is metadata). Pointing ustreamer at the wrong one yields "Wrong camera type or device not found"
# and a webcam that shows "disconnected". A fixed number is both wrong here and fragile across kernels;
# the by-id capture node is stable. If no camera is attached, leave the line alone.
CAM_BYID="$(ls /dev/v4l/by-id/*-video-index0 2>/dev/null | head -1)"
patch_crowsnest() {                                   # $1 = a crowsnest.conf to fix in place
  # The rules themselves live in ONE place, scripts/patch-crowsnest.sh, because the image bake needs
  # exactly the same edits at build time: the shipped crowsnest.conf is the donor's, and until this
  # function ran during the Phrozen install a freshly flashed printer streamed ustreamer at 5 fps --
  # reported from the field as "the webcam is suddenly stuttering". Copying the seds into rebake.sh
  # instead would be a second definition nobody keeps in step, which is the drift this project has
  # already paid for twice today.
  [ -f "$1" ] || return 0
  CAM_BYID="${CAM_BYID:-}" bash "$DIR/patch-crowsnest.sh" "$1"
}

# On first start voronFDM copies certain .py files out of serial-screen/ into klippy/ and DELETES the
# source. Phrozen ships v0.11 mcu.py/virtual_sdcard.py there, which clobber this v0.13 core and halt
# Klipper ("SerialReader.__init__() got an unexpected keyword argument 'warn_prefix'"). Replace any
# serial-screen/*.py that shadows a Klipper core file with the PRISTINE v0.13 version from our backup,
# so voronFDM's one-time copy is harmless (no manual git-checkout recovery needed on the recipient side).
SS="$PD/serial-screen"
if [ -d "$SS" ]; then
  for src in "$SS"/*.py; do
    [ -f "$src" ] || continue
    bn="$(basename "$src")"
    [ -f "$CORE_BK/$bn" ] && cp -f "$CORE_BK/$bn" "$src" && echo "   neutralized serial-screen/$bn (-> pristine v0.13 core)"
  done
  # Same one-time-copy trick: voronFDM copies serial-screen/crowsnest.conf over the user's config on
  # first start, then deletes the source. Fix it AT THE SOURCE so the copy is already correct.
  if [ -f "$SS/crowsnest.conf" ]; then
    patch_crowsnest "$SS/crowsnest.conf"
    echo "   neutralized serial-screen/crowsnest.conf (-> ustreamer, 1280x720, 15fps, device=${CAM_BYID:-unchanged})"
  fi
  # voronFDM gates its first-run "Ersteinrichtung" on a valid serial-screen/use_conf.txt. If it's
  # missing/empty (or voronFDM's save times out, esp. with un-flashed MCUs), it RE-RUNS setup on every
  # start -> CPU bursts that cause "Timer too close" during shaper calibration. Pre-seed a valid config
  # so voronFDM is "already set up" from the first start and never runs the Ersteinrichtung.
  CONF='{"number":1,"name":"arco","SetWaitTime":10,"Update_states":0,"Language":0,"Tempunit":0,"G_printer_position_z":10,"G_Cutting_blade_position":0}'
  # use_conf.txt: seed only if empty/missing (prevents the every-boot Ersteinrichtung loop).
  [ -s "$SS/use_conf.txt" ] || { printf '%s\n' "$CONF" > "$SS/use_conf.txt"; echo "   seeded serial-screen/use_conf.txt (skip Ersteinrichtung)"; }
  # use_conf_update.txt: after a USB install voronFDM arms a ONE-TIME post-update first-time setup by
  # writing number:88 here (the value its post-install setup checks to jump to "page first"). Force the
  # "already set up" state (number:1) so a fresh recipient doesn't land in the wizard before the MCUs are
  # flashed. If voronFDM re-arms 88 at its own runtime after the reboot this is a harmless no-op, and the
  # QUICKSTART covers the wizard either way.
  printf '%s\n' "$CONF" > "$SS/use_conf_update.txt"
  echo "   forced serial-screen/use_conf_update.txt -> number:1 (defuse post-install wizard)"
fi
# also fix any crowsnest.conf already placed in the config dir (belt + suspenders)
patch_crowsnest "$HOME/printer_data/config/crowsnest.conf"


# Phrozen's installer makes the whole ~/KlipperScreen tree executable and overwrites its start
# script, which Moonraker's update manager then flags as "dirty" (800+ mode changes). Tell git to
# ignore mode bits + the intentionally-modified start script + Phrozen's runtime files.
KS="$HOME/KlipperScreen"
if [ -d "$KS/.git" ]; then
  git -C "$KS" config core.fileMode false
  git -C "$KS" update-index --skip-worktree scripts/KlipperScreen-start.sh 2>/dev/null || true
  for f in disposable_params identities_list.txt log.txt; do
    grep -qxF "$f" "$KS/.git/info/exclude" 2>/dev/null || echo "$f" >> "$KS/.git/info/exclude"
  done
fi

echo ">> Applying Arco Unleashed v0.13 patches..."
tft_status "Applying v0.13 patches..." 90
bash "$DIR/apply-phrozen-patches.sh"   # 3 v0.13 API edits + M118 cal handshakes + mcu.py timing (umbrella)

# voronFDM one-time-copies serial-screen/mcu.py over the Klipper core on its FIRST start (then deletes the
# source). The neutralization above shadowed it with a PRISTINE v0.13 mcu.py -> that would REVERT the
# "Timer too close" timing widening apply-phrozen-patches just applied, so homing/first-move after the
# first boot trips Timer-too-close on EVERY fresh install (found on the dev printer 2026-07-05). Re-shadow
# with the PATCHED core so voronFDM's copy PRESERVES the timing patch.
SS_DIR="$HOME/klipper/klippy/extras/phrozen_dev/serial-screen"
[ -f "$SS_DIR/mcu.py" ] && cp -f "$HOME/klipper/klippy/mcu.py" "$SS_DIR/mcu.py" \
  && echo ">> re-shadowed serial-screen/mcu.py with the PATCHED core (preserves mcu.py timing across voronFDM's one-time copy)"

# voronFDM moonraker-websocket watchdog — auto-recovers the display (page home) after auto-calibration.
# Needs root (writes /etc/systemd/system + systemctl). On a manual interactive run sudo prompts and this
# works. In the first-boot 'su - mks' context it can't sudo non-interactively -> arco-firstrun re-installs
# it as root afterwards. Either way VERIFY (don't swallow silently) so a miss is visible.
bash "$DIR/install-watchdog.sh" || true
if systemctl is-active --quiet arco-voronfdm-watchdog.timer; then
  echo "voronFDM watchdog active."
else
  echo "NOTE: voronFDM watchdog NOT active yet — it installs as root (arco-firstrun does this automatically)."
  echo "      If running this by hand:  sudo bash $DIR/install-watchdog.sh"
fi

# PhrozenGo is OFF on delivery, on BOTH routes. It has to be an explicit action rather than a side
# effect of "the download has no PhrozenGo in it", because Phrozen's START SCRIPTS are published too
# and they carry `rm -rf ~/moonraker-obico` on lines 17-18: a printer that never had the cloud app at
# all would still delete the owner's Obico on every boot. Doing it here also makes both routes hand
# over the same machine instead of one that phones home and one that does not, and the marker
# phrozengo.sh writes makes the choice survive a later Phrozen firmware update.
# It deliberately leaves phrozen_master running — that is the AMS gateway, not the cloud app.
if [ -f "$DIR/phrozengo.sh" ]; then
  echo ">> Delivery default: PhrozenGo cloud OFF (menu 5 turns it back on)"
  bash "$DIR/phrozengo.sh" disable 2>&1 | sed 's/^/   /' || true
fi

echo ""
echo "Done — phrozen_dev (from Phrozen) + the v0.13 patches are installed."
if [ "$SRC" = github ]; then
  echo "  Source: Phrozen's own public repository, commit ${PHROZEN_PIN:0:8} (checksum verified)."
  echo "  That route does not include PhrozenGo, Phrozen's cloud app — which you do not need in"
  echo "  order to print. To add it, install Phrozen's Arco_FW_V*.zip the Phrozen way (USB firmware"
  echo "  update); the self-heal guards re-apply the v0.13 patches on the next boot."
else
  echo "  Source: your USB package ($(basename "$FWZIP"))."
fi
echo "PhrozenGo cloud is OFF by default. To turn it on:  bash $DIR/phrozengo.sh menu"
echo "Then: sudo systemctl restart klipper KlipperScreen"
