#!/bin/bash
# setup-nginx-ports.sh — make Mainsail answer on port 80 as well as 81.
#
# Usage:  sudo bash setup-nginx-ports.sh          (idempotent; safe to re-run)
#
# Why: Phrozen's stock Buster serves Mainsail on :80, so http://<printer-ip>/ just works and that is
# what every Arco owner's bookmark, phone shortcut and muscle memory expects. After the migration
# KIAUH put Mainsail on :81 and left :80 unbound -- so the factory URL silently answers nothing. That
# was never a decision, it is just where KIAUH landed.
#
# We ADD :80 rather than move off :81: anyone who got used to the :81 URL during the migration keeps it.
#
# The nginx sites are donor state -- nothing in the kit owned them until now, so a manual/base install
# got whatever KIAUH chose and the full image got the donor's copy. Same gap as AddOn.cfg had.
set -uo pipefail
SITE=/etc/nginx/sites-available/mainsail
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

[ -f "$SITE" ] || { echo "no Mainsail nginx site at $SITE -- nothing to do (is Mainsail installed?)"; exit 0; }

if grep -qE '^[[:space:]]*listen[[:space:]]+80;' "$SITE"; then
  echo "Mainsail already listens on :80 -- unchanged"
  exit 0
fi
if ! grep -qE '^[[:space:]]*listen[[:space:]]+81;' "$SITE"; then
  echo "unexpected: $SITE has no 'listen 81;' -- refusing to guess where :80 belongs"
  grep -nE '^[[:space:]]*listen' "$SITE" | sed 's/^/    /'
  exit 1
fi

BAK="$SITE.pre-port80.$(date +%s).bak"
cp -a "$SITE" "$BAK"
sed -i '0,/^\([[:space:]]*\)listen[[:space:]]\+81;/s//\1listen 81;\n\1listen 80;        # stock Arco URL: http:\/\/<ip>\/ (Phrozen served Mainsail here)/' "$SITE"

# A broken nginx config takes the whole web UI down, not just port 80. Never leave it broken.
if ! nginx -t >/dev/null 2>&1; then
  echo "nginx rejected the edit -- rolling back:"
  nginx -t 2>&1 | sed 's/^/    /'
  cp -a "$BAK" "$SITE"
  exit 1
fi

systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
echo "Mainsail now listens on :80 and :81  (backup: $BAK)"
grep -nE '^[[:space:]]*listen' "$SITE" | sed 's/^/    /'
