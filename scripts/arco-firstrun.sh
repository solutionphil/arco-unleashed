#!/bin/bash
# arco-firstrun.sh — first-boot orchestrator for the clean (Phrozen-free) image.
#   1) No WiFi configured  -> start the setup AP + captive portal (user enters WiFi -> reboot).
#   2) phrozen_dev missing -> install Phrozen's parts from a USER-PROVIDED USB stick (no download).
# Runs as root (mount + reboot). Installed as arco-firstrun.service.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
AUSER=mks
AHOME=/home/$AUSER
PD="$AHOME/klipper/klippy/extras/phrozen_dev"
WPA=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
CONSENT=/var/lib/arco-unleashed/phrozen-consent   # set by the portal when the user acknowledged Phrozen's use

has_wifi_config(){ grep -q 'ssid="' "$WPA" 2>/dev/null; }
# wait up to $1 seconds for wlan0 to actually be ONLINE (associated + an IPv4 lease). Returns as soon as
# it is (usually a second or two), so a correctly-configured Wi-Fi costs no real delay.
# A flat timeout was wrong, and hardware showed exactly how. On the first boot after a network is entered
# in the portal, this BCM43430 needs well over 100 s to complete its first association — the kernel logs
# cfg80211 connect/roam warnings the whole way through. With a flat 90 s we gave up at 90 and the radio
# finished at 102.5: the portal came up on a printer that WAS connecting. The user then re-entered the
# same credentials, which is really just a reboot — and it worked, because by then the network was in the
# scan cache. Hence "the portal always needs two attempts with the same data".
#
# So: wait for a lease, but only give up while nothing is happening. Any sign of progress from
# wpa_supplicant (associating, handshaking, associated) pushes the deadline out, up to a hard cap. A
# genuinely wrong network never gets past scanning and still falls through to the portal on the base
# window, which is what keeps a typo'd password from costing minutes.
wait_online(){
  # The cap was 300 s, on the strength of "the first association takes this radio over 100 s". That
  # evidence does not survive: every boot it came from had the seed's WRONG password in the config,
  # because the seed was being re-applied over what the portal had written. Those cfg80211 warnings on a
  # 30 s cycle were associations FAILING, not associations taking their time. With that fixed there is no
  # measurement showing a correct join is slow — and a 300 s cap has a real cost, because the case that
  # reaches it is a wrong PASSWORD (SSID on the air, never joins). Five minutes before the portal appears
  # is worse than what this gate replaced. 150 s leaves generous room for a genuinely slow join without
  # making a typo expensive.
  local base="${1:-45}" cap="${2:-150}" i=0 deadline="${1:-45}" st="" prev="" trail="" nudged=0 want="" seen=""
  want=$(sed -n 's/^[[:space:]]*ssid="\(.*\)"[[:space:]]*$/\1/p' "$WPA" 2>/dev/null | head -1)
  while [ "$i" -lt "$deadline" ] && [ "$i" -lt "$cap" ]; do
    ip -4 addr show wlan0 2>/dev/null | grep -q 'inet ' && {
      [ "$i" -gt "$base" ] && echo "[firstrun] online after ${i}s — the flat ${base}s window would have missed this"
      return 0
    }
    st=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^wpa_state=//p')
    # Record every state CHANGE, not just the last one. "last state = ASSOCIATING" says nothing about
    # whether the radio was cycling through the handshake for three minutes or sat idle and then woke
    # up — and those two need opposite fixes. The trail is what tells them apart.
    [ -n "$st" ] && [ "$st" != "$prev" ] && { trail="$trail ${i}s:$st"; prev="$st"; }
    case "$st" in
      AUTHENTICATING|ASSOCIATING|ASSOCIATED|4WAY_HANDSHAKE|GROUP_HANDSHAKE|COMPLETED)
        # the credentials are being accepted; only the lease is outstanding
        deadline=$((i + 45)); [ "$deadline" -gt "$cap" ] && deadline="$cap" ;;
    esac
    # When the base window is up with no address, decide on EVIDENCE instead of on the clock: is the
    # configured network actually on the air? If the SSID is in a fresh scan, the network exists and we
    # are merely slow — keep waiting to the cap. If it is not, no amount of waiting will help and the
    # portal is the right answer immediately, which is what protects a typo'd SSID from costing minutes.
    #
    # This replaces a pure stopwatch, and the stopwatch is what made this look like a portal bug. Older
    # releases only asked whether a wifi CONFIG existed, never whether it connected, so a slow first
    # association was invisible: the printer just took its time. Gating on real connectivity is right —
    # a wrong password used to strand a printer with no SSH and no usable display — but the gate has to
    # be measured against the radio, not against a guess.
    # Fires on the LAST iteration of the base window, not one past it: with no progress the deadline is
    # still the base window, so the loop would have ended before an "i == base" check could ever run —
    # and the scan verdict, the whole point, would never happen. (Caught by the offline suite.)
    if [ "$i" = "$((base - 1))" ] && [ "$nudged" = 0 ]; then
      nudged=1
      # nothing configured to look for -> there is no question to answer, go to the portal
      [ -n "$want" ] || break
      wpa_cli -i wlan0 reconfigure >/dev/null 2>&1
      wpa_cli -i wlan0 scan        >/dev/null 2>&1
      sleep 5
      seen=$(wpa_cli -i wlan0 scan_results 2>/dev/null | awk -F'\t' 'NR>1 && $5 != "" {print $5}')
      if printf '%s\n' "$seen" | grep -Fxq "$want"; then
        trail="$trail ${i}s:SSID-ON-AIR"
        echo "[firstrun] \"$want\" is on the air but not joined yet — waiting up to ${cap}s"
        deadline="$cap"
        wpa_cli -i wlan0 reassociate >/dev/null 2>&1
      elif [ -z "$seen" ]; then
        # No results AT ALL is not evidence that the network is gone — it is evidence that we could not
        # look: wpa_supplicant may not be up yet, or its control socket is not there. Concluding
        # "out of range" from a scan that never ran would send a perfectly good printer to the portal.
        # Absence of evidence is not evidence of absence, so keep waiting and say why.
        trail="$trail ${i}s:SCAN-EMPTY"
        echo "[firstrun] could not scan after ${i}s (no results at all — supplicant not ready?) — waiting up to ${cap}s"
        deadline="$cap"
      else
        trail="$trail ${i}s:SSID-NOT-FOUND"
        echo "[firstrun] \"$want\" is not among the $(printf '%s\n' "$seen" | grep -c .) networks in range (scanned after ${i}s) — going to the portal"
        break
      fi
    fi
    i=$((i+1)); sleep 1
  done
  echo "[firstrun] no address after ${i}s (last wpa_state=${st:-unknown}) trail:${trail:- none}"
  return 1
}

# voronFDM's one-time post-install first run is guarded by TWO independent files in serial-screen/, and
# stock phrozen_dev ships BOTH of them armed. Neutralise both, or the recipient gets a setup wizard they
# cannot complete yet (MCUs not flashed, printer model unset):
#
#   use_conf.txt         "Update_states":1  -> voronFDM paints "update complete - restart manually" AND
#                                             re-arms use_conf_update.txt to number:88 on the way.
#   use_conf_update.txt  "number":88        -> the setup wizard itself ("page first").
#
# Defusing only the wizard file is NOT enough: while "Update_states" is set, every voronFDM start paints
# "update complete" and re-arms number:88, so the wizard simply comes back on the next boot. voronFDM only
# clears "Update_states" itself from inside its startup path, which is gated behind its moonraker websocket
# (i.e. tens of seconds after a klipper restart) — far too late for us to race. So we clear it ourselves and
# never enter that branch at all. Called TWICE: before voronFDM ever starts (so nothing appears at all), and
# again before the reboot as belt-and-braces if it re-armed anything at runtime.
#
# "Update_states" is edited surgically: use_conf.txt also carries the Z-sync/name state, and voronFDM writes
# it as JSON with a trailing NUL, which the sed preserves byte-for-byte.
defuse_wizard(){
  local ucu="$PD/serial-screen/use_conf_update.txt"
  local uc="$PD/serial-screen/use_conf.txt"
  [ -d "$PD/serial-screen" ] || return 0
  printf '%s\n' '{"number":1,"name":"arco","SetWaitTime":10,"Update_states":0,"Language":0,"Tempunit":0,"G_printer_position_z":10,"G_Cutting_blade_position":0}' > "$ucu"
  chown "$AUSER:$AUSER" "$ucu" 2>/dev/null || true
  if [ -f "$uc" ]; then
    sed -i 's/"Update_states"[[:space:]]*:[[:space:]]*[0-9][0-9]*/"Update_states":0/' "$uc"
    chown "$AUSER:$AUSER" "$uc" 2>/dev/null || true
  fi
  # The "update complete" branch we just suppressed is also what stock uses to seed the two test prints into
  # the gcode folder. Do it ourselves so the recipient still gets them.
  local sc="$PD/serial-screen" gd="$AHOME/printer_data/gcodes"
  if [ -d "$gd" ]; then
    for _g in FDM_TEST.gcode Chroma_Kit_TEST.gcode; do
      [ -f "$sc/$_g" ] && cp -f "$sc/$_g" "$gd/" 2>/dev/null && chown "$AUSER:$AUSER" "$gd/$_g" 2>/dev/null
    done
  fi
  echo "[firstrun] defused voronFDM first run (use_conf_update.txt -> number:1, use_conf.txt -> Update_states:0)"
}

# --- Stage 0a: ensure sshd can start even if the host keys were stripped during imaging ---
# The image ships without /etc/ssh/ssh_host_* on purpose (one identity per printer, not one per release).
# arco-ssh-hostkeys.service now generates them BEFORE sshd's first start; this stays as the fallback for
# images built before that unit existed, and it has to clean up after sshd's own failed start: with no keys
# sshd's ExecStartPre (sshd -t) fails, Restart=on-failure burns systemd's start limit in under a second, and
# every later "systemctl restart ssh" is then REFUSED ("start request repeated too quickly") until the unit
# is reset -- which is why this used to leave SSH silently dead for the whole first boot. So: reset-failed
# first, and report what happened instead of swallowing it. SSH is the recipient's only way in.
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  echo "[firstrun] no SSH host keys present -> regenerating"
  ssh-keygen -A || echo "[firstrun] WARN: ssh-keygen -A failed — SSH will be unreachable!"
  systemctl reset-failed ssh.service sshd.service 2>/dev/null || true
  if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
    echo "[firstrun] sshd (re)started with fresh host keys"
  else
    echo "[firstrun] WARN: sshd would not start — SSH unreachable until the next boot!"
    systemctl status ssh --no-pager -l 2>&1 | head -20 || true
  fi
fi

# --- Stage 0b: grow the rootfs to the full eMMC (idempotent; no-op once at full size) ---
bash "$DIR/resize-emmc.sh" >/dev/null 2>&1 || true

# --- Stage 0b2: install the USB automount (mounts sticks at printer_data/gcodes/USB, like the stock MKS
# board does) if it isn't there yet — so the very first "insert USB for the firmware" step already works. ---
if [ ! -f /etc/udev/rules.d/99-arco-usb-automount.rules ]; then
  bash "$DIR/../system/install-usb-automount.sh" >/dev/null 2>&1 || true
  # On the self-flash path the stick is ALREADY plugged in on this first boot, so udev's coldplug ran long
  # before the rule existed and nothing would ever mount it. Replay the block 'add' events once.
  udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
  udevadm settle --timeout=10 2>/dev/null || true
fi

# --- Stage 0b3: make the systemd guards match the kit that is actually in this image ---
# The ExecStartPre self-heal guards are written by optimize-boot.sh at image-build time, so an image
# carries whatever guard set existed on the day it was built — while the bundled kit is swapped on every
# rebake. The two drift apart silently, and the drift is invisible: the printer boots fine and Klipper is
# ready, it simply has no recovery behaviour. A freshly flashed unit was found missing BOTH
# 13-arco-phrozen-restore and 14-arco-core-restore, and still carrying 15-arco-mcu-timing.conf pointing at
# a script the kit had already deleted. Re-running the installer here costs a few seconds once and makes
# the guards a property of the KIT rather than of the build date. It is idempotent by design (every step
# is check-first) and needs no network.
bash "$DIR/optimize-boot.sh" >/dev/null 2>&1 || true

# --- Stage 0c: eMMC self-flash headless onboarding (additive; no-op unless the self-flash markers are on
# the USB). Applies the seeded WiFi config + consent. (It still stamps /run/arco-skip-portal, now vestigial:
# Stage 1 decides on real connectivity, so a seeded WiFi that connects simply proceeds without the portal.) ---
bash "$DIR/apply-selfflash-seed.sh" 2>&1 || true

# --- Stage 1: bring up the setup portal unless the printer actually comes ONLINE. Real connectivity is the
# test, NOT just a present config: a wrong/typo'd Wi-Fi (bad password, changed network) that never connects
# must still fall through to the portal — otherwise the printer is stranded (no SSH; and until the MCUs are
# flashed the display is blocked by an MCU error, so its Wi-Fi screen can't be used either). A correctly
# seeded/entered Wi-Fi returns from wait_online in a second or two; no or failed Wi-Fi waits, then portals.
# (The old self-flash /run/arco-skip-portal fast-path is obsolete now — connectivity subsumes it.) ---
if has_wifi_config; then WIFI_TMO=90; else WIFI_TMO=1; fi   # seeded WiFi: allow the fresh-boot BCM43430 (driver+assoc+DHCP) enough time before falling back to the portal; a WiFi that connects returns immediately anyway
if ! wait_online "$WIFI_TMO"; then
  echo "[firstrun] not online (no or non-connecting Wi-Fi) -> launching setup portal"
  bash "$DIR/wifi-portal/wifi-portal.sh"     # blocks; reboots on user submit
  exit 0
fi
echo "[firstrun] Wi-Fi online -> continuing"

# --- Stage 2: install Phrozen's parts from a user-provided USB stick (FAT32) — no download ---
# first-boot progress screen on the TFT (stubs if tft.sh missing / voronFDM already up)
if [ -f "$DIR/tft.sh" ]; then source "$DIR/tft.sh"; else tft_init(){ :; }; tft_status(){ :; }; tft_done(){ :; }; tft_hint(){ :; }; fi
source "$DIR/usb-fw.sh"

if [ -f "$PD/cmds.py" ]; then
  # phrozen_dev is here, but that alone does NOT mean the previous run finished. Between voronFDM's start
  # (when it paints "update complete - restart printer manually") and us disabling this service lies a
  # few-second window; a user who obeys that screen and pulls the power there leaves phrozen_dev installed
  # while the relay + watchdog never were. cmds.py alone then made this stage exit forever, silently
  # shipping a printer without the display-freeze recovery for the auto-calibration SAVE_CONFIG restart.
  # Both installers overwrite their unit and 'enable --now', so re-asserting them is safe.
  echo "[firstrun] phrozen_dev already present -> re-asserting the display guards"
  if [ ! -f /etc/systemd/system/arco-wsrelay.service ]; then
    if bash "$DIR/install-wsrelay.sh"; then
      systemctl restart KlipperScreen.service 2>/dev/null || true   # voronFDM must pick up the LD_PRELOAD shim
      echo "[firstrun] voronFDM<->moonraker relay installed after an interrupted first run"
    else
      echo "[firstrun] WARN: voronFDM<->moonraker relay install failed"
    fi
  fi
  if ! systemctl is-active --quiet arco-voronfdm-watchdog.timer; then
    bash "$DIR/install-watchdog.sh" \
      && echo "[firstrun] voronFDM watchdog installed after an interrupted first run" \
      || echo "[firstrun] WARN: voronFDM watchdog install failed — auto-cal display recovery will not work!"
  fi
  # An interrupted first run may well have been interrupted BEFORE the gates were defused (or voronFDM
  # re-armed number:88 in the meantime), which strands the recipient in the setup wizard. Idempotent.
  defuse_wizard
  sync
  systemctl disable arco-firstrun.service 2>/dev/null || true
  exit 0
fi

# Phrozen's use is the user's own choice: the portal records consent. Without it, don't install —
# leave it to the explicit menu action (fetch from USB in arco-setup-*).
if [ ! -f "$CONSENT" ]; then
  echo "[firstrun] no Phrozen-use consent on file -> skipping auto-install."
  systemctl disable arco-firstrun.service 2>/dev/null || true
  exit 0
fi

tft_init
# Look for a FAT32 USB stick holding Arco_FW_V*.zip. The zip is no longer required — Phrozen publishes
# the display module themselves and fetch-phrozen-fw.sh offers to download it — but it still WINS when
# present, because it is the offline route and it also carries PhrozenGo + the display/AMS firmware.
#
# The poll used to run ten minutes, which was right while the zip was mandatory. Shortening it just
# trades one bad case for another: too long and every networked printer idles in front of a prompt for
# something it does not need; too short and someone who WANTED the zip (for PhrozenGo, or offline)
# silently gets the download because they were a minute late plugging the stick in.
#
# So the wait moved instead of shrinking. Look once, try to install; only if that fails is the stick
# the ONLY remaining route, and that is when it is worth waiting a long time for one. Result: no wait
# at all in the common case, and five patient minutes exactly where they help.
echo "[firstrun] consent on file -> looking for Arco_FW_V*.zip on USB (optional)..."
ZIP="$(find_fw_zip)" || ZIP=""
if [ -n "$ZIP" ]; then
  echo "[firstrun] found firmware on USB: $ZIP -> installing + applying v0.13 patches..."
  tft_status "Found firmware on USB - installing..." 25
else
  echo "[firstrun] no zip on USB -> fetch-phrozen-fw.sh will download from Phrozen's repository."
  tft_status "Downloading Phrozen module..." 25
fi

# Same script either way: FW_ZIP set uses the stick, FW_ZIP empty downloads.
INSTALLED=0
if su - "$AUSER" -c "FW_ZIP='$ZIP' bash '$DIR/fetch-phrozen-fw.sh'"; then
  INSTALLED=1
else
  # Nothing on USB and the download did not work — an IP without a route to the internet, most
  # likely, which the connectivity gate above cannot see (it only checks for an address). The stick
  # is now the only way in, so ask for it plainly and give it a moment.
  #
  # Half an hour, and that is deliberate. Whoever ends up here does not HAVE the zip -- that is why
  # the download was tried -- so they have to fetch it from Phrozen's website on a PC and copy it to
  # a stick. Thirty minutes is enough for exactly that, which is the difference between finishing the
  # install in one sitting and standing in front of a printer that has given up. The printer has
  # nothing else to do meanwhile, and the display says what it is waiting for the whole time.
  # Long polling is safe: find_fw_zip unmounts before each attempt and again on a miss, so nothing
  # accumulates however long this runs (usb-fw.sh). 10 s steps keep that to 180 passes.
  # It is still not the only way back: firstrun stays enabled, so a power-cycle repeats everything.
  echo "[firstrun] no download and no USB package -> waiting up to 30 min for a stick..."
  for _ in $(seq 1 180); do        # 30 min (10 s steps)
    tft_status "No internet - insert USB stick with Arco_FW_V*.zip" 8
    sleep 10
    ZIP="$(find_fw_zip)" || ZIP=""
    [ -n "$ZIP" ] || continue
    echo "[firstrun] stick appeared: $ZIP -> installing..."
    tft_status "Found firmware on USB - installing..." 25
    su - "$AUSER" -c "FW_ZIP='$ZIP' bash '$DIR/fetch-phrozen-fw.sh'" && { INSTALLED=1; break; }
  done
fi

if [ "$INSTALLED" = 1 ]; then
    # BEFORE voronFDM is ever started below: neutralise the setup wizard the freshly unpacked phrozen_dev
    # arms (number:88). Doing it only at the end let the wizard appear on the display until the reboot.
    defuse_wizard
    # Get the freshly unpacked phrozen_dev onto the disk NOW. The rootfs is mounted with commit=120, so up
    # to two minutes of writes live only in page cache. The moment voronFDM starts below it paints its own
    # "update complete - restart printer manually" screen, and a user who obeys it and yanks the power would
    # otherwise lose most of the install while cmds.py (which Stage 2 checks) had already landed — leaving a
    # half-installed phrozen_dev that firstrun would never repair.
    sync
    # fetch.sh ran as mks, which has NO passwordless sudo -> its install-watchdog.sh call can't elevate
    # non-interactively and fails silently. The voronFDM watchdog needs root (/etc/systemd/system +
    # systemctl), so install it HERE as root (firstrun is root). Without it the display has no
    # auto-recovery and hangs on the calibration page after the auto-cal SAVE_CONFIG -> klippy restart.
    # voronFDM<->moonraker relay: prevents the SAVE_CONFIG-restart freeze at the source (moonraker never
    # drops voronFDM, so the display never hangs on the cal page). Install + restart KlipperScreen so
    # voronFDM picks up the LD_PRELOAD shim, THEN the watchdog (now checking the 7126 relay) as backup.
    bash "$DIR/install-wsrelay.sh" || echo "[firstrun] WARN: voronFDM<->moonraker relay install failed"
    systemctl restart KlipperScreen.service 2>/dev/null || true
    sleep 5
    bash "$DIR/install-watchdog.sh" || echo "[firstrun] WARN: voronFDM watchdog install failed"
    systemctl is-active --quiet arco-voronfdm-watchdog.timer && echo "[firstrun] voronFDM watchdog active" \
      || echo "[firstrun] WARN: voronFDM watchdog NOT active — auto-cal display recovery will not work!"
    # (No tft_* call here: voronFDM has held /dev/ttyS1 since the KlipperScreen restart above, and the
    # helpers self-disable while it does. A tft_done here was a silent no-op. The completion screen is
    # painted at the very end instead, once voronFDM is stopped for the reboot.)
    cleanup_fw_mount
    systemctl disable arco-firstrun.service 2>/dev/null || true
    systemctl restart klipper KlipperScreen 2>/dev/null || true
    # Stock would now show a one-time first-run ("update complete") and wait for a MANUAL power-cycle;
    # defuse_wizard above disarmed both gates before voronFDM started, so it goes straight to the home
    # screen instead and we reboot ONCE automatically. The recipient never power-cycles by hand.
    #
    # This settle is NOT a race window — do not treat it as one. An earlier version relied on sleeping long
    # enough for voronFDM to reach its own startup branch (which clears "Update_states" and re-arms
    # number:88) so that the defuse below could get the last word. That branch sits behind voronFDM's
    # moonraker websocket, i.e. after the klipper restart above has reconnected its MCUs (~13 s and up), so
    # the window was never reliably long enough — shortening it to 7 s shipped the wizard to testers.
    # Both gates are now cleared up front, so nothing has to be outrun and this is a plain settle.
    echo "[firstrun] installed — settling, then auto-rebooting (remove the USB stick)..."
    sync            # everything above is on disk before the settle window
    sleep "${ARCO_POSTINSTALL_SETTLE:-7}"
    defuse_wizard   # belt-and-braces: re-clear both gates in case voronFDM re-armed anything at runtime
    sync
    # Take the display back for the final word. Suppressing stock's "update complete" also removed the only
    # moment the printer ever says "done", so we owe the recipient our own — otherwise the install just goes
    # quiet and reboots, and they cannot tell success from a hang. The tft_* helpers stand down while
    # voronFDM owns /dev/ttyS1, so stop it first; we are rebooting in a second anyway, so that costs nothing.
    # tft_init repaints page 6 from scratch (voronFDM has switched pages since our last draw).
    #
    # Deliberately a STATUS, not a prompt: the rootfs is commit=120, so inviting a power-cycle here is
    # inviting the plug-pull that this auto-reboot exists to avoid. The sync above already landed the
    # install; the reboot is ours to make, not the user's.
    systemctl stop KlipperScreen 2>/dev/null || true
    sleep 1                       # let voronFDM release the serial port before we draw on it
    tft_init
    tft_done "Update complete"
    tft_hint "wait for restart..."
    sync
    systemctl reboot
else
    # Reached when there was no zip on the stick AND the download did not work — on a printer with an
    # IP but no route to the internet, for instance, which the connectivity gate above cannot detect
    # (it only checks for an address). Nothing is disabled, so the next boot tries again: adding the
    # stick, or giving the printer real internet, finishes the install without any further command.
    cleanup_fw_mount
    # After half an hour of asking, the display is the only place this can still be explained, and it
    # has to name the power-cycle: that IS the recovery. firstrun stays enabled, so the next boot
    # repeats the whole attempt. Without saying so, a recipient who finally has the zip plugs the
    # stick in and watches a printer that does nothing, with no reason to suspect a restart helps.
    # Split over status + hint because one line long enough to say all of it would not fit page 6.
    tft_status "Not installed - put Arco_FW_V*.zip on the USB stick" 0
    tft_hint "then power off and on again"
    echo "[firstrun] install failed (no USB zip on the stick, and no working download)."
    echo "[firstrun] firstrun is NOT disabled. To finish the install, do EITHER:"
    echo "[firstrun]   * copy Phrozen's Arco_FW_V*.zip (still zipped) to the top level of a FAT32"
    echo "[firstrun]     stick, plug it in, and POWER-CYCLE the printer, or"
    echo "[firstrun]   * give the printer working internet and POWER-CYCLE it."
    echo "[firstrun] Everything above then runs again by itself — no commands needed."
fi
