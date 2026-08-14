#!/bin/bash
# repair-phrozen.sh — replace CORRUPTED files in an installed phrozen_dev from Phrozen's own repository.
#
# WHY THIS EXISTS. A tester's printer halted with "Internal error during connect: source code string
# cannot contain null bytes". One file -- phrozen_dev/cmds.py -- had been written short and full of NUL
# bytes, 800422 bytes where a healthy printer has 800809. Nothing in the kit could put it back: cmds.py
# is untracked, so git cannot restore it, and the phrozen_dev backup had already been overwritten with
# the damaged copy (see apply-phrozen-restore.sh -- its completeness check tests that files EXIST, not
# that they are readable).
#
# NOT A REINSTALL, and that is the point. It swaps in only the files that are demonstrably broken.
# Everything the repository does not carry -- the display .tft, the AMS firmware, PhrozenGo -- stays
# exactly where it is. A wholesale reinstall would take those away, and they only ever come from the
# owner's own zip.
#
# ONLY .py. A Python file containing NUL bytes cannot be imported, full stop, so the verdict is
# unambiguous. Wider rules produce false positives: serial-screen/use_conf.txt legitimately contains NUL
# bytes -- on a healthy printer and in Phrozen's repository alike -- and a first version of this script
# reported it as damage.
#
# Nothing from Phrozen is redistributed here. The source is Phrozen's own public repository, pinned to
# the same commit fetch-phrozen-fw.sh uses, and voronFDM is checked against its known hash before any of
# it is used.
#
# Usage:  bash repair-phrozen.sh          repair
#         DRY_RUN=1 bash repair-phrozen.sh   report only, change nothing
set -uo pipefail

PIN=c1289f07b0a00e2bf126643544e3e48fc31fbc79
TARBALL="https://codeload.github.com/phrozen3d/klipper/tar.gz/$PIN"
VFDM_SHA=b7f827fbcef26e1836357d1c466f9b57fe73bf2a84904438c5e8d4acac74faea
PD="$HOME/klipper/klippy/extras/phrozen_dev"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
DRY="${DRY_RUN:-0}"

[ -d "$PD" ] || { echo "ERROR: $PD does not exist — nothing to repair here."; exit 1; }

echo "=== 1. What is damaged? (.py files containing NUL bytes) ==="
mapfile -t BAD < <(python3 - "$PD" <<'PY'
import sys, pathlib
pd = pathlib.Path(sys.argv[1])
for p in sorted(pd.rglob("*.py")):
    try:
        if b"\x00" in p.read_bytes(): print(p.relative_to(pd))
    except Exception: pass
PY
)
if [ "${#BAD[@]}" -eq 0 ]; then
  echo "  nothing damaged — there is nothing to do."; exit 0
fi
for f in "${BAD[@]}"; do echo "  DAMAGED: $f ($(stat -c%s "$PD/$f") bytes)"; done

echo
echo "=== 2. Fetch the module from Phrozen (commit ${PIN:0:8}) ==="
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gh"
curl -fsSL --connect-timeout 15 --max-time 900 "$TARBALL" \
  | tar -xz -C "$W/gh" --wildcards '*/klippy/extras/phrozen_dev/*' 2>/dev/null \
  || { echo "  ERROR: download or extraction failed."; exit 1; }
NEW="$(dirname "$(find "$W/gh" -name base.py 2>/dev/null | head -1)")"
[ -d "$NEW" ] || { echo "  ERROR: no phrozen_dev inside the archive."; exit 1; }
got=$(sha256sum "$NEW/serial-screen/voronFDM" 2>/dev/null | cut -d' ' -f1)
[ "$got" = "$VFDM_SHA" ] || { echo "  ERROR: voronFDM checksum mismatch ($got) — refusing."; exit 1; }
echo "  downloaded and verified: voronFDM matches the expected build"

echo
echo "=== 3. Replace only the damaged files ==="
n=0
for f in "${BAD[@]}"; do
  if [ ! -f "$NEW/$f" ]; then echo "  $f: not in the repository — left alone"; continue; fi
  if python3 -c "import sys;sys.exit(0 if b'\x00' in open(sys.argv[1],'rb').read() else 1)" "$NEW/$f"; then
    echo "  $f: the repository copy is damaged too — left alone"; continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "  $f: would be replaced ($(stat -c%s "$PD/$f") -> $(stat -c%s "$NEW/$f") bytes)"
  else
    cp -a "$NEW/$f" "$PD/$f" && echo "  $f: replaced ($(stat -c%s "$PD/$f") bytes)" && n=$((n+1))
  fi
done

if [ "$DRY" = 1 ]; then echo; echo "  Dry run — nothing changed."; exit 0; fi
[ "$n" -gt 0 ] || { echo; echo "  nothing replaced."; exit 1; }

echo
echo "=== 4. Re-apply the v0.13 patches (the repository copy is UNPATCHED) ==="
if [ -f "$KIT/scripts/apply-phrozen-patches.sh" ]; then
  bash "$KIT/scripts/apply-phrozen-patches.sh" 2>&1 | sed 's/^/  /'
else
  echo "  WARNING: $KIT/scripts/apply-phrozen-patches.sh missing — apply them by hand!"
fi

echo
echo "=== 5. Verify ==="
python3 - "$PD" <<'PY'
import sys, pathlib
pd = pathlib.Path(sys.argv[1]); bad = 0
for p in sorted(pd.rglob("*.py")):
    try:
        if b"\x00" in p.read_bytes(): print("  still damaged:", p.relative_to(pd)); bad += 1
    except Exception: pass
print("  all clean" if not bad else "  %d file(s) still damaged" % bad)
PY
echo
echo "  Now:  sudo systemctl restart klipper"
