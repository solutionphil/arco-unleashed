#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# support-bundle.sh — everything a bug report needs, in one file next to printer.cfg
#
# WHY. A report in #bugs starts the same way every time: which channel, which kit commit, which
# guards, which AddOn features, and a log. The log alone is the problem -- klippy.log grows past
# 50 MB, which is over Discord's attachment limit and is mostly weeks of lines nobody reads. So this
# takes the tail of it, adds the answers to the questions we always ask anyway, and drops the result
# where Mainsail can hand it over: the config folder, which Moonraker serves like any other root.
#
# WHAT IS DELIBERATELY NOT IN IT. Only three config files travel with their contents -- printer.cfg,
# AddOn.cfg and moonraker.conf. Everything else in the folder is listed by name, size and checksum
# and left behind. Phrozen's printer_gcode_macro.cfg and any KAOS file are somebody else's work, and
# a bundle meant to be posted in public is the wrong place to carry it. The inventory still shows a
# helper whether those files are present and whether they have been modified.
#
# The whole thing is overwritten on every run rather than timestamped: an SBC with a full eMMC is a
# worse problem than not having yesterday's bundle.
#
# Env overrides, meant for testing: ARCO_SUPPORT_OUT (target file), ARCO_SUPPORT_LOG_MB (log tail).
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -u

HOME_DIR="${HOME:-/home/mks}"
CFG="$HOME_DIR/printer_data/config"
LOGS="$HOME_DIR/printer_data/logs"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ARCO_SUPPORT_OUT:-$CFG/arco-support.tar.gz}"
LOG_MB="${ARCO_SUPPORT_LOG_MB:-20}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/arco-support"
mkdir -p "$D"

say(){ echo "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ── the logs, from the end ───────────────────────────────────────────────────────────────────────
# tail -c on a file Klipper is still writing is safe: it reads what is there and stops.
for pair in "klippy.log:$LOG_MB" "moonraker.log:5"; do
  f="${pair%%:*}"; mb="${pair##*:}"
  if [ -f "$LOGS/$f" ]; then
    tail -c "$((mb * 1024 * 1024))" "$LOGS/$f" 2>/dev/null | tail -n +2 > "$D/${f%.log}-tail.log"
    say "  ${f%.log}-tail.log  $(du -h "$D/${f%.log}-tail.log" 2>/dev/null | cut -f1) (last ${mb} MB of $(du -h "$LOGS/$f" | cut -f1))"
  fi
done
# arco-wifi-seed.log is the flasher's own record of WHICH WiFi route it took. It is the answer to
# "no WiFi after flashing", and that question arrives as a bug report -- so it belongs in the bundle.
for f in arco-reconcile.log arco-update-refresh.log arco-wifi-seed.log; do
  [ -f "$LOGS/$f" ] && tail -c 262144 "$LOGS/$f" > "$D/$f" 2>/dev/null
done

# ── the three config files that are ours to share ────────────────────────────────────────────────
for f in printer.cfg AddOn.cfg moonraker.conf; do
  [ -f "$CFG/$f" ] && cp "$CFG/$f" "$D/$f" 2>/dev/null
done

# ── and an inventory of everything else, contents left behind ────────────────────────────────────
{
  echo "Files in $CFG — only printer.cfg, AddOn.cfg and moonraker.conf travel with their contents."
  echo
  printf '%-52s %10s  %s\n' "FILE" "BYTES" "SHA256"
  for f in "$CFG"/*; do
    [ -f "$f" ] || continue
    printf '%-52s %10s  %s\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')" \
      "$(sha256sum "$f" 2>/dev/null | cut -c1-16)"
  done
} > "$D/config-inventory.txt" 2>/dev/null

# ── which kit, which channel, and is it clean ────────────────────────────────────────────────────
{
  echo "== kit =="
  if [ -d "$KIT/.git" ]; then
    echo "path:    $KIT"
    echo "branch:  $(git -C "$KIT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    echo "commit:  $(git -C "$KIT" log -1 --format='%h %ci %s' 2>/dev/null)"
    echo "version: $(git -C "$KIT" describe --tags --always 2>/dev/null)"
    echo "remote:  $(git -C "$KIT" config --get remote.origin.url 2>/dev/null)"
    echo
    echo "-- uncommitted changes (empty is good) --"
    git -C "$KIT" status --porcelain 2>/dev/null | head -40
  else
    echo "no git clone at $KIT — this kit is still the image's flat copy"
  fi
  echo
  echo "== AddOn.cfg features present =="
  grep -h '^#@FEAT ' "$CFG/AddOn.cfg" 2>/dev/null | sed 's/^#@FEAT /  /'
  echo
  echo "== features already seeded (never offered again) =="
  sed 's/^/  /' "$HOME_DIR/.arco-unleashed/addon-seeded-features" 2>/dev/null || echo "  (no seed file)"
} > "$D/kit.txt" 2>&1

# ── the guards, and what the host looks like ─────────────────────────────────────────────────────
[ -x "$KIT/scripts/guards-toggle.sh" ] && \
  bash "$KIT/scripts/guards-toggle.sh" status > "$D/guards.txt" 2>&1

{
  echo "== host =="; uname -a; echo; uptime; echo
  echo "== memory =="; free -h; echo
  echo "== disk =="; df -h /; echo
  echo "== failed units =="; systemctl --failed --no-pager 2>&1 | head -20; echo
  echo "== slowest units at boot =="; systemd-analyze blame 2>/dev/null | head -25; echo
  echo "== klipper / moonraker =="
  for s in klipper moonraker; do
    printf '%-12s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
} > "$D/system.txt" 2>&1

# ── blank anything that reads like a credential ──────────────────────────────────────────────────
# A bundle is made to be posted in public, so this runs over the staged copies, never the originals.
SECRETS='(api[_-]?key|access[_-]?token|token|password|passwd|secret|webhook|bearer|psk)'
HITS=0
for f in "$D"/*.cfg "$D"/*.conf "$D"/*.txt "$D"/*.log; do
  [ -f "$f" ] || continue
  n=$(grep -EiIc "^[^#;]*${SECRETS}[[:space:]]*[:=]" "$f" 2>/dev/null || true)
  HITS=$((HITS + ${n:-0}))
  u=$(grep -EcI "://[^/[:space:]:]+:[^@[:space:]]+@" "$f" 2>/dev/null || true)
  HITS=$((HITS + ${u:-0}))
  sed -i -E "s/^([^#;]*${SECRETS}[[:space:]]*[:=][[:space:]]*).+$/\1<removed for sharing>/I" "$f" 2>/dev/null
  sed -i -E 's#(://[^/[:space:]:]+):[^@[:space:]]+@#\1:<removed>@#g' "$f" 2>/dev/null
done

# ── a note for whoever opens it ──────────────────────────────────────────────────────────────────
{
  echo "Arco Unleashed support bundle"
  echo "built:   $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "host:    $(hostname)"
  echo
  echo "klippy-tail.log        the last ${LOG_MB} MB of klippy.log, not the whole file"
  echo "moonraker-tail.log     the last 5 MB of moonraker.log"
  echo "printer.cfg            as it is on the machine, including the SAVE_CONFIG block at the end"
  echo "AddOn.cfg              the kit's own config"
  echo "moonraker.conf         Moonrakers own config"
  echo "config-inventory.txt   every other file in the config folder: name, size, checksum only"
  echo "kit.txt                branch, commit, version, uncommitted changes, features"
  echo "guards.txt             which guards are on"
  echo "system.txt             host, memory, disk, failed units, boot times"
  echo
  echo "${HITS} line(s) looked like a key or a password and were blanked out. This is plain text:"
  echo "read it before posting it if you would rather check for yourself."
} > "$D/README.txt"

# ── pack it ──────────────────────────────────────────────────────────────────────────────────────
rm -f "$OUT"
if tar -czf "$OUT" -C "$STAGE" arco-support 2>/dev/null; then
  say "  bundle:  $OUT  ($(du -h "$OUT" | cut -f1), ${HITS} line(s) blanked)"
  say "  Mainsail: sidebar -> Machine -> $(basename "$OUT") -> download"
  exit 0
fi
say "  FAILED to write $OUT"
exit 1
