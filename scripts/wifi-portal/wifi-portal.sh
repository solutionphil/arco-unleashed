#!/bin/bash
# wifi-portal.sh — bring up the "Arco-Unleashed-Setup" AP + captive portal.
# Pre-scans WiFi, runs hostapd + dnsmasq on wlan0 (192.168.4.1), then portal.py.
# Must run as root. Started by arco-firstrun.sh when the printer did not come online.
#
# NOTE: needs hostapd + dnsmasq (pre-install them in the image). brcmfmac/AP6212 supports AP mode.
#
# This script deliberately does NOT use `set -e`. It used to, and that made the worst failure mode
# possible: `hostapd`/`dnsmasq` were called unchecked and the setup screen was painted only AFTER
# them, so if the AP did not come up the shell died right there — no access point, no screen, no log
# line, and arco-firstrun then exited 0 as if all was well. A recipient saw a printer that simply sat
# there. Now every critical step is checked, failures are announced on the TFT and in the journal,
# and the AP gets a second attempt before we give up.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
IFACE=wlan0
IP=192.168.4.1
AP_SSID="Arco-Unleashed-Setup"

log(){ echo "[wifi-portal] $*"; }

systemctl stop hostapd dnsmasq 2>/dev/null || true
# stop voronFDM (KlipperScreen.service) so it doesn't fight our setup screen on /dev/ttyS1
systemctl stop KlipperScreen 2>/dev/null || true

# --- TFT drawing ---------------------------------------------------------------------------------
# Branded screens on the serial display (TJC, page 6). We draw on page 6 (empty page = no Phrozen
# widgets overwrite us). Colors are RGB565 and come from the same palette as
# selfflash/initramfs/arco-emmc-flash and scripts/tft.sh — the three screens a user meets during an
# install are one design.
# These are defined UP HERE (not next to their first use) on purpose: the "please wait" screen has to
# be paintable before the ~15 s pre-scan, and the error screen before anything can fail.
TTY="${ARCO_TFT_TTY:-/dev/ttyS1}"   # overridable so the failure path can be tested offline
C_BG=4359      # #10233B deep navy
C_ACC=11294    # #2F81F7 brand blue (header band)
C_TXT=65535    # white
C_OK=2016      # #00FF00 green (the SSID to type) — deliberately left as-is: it is a semantic
               # highlight, the portal is tested and working, and nobody asked for it. It IS loud
               # against the navy; changing it is a design call, not a drift fix.
C_ERR=63488    # #FF0000 red (failure headline only)

tft_open(){ [ -e "$TTY" ] || return 1; stty -F "$TTY" 115200 raw -echo 2>/dev/null || return 1; }
tft_page6_bg(){
  printf 'page 6\xff\xff\xff' > "$TTY"; sleep 0.3
  printf 'fill 0,0,800,480,%s\xff\xff\xff' "$C_BG"  > "$TTY"
  printf 'fill 0,0,800,96,%s\xff\xff\xff' "$C_ACC"  > "$TTY"
  printf 'xstr 0,22,800,52,0,%s,%s,1,1,1,"ARCO UNLEASHED"\xff\xff\xff' "$C_TXT" "$C_ACC" > "$TTY"
}
# line <y> <height> <color> <text>
tft_line(){ printf 'xstr 0,%s,800,%s,0,%s,%s,1,1,1,"%s"\xff\xff\xff' "$1" "$2" "$3" "$C_BG" "$4" > "$TTY"; }

draw_wait_screen(){
  tft_open || return 0
  tft_page6_bg
  tft_line 170 34 "$C_TXT" "Starting Wi-Fi setup..."
  tft_line 215 34 "$C_TXT" "Please wait"
}
draw_setup_screen(){
  tft_open || return 0
  tft_page6_bg
  tft_line 150 34 "$C_TXT" "Connect to WiFi hotspot"
  tft_line 190 34 "$C_TXT" "with your phone:"
  tft_line 255 48 "$C_OK"  "$AP_SSID"
}
# Shown when the access point could not be raised. Without this the printer looks dead; with it the
# user at least knows the reliable way out (wifi-seed.txt on the stick joins their own network
# directly and skips this portal entirely).
draw_error_screen(){
  tft_open || return 0
  tft_page6_bg
  tft_line 150 40 "$C_ERR" "Wi-Fi hotspot failed to start"
  tft_line 205 30 "$C_TXT" "Power-cycle to retry, or put a file"
  tft_line 240 30 "$C_TXT" "wifi-seed.txt on the USB stick with:"
  tft_line 280 34 "$C_OK"  "SSID=  PSK=  COUNTRY="
}

# A different failure than the one above and it must not borrow that wording: here the hotspot DID
# start, so telling the user it did not would send them chasing the wrong thing.
draw_portal_error_screen(){
  tft_open || return 0
  tft_page6_bg
  tft_line 150 40 "$C_ERR" "Setup page not reachable"
  tft_line 205 30 "$C_TXT" "The hotspot started, but the setup"
  tft_line 240 30 "$C_TXT" "page could not run. Power-cycle, or use"
  tft_line 280 34 "$C_OK"  "wifi-seed.txt on the USB stick"
}

draw_wait_screen

# 1) pre-scan -> SSID list for the portal (can't scan once the AP is up).
# On a sanitized image wlan0 is NOT associated, so the regulatory domain defaults to "world" (00)
# and the brcmfmac/AP6212 only does a limited passive scan that often returns nothing. Set the
# regdomain explicitly (from the wpa config's country=, else DE) so scanning works like on a
# configured printer — this is the key difference vs. before sanitizing.
WPA_CONF_PATH=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
# NOTE: this cfg80211 regdomain is essentially cosmetic for the AP. The AP6212/brcmfmac is *self-managed*
# and takes its channel + beacon rules from the firmware NVRAM `ccode` (shipped `ccode=ALL` = all channels
# permitted), NOT from `iw reg`/`country=` (verified: `iw reg get` shows global <CC> but phy stays `99`).
# So `country=00` does NOT stop the setup AP beaconing, and setting DE here does not "fix" it — kept only so
# the pre-scan below reports sane channels. If the AP genuinely fails to show, debug hostapd/brcmfmac AP mode
# on the unit; it is not a regdomain problem. The AP itself runs on 2.4 GHz channel 6, which is permitted in
# every regulatory domain worldwide, and hostapd is given NO country_code on purpose: a country_code (with
# ieee80211d) makes hostapd validate the channel against the regdomain and REFUSE to start on a mismatch,
# i.e. it can only add failure modes here, never remove one.
CC=$(sed -n 's/^[[:space:]]*country=//p' "$WPA_CONF_PATH" 2>/dev/null | head -1); CC=${CC:-DE}
rfkill unblock wifi 2>/dev/null || true
iw reg set "$CC" 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true
sleep 2                                   # let the radio settle after boot before scanning
SSIDS=""
# wpa_supplicant owns wlan0 (ctrl socket present) -> ask IT to scan; a raw `iw scan` would fail "busy".
# The AP6212/brcmfmac scan can take >5 s, so trigger then poll the results a few times.
if wpa_cli -i "$IFACE" scan >/dev/null 2>&1; then
  for _ in 1 2 3 4 5; do
    sleep 3
    SSIDS=$(wpa_cli -i "$IFACE" scan_results 2>/dev/null | awk -F'\t' 'NR>1{print $5}' | sed '/^$/d' | sort -u)
    [ -n "$SSIDS" ] && break
  done
fi
# fallback: free the interface and scan with iw (retry a couple of times)
if [ -z "$SSIDS" ]; then
  systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
  pkill -x wpa_supplicant 2>/dev/null || true
  sleep 1; ip link set "$IFACE" up 2>/dev/null || true
  for _ in 1 2 3; do
    SSIDS=$(iw dev "$IFACE" scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | sed '/^$/d' | sort -u)
    [ -n "$SSIDS" ] && break
    sleep 2
  done
fi
log "pre-scan found $(printf '%s\n' "$SSIDS" | grep -c . ) network(s)"
printf '%s\n' "$SSIDS" | python3 -c "import sys,json;print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))" \
  > /tmp/arco-wifi-networks.json 2>/dev/null || echo "[]" > /tmp/arco-wifi-networks.json

# 2) config files for the AP + the captive DHCP/DNS catch-all
# ctrl_interface is not optional here: without it hostapd opens no control socket, hostapd_cli can never
# reach it ("wpa_ctrl_open: No such file or directory"), and the state check below can never succeed —
# no matter how healthy the AP is. That is exactly what happened on hardware: hostapd logged
# "AP-ENABLED", the phone saw the network, and the check still reported failure and killed it on retry.
cat > /tmp/arco-hostapd.conf <<EOF
interface=$IFACE
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ssid=$AP_SSID
hw_mode=g
channel=6
auth_algs=1
wmm_enabled=0
EOF
cat > /tmp/arco-dnsmasq.conf <<EOF
interface=$IFACE
bind-interfaces
dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,12h
dhcp-option=3,$IP
dhcp-option=6,$IP
address=/#/$IP
EOF

# 3) raise the AP — every step checked, two attempts.
#
# The diagnosis goes on the USB STICK, not into /tmp. A printer in this state has no network and no
# usable display beyond our own screens, so anything written to /tmp or the journal (which is volatile
# here) is unreachable by the one person who needs it. That is exactly why an AP failure reported by a
# tester stayed unexplained for two days: hostapd's own output existed, on a machine nobody could log
# into. The stick is plugged in — it is the only channel out.
find_usb(){
  for d in /home/mks/printer_data/gcodes/USB /media/* /mnt/* /run/media/*/*; do
    [ -d "$d" ] || continue
    [ -w "$d" ] || continue
    # the flash stick is the one carrying our own files, not some random mount
    [ -e "$d/wifi-seed.txt" ] || [ -e "$d/wifi-seed.txt.applied" ] || ls "$d"/Arco-Unleashed*.img.gz >/dev/null 2>&1 \
      || [ -e "$d/unleashed-selfflash.tar.gz" ] || continue
    echo "$d"; return 0
  done
  return 1
}
USB_DIR="$(find_usb || true)"
DIAG="${USB_DIR:+$USB_DIR/arco-wifi-portal.log}"
HOSTAPD_LOG=/tmp/arco-hostapd.log

# Everything worth knowing about why a radio does or does not beacon, in one place. Written on failure
# AND on success: a working run is the reference you compare a broken one against, and without it the
# first failure report is just as unreadable as before.
dump_diag(){ # $1 = headline
  [ -n "$DIAG" ] || { log "no USB stick found — diagnosis stays in $HOSTAPD_LOG (unreachable without network)"; return 0; }
  {
    echo "==== $1  ($(date 2>/dev/null))"
    echo "--- hostapd.conf";           cat /tmp/arco-hostapd.conf 2>/dev/null
    echo "--- hostapd output";         cat "$HOSTAPD_LOG" 2>/dev/null
    echo "--- hostapd_cli status";     hostapd_cli status 2>&1 | head -25
    echo "--- iw dev";                 iw dev 2>&1 | head -20
    echo "--- iw reg get";             iw reg get 2>&1 | head -10
    echo "--- rfkill";                 rfkill list 2>&1 | head -10
    echo "--- ip addr wlan0";          ip addr show "$IFACE" 2>&1 | head -10
    echo "--- processes";              pgrep -a -x hostapd; pgrep -a -x wpa_supplicant; pgrep -a -x dnsmasq
    # WHY the station never got a lease is the question the AP dump could not answer: the portal only
    # proves the hotspot is fine. wpa_supplicant's own log is the one place that says whether the
    # association failed on the key, the channel, or never started — and journald is volatile here, so
    # after the next reboot it is gone. It has to leave with the stick or it does not exist.
    # firstrun decided we are here; its own log says WHY — whether a seed was found, applied, skipped as
    # already-used, or never seen because the stick was not mounted yet. Without it the portal's presence
    # is a symptom with no cause attached, and the cause dies with the boot (journald is volatile here).
    echo "--- arco-firstrun (this boot)"; journalctl -b -u arco-firstrun --no-pager 2>/dev/null | tail -40
    echo "--- wpa_supplicant (this boot)"; journalctl -b -u wpa_supplicant@wlan0 --no-pager 2>/dev/null | tail -60
    # The key itself never goes in a log the user may hand to someone. Its SHAPE is what diagnoses a
    # failing association: a backslash or quote inside an unescaped psk="..." silently changes the key
    # wpa_supplicant computes, and the symptom is exactly "correct password, never associates".
    echo "--- wifi config (key described, never printed)"
    awk '
      /^[[:space:]]*psk=/ {
        v = $0; sub(/^[[:space:]]*psk=/, "", v); gsub(/^"|"$/, "", v)
        f = ""
        if (v ~ /\\/)  f = f " backslash"
        if (v ~ /"/)   f = f " quote"
        if (v ~ / /)   f = f " space"
        if (v ~ /\$/)  f = f " dollar"
        if (v ~ /^[0-9a-fA-F]{64}$/) f = f " looks-like-raw-hash"
        printf "    psk: %d chars,%s\n", length(v), (f == "" ? " no characters needing escaping" : f)
        next
      }
      { print "    " $0 }
    ' /etc/wpa_supplicant/wpa_supplicant-wlan0.conf 2>/dev/null
    echo "--- dmesg (brcmfmac)";       dmesg 2>/dev/null | grep -iE 'brcmfmac|ieee80211|cfg80211|wlan0' | tail -60
    echo
  } >> "$DIAG" 2>/dev/null
  sync 2>/dev/null
  log "diagnosis appended to $DIAG"
}

# "Is it beaconing?" — not "did the process start?". hostapd sets the interface to AP mode within
# milliseconds and only then brings the BSS up, so pgrep+`type AP` reports success while the radio is
# still silent. That is the state a tester actually hit: our setup screen was showing, hostapd was
# running, wlan0 said AP — and no phone could see the network. hostapd_cli is the only thing that
# distinguishes the two, so give it a few seconds to reach ENABLED before believing anything.
ap_enabled(){
  local i=0
  while [ "$i" -lt 10 ]; do
    pgrep -x hostapd >/dev/null 2>&1 || return 1
    hostapd_cli status 2>/dev/null | grep -qE '^state=(ENABLED|ACS|HT_SCAN)' && {
      hostapd_cli status 2>/dev/null | grep -q '^state=ENABLED' && return 0
    }
    i=$((i+1)); sleep 1
  done
  # hostapd_cli may be absent on a slimmed image — fall back to the old, weaker test rather than
  # failing a working AP, but say so, because the weaker test is what hid this for two days.
  command -v hostapd_cli >/dev/null 2>&1 || {
    log "NOTE: hostapd_cli missing — falling back to the weaker 'process alive + type AP' test"
    pgrep -x hostapd >/dev/null 2>&1 && iw dev "$IFACE" info 2>/dev/null | grep -qi 'type AP' && return 0
  }
  return 1
}
ap_up=0
for attempt in 1 2; do
  log "bringing up AP (attempt $attempt/2)"
  # free wlan0 from station managers and give it the AP IP
  systemctl stop wpa_supplicant@wlan0 2>/dev/null || true
  pkill -x wpa_supplicant 2>/dev/null || true
  pkill -x hostapd 2>/dev/null || true
  pkill -x dnsmasq 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true
  ip addr flush dev "$IFACE" 2>/dev/null || true
  if ! ip addr add "$IP/24" dev "$IFACE" 2>/dev/null; then
    log "WARN: could not add $IP to $IFACE (already present?) — continuing"
  fi
  if ! ip link set "$IFACE" up 2>/dev/null; then
    log "WARN: could not bring $IFACE up"
  fi

  if ! dnsmasq -C /tmp/arco-dnsmasq.conf 2>>"$HOSTAPD_LOG"; then
    log "WARN: dnsmasq failed to start — phones will not get an IP automatically"
  fi
  if ! hostapd -B /tmp/arco-hostapd.conf >>"$HOSTAPD_LOG" 2>&1; then
    log "WARN: hostapd exited non-zero on attempt $attempt"
  fi

  if ap_enabled; then ap_up=1; break; fi
  log "AP did not reach state=ENABLED on attempt $attempt"
  dump_diag "AP attempt $attempt FAILED to reach ENABLED"
  [ "$attempt" = 1 ] && sleep 3
done

if [ "$ap_up" != 1 ]; then
  log "ERROR: could not raise the setup access point '$AP_SSID'."
  log "ERROR: hostapd output follows (also in $HOSTAPD_LOG):"
  sed 's/^/[wifi-portal]   /' "$HOSTAPD_LOG" 2>/dev/null | tail -30
  log "ERROR: interface state:"
  iw dev "$IFACE" info 2>&1 | sed 's/^/[wifi-portal]   /'
  rfkill list 2>&1 | sed 's/^/[wifi-portal]   /'
  dump_diag "AP FAILED — final state"
  draw_error_screen
  log "The printer stays reachable only if Wi-Fi is seeded: put wifi-seed.txt (SSID=/PSK=/COUNTRY=)"
  log "on the USB stick and re-flash, or fix the AP on this unit. Firstrun re-runs on the next boot."
  exit 1
fi

# 4) AP is confirmed up -> show the join instructions.
# No periodic redraw: voronFDM is stopped above, so nothing overwrites our page-6 screen. A redraw
# loop would re-issue 'page 6' and briefly show the blank page (~0.5 s flicker every cycle) — so we
# draw once and leave it. (If a future panel drifts back to its home page on its own, re-add a
# repaint that does NOT switch pages.)
dump_diag "AP UP — reference state for comparing a failure against"

# The portal needs :80 — captive-portal detection on every phone probes plain HTTP, and our own
# setup-nginx-ports.sh hands that port to Mainsail (the stock Arco URL). So on a real printer nginx
# holds it and portal.py cannot bind. Free it BEFORE painting the join screen: nothing reaches Mainsail
# during setup anyway (there is no network yet), and a successful submit reboots, which brings it back.
#
# KNOWN EDGE, accepted deliberately: "there is no network yet" stopped being universally true once a
# USB Ethernet adapter could get an address (25-wired.network). A printer that is online by CABLE and
# has no WiFi configured still lands here, because arco-firstrun decides on wlan0 alone — and then
# this stops the very Mainsail that was reachable over the cable, to ask for credentials nobody needs.
# Left as is: it costs one first boot on a wired-only machine, and firstrun self-disables afterwards.
# If that case ever matters, fix it in arco-firstrun's wait_online (accept ANY routable interface),
# not here — by the time this runs, the decision to portal has already been made.
if systemctl is-active --quiet nginx 2>/dev/null; then
  log "stopping nginx so the portal can use :80 (it returns on the reboot after setup)"
  systemctl stop nginx 2>/dev/null || log "WARN: could not stop nginx — portal.py will retry the bind"
fi

draw_setup_screen
log "AP '$AP_SSID' up on $IP — connect a phone and open the portal."

# portal.py blocks until the user submits, then writes the wpa config and reboots. If it RETURNS, the
# portal is dead — and a silent return is the worst outcome available here: this script would exit, the
# oneshot unit would finish, and systemd would reap hostapd out of the cgroup. The access point would
# disappear while the join screen kept telling the user to connect to it. That is not theory; it is what
# a tester saw. So: retry, and if it will not stay up, say so on the display instead of vanishing.
# The portal's own output — including every HTTP request the phone makes — goes to the STICK too, not
# just /tmp. A submit that fails and then succeeds on an identical retry (reported on hardware) leaves no
# trace otherwise: the portal's log lives in /tmp, and a successful submit reboots, which wipes it. The
# one exchange worth seeing is therefore the one that is guaranteed to be gone. -u keeps python from
# block-buffering its output into a pipe, which would lose the tail on reboot.
for try in 1 2 3; do
  if [ -n "$DIAG" ]; then
    printf '\n==== portal session %s/3  (%s)\n' "$try" "$(date 2>/dev/null)" >> "$DIAG" 2>/dev/null
    python3 -u "$DIR/portal.py" 2>&1 | tee -a "$HOSTAPD_LOG" "$DIAG" | sed 's/^/[portal] /'
  else
    python3 -u "$DIR/portal.py" 2>&1 | tee -a "$HOSTAPD_LOG" | sed 's/^/[portal] /'
  fi
  log "portal.py exited (attempt $try/3) — it should only ever exit by rebooting"
  sleep 2
done
dump_diag "PORTAL DIED — AP was up, but portal.py would not stay running"
draw_portal_error_screen
log "ERROR: the AP came up but the portal could not serve. Most likely :80 is held by another service."
exit 1
