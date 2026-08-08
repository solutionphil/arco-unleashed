#!/bin/bash
# arco-write-ip.sh — leave a "how to reach me" note on the USB stick.
#
# WHY. Finding the printer is the first wall a new owner hits, and at that point in the manual the
# display cannot help: it is sitting on the "Error occurred" screen until the MCUs are flashed, so the
# address cannot be read there. unleashed.local solves it for most people, but mDNS is blocked on plenty
# of routers and on nearly every guest or corporate network. The stick is the one channel that always
# works: it is already in the printer during setup, and the owner can read it on the machine they are
# sitting at.
#
# Written on every boot, because a DHCP address can change and a stale note is worse than none. It is a
# few hundred bytes onto a stick that is only there during setup, so the cost is nil. No stick, no IP, or
# a read-only stick: it does nothing and says so.
set -uo pipefail

KITDIR="$(cd "$(dirname "$0")/.." && pwd)"
AHOME="$(dirname "$KITDIR")"
say(){ echo "[write-ip] $*"; }

# Wait for an address. On a first boot this races Wi-Fi association, which is exactly when the note is
# most wanted -- so wait, rather than write "no address" and be wrong for the rest of the session.
IP=""
for _ in $(seq 1 40); do
  IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -n "$IP" ] && break
  sleep 3
done
[ -n "$IP" ] || { say "no address after two minutes — nothing to write"; exit 0; }

# The stick, wherever it is mounted. GCODE_USB first: our own automount claims it there before anything
# else looks, and leaving it out is what once had firstrun polling for a stick that was mounted all along.
USB=""
for d in "$AHOME/printer_data/gcodes/USB" /media/*/* /media/* /run/media/*/* /mnt/usb; do
  [ -d "$d" ] || continue
  # Must be a real mount, not the empty directory the mount point leaves behind, and must be writable.
  mountpoint -q "$d" 2>/dev/null || continue
  [ -w "$d" ] || continue
  USB="$d"; break
done
[ -n "$USB" ] || { say "no writable USB stick mounted — nothing to write"; exit 0; }

HOST=$(hostname 2>/dev/null || echo unleashed)
TMP="$USB/.ip.txt.tmp"
{
  printf 'Arco Unleashed — how to reach this printer\r\n'
  printf '\r\n'
  printf '  Web interface   http://%s/\r\n' "$IP"
  printf '  SSH             ssh mks@%s\r\n' "$IP"
  printf '\r\n'
  printf 'By name, if your network passes mDNS (most home routers do):\r\n'
  printf '\r\n'
  printf '  Web interface   http://%s.local/\r\n' "$HOST"
  printf '  SSH             ssh mks@%s.local\r\n' "$HOST"
  printf '\r\n'
  printf 'Login: mks / makerbase\r\n'
  printf '\r\n'
  printf 'Rewritten on every boot, so this is the address as of\r\n'
  printf '%s. Safe to delete.\r\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
# CRLF throughout: this is read on the machine the owner is sitting at, and Windows Notepad still shows
# a LF-only file as one long line.
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$USB/ip.txt" 2>/dev/null || {
  rm -f "$TMP" 2>/dev/null; say "could not write to $USB — leaving it"; exit 0; }

# Belongs to the owner, not to root, or they cannot delete it from the web UI's file browser.
chown --reference="$AHOME" "$USB/ip.txt" 2>/dev/null || true
sync 2>/dev/null || true
say "wrote $USB/ip.txt ($IP, $HOST.local)"
exit 0
