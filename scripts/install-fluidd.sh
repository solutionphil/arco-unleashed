#!/bin/bash
# install-fluidd.sh — install the Fluidd web interface next to Mainsail.
#
# Usage:  bash install-fluidd.sh [version]      version e.g. v1.37.2; default: latest release
#
# The Arco ships with BOTH interfaces: Phrozen's stock Buster serves Mainsail on :80 and Fluidd on
# :8808 (verified in the stock image). The migration installed Mainsail and dropped Fluidd, but the
# nginx site came along -- so :8808 has been answering 404 ever since, pointing at a /home/mks/fluidd
# that does not exist. This puts the files back where that site already looks.
#
# Because the site is already configured and already proxies moonraker (/websocket, /printer, /api,
# /machine, /server, /webcam), this needs NO nginx reload, NO moonraker change and NO restarts:
# the 404 turns into a 200 the moment the files land. Everything is same-origin through nginx, so
# moonraker's cors_domains is not involved.
#
# Fluidd is GPL-3.0 (like Mainsail) -- redistributable, and compatible with this kit's AGPL-3.0.
#
# Safe to run during a print: the download and extraction are niced and ionice'd, and the new tree is
# built in a staging dir and swapped in with mv, so :8808 never serves a half-written directory.
set -uo pipefail
VER="${1:-latest}"
DEST="${FLUIDD_DEST:-$HOME/fluidd}"
STAGE="$(dirname "$DEST")/.fluidd-stage.$$"
TMPZ="$(mktemp -t fluidd.XXXXXX.zip)"
cleanup(){ rm -rf "$TMPZ" "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if [ "$VER" = latest ]; then
  URL="https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip"
else
  URL="https://github.com/fluidd-core/fluidd/releases/download/$VER/fluidd.zip"
fi

command -v unzip >/dev/null 2>&1 || { echo "unzip missing: sudo apt install unzip"; exit 1; }

echo "Fluidd $VER -> $DEST"
echo "  downloading ..."
if ! nice -n 19 ionice -c3 curl -fsSL --retry 2 -o "$TMPZ" "$URL"; then
  echo "  download failed: $URL"; exit 1
fi

# No checksum is published with the release, so verify what we actually got: a real zip that contains
# fluidd's entry point. A truncated download or an HTML error page would otherwise be extracted happily.
if ! unzip -tqq "$TMPZ" >/dev/null 2>&1; then
  echo "  not a valid zip ($(du -h "$TMPZ" | cut -f1)) -- refusing to unpack"; exit 1
fi
if ! unzip -l "$TMPZ" 2>/dev/null | grep -q 'index\.html'; then
  echo "  zip has no index.html -- this is not a fluidd bundle, refusing"; exit 1
fi

echo "  extracting ..."
rm -rf "$STAGE"; mkdir -p "$STAGE"
nice -n 19 ionice -c3 unzip -qq "$TMPZ" -d "$STAGE" || { echo "  extract failed"; exit 1; }
[ -f "$STAGE/index.html" ] || { echo "  no index.html after extract -- refusing to swap"; exit 1; }

# Swap last and atomically-ish: build fully, then move the old tree aside and the new one in.
if [ -d "$DEST" ]; then
  OLD="$DEST.old.$$"
  mv "$DEST" "$OLD" && mv "$STAGE" "$DEST" || { echo "  swap failed"; exit 1; }
  rm -rf "$OLD"
  echo "  replaced existing install"
else
  mv "$STAGE" "$DEST" || { echo "  install failed"; exit 1; }
fi

echo
echo "Fluidd installed. It is served by the nginx site that was already there -- no restart needed."
if command -v curl >/dev/null 2>&1; then
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8808/ 2>/dev/null || echo '???')
  echo "  http://localhost:8808/ -> HTTP $code"
fi
echo "  Reach it at:  http://<printer-ip>:8808/     (Mainsail stays on :80 and :81)"
