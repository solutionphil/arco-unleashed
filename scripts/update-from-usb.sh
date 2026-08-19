#!/bin/bash
# update-from-usb.sh — update this kit from a tarball on a USB stick, with no network.
#
#   bash scripts/update-from-usb.sh [/path/to/kit.tar]
#
# WHY: until the repository is public, scripts/selfupdate.sh has nothing to pull from, so a tester
# with a flashed printer cannot get a kit fix without reflashing the whole eMMC. A stick and this
# script are enough.
#
# THE PART THAT MATTERS. It NEVER extracts over the live kit. It unpacks beside it and then renames
# the directories, because a rename leaves the running script's inode alone while extracting on top
# of it truncates the very file bash is still reading — that is not theoretical, it happened here on
# 2026-07-29: a script was replaced mid-run, bash carried on at its old byte offset, skipped the step
# that writes firmware and left a toolhead erased with nothing on it.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
# Which kit are we updating? Normally the one this script sits in. But there is a bootstrap case, and a
# tester hit it on 2026-07-30: to get this script at all on a printer whose installed kit predates it,
# you have to unpack it somewhere first -- /tmp/scripts, say. Then $KIT is /tmp, its parent is /, and the
# script tries to create a work directory at the filesystem root: "//tmp.incoming-...: Permission denied",
# followed by a misleading "bad or truncated tarball" when nothing could be extracted into it.
# So: if this script is not sitting inside something that looks like the kit, update the INSTALLED one.
kit_looking() { [ -f "$1/scripts/unleashed_setup.sh" ] && [ -f "$1/config-templates/AddOn.cfg.template" ]; }
if ! kit_looking "$KIT"; then
  for cand in "${ARCO_KIT:-}" "$HOME/arco-unleashed" /home/mks/arco-unleashed; do
    [ -n "$cand" ] && kit_looking "$cand" && { KIT="$(cd "$cand" && pwd)"; break; }
  done
  if ! kit_looking "$KIT"; then
    echo "Cannot tell which kit to update."
    echo "This script is running from $(dirname "$0"), which is not inside a kit, and there is no"
    echo "installed kit at ~/arco-unleashed either. Point it at one:"
    echo "  ARCO_KIT=/path/to/arco-unleashed bash $0 <tarball>"
    exit 1
  fi
  echo "  running from outside a kit — updating the installed one at $KIT"
fi
PARENT="$(dirname "$KIT")"
NAME="$(basename "$KIT")"
STAMP="$(date +%Y%m%d-%H%M)"
USBDIR="${ARCO_USB:-$HOME/printer_data/gcodes/USB}"

TAR="${1:-}"
if [ -z "$TAR" ]; then
  TAR=$(ls -1t "$USBDIR"/kit*.tar "$USBDIR"/arco-unleashed*.tar 2>/dev/null | head -1)
  [ -n "$TAR" ] && echo "  found on the stick: $TAR"
fi
[ -z "$TAR" ] || [ -f "$TAR" ] || { echo "No such file: $TAR"
                   echo "Check the name — the stick holds: $(ls -1 "$USBDIR"/*.tar 2>/dev/null | tr '\n' ' ')"; exit 1; }
[ -f "$TAR" ] || { echo "No kit tarball given and none found in $USBDIR."
                   echo "Build one on the PC:  bash image-toolbox/build-kit-tar.sh kit.tar HEAD"
                   echo "then copy it to the stick and run this again."; exit 1; }

# A kit that was adopted has real git history; replacing it with a flat copy would throw that away
# and leave the owner unable to update the normal way afterwards.
if [ -d "$KIT/.git" ]; then
  echo "This kit is a git clone — use 'bash scripts/selfupdate.sh update' instead."
  echo "(That keeps its history; this script would replace it with a flat copy.)"
  exit 1
fi

NEW="$PARENT/$NAME.incoming-$STAMP"
rm -rf "$NEW"; mkdir -p "$NEW"
tar -xf "$TAR" -C "$NEW" \
  || { echo "extract FAILED — bad or truncated tarball"; rm -rf "$NEW"; exit 1; }

# Refuse anything that is not recognisably this kit, before it can replace a working one.
for must in scripts/unleashed_setup.sh scripts/_arco-lib.sh config-templates/AddOn.cfg.template; do
  [ -f "$NEW/$must" ] || { echo "REFUSING: the tarball has no $must — is it really the kit?"
                           rm -rf "$NEW"; exit 1; }
done
echo "  extracted $(find "$NEW" -type f | wc -l) files"
if [ -f "$NEW/.kit-commit" ]; then
  echo "  incoming commit: $(cut -c1-8 < "$NEW/.kit-commit")"
  [ -f "$KIT/.kit-commit" ] && echo "  installed now:   $(cut -c1-8 < "$KIT/.kit-commit")"
fi

# git archive carries the modes from the commit, but a tarball built on Windows can arrive with
# everything 644. Restore the bit rather than discovering it at the next menu run.
chmod +x "$NEW"/scripts/*.sh 2>/dev/null || true

chmod +x "$NEW"/unleashed-x-kaos/scripts/*.sh 2>/dev/null || true

# CARRY THE BRIDGE'S RUNTIME STATE ACROSS THE SWAP. unleashed-x-kaos/ is part of the kit now, so the
# tarball brings its CODE -- but .cache is the printer's, not the repository's: it holds the KAOS
# payload that KAOS_ON downloaded and, decisively, the backup of Phrozen's own dev.py that KAOS_OFF
# restores. The swap below moves the whole kit aside, so without this the backup would end up in a
# .replaced- directory nobody looks in, and a printer with KAOS active could no longer be put back to
# the vendor file -- an armed motion guard with no way home, which the boot guard calls the one state
# never to boot into. Copied rather than moved: if anything below fails, the old kit is still intact.
if [ -d "$KIT/unleashed-x-kaos/.cache" ]; then
  if cp -a "$KIT/unleashed-x-kaos/.cache" "$NEW/unleashed-x-kaos/.cache" 2>/dev/null; then
    echo "  carried the bridge's cache across (KAOS payload + vendor dev.py backup)"
  else
    echo "  REFUSING: could not carry the bridge's .cache across — the swap would strand the"
    echo "            backup of Phrozen's dev.py. Nothing was changed."
    rm -rf "$NEW"; exit 1
  fi
fi

OLD="$PARENT/$NAME.replaced-$STAMP"
mv "$KIT" "$OLD" && mv "$NEW" "$KIT" || { echo "SWAP FAILED — the old kit is at $OLD"; exit 1; }
echo "  swapped in. Previous kit kept at $OLD"

cat <<TXT

=== Updated ===
 This script is still running from the OLD copy — that is deliberate and safe, a
 rename does not disturb a file bash already has open. The new one takes effect
 the next time you start something.

 Worth running now:
   bash $KIT/scripts/check-guards.sh      # a kit update does not rewire the guards
   bash $KIT/scripts/unleashed_setup.sh

 The update lands when the klipper SERVICE starts — Klipper's own RESTART /
 FIRMWARE_RESTART does not run the guards. Config features, Klipper extras and
 the Mainsail theme all arrive then:
   sudo systemctl restart klipper

 If anything is wrong, the previous kit is intact at:
   $OLD
TXT
