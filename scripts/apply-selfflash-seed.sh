#!/bin/bash
# apply-selfflash-seed.sh — headless onboarding for the eMMC self-flash path (additive; no effect on the
# normal external-flash path). If the install-unleashed self-flash tool left its markers on the USB stick:
#   .arco-skip-portal  -> skip the WiFi captive portal this boot (stamp /run/arco-skip-portal)
#   .arco-wifi.conf    -> apply the captured/seeded WiFi (else leave empty for the display menu)
#   .arco-consent      -> record Phrozen-use consent (the self-flash arm confirmation)
# and, as a user-writable RECOVERY path after a bad first boot:
#   wifi-seed.txt      -> plain SSID=/PSK=/COUNTRY= file, applied then renamed to .applied
# Markers are CONSUMED (one-shot) so a reused stick never re-triggers. No marker => no-op.
# Keyed ONLY off files the self-flash tool writes, so the external-flash user (who never creates them)
# is completely unaffected. Called by arco-firstrun before the portal stage. Runs as root.
set -uo pipefail
WPA="${WPA:-/etc/wpa_supplicant/wpa_supplicant-wlan0.conf}"
CONSENT="${CONSENT:-/var/lib/arco-unleashed/phrozen-consent}"
STAMP="${ARCO_SKIP_STAMP:-/run/arco-skip-portal}"

SEED_WIFI_APPLIED=0                # set to 1 as soon as a Wi-Fi config has really been written
# Which seeds have already been consumed — on the printer, deliberately not on the removable stick.
SEED_STAMP="${ARCO_SEED_STAMP:-/var/lib/arco-unleashed/seed-applied}"
# Where the flasher's WiFi decision is kept once the printer is up. printer_data/logs so ARCO_SUPPORT
# picks it up with everything else a bug report needs.
WIFI_DECISION_DST="${ARCO_WIFI_DECISION_DST:-/home/mks/printer_data/logs/arco-wifi-seed.log}"
# Written by the setup portal when the user enters a network there.
PORTAL_MARK="${ARCO_PORTAL_MARK:-/var/lib/arco-unleashed/portal-configured}"

# The rule everything else follows: what the user typed into the portal beats a file that was already on
# the stick when they typed it. The stick can hold more than one source — the flasher captures a
# .arco-wifi.conf at arm time AND the user may leave a wifi-seed.txt — and they get consumed on
# successive boots, each overwriting the network the portal had just written. That is exactly why the
# portal appeared twice: once per stale source.
#
# This is decided by CONTENT, never by timestamps. The first version compared mtimes, and on hardware
# that failed every time: the stick is FAT, Windows writes FAT timestamps in LOCAL time, and Linux reads
# them as UTC — so a file the user created on their PC looks about two hours into the future. Measured on
# the printer: a seed written at 15:36 local read back as 15:36 UTC while the clock said 14:03. Every
# stick file therefore looked newer than anything on the printer, and the rule never protected anything.
# Cross-filesystem mtime comparisons are simply not available to us.
#
# So the portal records the digest of whatever was on the stick when it wrote a network, and those are
# treated as spent. A seed the user adds AFTERWARDS has a different digest and still applies, which is
# what keeps the documented rescue working.
consumed(){      # $1 = digest
  [ -n "$1" ] && [ -f "$SEED_STAMP" ] && grep -qxF "$1" "$SEED_STAMP" 2>/dev/null
}
# sha256 ONLY: portal.py writes sha256 digests into the same file, so a cksum fallback could never match
# and the two halves would disagree in silence forever — stale seeds re-applying on every boot with
# nothing to show for it. If sha256sum is ever missing, say so instead of degrading quietly.
digest_of(){     # $1 = file -> digest on stdout (empty if it cannot be hashed)
  sha256sum < "$1" 2>/dev/null | cut -d' ' -f1
}
command -v sha256sum >/dev/null 2>&1 || \
  echo "[selfflash-seed] WARN: sha256sum missing — cannot tell which WiFi files were already used" >&2

# wpa_supplicant validates the WHOLE configuration file, so one bad passphrase does not just skip one
# network: it makes the service exit 255, and systemd's start limit then keeps it down for the rest of
# the boot. Nothing connects, nothing says why, and a later good config cannot help either. Observed on
# hardware with a 5-character test password. So a seed that cannot produce a valid file is refused here,
# with the reason, instead of being written out and taking the radio down with it.
# Escape a value for a QUOTED wpa_supplicant string. Deleting quotes (what this used to do implicitly by
# not handling them) silently changes the key or the network name; an unescaped backslash escapes the
# closing quote and makes wpa_supplicant reject the entire file.
wpa_esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
# wpa_supplicant allows at most 32 BYTES of SSID; beyond that the whole file is a parse error.
valid_ssid(){ [ "$(printf '%s' "$1" | wc -c)" -le 32 ] && [ -n "$1" ]; }
valid_psk(){     # $1 = passphrase ("" = open network)
  case "${#1}" in
    0) return 0 ;;                                     # open network -> key_mgmt=NONE
    64) case "$1" in *[!0-9A-Fa-f]*) : ;; *) return 0 ;; esac ;;   # raw 64-hex PSK
  esac
  n=$(printf %s "$1" | wc -c); [ "$n" -ge 8 ] && [ "$n" -le 63 ]   # BYTES: wpa_supplicant counts bytes, not characters
}

apply_from(){                      # $1 = mountpoint that may hold the markers; returns 0 if applied
  local mp="$1"
  [ -f "$mp/.arco-skip-portal" ] || return 1
  echo "[selfflash-seed] marker on $mp -> headless onboarding (portal skipped)"
  if [ -s "$mp/.arco-wifi.conf" ] && consumed "$(digest_of "$mp/.arco-wifi.conf")"; then
    echo "[selfflash-seed] this stick WiFi was already used (or superseded in the setup portal) -> keeping the current one"
  elif [ -s "$mp/.arco-wifi.conf" ]; then
    install -D -m600 "$mp/.arco-wifi.conf" "$WPA"
    SEED_WIFI_APPLIED=1
    # Record it as spent HERE, not only by deleting it below. Deleting is the only thing that stopped
    # this file repeating, and deletion fails silently on a stick that is read-only or not writable yet
    # this early in boot — after which it is applied again on every boot, over whatever the user set in
    # the portal. That is the same trap the wifi-seed.txt path was hardened against; this branch had
    # been left with the old, weaker mechanism. (Found by auditing for the bug class after fixing it.)
    install -d "$(dirname "$SEED_STAMP")" 2>/dev/null || true
    digest_of "$mp/.arco-wifi.conf" >> "$SEED_STAMP" 2>/dev/null || true
    echo "[selfflash-seed] WiFi applied -> $WPA"
    systemctl reset-failed wpa_supplicant@wlan0 2>/dev/null; systemctl restart wpa_supplicant@wlan0 2>/dev/null || echo "[selfflash-seed] WARN: wpa_supplicant@wlan0 would not start — check: systemctl status wpa_supplicant@wlan0" >&2
  else
    echo "[selfflash-seed] no WiFi seed -> leaving empty (enter it in the printer's display WiFi menu)"
  fi
  if [ -f "$mp/.arco-consent" ]; then
    install -d "$(dirname "$CONSENT")"; : > "$CONSENT"
    echo "[selfflash-seed] Phrozen-use consent recorded (from self-flash arm)"
  fi
  install -d "$(dirname "$STAMP")" 2>/dev/null || true
  : > "$STAMP"                                                   # firstrun reads this to skip the portal
  rm -f "$mp/.arco-skip-portal" "$mp/.arco-wifi.conf" "$mp/.arco-consent"   # one-shot consume
  return 0
}

# --- RECOVERY: a plain wifi-seed.txt the user can write on the stick AFTER a bad first boot -------
# Rescuing a stranded printer from the stick was ALREADY possible: apply_from() above runs on every
# boot, so hand-creating .arco-skip-portal plus a .arco-wifi.conf and power-cycling brings a unit
# back — that is exactly how a tester's printer was recovered in practice, and it stays supported.
# What it asks of the person doing it is the problem: two dot-prefixed filenames (which Windows
# Explorer hides and Notepad silently appends ".txt" to) plus a hand-written wpa_supplicant config
# block with the right quoting and a network={} body. wifi-seed.txt is the same rescue expressed as
# three plain KEY=VALUE lines, and it is the file the portal's error screen and the docs point at —
# so the instruction a stranded user is given now matches a file this system actually reads.
# Windows quirks are normalised exactly as install-unleashed.sh does (UTF-8 BOM on line 1 from
# Notepad's "UTF-8", CRLF line endings, leading whitespace), because that is how these files get made.
apply_wifi_seed(){
  local mp="$1" seed s p c dg=""
  [ -f "$mp/wifi-seed.txt" ] || return 1
  # "Applied once" is a fact recorded on the PRINTER, keyed by the seed's CONTENT. It used to depend on
  # renaming the file to .applied on the stick, and that rename can fail silently on a FAT stick that is
  # read-only or not yet writable this early in boot — after which the seed was applied again on the next
  # boot, over the network the user had just entered in the portal.
  dg=$(digest_of "$mp/wifi-seed.txt")
  if consumed "$dg"; then
    echo "[selfflash-seed] this wifi-seed.txt was already used (or superseded in the setup portal) -> leaving the current WiFi alone"
    echo "[selfflash-seed] (to use it again, write it onto the stick with different contents, e.g. the corrected password)"
    return 1
  fi
  seed=$(sed '1s/^\xEF\xBB\xBF//' "$mp/wifi-seed.txt" 2>/dev/null | tr -d '\r')
  s=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*SSID=//p'    | head -1)
  p=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*PSK=//p'     | head -1)
  c=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*COUNTRY=//p' | head -1 | tr -cd 'A-Za-z')
  if [ -z "$s" ]; then
    echo "[selfflash-seed] $mp/wifi-seed.txt has no SSID= line -> ignored"
    return 1
  fi
  if ! valid_ssid "$s"; then
    echo "[selfflash-seed] $mp/wifi-seed.txt: SSID is longer than 32 bytes — wpa_supplicant would reject the whole config" >&2
    return 1
  fi
  # Refuse a passphrase wpa_supplicant will reject, rather than writing a file that takes the radio down
  # for the whole boot (see valid_psk). The portal is a better outcome than a dead supplicant.
  if ! valid_psk "$p"; then
    echo "[selfflash-seed] $mp/wifi-seed.txt: PSK is ${#p} characters — WiFi passwords must be 8 to 63" >&2
    echo "[selfflash-seed] refusing to write it: wpa_supplicant rejects the whole config and stops, which would" >&2
    echo "[selfflash-seed] leave the printer with no WiFi at all. Fix the password and power-cycle, or use the setup portal." >&2
    return 1
  fi
  { printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\ncountry=%s\n\nnetwork={\n\tssid="%s"\n' "${c:-00}" "$(wpa_esc "$s")"
    if [ -n "$p" ]; then printf '\tpsk="%s"\n' "$(wpa_esc "$p")"; else printf '\tkey_mgmt=NONE\n'; fi
    printf '}\n'
  } > "$mp/.arco-seed.tmp" 2>/dev/null || return 1
  install -D -m600 "$mp/.arco-seed.tmp" "$WPA"; rm -f "$mp/.arco-seed.tmp"
  SEED_WIFI_APPLIED=1
  echo "[selfflash-seed] wifi-seed.txt applied (SSID \"$s\", country ${c:-00}) -> $WPA"
  # One-shot, but RENAMED rather than deleted: the user can see it was picked up, and can re-arm it by
  # renaming back. Re-applying on every boot would silently overwrite whatever they later set through
  # the setup portal, which would make the portal look broken.
  # Record it here FIRST: this is the copy that decides, and it lives on a filesystem we can always write.
  install -d "$(dirname "$SEED_STAMP")" 2>/dev/null || true
  [ -n "$dg" ] && printf '%s\n' "$dg" >> "$SEED_STAMP" 2>/dev/null
  if ! mv -f "$mp/wifi-seed.txt" "$mp/wifi-seed.txt.applied" 2>/dev/null; then
    rm -f "$mp/wifi-seed.txt" 2>/dev/null \
      || echo "[selfflash-seed] NOTE: could not rename or remove wifi-seed.txt (stick read-only?) — the stamp in $SEED_STAMP is what stops it being applied again"
  fi
  systemctl reset-failed wpa_supplicant@wlan0 2>/dev/null; systemctl restart wpa_supplicant@wlan0 2>/dev/null || echo "[selfflash-seed] WARN: wpa_supplicant@wlan0 would not start — check: systemctl status wpa_supplicant@wlan0" >&2
  return 0
}

# Markers first (self-flash onboarding), then the user-writable recovery file.
# The fall-through is keyed on whether Wi-Fi was ACTUALLY written, not on whether apply_from found a
# marker. A bare .arco-skip-portal with no .arco-wifi.conf otherwise returns success, consumes itself
# and short-circuits the seed file — while leaving the printer with no Wi-Fi at all. That is exactly
# the combination a user following recovery instructions produces, since the older marker route needs
# .arco-skip-portal and it is natural to create it alongside a wifi-seed.txt.
# ---- carry the flasher's WiFi decision into the printer -------------------------------------------
# install-unleashed.sh appends which of the four routes it took (no_wifi / wifi-seed / live capture /
# NM fallback) and why to .arco-wifi-decision.log on the stick. Two testers in a row reported "no WiFi
# after flashing" and it could not be reconstructed, because everything the flasher said had scrolled
# past and the reboot took it.
#
# Copied HERE and not inside apply_from(), which returns early when there is no .arco-skip-portal --
# and that is exactly the case this log exists to explain. Also deliberately NOT consumed with the
# other markers: the owner keeps the stick, and reading the same answer twice costs nothing.
carry_wifi_decision_log(){
  local src="$1/.arco-wifi-decision.log"
  [ -s "$src" ] || return 0
  install -d "$(dirname "$WIFI_DECISION_DST")" 2>/dev/null || true
  cmp -s "$src" "$WIFI_DECISION_DST" 2>/dev/null && return 0
  if install -m644 "$src" "$WIFI_DECISION_DST" 2>/dev/null; then
    chown --reference="$(dirname "$WIFI_DECISION_DST")" "$WIFI_DECISION_DST" 2>/dev/null || true
    echo "[selfflash-seed] flasher WiFi decision copied -> $WIFI_DECISION_DST"
  fi
}

apply_any(){
  local mp="$1" rc=1
  carry_wifi_decision_log "$mp"
  apply_from "$mp" && rc=0
  if [ "$SEED_WIFI_APPLIED" != 1 ]; then apply_wifi_seed "$mp" && rc=0; fi
  return "$rc"
}

# --- 1) stick already mounted, or about to be ---
# The automount is a systemd service that udev triggers; firstrun's `udevadm settle` waits for the udev
# events, NOT for that service to finish mounting. So this stage can run in the seconds where the stick
# exists but is not mounted yet — and a perfectly good wifi-seed.txt is then simply not seen, the printer
# raises the setup portal, and the seed sits on the stick still armed. Observed exactly that: the portal
# found the stick (its log is written there) while this stage, moments earlier, had not.
# So wait — but only while there is something to wait FOR: with no USB block device present at all this
# returns immediately, so a boot without a stick is not delayed.
usb_present(){ ls /dev/sd*[0-9] >/dev/null 2>&1; }
try_mountpoints(){
  local mp
  # shellcheck disable=SC2086
  for mp in ${ARCO_USB_DIRS:-/home/mks/printer_data/gcodes/USB /media/* /mnt/* /run/media/*/*}; do
    apply_any "$mp" && return 0
  done
  return 1
}
i=0
while :; do
  try_mountpoints && exit 0
  usb_present || break
  [ "$i" -ge "${ARCO_USB_WAIT:-15}" ] && { echo "[selfflash-seed] a USB device is present but nothing is mounted after ${i}s — trying to mount it myself"; break; }
  [ "$i" = 0 ] && echo "[selfflash-seed] USB device present but not mounted yet — waiting for the automount"
  i=$((i+1)); sleep 1
done

# --- 2) NOT mounted -> mount the candidates ourselves. On the self-flash path the stick is ALREADY plugged
# in when the fresh system boots for the very first time, i.e. before firstrun installs the USB automount
# udev rule — udev's coldplug has long passed, so nothing ever mounts it and the markers stay invisible.
# (This is exactly why the first real self-flash boot fell back to the WiFi portal, while the Phrozen
# firmware install still worked: usb-fw.sh mounts the stick itself.) Mount rw, since we consume the
# markers, and always put it back afterwards. ---
TMP="${ARCO_SEED_TMP:-/run/arco-seed-usb}"
mkdir -p "$TMP"
for dev in $(blkid -o device 2>/dev/null) $(ls /dev/sd*[0-9] 2>/dev/null); do
  case "$dev" in /dev/sd*) : ;; *) continue ;; esac
  [ -b "$dev" ] || continue
  mount -o rw "$dev" "$TMP" 2>/dev/null || mount -t vfat -o rw "$dev" "$TMP" 2>/dev/null || continue
  if apply_any "$TMP"; then
    sync; umount "$TMP" 2>/dev/null; rmdir "$TMP" 2>/dev/null
    exit 0
  fi
  umount "$TMP" 2>/dev/null
done
rmdir "$TMP" 2>/dev/null
exit 0
