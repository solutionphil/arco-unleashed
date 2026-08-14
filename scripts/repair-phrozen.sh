#!/bin/bash
# repair-phrozen.sh — put a printer's Python back together after files on disk have been damaged.
#
# WHY THIS EXISTS. A tester's printer halted with "Internal error during connect: source code string
# cannot contain null bytes". One file -- phrozen_dev/cmds.py -- had been written short and full of NUL
# bytes, 800422 bytes where a healthy printer has 800809. Nothing in the kit could put it back: cmds.py
# is untracked, so git cannot restore it, and the phrozen_dev backup had already been overwritten with
# the damaged copy.
#
# WHY IT NO LONGER STOPS AT phrozen_dev. That first repair fixed cmds.py, and the printer then halted
# on serialhdl.py, and after that on garbage_collection -- three separate files, three more rounds, each
# one only reaching as far as the NEXT broken file, because Klipper loads its modules in order and stops
# at the first one it cannot import. The damage was never "a file", it was "everything written shortly
# before the power went". So this repairs the whole tree in one run.
#
# Two different problems need two different sources, and the split matters:
#   * Klipper's OWN files are tracked by its git, so `git checkout HEAD` restores them EXACTLY. Nothing
#     in this kit ever edits a tracked Klipper file -- the MCU timing values were deliberately moved out
#     to klippy/extras/arco_mcu_timing.py for precisely this reason -- so a blanket restore of klippy/
#     is safe and loses nothing.
#   * phrozen_dev and the arco_* extras are untracked, so git has never seen them. The extras come back
#     from the kit; phrozen_dev comes from Phrozen's own public repository, pinned to the same commit
#     fetch-phrozen-fw.sh uses, with voronFDM checked against its known hash before any of it is used.
#     Nothing from Phrozen is redistributed here.
#
# NOT A REINSTALL, and that is the point. Only demonstrably broken files are replaced. Everything the
# repository does not carry -- the display .tft, the AMS firmware, PhrozenGo -- stays exactly where it
# is. A wholesale reinstall would take those away, and they only ever come from the owner's own zip.
#
# HOW DAMAGE IS RECOGNISED. For tracked files, git decides: anything that differs from HEAD is suspect,
# which needs no heuristics at all. For untracked files the test is NUL bytes or an empty file, and it
# is applied ONLY to .py: a Python file containing NUL bytes cannot be imported, full stop, and an empty
# one imports but defines nothing (which is how serialhdl.py produced "module 'serialhdl' has no
# attribute 'SerialReader'"). Wider rules produce false positives -- serial-screen/use_conf.txt
# legitimately contains NUL bytes, on a healthy printer and in Phrozen's repository alike, and a first
# version of this script reported it as damage.
#
# Usage:  bash repair-phrozen.sh          repair
#         DRY_RUN=1 bash repair-phrozen.sh   report only, change nothing
set -uo pipefail

PIN=c1289f07b0a00e2bf126643544e3e48fc31fbc79
TARBALL="https://codeload.github.com/phrozen3d/klipper/tar.gz/$PIN"
VFDM_SHA=b7f827fbcef26e1836357d1c466f9b57fe73bf2a84904438c5e8d4acac74faea
KL="$HOME/klipper"
PD="$KL/klippy/extras/phrozen_dev"
# The kit is NOT simply "one level up from this script". Run from /tmp -- which is exactly how a tester
# receives it during a fault -- that resolves to "/", so the patch step looks for //scripts/... and skips
# the v0.13 patches with a warning nobody reads in a hurry. That happened on the first real use and left
# a pristine but UNPATCHED cmds.py on a v0.13 Klipper. Try the script's own kit first (correct when it is
# installed in one), then the standard location, and accept only a candidate that holds the patcher.
KIT=""
for _c in "$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" "$HOME/arco-unleashed"; do
  [ -n "$_c" ] && [ -f "$_c/scripts/apply-phrozen-patches.sh" ] && { KIT="$_c"; break; }
done
DRY="${DRY_RUN:-0}"
[ "$DRY" = 1 ] && echo "*** DRY RUN — nothing will be changed. ***" && echo

[ -d "$KL" ] || { echo "ERROR: $KL does not exist — this is not an Arco Unleashed printer."; exit 1; }

# --- 1. Klipper's own files ------------------------------------------------------------------------
echo "=== 1. Klipper core files (tracked by git) ==="
CORE_FIXED=0
if [ -d "$KL/.git" ]; then
  git config --global --add safe.directory "$KL" 2>/dev/null || true
  # The WHOLE tree, not just klippy/. A first pass restored only klippy/ and left docs/Load_Cell.md and
  # src/trigger_analog.c emptied -- harmless at runtime, but they keep the repository dirty, and Moonraker
  # silently refuses to update a dirty repository. The printer would have run fine and quietly never taken
  # another Klipper update again.
  mapfile -t DIRTY < <(git -C "$KL" diff --name-only HEAD 2>/dev/null)
  if [ "${#DIRTY[@]}" -eq 0 ]; then
    echo "  clean — every tracked file under klippy/ matches the release."
  else
    for f in "${DIRTY[@]}"; do echo "  DIFFERS: $f ($(stat -c%s "$KL/$f" 2>/dev/null || echo missing) bytes)"; done
    if [ "$DRY" = 1 ]; then
      echo "  would restore all of the above from git HEAD"
    else
      # Blanket restore rather than file-by-file: the list above IS the damage, and restoring the whole
      # tree also brings back anything deleted outright, which a diff of existing files misses.
      # Safe by construction: nothing in this kit edits a tracked Klipper file, so HEAD is what the
      # printer is supposed to be running. The one time this looked risky -- four modified files that
      # clustered suspiciously around the load cell -- `git diff --stat` settled it in one line:
      # 721 deletions and NOT ONE insertion. A patch adds something. Emptied files only ever subtract.
      git -C "$KL" checkout HEAD -- . 2>&1 | sed 's/^/    /'
      CORE_FIXED=${#DIRTY[@]}
      echo "  restored $CORE_FIXED file(s) from git HEAD"
    fi
  fi
else
  echo "  WARNING: $KL is not a git checkout — Klipper's own files cannot be verified here." >&2
fi

# --- 2. The kit's own untracked extras -------------------------------------------------------------
echo
echo "=== 2. Arco extras (untracked — they come from the kit) ==="
if [ -z "$KIT" ]; then
  echo "  WARNING: no kit found — skipping. Reinstate them later with:" >&2
  echo "           bash ~/arco-unleashed/scripts/apply-arco-extras.sh" >&2
elif [ "$DRY" = 1 ]; then
  echo "  would run $KIT/scripts/apply-arco-extras.sh"
elif [ -f "$KIT/scripts/apply-arco-extras.sh" ]; then
  bash "$KIT/scripts/apply-arco-extras.sh" 2>&1 | sed 's/^/  /'
else
  echo "  NOTE: apply-arco-extras.sh is not in this kit — nothing to do."
fi

# --- 3. phrozen_dev --------------------------------------------------------------------------------
echo
echo "=== 3. phrozen_dev (untracked — it comes from Phrozen) ==="
if [ ! -d "$PD" ]; then
  echo "  $PD does not exist. It is not damaged, it is GONE — a Klipper 'hard recover' does that."
  echo "  Re-install it from your own Arco_FW_V*.zip: type  unleashed"
else
  mapfile -t BAD < <(python3 - "$PD" <<'PY'
import sys, pathlib
pd = pathlib.Path(sys.argv[1])
for p in sorted(pd.rglob("*.py")):
    try:
        b = p.read_bytes()
        if b"\x00" in b or not b.strip():
            print(p.relative_to(pd))
    except Exception:
        pass
PY
)
  if [ "${#BAD[@]}" -eq 0 ]; then
    echo "  clean — no damaged .py in the module."
  else
    for f in "${BAD[@]}"; do echo "  DAMAGED: $f ($(stat -c%s "$PD/$f") bytes)"; done
    echo
    echo "  Fetching the module from Phrozen (commit ${PIN:0:8})..."
    W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
    mkdir -p "$W/gh"
    if ! curl -fsSL --connect-timeout 15 --max-time 900 "$TARBALL" \
         | tar -xz -C "$W/gh" --wildcards '*/klippy/extras/phrozen_dev/*' 2>/dev/null; then
      echo "  ERROR: download or extraction failed." >&2; exit 1
    fi
    NEW="$(dirname "$(find "$W/gh" -name base.py 2>/dev/null | head -1)")"
    [ -d "$NEW" ] || { echo "  ERROR: no phrozen_dev inside the archive." >&2; exit 1; }
    got=$(sha256sum "$NEW/serial-screen/voronFDM" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$VFDM_SHA" ] || { echo "  ERROR: voronFDM checksum mismatch ($got) — refusing." >&2; exit 1; }
    echo "  downloaded and verified: voronFDM matches the expected build"
    n=0
    for f in "${BAD[@]}"; do
      if [ ! -f "$NEW/$f" ]; then echo "  $f: not in the repository — left alone"; continue; fi
      if python3 -c "import sys;b=open(sys.argv[1],'rb').read();sys.exit(0 if (b'\x00' in b or not b.strip()) else 1)" "$NEW/$f"; then
        echo "  $f: the repository copy is damaged too — left alone"; continue
      fi
      if [ "$DRY" = 1 ]; then
        echo "  $f: would be replaced ($(stat -c%s "$PD/$f") -> $(stat -c%s "$NEW/$f") bytes)"
      else
        cp -a "$NEW/$f" "$PD/$f" && echo "  $f: replaced ($(stat -c%s "$PD/$f") bytes)" && n=$((n+1))
      fi
    done
    # The repository copy is UNPATCHED, and this is a v0.13 Klipper. Re-patching is idempotent, so it is
    # also harmless when nothing was replaced.
    if [ "$n" -gt 0 ] && [ "$DRY" != 1 ]; then
      echo
      echo "  Re-applying the v0.13 patches (the repository copy is UNPATCHED)..."
      if [ -n "$KIT" ]; then
        bash "$KIT/scripts/apply-phrozen-patches.sh" 2>&1 | sed 's/^/    /'
      else
        echo "    WARNING: no kit found — the module is now PRISTINE BUT UNPATCHED, which a v0.13" >&2
        echo "             Klipper will not accept. Run this by hand before restarting:" >&2
        echo "                 bash ~/arco-unleashed/scripts/apply-phrozen-patches.sh" >&2
      fi
    fi
  fi
fi

# --- 4. Verify -------------------------------------------------------------------------------------
echo
echo "=== 4. Verify ==="
if [ "$DRY" = 1 ]; then
  echo "  Dry run — nothing changed."
  exit 0
fi
python3 - "$KL" <<'PY'
import sys, pathlib
kl = pathlib.Path(sys.argv[1]); bad = 0; n = 0
for p in sorted(kl.rglob("*.py")):
    n += 1
    try:
        b = p.read_bytes()
        if b"\x00" in b or not b.strip():
            print("  still damaged:", p.relative_to(kl)); bad += 1
    except Exception as e:
        print("  unreadable:", p.relative_to(kl), e); bad += 1
print("  %d .py files checked — %s" % (n, "all clean" if not bad else "%d still damaged" % bad))
PY
[ -d "$KL/.git" ] && {
  left=$(git -C "$KL" diff --name-only HEAD 2>/dev/null | wc -l)
  echo "  tracked files still differing from the release: $left"
  [ "$left" -eq 0 ] || echo "  NOTE: while any remain, Moonraker will refuse to update Klipper." >&2
}

# The whole reason this repair was needed. The rootfs is mounted commit=120, so everything written above
# would sit in page cache for up to two minutes -- long enough for a power-cycle to undo the entire
# repair and leave the printer looking exactly as broken as before.
sync
echo
echo "  Written to disk (sync). Now:  sudo systemctl restart klipper"
