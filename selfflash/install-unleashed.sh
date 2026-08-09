#!/bin/bash
# install-unleashed.sh — reflash the internal eMMC from the RUNNING system, image streamed from the
# external USB stick. No teardown. Two-phase: this driver ARMS the flash (verify + detect + confirm
# + embed params into a fresh initramfs + reboot); the actual write happens in the initramfs
# (arco-emmc-flash init-premount hook) where the eMMC is not yet the root filesystem.
#
#   *** Proven end-to-end on real hardware (2026-07-10), but still ONE SHOT, NO NET: once the write has
#       begun, a failure needs a recovery that opens the printer: pull the eMMC + re-flash it on a PC (path B).
#       Before the write starts, pulling the USB stick + a power-cycle makes the flasher stand down. ***
#
# Usage:
#   sudo bash install-unleashed.sh                # inspect: find image, verify, show target — no changes
#   sudo bash install-unleashed.sh --arm          # verify + confirm + arm the initramfs flash + reboot
#   sudo bash install-unleashed.sh --backup       # back THIS printer's eMMC up to the stick (read-only)
#   sudo bash install-unleashed.sh --disarm       # remove a pending flash or backup + rebuild initramfs
#   options: --image PATH  --usb DIR  --yes(skip typed confirm; discouraged)  --no-reboot
#
# --backup is the way back that otherwise does not exist. Phrozen publish no stock image, so today
# returning a printer to factory means opening it and pulling the eMMC. Run --backup BEFORE flashing and
# the owner keeps their own restore image; restoring it later is the ordinary flash with --image.
# The result is a copy of Phrozen's system, licensed to that one owner: it stays on their stick and is
# never shared or redistributed.
#
# Standalone by design (a first migration runs on stock Buster with no kit) — no kit paths assumed.
set -uo pipefail

# ---- self-locating (the initramfs bits live next to this script) --------------------------------
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${ARCO_STATE_DIR:-/etc/arco-selfflash}"        # persistent arm params (also embedded into initramfs)
ITOOLS="${ARCO_INITRAMFS_DIR:-/etc/initramfs-tools}"      # initramfs-tools root (overridable for offline tests)
HOOK_SRC="$SELFDIR/initramfs/arco-emmc-flash.hook"
PREMOUNT_SRC="$SELFDIR/initramfs/arco-emmc-flash"
TEST="${ARCO_SELFFLASH_TEST:-0}"              # 1 = relax HW gates so a loop device can stand in (offline test)
# Deliberately NOT matching Arco-Unleashed*.img.gz: the flasher picks its image by that pattern and takes
# the first match, so a backup named like a release could be flashed instead of the release.
#
# The name carries WHICH SYSTEM was imaged, and that is not cosmetic. With one fixed name and a single
# .previous, an image of Phrozen's original system -- which cannot be obtained any other way, because
# Phrozen publish none -- was rotated out by the second routine backup taken afterwards and deleted by
# the third. Two ordinary backups destroyed the only way back. Rotation is per name, so an Unleashed
# backup can no longer displace a stock one; and the revert menu can label its candidates instead of
# asking the owner to remember.
# In the NAME, not a sidecar: a sidecar can be left behind when the file is copied to another stick,
# and then the image is anonymous again. The name travels with it.
# Both still begin with arco-emmc-backup, which is what the restore-detection tests match on, and the
# old plain name keeps working for sticks that already exist.
arco_system_kind(){                      # "stock" (Phrozen's) or "unleashed" (ours)
  local home=""
  [ -n "${SUDO_USER:-}" ] && home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$home" ] || home="$HOME"
  [ -f "$home/arco-unleashed/.kit-commit" ] && { echo unleashed; return; }
  [ -d "$home/arco-unleashed/scripts" ]     && { echo unleashed; return; }
  echo stock
}
BACKUP_NAME="${ARCO_BACKUP_NAME:-arco-emmc-backup-$(arco_system_kind).img.gz}"

# ---- args ----------------------------------------------------------------------------------------
# Backups are split into parts of at most SPLITSZ so they fit FAT32, whose per-file ceiling is 4 GiB
# minus one byte. 3.7 GiB leaves 308 MiB of headroom for filesystem slack and for anyone who later
# moves the parts around. Overridable mainly so the split path can be exercised without first filling
# an eMMC with several gigabytes of junk: ARCO_BACKUP_SPLIT=400000000 turns any backup into a set.
SPLITSZ="${ARCO_BACKUP_SPLIT:-3972005888}"
# -1 is the default because this runs on a printer the owner must not switch off, and time is the cost
# that hurts. --small trades that: measured on an Arco, level 6 packs runs of zeros 4.5x tighter than
# level 1 (0.097% vs 0.436%) and costs about 40% more wall clock. Levels 2 and 3 are NOT worth offering
# -- they use the same fast deflate strategy as 1 and measured byte-identical on zeros.
GZLEVEL="${ARCO_BACKUP_GZIP:-1}"

MODE=inspect; IMG=""; USBDIR=""; ASSUME_YES=0; DO_REBOOT=1
while [ $# -gt 0 ]; do case "$1" in
  --arm)       MODE=arm ;;
  --backup)    MODE=backup ;;
  --disarm)    MODE=disarm ;;
  --image)     IMG="${2:?}"; shift ;;
  --usb)       USBDIR="${2:?}"; shift ;;
  --fast)      GZLEVEL=1 ;;
  --small)     GZLEVEL=6 ;;
  --yes)       ASSUME_YES=1 ;;
  --no-reboot) DO_REBOOT=0 ;;
  -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown arg: $1"; exit 2 ;;
esac; shift; done
case "$GZLEVEL" in [1-9]) : ;; *) GZLEVEL=1 ;; esac
case "$SPLITSZ" in ''|*[!0-9]*) SPLITSZ=3972005888 ;; esac
[ "$SPLITSZ" -lt 1048576 ] && SPLITSZ=1048576

die(){ echo "  ✗ $*" >&2; exit 1; }
note(){ echo "  · $*"; }
# Non-fatal, but must be seen: this script's failures are diagnosed from what the user reports back,
# so anything that explains a refusal has to reach the screen instead of being swallowed.
warn(){ echo "  ! $*" >&2; }
hr(){ printf '%s\n' "----------------------------------------------------------------------"; }
ask_yn(){ local a; read -rp "  $1 [y/n] " a; [ "$a" = y ] || [ "$a" = Y ] || [ "$a" = yes ]; }

# ---- which filesystems the INITRAMFS flasher can mount -------------------------------------------
# This shell can mount far more than the initramfs can, so "the stick mounted fine" proves nothing about
# what happens after the reboot. These two answer the only question that matters at arm time.
# Keep in step with initramfs/arco-emmc-flash{,.hook}: vfat and exfat are added there by name; ext* rides
# along because initramfs-tools always carries the root filesystem's driver.
fs_available(){   # can THIS kernel mount <fstype> at all — built-in, already loaded, or a module on disk?
  grep -qE "[[:space:]]$1\$" /proc/filesystems 2>/dev/null && return 0
  modinfo "$1" >/dev/null 2>&1
}
fs_flashable(){
  case "$1" in
    vfat|exfat|ext2|ext3|ext4) fs_available "$1" ;;
    *)                         return 1 ;;
  esac
}
fs_flashable_list(){
  local out= f
  for f in vfat exfat ext4; do fs_flashable "$f" && out="${out:+$out, }$f"; done
  echo "${out:-vfat}"
}
# Empty/declined Wi-Fi -> confirm we fall through to the first-boot setup portal (set from a phone), or abort
# BEFORE anything is armed. Never silently flash with no Wi-Fi: from Buster that would strand the printer
# (MCUs unflashed -> Klipper error blocks the display; no Wi-Fi -> no SSH).
use_portal_or_die(){
  note "wifi: $1"
  if [ "$ASSUME_YES" = 1 ] || ask_yn "No Wi-Fi captured — set it up on first boot from a phone instead?"; then
    note "wifi: empty -> the first-boot portal will handle it (join the"
    note "      Arco-Unleashed-Setup network from a phone and pick yours)"
  else
    die "aborted before arming — nothing changed. Re-run with a correct
         wifi-seed.txt, or connect the printer to Wi-Fi first."
  fi
}
disclaimer(){ cat <<'EOF'

  Arco Unleashed is an INDEPENDENT, community project — NOT developed,
  supported, sponsored, endorsed by, or affiliated with Phrozen Tech Co.,
  Ltd. or ThroughTek Co., Ltd. It bundles, hosts and mirrors NO proprietary
  Phrozen/ThroughTek software. Phrozen's parts reach this printer either
  from the Arco_FW_V*.zip YOU provide, or — only after you confirm it —
  downloaded from PHROZEN'S OWN public repository. Either way the copy
  comes from Phrozen or from you, never from us, and any use of Phrozen's
  software or cloud is at YOUR OWN RISK under Phrozen's own license and
  privacy terms. 'Phrozen', 'Arco' and 'PhrozenGo' are trademarks of their
  owners, used only for identification (nominative fair use).

  Replacing the factory OS very likely VOIDS YOUR PHROZEN WARRANTY, and
  this overwrites the eMMC. If you may ever want the printer back as it
  is now, make an image of it first:  install-unleashed.sh --backup
  That image is also the ONLY way back to Phrozen's system later — it
  cannot be made once this flash has run.
EOF
}
[ "$(id -u)" = 0 ] || die "run as root (sudo)."

# ---- 1) find the image on the external USB -------------------------------------------------------
find_image() {
  # A split backup has no file under the plain name, only PREFIX.001 and its siblings -- and the owner
  # will quite reasonably pass the plain name, because that is what the .sha256 is called and what every
  # message about it says. Accept either, and also accept being handed one of the parts, since tab
  # completion makes that the easiest thing to type.
  if [ -n "$IMG" ]; then
    case "$IMG" in
      *.[0-9][0-9][0-9]) [ -f "$IMG" ] && IMG="${IMG%.*}" ;;
    esac
    [ -f "$IMG" ] || [ -f "$IMG.001" ] || die "image not found: $IMG  (a split backup needs its .001 part beside the name)"
    echo "$IMG"; return
  fi
  local dirs=() d
  [ -n "$USBDIR" ] && dirs+=("$USBDIR")
  dirs+=(/root/printer_data/gcodes/USB /home/*/printer_data/gcodes/USB /media/* /mnt/* /run/media/*/*)
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    local all; all=$(ls -1 "$d"/Arco-Unleashed*bookworm*.img.gz "$d"/Arco-Unleashed*.img.gz 2>/dev/null | awk '!seen[$0]++')
    [ -n "$all" ] || continue
    # More than one candidate is how a stale leftover wins silently: the glob picks the first,
    # while the .sha256 beside it may describe a different file -- which then surfaces only as an
    # unexplained "sha256 MISMATCH" much later. Say it here, while the names are still on screen.
    local n; n=$(printf '%s\n' "$all" | wc -l)
    if [ "$n" -gt 1 ]; then
      warn "$n Arco-Unleashed images on the USB — it should hold exactly ONE:"
      printf '%s\n' "$all" | sed 's/^/        /' >&2
      warn "using the first; delete the others and re-run if that is wrong."
    fi
    printf '%s\n' "$all" | head -1; return
  done
  die "no Arco-Unleashed*.img.gz on the USB. Looked in: ${dirs[*]}
         Pass --image PATH to name one explicitly."
}

# ---- one file, or a numbered set? -----------------------------------------------------------------
# A backup too large for FAT32 is written as PREFIX.001, .002, ... -- the same single gzip stream cut
# into pieces, so concatenating them reproduces the original file exactly. Everything from here on asks
# these four helpers instead of touching the path, which is what lets one code path verify, arm and
# restore both shapes. The glob is three digits so the shell sorts the parts and the .sha256/.rawsize
# sidecars cannot be swept in with them.
img_nparts_of(){ set -- "$1".[0-9][0-9][0-9]; if [ -f "$1" ]; then echo $#; else echo 0; fi; }
img_cat_of(){ if [ -f "$1" ]; then cat "$1"; else cat "$1".[0-9][0-9][0-9]; fi; }
img_size_of(){
  if [ -f "$1" ]; then wc -c < "$1" 2>/dev/null | tr -dc '0-9'; return; fi
  local p t=0 s
  for p in "$1".[0-9][0-9][0-9]; do
    [ -f "$p" ] || continue
    s=$(wc -c < "$p" 2>/dev/null | tr -dc '0-9'); t=$(( t + ${s:-0} ))
  done
  echo "$t"
}
# The gzip trailer lives at the very end of the STREAM, which for a set is the end of its last part.
img_tail4_of(){
  if [ -f "$1" ]; then tail -c 4 "$1" 2>/dev/null; return; fi
  set -- "$1".[0-9][0-9][0-9]
  [ -f "$1" ] || return 0
  shift $(( $# - 1 ))
  tail -c 4 "$1" 2>/dev/null
}

# ---- 2) verify checksum against the sidecar ------------------------------------------------------
# A tester hit this and all we got back was the words "sha256 MISMATCH". That was our own fault:
# `sha256sum -c` was run with its output thrown away, and it checks the filename written INSIDE the
# sidecar -- so a missing file, a renamed file and a genuinely corrupt file all failed identically,
# with nothing to tell them apart. Compare the hashes ourselves and name what is actually wrong.
verify_image() {
  local img="$1" sha="$1.sha256"
  [ -f "$sha" ] || die "missing checksum sidecar: $sha  (refusing to flash unverified image)"

  # First field of the sidecar = expected hash, rest = the name it was written for. Tolerate both
  # sha256sum spellings: "<hash>  <name>" (text) and "<hash> *<name>" (binary).
  #
  # TWO SHAPES, one reader. A single-file sidecar is the ordinary "<hash>  <name>" line. A split set's
  # sidecar carries one line per PART -- so that `sha256sum -c` works on it and names the bad part -- and
  # the hash of the whole stream in a marked comment, because that hash describes a file that does not
  # exist on disk. Read the marker when it is there, the first real line when it is not.
  #
  # The comment-skipping is not cosmetic: the first attempt at this took line 1 unconditionally, read
  # "#", stripped it to nothing and refused a healthy backup as "not a sha256 line". Found by the first
  # real restore against a split set.
  local want name
  want=$(awk '/^[ 	]*#[ 	]*arco-stream-sha256:/ {print $3; exit}
              /^[ 	]*#/ {next}
              NF {print $1; exit}' "$sha" | tr -dc '0-9a-fA-F')
  # Only meaningful for a single file; for a set the first real line names a part, not the image, and
  # warning about that would be noise on every split restore.
  name=$(awk '/^[ 	]*#[ 	]*arco-stream-sha256:/ {exit}
              /^[ 	]*#/ {next}
              NF {sub(/^[^ ]+[ ]+[*]?/, ""); print; exit}' "$sha")
  [ ${#want} -eq 64 ] || die "checksum sidecar is not a sha256 line: $sha"

  if [ -n "$name" ] && [ "$name" != "$(basename "$img")" ]; then
    warn "the sidecar was written for '$name', but the image found is '$(basename "$img")'."
    warn "comparing by content anyway — a name mismatch is not corruption."
  fi

  # Cheap structural check FIRST. Hashing 1.5 GB off a USB stick takes minutes, and the overwhelmingly
  # common failure -- an incomplete copy -- can be caught in milliseconds instead: a gzip file ends in a
  # 4-byte little-endian ISIZE (uncompressed size mod 2^32), and we ship that size in the .rawsize
  # sidecar. If the tail does not agree, the file is truncated or damaged at the end and there is no
  # point reading all of it. This also tells the two failure classes apart, which the hash alone cannot:
  # a short file is a copy problem, a full-length file with a wrong hash is flipped bits or a different
  # image. Skipped silently when .rawsize is absent -- it is an optimisation, never a new requirement.
  local size; size=$(img_size_of "$img")
  local raw=""; [ -f "$img.rawsize" ] && raw=$(tr -dc '0-9' < "$img.rawsize")
  local trailer_checked=0          # only then may the mismatch message claim the file is whole
  if [ -n "$raw" ]; then
    local b0 b1 b2 b3 isize
    read -r b0 b1 b2 b3 <<EOF
$(img_tail4_of "$img" | od -An -tu1)
EOF
    if [ -n "$b3" ]; then
      isize=$(( b0 + b1 * 256 + b2 * 65536 + b3 * 16777216 ))
      trailer_checked=1
      if [ "$isize" -ne $(( raw % 4294967296 )) ]; then
        printf '\n' >&2
        warn "the image file is INCOMPLETE or damaged — refusing to flash."
        warn "  It does not end the way a complete copy ends: that carries a"
        warn "  final marker for $(( raw % 4294967296 )) bytes of content, this one carries $isize."
        warn "  size on the stick: ${size:-unknown} bytes"
        printf '\n' >&2
        warn "This is almost always an interrupted copy: the stick was pulled,"
        warn "or Windows was still flushing its cache. Copy it again and eject"
        warn "properly (\"Safely Remove Hardware\") before unplugging it — then re-run."
        die "aborting before touching the eMMC."
      fi
    fi
  fi

  note "verifying sha256 of ${img##*/} — reads all of it, a few minutes ..."
  local have; have=$(img_cat_of "$img" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')
  [ -n "$have" ] || die "could not read $img to hash it — bad USB stick or unreadable file."

  if [ "$have" != "$want" ]; then
    printf '\n' >&2
    warn "sha256 MISMATCH — refusing to flash."
    warn "  expected (sidecar): $want"
    warn "  actual   (on USB) : $have"
    warn "  size on the stick : ${size:-unknown} bytes"
    printf '\n' >&2
    if [ "$trailer_checked" = 1 ]; then
      warn "The file is NOT truncated: its gzip trailer matches the expected"
      warn "size, so the bytes themselves differ. Most likely one of:"
    else
      warn "There was no .rawsize sidecar to check the length against, so a"
      warn "truncated copy cannot be ruled out. Most likely one of:"
    fi
    warn "  * image and .sha256 are from different releases (copy BOTH);"
    warn "  * the stick still holds an older image (see the warning above);"
    warn "  * the download was damaged — check the .zip on your PC first:"
    warn "      Windows:  certutil -hashfile <image> SHA256"
    warn "      Linux:    sha256sum -c <image>.sha256"
    warn "    if the PC copy is wrong, download again; if it is correct but"
    warn "    the stick's is not, the stick or port is faulty — try another."
    warn "  * the stick is on a USB HUB. Plug it straight into the printer."
    warn "    A hub is the most common cause of a file that copies fine and"
    warn "    then reads back different."
    warn "If the log also shows CRC or I/O errors, stop swapping settings: that"
    warn "is the stick itself failing, or one this printer cannot drive. Use a"
    warn "different one — preferably USB 2.0 and plainly branded."
    warn "Fix: delete the image and .sha256 from the stick, copy both, re-run."
    die "aborting before touching the eMMC."
  fi
  note "checksum OK ✓"
}

# ---- 3) detect the internal eMMC + refuse anything else ------------------------------------------
# eMMC = the block device backing '/', which must be a non-removable mmcblk with boot0/boot1 siblings.
parent_disk() {  # partition -> its parent whole-disk device (mmcblk1p2 -> /dev/mmcblk1, sda1 -> /dev/sda)
  local src="$1" base
  [ -n "$src" ] || return 1
  base=$(lsblk -no pkname "$src" 2>/dev/null | head -1)
  [ -n "$base" ] || base=$(basename "$src" | sed -E 's/p?[0-9]+$//')   # fallback if lsblk lacks pkname
  [ -n "$base" ] && echo "/dev/$base"
}
usb_device_of() {  # underlying whole-disk device holding a path (image or directory)
  # Called with BOTH shapes: an image path, and the USB directory itself. So resolve the nearest path
  # that actually exists, rather than always reaching for the parent.
  #
  # A split backup has no file under its base name, and `findmnt --target` on a path that does not exist
  # returns nothing. An empty answer is not harmless here: the same-device guard is written as
  # `[ -n "$imgdev" ] && ...`, so it would quietly skip itself -- switching off the check that stops
  # someone flashing from an image sitting on the eMMC, for exactly the backups that need it.
  #
  # Reaching for the parent unconditionally fixed that and broke the other caller: find_usb_dir passes a
  # DIRECTORY, whose parent is on the eMMC, so every stick was rejected as "that is the eMMC itself" and
  # --backup reported no writable USB at all. One helper, two kinds of argument -- test both.
  local p="$1"
  [ -e "$p" ] || p="$(dirname "$p")"
  parent_disk "$(findmnt -no SOURCE --target "$p" 2>/dev/null)"
}
detect_emmc() {
  local rootsrc dev base
  rootsrc=$(findmnt -no SOURCE / 2>/dev/null) || die "cannot resolve root device"
  dev="$(parent_disk "$rootsrc")"; base="$(basename "$dev")"
  [ -b "$dev" ] || die "root device '$dev' is not a block device"
  if [ "$TEST" = 1 ]; then echo "$dev"; return; fi        # offline test: skip HW hallmarks
  case "$base" in mmcblk*) : ;; *) die "root '$dev' is not an mmc device — refusing (unexpected layout)";; esac
  [ -e "/dev/${base}boot0" ] || die "'$dev' has no boot0 partition — not an eMMC. Refusing."
  [ "$(cat "/sys/block/$base/removable" 2>/dev/null)" = 0 ] || die "'$dev' is removable — that's SD/USB, not the eMMC. Refusing."
  echo "$dev"
}

# ---- shared: assemble + show the plan ------------------------------------------------------------
plan() {
  IMG="$(find_image)"; note "image : $IMG"
  local imgdev; imgdev="$(usb_device_of "$IMG")"; note "source USB device: ${imgdev:-?}"
  # The initramfs must be able to mount the stick this image sits on, and it can mount far less than this
  # shell can. Buster in particular mounts exFAT through FUSE in userspace, which does not exist in an
  # initramfs at all -- so the stick reads perfectly here and is simply absent after the reboot. Refuse
  # now, where it is a sentence, rather than after a reboot into a flasher that finds nothing.
  local imgfs; imgfs=$(findmnt -no FSTYPE --target "$(dirname "$IMG")" 2>/dev/null)
  if [ -n "$imgfs" ] && ! fs_flashable "$imgfs"; then
    warn "the image is on a $imgfs filesystem, which the initramfs flasher cannot mount"
    warn "(it can do: $(fs_flashable_list))."
    die "move the image to a stick it can read, then re-run — nothing was changed."
  fi
  EMMC="$(detect_emmc)" || die "could not identify the internal eMMC (see the message above)."
  note "target eMMC     : $EMMC  ($(cat "/sys/block/$(basename "$EMMC")/size" 2>/dev/null | awk '{printf "%.1f GB", $1*512/1e9}'))"
  [ -n "$imgdev" ] && [ "$imgdev" = "$EMMC" ] && die "source and target are the SAME device — the image must live on the external USB, not the eMMC."
  fits_target "$IMG" "$EMMC"
  verify_image "$IMG"
}

# Does the image even fit? Nothing used to ask. It never bit, because the released image is 5.5 GB and
# the smallest eMMC an Arco ships with is 8 GB -- but the margin is luck, not a check, and the failure
# mode is the worst one this tool has: dd fills the device, hits ENOSPC and stops, and what is left is a
# half-written eMMC. That happens AFTER the point of no return, so the printer needs path B (open it up,
# pull the eMMC) to come back. The one thing worth spending a millisecond on is making sure we never
# start a write that cannot finish.
# It matters more now that images can also be BACKED UP from a printer: an image taken from a machine
# with a retrofitted 32 GB eMMC can never be written to a stock 8 GB one, and nothing about the file
# says so.
# .rawsize is the uncompressed length; skipped when the sidecar is absent, like the trailer check.
fits_target() {
  local img="$1" dev="$2" raw devsz
  [ -f "$img.rawsize" ] || return 0
  raw=$(tr -dc '0-9' < "$img.rawsize"); [ -n "$raw" ] || return 0
  devsz=$(cat "/sys/block/$(basename "$dev")/size" 2>/dev/null | tr -dc '0-9')
  [ -n "$devsz" ] || return 0
  devsz=$(( devsz * 512 ))
  [ "$raw" -le "$devsz" ] && return 0
  printf '\n' >&2
  warn "this image does NOT fit the eMMC in this printer — refusing to flash."
  warn "  image needs : $raw bytes ($(( raw / 1000000000 )).$(( raw / 100000000 % 10 )) GB uncompressed)"
  warn "  $dev holds  : $devsz bytes ($(( devsz / 1000000000 )).$(( devsz / 100000000 % 10 )) GB)"
  printf '\n' >&2
  warn "Writing it anyway would fill the eMMC and stop part-way, leaving a"
  warn "printer that only opening it and pulling the eMMC can recover."
  warn "If this backup came from another printer, that one has a larger eMMC."
  die "aborting before touching the eMMC."
}

# ---- resolve WiFi + always suppress our captive portal (written to the USB for firstrun) -----------
# Precedence: no_wifi.txt > wifi-seed.txt > live capture > empty. Live capture scans BOTH wpa configs
# (wpa_supplicant-wlan0.conf AND the generic wpa_supplicant.conf) — stock Buster and some Bookworm setups
# point the wpa service at the generic file, others at the per-iface one. NM = defensive fallback.
# Consistent header (matches the new image: short ctrl_interface + country) + a network block. Live
# capture EXTRACTS the verbatim network={...} block(s) — preserving quoted-plaintext OR unquoted-hash
# psk exactly — and grafts them under our header, so only ssid/psk come from the old system.
ARCO_WIFI_CC="${ARCO_WIFI_CC:-00}"   # regulatory country for the seeded WiFi (00 = world roaming). A WRONG country
                                     # stops the printer joining a network abroad — set from wifi-seed COUNTRY= or
                                     # (live capture) the source config's own country=.
# country=00 (world) here is DELIBERATE: brcmfmac/AP6212 is self-managed, so 00 lets the STA roam and
# associate to the user's AP in any country (a former hardcoded DE blocked association abroad). Keep it.
# 00 only breaks the *setup AP's* ability to beacon — that is fixed where the AP is raised (wifi-portal.sh),
# NOT by weakening the roaming seed here.
ARCO_WIFI_LIVE_SSID=""               # SSID this printer is associated with right now (filled during live capture)
wpa_header()   { printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\ncountry=%s\n' "$ARCO_WIFI_CC"; }
# Writes ONE network block from a typed-in SSID/password. Three things here are not cosmetic, because
# wpa_supplicant validates the WHOLE file: any one of them makes it exit 255, systemd's start limit then
# keeps the service down for the rest of the boot, and the printer has no WiFi at all with nothing
# saying why. All three were reachable from this function:
#   * an EMPTY password wrote psk="" — a zero-length passphrase, rejected. An open network needs
#     key_mgmt=NONE instead.
#   * a password outside 8..63 bytes (or an SSID over 32) — rejected. Seen on hardware with 5 characters.
#   * a quote or backslash written raw — the closing quote gets escaped and the block falls apart.
wpa_esc()      { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
wpa_len_ok()   { n=$(printf '%s' "$1" | wc -c); [ "$n" -ge "$2" ] && [ "$n" -le "$3" ]; }
wpa_net()      {
  local s="$1" p="$2"
  wpa_len_ok "$s" 1 32 || { echo "  ✗ wifi: the network name must be 1-32 characters — not written" >&2; return 1; }
  if [ -n "$p" ] && ! wpa_len_ok "$p" 8 63; then
    case "$p" in
      *[!0-9A-Fa-f]*|"") echo "  ✗ wifi: a WiFi password must be 8-63 characters — not written" >&2; return 1 ;;
      *) [ "$(printf '%s' "$p" | wc -c)" = 64 ] || { echo "  ✗ wifi: a WiFi password must be 8-63 characters — not written" >&2; return 1; } ;;
    esac
  fi
  printf 'network={\n\tssid="%s"\n' "$(wpa_esc "$s")"
  if [ -n "$p" ]; then printf '\tpsk="%s"\n' "$(wpa_esc "$p")"; else printf '\tkey_mgmt=NONE\n'; fi
  printf '}\n'
}
# Extract the network={...} blocks from a wpa_supplicant config, VERBATIM — byte for byte. That is a
# deliberate design decision, verified against two independent real stock Arco images (both carried a
# single plain block, quoted plaintext psk, no extras): a psk may legally contain quotes/backslashes
# which are ALREADY escaped correctly in the source, and re-parsing + re-quoting them is precisely how
# such passwords get destroyed. So we never rewrite a block's content — we only ever drop WHOLE blocks
# that provably cannot work on the fresh system:
#   * key_mgmt=...EAP...   -> dropped. WPA-Enterprise references identities/certificates that do not
#                             exist after flashing, so it could never associate; carrying it along
#                             just strands the recipient silently.
#   * disabled=1           -> dropped. wpa_supplicant would never select it anyway.
#   * ARCO_WIFI_LIVE_SSID  -> if set and it matches a block, ONLY that block is emitted: it is the
#                             network the donor printer is associated with at this moment, i.e. the one
#                             set of credentials proven to work.
# Kept blocks go to stdout (that is the config); one human-readable line per decision goes to stderr.
# [ \t] rather than [[:space:]] -- and this is not style. The awk on a STOCK Arco is mawk 1.3.3
# (November 1996), which does not implement POSIX character classes at all: [[:space:]] simply never
# matches. Proven on the printer after the revert -- the stock wpa config, one network={ } block with
# ssid="..." indented by a tab, produced NOTHING, while [ \t] matched it. This function runs during
# path A, which is started FROM stock Buster, so the case it silently failed in was the main one: the
# seeded config would carry our header and no network, the flashed printer would have no Wi-Fi, and
# the run would have already printed "captured live -> portal skipped". It only ever worked in
# testing because the tests ran from an already-migrated printer, where mawk is 1.3.4.
wpa_networks() {
  awk -v live="${ARCO_WIFI_LIVE_SSID:-}" '
    /^[ \t]*network[ \t]*=[ \t]*\{/ { inb=1; buf=""; ssid=""; eap=0; dis=0 }
    inb {
      buf = buf $0 "\n"
      if ($0 ~ /^[ \t]*ssid[ \t]*=/) {
        s = $0; sub(/^[ \t]*ssid[ \t]*=[ \t]*/, "", s)
        sub(/[ \t]*$/, "", s); gsub(/^"|"$/, "", s); ssid = s
      }
      if ($0 ~ /key_mgmt[ \t]*=[^#]*EAP/)             eap = 1
      if ($0 ~ /^[ \t]*disabled[ \t]*=[ \t]*1/)       dis = 1
      if ($0 ~ /^[ \t]*\}/) {
        inb = 0
        if (eap)      printf("  · wifi: skipping network \"%s\" — WPA-Enterprise cannot be carried to a fresh system\n", ssid) > "/dev/stderr"
        else if (dis) printf("  · wifi: skipping network \"%s\" — disabled=1\n", ssid) > "/dev/stderr"
        else { n++; blk[n] = buf; nm[n] = ssid }
      }
      next
    }
    END {
      if (inb) print "  · wifi: ignoring an unterminated network={ block at end of file" > "/dev/stderr"
      if (live != "") {
        for (i = 1; i <= n; i++) if (nm[i] == live) {
          printf("%s", blk[i])
          printf("  · wifi: seeding the network it is associated with: \"%s\"\n", live) > "/dev/stderr"
          exit
        }
      }
      for (i = 1; i <= n; i++) printf("%s", blk[i])
    }
  ' "$1"
}
# Wi-Fi profiles that stock units ship from the factory. Verified on a real donor image, where
# /etc/NetworkManager/system-connections/ held MAKERBASE3D, MENSON-WIFI and 创客基地 — all dated to the
# manufacturing run, none of them the owner's network. Seeding one hands the recipient a printer
# hunting for a network on another continent, so the NetworkManager fallback below de-prioritises them.
is_factory_ssid(){ case "$1" in MAKERBASE3D|MENSON-WIFI|创客基地|[Mm][Aa][Kk][Ee][Rr][Bb][Aa][Ss][Ee]*) return 0 ;; *) return 1 ;; esac; }

resolve_wifi() {
  local usb; usb="$(dirname "$IMG")"
  local out="$usb/.arco-wifi.conf" flag="$usb/.arco-skip-portal"
  rm -f "$out" "$flag"                                        # start clean — only skip our portal if WiFi is ACTUALLY seeded
  # IMPORTANT: the .arco-skip-portal flag must ONLY be dropped when a WiFi config is written. If we skip
  # the portal WITHOUT seeding WiFi, first boot has no WiFi AND no portal — and from Buster the display is
  # blocked by an MCU error (MCUs not yet flashed), so there is no way in. Leaving the flag off makes the
  # first-boot setup portal come up so WiFi can be set from a phone (independent of the display).
  # no_wifi.txt: explicit "portal" choice — still confirm so it's a deliberate decision, not a surprise.
  # Accept the hyphen spelling too. The documented name uses an underscore, but "no-wifi.txt" is what
  # people actually type — and getting it wrong used to be silent: the file was ignored, the live-capture
  # branch ran instead, and the printer was seeded with the very network the user was trying NOT to seed.
  for _nw in no_wifi.txt no-wifi.txt; do
    [ -f "$usb/$_nw" ] || continue
    use_portal_or_die "$_nw selected — no Wi-Fi will be seeded"; return
  done

  # wifi-seed.txt: show the SSID and confirm it; decline -> portal fallback.
  if [ -f "$usb/wifi-seed.txt" ]; then
    # wifi-seed.txt is almost always made on Windows, so normalise the Windows text quirks that otherwise
    # make SSID=/PSK=/COUNTRY= silently NOT parse (then we fall through to the less-reliable live-capture /
    # portal): strip a UTF-8 BOM off line 1 (Notepad "UTF-8"), drop every CR (CRLF), and allow leading
    # whitespace before the key. Do it once into $seed, then read the fields from that.
    local s p c seed; seed=$(sed '1s/^\xEF\xBB\xBF//' "$usb/wifi-seed.txt" 2>/dev/null | tr -d '\r')
    s=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*SSID=//p'    | head -1)
    p=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*PSK=//p'     | head -1)
    c=$(printf '%s\n' "$seed" | sed -n 's/^[[:space:]]*COUNTRY=//p' | head -1 | tr -cd 'A-Za-z')
    [ -n "$c" ] && ARCO_WIFI_CC="$c"
    if [ -n "$s" ]; then
      if [ "$ASSUME_YES" = 1 ] || ask_yn "Wi-Fi from wifi-seed.txt: SSID \"$s\" — flash with this network?"; then
        if { wpa_header; wpa_net "$s" "$p"; } > "$out"; then chmod 600 "$out"; : > "$flag"; else rm -f "$out"; use_portal_or_die "the captured Wi-Fi is not usable as written (see the message above)"; return; fi
        note "wifi: from wifi-seed.txt (SSID \"$s\") -> portal skipped"; return
      fi
      use_portal_or_die "wifi-seed.txt SSID \"$s\" declined"; return
    fi
    note "wifi: wifi-seed.txt unparseable -> trying live capture"
  fi

  # live capture from the running system: show the SSID(s) and confirm; decline -> portal fallback.
  # Creds may live in the per-iface wpa_supplicant-wlan0.conf OR the generic wpa_supplicant.conf (stock
  # Buster + some Bookworm point the wpa service at the latter) — pick the first that holds a network.
  local live=""
  for _cand in ${ARCO_WPA_SRC:+"$ARCO_WPA_SRC"} /etc/wpa_supplicant/wpa_supplicant-wlan0.conf /etc/wpa_supplicant/wpa_supplicant.conf; do
    if [ -f "$_cand" ] && grep -qi 'ssid=' "$_cand" 2>/dev/null; then live="$_cand"; break; fi
  done
  if [ -n "$live" ]; then
    local srcc; srcc=$(sed -n 's/^[[:space:]]*country=//p' "$live" | head -1 | tr -cd 'A-Za-z')
    # stock Buster's wpa config carries NO country=, so this alone would default to world/00. But the running
    # printer is ASSOCIATED, so it has already learned the AP's regulatory country from its 802.11d beacon —
    # `iw reg get` reports it (e.g. "country DE:"). Prefer that: the seed then carries the AP's real country
    # instead of 00, matching the network the fresh system will re-join (correct channels/TX power).
    [ -z "$srcc" ] && srcc=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z][A-Z]\):.*/\1/p' | grep -vx 00 | head -1)
    [ -n "$srcc" ] && ARCO_WIFI_CC="$srcc"   # source wpa country=, else the connected AP's learned 802.11d country
    local caps; caps=$(grep -oE 'ssid="[^"]*"' "$live" | sed 's/^ssid="//; s/"$//' | paste -sd, -); [ -n "$caps" ] || caps="(SSID not shown)"
    # Cross-check against the network this printer is ACTUALLY associated with. That live association is
    # the only *proof* we have that a set of credentials works — a config file can be stale (edited but
    # never re-connected, or several saved nets of which only one is in range). When we can read it we
    # seed exactly that block; when it contradicts the file we say so. Until now a stale file was seeded
    # in silence, and the recipient got a printer hunting for a network that does not exist here.
    ARCO_WIFI_LIVE_SSID=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p' | head -1)
    if [ -n "$ARCO_WIFI_LIVE_SSID" ]; then
      if printf '%s\n' "$caps" | tr ',' '\n' | grep -qxF -- "$ARCO_WIFI_LIVE_SSID"; then
        note "wifi: seeding the network it is associated with: \"$ARCO_WIFI_LIVE_SSID\""
      else
        note "wifi: WARNING — associated with \"$ARCO_WIFI_LIVE_SSID\", but $live lists \"$caps\"."
        note "wifi:          That file looks stale; the network may not work here."
      fi
    else
      note "wifi: live association unreadable — going by the config file"
    fi
    if [ "$ASSUME_YES" = 1 ] || ask_yn "Captured this printer's Wi-Fi \"$caps\" — flash with it?"; then
      { wpa_header; wpa_networks "$live"; } > "$out"; chmod 600 "$out"   # verbatim network block(s) + our header
      # Self-check BEFORE dropping the skip-portal flag. The block filter can legitimately reject every
      # network (an enterprise-only or all-disabled donor), and a header-only config would then skip the
      # portal while providing no network at all — exactly the combination that leaves a printer with no
      # Wi-Fi, no portal and, from Buster, no display (MCUs unflashed). Fall back to the portal instead.
      if grep -q 'ssid="' "$out" 2>/dev/null; then
        : > "$flag"
        note "wifi: captured live (SSID \"${ARCO_WIFI_LIVE_SSID:-$caps}\") -> portal skipped"; return
      fi
      rm -f "$out"
      use_portal_or_die "no usable network survived from $live (enterprise-only/disabled)"; return
    fi
    use_portal_or_die "captured SSID \"$caps\" declined"; return
  fi

  # NetworkManager fallback: same show-and-confirm, but choose sensibly instead of taking the first hit.
  # A stock unit typically has BOTH: the wpa file the running system actually uses (handled above, and
  # authoritative) and leftover factory NM profiles. Picking blindly can therefore land on a factory
  # network. Prefer any non-factory profile; only fall back to a factory one, and then say so loudly.
  local nm="" nm_factory="" nmf nms
  for nmf in "${ARCO_NM_DIR:-/etc/NetworkManager/system-connections}"/*.nmconnection; do
    [ -f "$nmf" ] || continue
    grep -q '^psk=' "$nmf" 2>/dev/null || continue
    nms=$(sed -n 's/^ssid=//p' "$nmf" | head -1); [ -n "$nms" ] || continue
    if is_factory_ssid "$nms"; then [ -n "$nm_factory" ] || nm_factory="$nmf"
    else nm="$nmf"; break; fi
  done
  [ -n "$nm" ] || nm="$nm_factory"
  if [ -n "$nm" ]; then
    local s p; s=$(sed -n 's/^ssid=//p' "$nm" | head -1); p=$(sed -n 's/^psk=//p' "$nm" | head -1)
    # Same country reasoning as the wpa branch: an associated printer has already learned the AP's
    # regulatory country from its 802.11d beacon, so prefer that over plain world/00.
    local nmc; nmc=$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z][A-Z]\):.*/\1/p' | grep -vx 00 | head -1)
    [ -n "$nmc" ] && ARCO_WIFI_CC="$nmc"
    if [ -n "$s" ]; then
      if is_factory_ssid "$s"; then
        note "wifi: WARNING — the only NetworkManager profile found is \"$s\", which is a FACTORY network"
        note "wifi:          from the factory line, not yours. It would never join."
        note "wifi:          Prefer a wifi-seed.txt on the stick (SSID=/PSK=/COUNTRY=)."
        # Under --yes nobody is watching, so do NOT silently seed a network we know is wrong.
        [ "$ASSUME_YES" = 1 ] && { use_portal_or_die "only a factory NetworkManager profile (\"$s\") — refusing to seed it"; return; }
      fi
      if [ "$ASSUME_YES" = 1 ] || ask_yn "Captured Wi-Fi (NetworkManager): SSID \"$s\" — flash with this network?"; then
        if { wpa_header; wpa_net "$s" "$p"; } > "$out"; then chmod 600 "$out"; : > "$flag"; else rm -f "$out"; use_portal_or_die "the captured Wi-Fi is not usable as written (see the message above)"; return; fi
        note "wifi: captured from NetworkManager (SSID \"$s\") -> portal skipped"; return
      fi
      use_portal_or_die "NetworkManager SSID \"$s\" declined"; return
    fi
  fi

  # nothing found: confirm the portal path.
  use_portal_or_die "no Wi-Fi found on this system"
}

# ---- free the TFT so the static "DO NOT POWER OFF" screen holds. Best-effort, NEVER fatal: stock
# Buster lacks our watchdog and may name the voronFDM unit differently. -----------------------------
stop_display_owner() {
  local pid unit
  pid=$(pgrep -x voronFDM 2>/dev/null | head -1)
  if [ -n "$pid" ]; then
    unit=$(ps -o unit= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$unit" ] && [ "$unit" != "-" ] && systemctl stop "$unit" 2>/dev/null || true
  fi
  systemctl stop KlipperScreen 2>/dev/null || true
  systemctl stop arco-voronfdm-watchdog.timer 2>/dev/null || true
  pkill -x voronFDM 2>/dev/null || true
  note "display owner stopped — the TFT holds its last frame through this"
  # TODO(v1): draw the static 'DO NOT POWER OFF' screen here via the tft.sh/TJC serial path.
}

# ---- verify the stick also carries what the FIRST BOOT needs (checked after consent, before flashing) --
check_usb_payload() {
  # first-boot payload (Phrozen FW + AMS backup) is only consumed by the Unleashed firstrun;
  # a non-Unleashed image (e.g. a stock Buster full-disk image via --image) does not need it.
  case "$(basename "$IMG")" in
    Arco-Unleashed*) : ;;
    *) note "non-Unleashed image ($(basename "$IMG")) -> skipping Unleashed first-boot payload check"; return 0 ;;
  esac
  local usb; usb="$(dirname "$IMG")" miss=""
  # The AMS backup is still fatal: phrozen_master and ~/hdlDat exist ONLY on the running original
  # printer -- they are in no download and in no Phrozen package, so once this flash is done they are
  # gone for good. Verified against Phrozen's own public repository too: frp-oms there holds only frp/.
  [ -f "$usb/arco-phrozen-ams.tar.gz" ] || miss="$miss\n    - arco-phrozen-ams.tar.gz   (AMS backup from collect_data_arco.sh)"
  if [ -n "$miss" ]; then
    printf '  Missing on the USB stick (needed for the first boot):%b\n' "$miss" >&2
    die "add the missing file(s) to the stick and re-run. Nothing was flashed."
  fi
  # The firmware zip used to be fatal here as well. It no longer is: Phrozen publishes the display
  # module themselves, so the first boot offers to fetch it from their repository. Refusing to flash
  # over a missing zip would now block installs that will work perfectly well.
  if ls "$usb"/Arco_FW_V*.zip >/dev/null 2>&1; then
    note "USB payload OK (AMS backup + Phrozen firmware zip present)"
  else
    note "USB payload OK (AMS backup present)"
    # Kept under 80 columns: this is read in the recipient's default PuTTY, and a wrapped
    # paragraph in front of an irreversible action reads like something already went wrong.
    echo "  No Arco_FW_V*.zip on the stick — that is fine. At first boot the"
    echo "  printer offers to download Phrozen's display module from Phrozen's"
    echo "  own public repository (you confirm once)."
    echo "  Add the zip now only if the printer will have NO INTERNET during"
    echo "  setup, or if you want PhrozenGo, Phrozen's cloud app — the one"
    echo "  thing that lives only in their own package."
  fi
}

# ---- ARM: embed params into a fresh initramfs, then reboot ---------------------------------------
arm() {
  local restoring=0
  # --image is always given for a restore, so this is knowable before anything is printed. plan() can
  # still change IMG (it resolves the pattern when --image was not used), so it is re-checked after.
  # The filename test only recognises OUR backups. Going back to Phrozen's system is just as much a
  # restore -- the image already carries its own Wi-Fi and its own everything -- but the owner's stock
  # image can be called anything, so the name cannot tell us. Seen on hardware during the first revert:
  # it asked to capture the Wi-Fi and print the "replacing the factory OS" disclaimer while putting the
  # factory OS back. Harmless, and exactly backwards. The menu that knows what it is doing says so.
  [ "${ARCO_RESTORING:-0}" = 1 ] && restoring=1
  [ -n "$IMG" ] && case "$(basename "$IMG")" in arco-emmc-backup*) restoring=1;; esac
  if [ "$restoring" = 1 ]; then
    hr; echo "  RESTORE this printer from your own image"; hr
  else
    hr; echo "  ARM eMMC self-flash"; hr
  fi
  refuse_if_printing "the flash"
  # The disclaimer is about replacing Phrozen's system with this project's. Writing back the owner's own
  # image is neither of those things, so it would just be noise in front of the one screen that matters.
  [ "$restoring" = 1 ] || disclaimer
  plan
  [ "${ARCO_RESTORING:-0}" = 1 ] && restoring=1
  case "$(basename "$IMG")" in arco-emmc-backup*) restoring=1;; esac
  # Same rule as verify_image, and it has to be: the initramfs compares this against the hash of the
  # parts concatenated, so for a split set it must be the STREAM hash from the marked comment, not the
  # first part's. `cut -d' ' -f1` -- what stood here -- takes the first field of EVERY line, so it would
  # have handed over a multi-line string starting with "#", and the flash would have failed after the
  # reboot with an unexplained mismatch.
  local sha; sha=$(awk '/^[ 	]*#[ 	]*arco-stream-sha256:/ {print $3; exit}
                        /^[ 	]*#/ {next}
                        NF {print $1; exit}' "$IMG.sha256")
  # Restoring one of our own backups is not an install, and the install-only steps are wrong for it.
  # The image IS this printer, byte for byte: it already carries the Wi-Fi configuration, so asking for
  # a network and seeding one onto the stick decides nothing; and it already carries phrozen_dev, so
  # demanding Arco_FW_V*.zip and the AMS tarball on the stick would abort an otherwise valid restore
  # over files the restored system does not need.
  # Worked out before anything is printed (top of this function), because the consent text differs too.
  # Printing the install text and then skipping the install steps told the reader the stick would be
  # checked for two files, and then did not check -- a promise the run does not keep is worse than none.
  echo
  if [ "$restoring" = 1 ]; then
    echo "  About to arm a RESTORE that will OVERWRITE $EMMC on the next boot"
    echo "  with your own backup. Everything on this printer is replaced by the"
    echo "  image; anything done since it was taken is gone."
    echo "  A failed write leaves the printer unbootable until you recover it"
    echo "  by OPENING the housing and re-flashing the eMMC on a PC (path B)."
    echo "  Its size and checksum were both checked above, before this prompt."
    echo "  No Wi-Fi or firmware files are needed: your image already has them."
  else
    echo "  About to arm a self-flash that will OVERWRITE $EMMC on the next boot."
    echo "  A failed write leaves the printer unbootable until you recover it"
    echo "  by OPENING the housing and re-flashing the eMMC on a PC (path B)."
    echo "  Arming also records your consent to install Phrozen's software and"
    echo "  to Phrozen's software and cloud terms."
    echo "  The USB stick must ALSO hold, for the first boot after flashing:"
    echo "    - arco-phrozen-ams.tar.gz  (from collect_data_arco.sh, step 0)"
    echo "      Checked right after your consent; without it nothing is flashed,"
    echo "      because it cannot be obtained any other way once this eMMC is"
    echo "      overwritten."
    echo "  Optional, and only if the printer will have NO INTERNET at setup, or"
    echo "  you want PhrozenGo (Phrozen's cloud app):"
    echo "    - Arco_FW_V*.zip           (Phrozen's package, you provide it)"
    echo "      Without it the first boot offers to download just the display"
    echo "      module from Phrozen's own public repository."
  fi
  echo
  if [ "$ASSUME_YES" != 1 ]; then
    if [ "$restoring" = 1 ]; then
      read -rp "  Type 'yes' to restore this printer from that image: " c
    else
      read -rp "  Type 'yes' to acknowledge the disclaimer + consent above: " c
    fi
    [ "$c" = yes ] || die "not acknowledged — aborted, nothing changed."
    read -rp "  Now type the target device EXACTLY to write ($EMMC): " a
    [ "$a" = "$EMMC" ] || die "confirmation '$a' != '$EMMC' — aborted, nothing changed."
  fi
  [ "$restoring" = 1 ] || check_usb_payload       # first-boot files: only an install needs them
  # requires the initramfs pieces present
  [ -f "$HOOK_SRC" ] && [ -f "$PREMOUNT_SRC" ] || die "initramfs pieces missing next to the script ($HOOK_SRC / $PREMOUNT_SRC)"
  install -d "$STATE_DIR"
  if [ "$restoring" != 1 ]; then
    resolve_wifi                                  # capture/seed WiFi; skips the portal ONLY if WiFi was seeded
    : > "$(dirname "$IMG")/.arco-consent"         # headless FW-install consent (mirrors the portal checkbox)
  fi
  # params the initramfs hook reads (image is matched by basename on the USB at flash time).
  # ARCO_IMG_RAW = uncompressed byte size (from the .rawsize sidecar) -> drives the progress %; 0 = unknown.
  local raw; raw=$(cat "$IMG.rawsize" 2>/dev/null | tr -dc '0-9'); [ -n "$raw" ] || raw=0
  # The mirror of what --backup does to a pending flash. The initramfs prefers backup.conf when both
  # exist, so arming a flash on top of a pending backup would quietly take a backup instead -- the user
  # would watch the wrong job run and the flash would still be waiting afterwards.
  rm -f "$STATE_DIR/backup.conf"
  # How many parts the set had WHEN IT WAS CHECKED. The initramfs counts them again on the stick and
  # refuses if the number changed: a part deleted to make room, or a copy that stopped early, would
  # otherwise be discovered as a stream ending mid-sentence -- after the eMMC had been partly
  # overwritten. 0 means an ordinary single file.
  local nparts; nparts=$(img_nparts_of "$IMG")
  cat > "$STATE_DIR/flash.conf" <<EOF
ARCO_FLASH_ARMED=1
ARCO_IMG_NAME=$(basename "$IMG")
ARCO_IMG_PARTS=$nparts
ARCO_IMG_SHA=$sha
ARCO_IMG_RAW=$raw
ARCO_TARGET=$EMMC
EOF
  # install the initramfs-tools hooks (embed params + busybox) + the premount flasher
  install -D -m0755 "$HOOK_SRC"     "$ITOOLS/hooks/arco-emmc-flash"
  install -D -m0755 "$PREMOUNT_SRC" "$ITOOLS/scripts/init-premount/arco-emmc-flash"
  note "rebuilding initramfs (embeds flash params) ..."
  if [ "$TEST" = 1 ]; then note "[TEST] skipping update-initramfs + reboot"; return; fi
  # If the rebuild fails we must ACTUALLY disarm, not just say so: flash.conf + the hooks are already on
  # disk, so the next unrelated `update-initramfs` (a kernel upgrade, say) would arm the flash behind the
  # user's back. Remove them before bailing out.
  run_update_initramfs || {
    rm -f "$STATE_DIR/flash.conf" "$ITOOLS/hooks/arco-emmc-flash" "$ITOOLS/scripts/init-premount/arco-emmc-flash"
    die "update-initramfs failed — params and hooks removed again, so a
         later kernel update cannot arm the flash unnoticed."
  }
  echo
  echo "  ARMED. On the next boot the initramfs verifies the image and"
  echo "  writes it to $EMMC."
  echo "  Leave the USB stick in. To cancel: sudo bash $0 --disarm"
  if [ "$DO_REBOOT" = 1 ]; then
    read -rp "  Reboot now to start the flash? [y/N] " r
    if [ "$r" = y ]; then stop_display_owner; reboot
    else note "not rebooting; run 'reboot' when ready (the DO-NOT-POWER-OFF screen shows only on the armed reboot)."; fi
  fi
}

# Rewrap /boot/uInitrd ourselves after every initramfs rebuild — do NOT rely on Armbian's
# /etc/initramfs/post-update.d/99-uboot hook existing.
# WHY: extlinux boots `initrd /uInitrd` (a mkimage-wrapped copy of /boot/initrd.img-<ver>). On a full
# Armbian the 99-uboot post-update hook rewraps uInitrd after `update-initramfs`. But some stock Arco
# units SHIP WITHOUT that hook (`/etc/initramfs/post-update.d/` doesn't even exist) — so update-initramfs
# rebuilds initrd.img (now carrying our flasher) while uInitrd stays the FACTORY image, and the bootloader
# keeps loading the old ramdisk: the flash never arms and the old system just boots. Confirmed on a real
# V199 unit (fresh initrd.img, Mar-2023 uInitrd, no post-update.d). Rewrapping here is idempotent — a
# no-op where uInitrd isn't the boot artifact, and harmless where 99-uboot already did it.
regen_bootloader_ramdisk() {
  [ "$TEST" = 1 ] && return 0
  local kver initrd uinitrd arch
  kver="$(uname -r)"; initrd="/boot/initrd.img-$kver"; uinitrd="/boot/uInitrd"
  # only relevant when the boot chain actually loads uInitrd (extlinux/boot.cmd reference it, or it exists)
  { [ -f "$uinitrd" ] || grep -qsiE 'uInitrd' /boot/extlinux/extlinux.conf /boot/boot.cmd 2>/dev/null; } || return 0
  [ -f "$initrd" ] || { note "uInitrd rewrap skipped ($initrd not present)"; return 0; }
  if ! command -v mkimage >/dev/null 2>&1; then
    echo "  ⚠ mkimage (u-boot-tools) is missing — cannot rewrap /boot/uInitrd."
    echo "    The flash will NOT arm until uInitrd carries the new initramfs."
    echo "    Run: sudo apt-get install u-boot-tools, then arm again."
    return 0
  fi
  case "$(uname -m)" in aarch64) arch=arm64;; armv7l|armhf|arm*) arch=arm;; *) arch=arm64;; esac
  if mkimage -A "$arch" -O linux -T ramdisk -C none -n uInitrd -d "$initrd" "$uinitrd.new" >/dev/null 2>&1; then
    mv -f "$uinitrd.new" "$uinitrd"; sync
    note "rewrapped /boot/uInitrd (arch=$arch) — the bootloader loads it now"
  else
    rm -f "$uinitrd.new"; echo "  ⚠ mkimage failed to rewrap /boot/uInitrd — the flash may not arm on this unit; check /boot."
  fi
}

# update-initramfs, minus the alarming noise it can't help producing here.
# /boot is vfat: its hard-link backup of the old initrd, and Armbian's uInitrd symlink, are both impossible
# on FAT and fail with "Operation not permitted" — after which both fall back to a plain copy/move and the
# result is perfectly correct. Those two lines read like a crash to anyone flashing their printer, so drop
# exactly them and pass everything else through. On a real failure nothing is filtered: the whole output is
# printed and the caller decides what to do.
run_update_initramfs() {
  local log rc=0
  log="$(mktemp)" || return 1
  update-initramfs -u >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  update-initramfs FAILED (exit $rc) — full, unfiltered output:"
    sed 's/^/    /' "$log"
  else
    grep -vE "ln: failed to create (hard|symbolic) link.*Operation not permitted|Symlink failed, moving|^renamed " \
      "$log" | sed 's/^/  /'
    regen_bootloader_ramdisk     # <-- rewrap uInitrd ourselves; stock units may lack the 99-uboot post-update hook
  fi
  rm -f "$log"
  return "$rc"
}

# ---- backup: copy the eMMC to the stick, before anything is overwritten -------------------------
# Same machinery as the flash, pointed the other way: the initramfs is the only moment the filesystem is
# unmounted, which is what makes the image consistent. Nothing on the printer is written.
# Both jobs end in a reboot, and both are now reachable from the setup menu on a printer that is
# otherwise perfectly usable. The first version guarded only the backup, on the reasoning that nobody
# runs --arm mid-print because it is part of an install -- which stopped being true the moment restoring
# a backup became a menu entry. A backup can wait; a print cannot resume from where the power went.
refuse_if_printing() {
  local pstate
  pstate=$(curl -s --max-time 4 http://127.0.0.1:7125/printer/objects/query?print_stats 2>/dev/null \
           | tr ',{}' '\n' | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)
  case "${pstate:-}" in
    printing|paused)
      warn "this printer is $pstate right now, and $1 reboots it."
      die "wait until the print has finished, then run it again — nothing
           was changed.";;
  esac
}

backup_emmc() {
  hr; echo "  BACKUP — copy this printer's eMMC to a USB stick"; hr
  refuse_if_printing "the backup"
  EMMC="$(detect_emmc)" || die "could not identify the internal eMMC (see the message above)."
  local devsz; devsz=$(( $(cat "/sys/block/$(basename "$EMMC")/size") * 512 ))
  note "source eMMC : $EMMC ($(( devsz / 1000000000 )).$(( devsz / 100000000 % 10 )) GB)"

  local usb; usb="$(find_usb_dir)" || die "no writable USB stick found. Plug one in (FAT32) and re-run."
  note "USB stick   : $usb"
  # ---- one-shot token ----------------------------------------------------------------------------
  # The arming lives inside the initramfs, and an image taken while it is armed contains it. So a
  # restored backup comes back armed, and on its next boot the initramfs would look for a stick and, on
  # any stick without the old run's stamp, take a second 25-minute backup nobody asked for. The initramfs
  # cannot rebuild itself, so it cannot disarm itself either.
  # A token settles it without touching the eMMC: arming writes a random name onto the stick and puts it
  # in the conf. The job runs only if that exact file is there, and deletes it before starting -- so it
  # can fire once, for the stick it was armed with, and never again. A restored image carries a token
  # whose file was consumed months ago and is therefore inert, whatever stick is plugged in.
  rm -f "$usb"/.arco-armed-* "$usb/.arco-backup-done" 2>/dev/null || true
  local token; token=$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -dc '0-9a-f')
  [ -n "$token" ] || token="$$$(date +%s 2>/dev/null)"
  : > "$usb/.arco-armed-$token" || die "cannot write to $usb — is the stick read-only?"

  # How big will it be? Measured on real hardware rather than guessed: a full stock 8 GB eMMC gzips to
  # about 2.0 GiB (27.6%), and an Unleashed 32 GB one to about 1.5 GB, because everything past the
  # installed system is untouched flash and compresses away. Budget 35% and check BEFORE rebooting --
  # discovering a full stick after a 5-minute read, from an initramfs, helps nobody.
  local need free
  echo
  echo "  Measuring how big the backup will be. This samples the eMMC and takes"
  echo "  about a minute, with no output until it is done. Nothing is written."
  echo "  A quiet screen here is normal — please wait."
  local est exp
  est=$(estimate_backup_size "$EMMC" "$devsz" "$GZLEVEL")
  exp=${est%% *}; need=${est##* }
  free=$(df -B1 --output=avail "$usb" 2>/dev/null | tail -1 | tr -dc '0-9')
  # Both figures, because they answer different questions: the expected size is what the owner will
  # actually see, the worst case is what the stick has to be able to hold. Checking against the worst
  # case keeps the old asymmetry -- running out of room after half an hour of reading is expensive, a
  # cautious sentence on screen is not -- without the flat 35% that used to refuse good sticks.
  note "backup size: ~$(( exp / 1000000000 )).$(( exp / 100000000 % 10 )) GB expected, up to $(( need / 1000000000 )).$(( need / 100000000 % 10 )) GB worst case (gzip -$GZLEVEL)"
  note "free on the stick: $(( ${free:-0} / 1000000000 )).$(( ${free:-0} / 100000000 % 10 )) GB"
  if [ -n "$free" ] && [ "$free" -lt "$need" ]; then
    warn "the stick does not have room for the backup (needs roughly $(( need / 1000000000 + 1 )) GB free)."
    # Naming backups per system doubled how many can pile up here: stock and unleashed, each with a
    # .previous. On a small stick that is the difference between fitting and not. So say what is using
    # the room and which of it is safe to remove -- and, above all, which is NOT: an image of Phrozen's
    # original system cannot be remade once the printer has been migrated.
    local b n
    for b in "$usb"/arco-emmc-backup*.img.gz "$usb"/arco-emmc-backup*.img.gz.previous; do
      [ -f "$b" ] || continue
      n=$(basename "$b")
      case "$n" in
        *.previous)   warn "  $n  ($(du -h "$b" 2>/dev/null | cut -f1)) — older copy of the same kind, safe to delete";;
        *-stock*)     warn "  $n  ($(du -h "$b" 2>/dev/null | cut -f1)) — Phrozen's original system: KEEP, it cannot be remade";;
        *-unleashed*) warn "  $n  ($(du -h "$b" 2>/dev/null | cut -f1)) — this project; you can make another any time";;
        *)            warn "  $n  ($(du -h "$b" 2>/dev/null | cut -f1))";;
      esac
    done
    die "delete what you no longer need, or use a bigger stick, then re-run."
  fi
  # FAT32 cannot hold a file of 4 GiB or more. It is the limit that bites first -- long before capacity --
  # and it would surface as a write error minutes in, so say it here where it is still just a sentence.
  #
  # WHICH filesystem to send the owner to is not a free choice: whatever they format, the INITRAMFS has to
  # mount it, and that is a much smaller world than this shell. exFAT is a kernel module (mainline since
  # 5.7), so on an older stock kernel it may not exist at all -- and then "just use exFAT" produces a stick
  # that arms perfectly here and cannot be mounted after the reboot. That failure is invisible: the flasher
  # falls through to a normal boot, and the log it would have complained in lives on the stick it could not
  # mount. So test for the driver before naming it, and never arm onto a filesystem we cannot mount.
  local fstype; fstype=$(findmnt -no FSTYPE --target "$usb" 2>/dev/null)
  if [ -n "$fstype" ] && ! fs_flashable "$fstype"; then
    warn "this stick is formatted $fstype, which the initramfs flasher cannot mount"
    warn "(it can do: $(fs_flashable_list)). It would arm here and then do nothing after the reboot."
    die "aborting — nothing was changed. Reformat the stick, or image the eMMC on a PC instead."
  fi
  # FAT32 cannot hold a file of 4 GiB or more. That used to end the run here, with advice to zero the
  # free space and compress harder -- and refusing was the wrong answer twice over: the zeroing step was
  # never something the printer could actually do (see the initramfs hook), and a backup that does not
  # fit in ONE file fits perfectly well in several. So it is written as a numbered set now, and the only
  # question left is whether the stick has room in TOTAL, which was already asked above.
  if [ "$need" -ge "$SPLITSZ" ]; then
    local parts=$(( (need + SPLITSZ - 1) / SPLITSZ ))
    note "too large for one file on FAT32 — it will be written as about $parts parts"
    echo
    echo "  The parts are named ${BACKUP_NAME}.001, .002 and so on. They are one"
    echo "  stream cut into pieces, so ALL OF THEM ARE NEEDED: keep them together,"
    echo "  copy them together, and never delete one to make room."
    echo
    echo "  Restoring from this printer handles the set for you. On a PC it is:"
    echo "      cat ${BACKUP_NAME}.??? | gunzip | dd of=/dev/<your-emmc> bs=4M"
    echo
  fi

  echo
  echo "  What happens: the printer reboots, reads $EMMC into"
  echo "    $usb/$BACKUP_NAME"
  echo "  and boots back into what you have now. NOTHING on the printer is"
  echo "  written to or changed, and pulling the stick cancels it at any point."
  echo
  echo "  Keep the result, and keep it to yourself. It is a byte-for-byte copy,"
  echo "  so it holds your WiFi password, SSH keys and any API tokens — and,"
  echo "  on a factory printer, Phrozen's software. Never post or share it."
  echo
  if [ "$ASSUME_YES" != 1 ]; then
    read -rp "  Type 'yes' to back up this printer to the stick: " c
    [ "$c" = yes ] || die "not confirmed — aborted, nothing changed."
  fi

  [ -f "$HOOK_SRC" ] && [ -f "$PREMOUNT_SRC" ] || die "initramfs pieces missing next to the script ($HOOK_SRC / $PREMOUNT_SRC)"
  install -d "$STATE_DIR"
  # A pending flash and a pending backup must never coexist: whichever the initramfs picked, the other
  # would still be sitting there armed for the boot after.
  rm -f "$STATE_DIR/flash.conf"
  # GZIP and SPLIT are carried into the initramfs here rather than decided there, so what the owner saw
  # on screen -- the size estimate, the part count -- is measured with exactly the settings that will
  # run. ARCO_BACKUP_ZEROFREE used to sit here too; it is gone, along with the feature it switched.
  cat > "$STATE_DIR/backup.conf" <<EOF
ARCO_BACKUP_ARMED=1
ARCO_BACKUP_NAME=$BACKUP_NAME
ARCO_BACKUP_TOKEN=$token
ARCO_BACKUP_GZIP=$GZLEVEL
ARCO_BACKUP_SPLIT=$SPLITSZ
ARCO_TARGET=$EMMC
EOF
  install -D -m0755 "$HOOK_SRC"     "$ITOOLS/hooks/arco-emmc-flash"
  install -D -m0755 "$PREMOUNT_SRC" "$ITOOLS/scripts/init-premount/arco-emmc-flash"
  install_backup_autodisarm
  echo
  echo "  Rebuilding the startup image, so the backup can run before the system"
  echo "  boots. Up to a minute, also silent. Do not interrupt it — please wait."
  if [ "$TEST" = 1 ]; then note "[TEST] skipping update-initramfs + reboot"; return; fi
  run_update_initramfs || {
    rm -f "$STATE_DIR/backup.conf" "$ITOOLS/hooks/arco-emmc-flash" "$ITOOLS/scripts/init-premount/arco-emmc-flash"
    die "update-initramfs failed — backup params + hooks removed again."
  }
  echo
  echo "  ARMED FOR BACKUP. Reboot and it runs; the printer comes back"
  echo "  exactly as it is now."
  echo "  To cancel: sudo bash $0 --disarm"
  if [ "$DO_REBOOT" = 1 ]; then
    read -rp "  Reboot now to start the backup? [y/N] " r
    if [ "$r" = y ]; then stop_display_owner; reboot
    else note "not rebooting; run 'reboot' when ready."; fi
  fi
}

# The flash disarms itself by construction — it overwrites the eMMC, so its conf is gone with the old
# system. A backup changes nothing, so its conf survives and the printer would back itself up on EVERY
# boot, forever. This one-shot unit runs the ordinary --disarm on the next boot, then removes itself.
install_backup_autodisarm() {
  local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  cat > /etc/systemd/system/arco-backup-disarm.service <<EOF
[Unit]
Description=Disarm the one-shot Arco eMMC backup after it has run
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash $self --disarm
ExecStartPost=/bin/systemctl disable arco-backup-disarm.service
ExecStartPost=/bin/rm -f /etc/systemd/system/arco-backup-disarm.service

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-backup-disarm.service 2>/dev/null \
    && note "one-shot: it disarms itself after the backup (no backup loop on later boots)" \
    || warn "could not enable the auto-disarm unit — run 'sudo bash $0 --disarm' yourself after the backup."
}

# A writable directory on a mounted USB stick. Deliberately not the same as find_image's search: this one
# has to be writable and must never be the eMMC we are about to read.
# How big will the .img.gz be? A flat percentage cannot answer this, because the two real cases are far
# apart: a full factory 8 GB eMMC gzips to about 28% (measured: 7652311552 -> 2108875153 bytes), while a
# printer whose filesystem was expanded over a 32 GB eMMC is mostly untouched flash and lands nearer 5%.
# A worst-case budget would refuse a perfectly adequate stick on the second kind of machine; an optimistic
# one would run out of space minutes into the read. So sample the device and measure, which costs about a
# minute of reading and nothing else. Read-only.
estimate_backup_size() {
  # Prints two byte counts: "<expected> <worst-case>".
  #
  # THE OLD VERSION ESTIMATED SOMETHING IT DID NOT HAVE TO. It sampled 64 chunks spread evenly over the
  # whole device and extrapolated, which means it was measuring two quantities at once: how much of the
  # device carries data, and how well that data compresses. Only the second needs sampling -- df knows
  # the first exactly -- and the noise in the first dominated the error. Measured on a 31 GB Arco: the
  # sample hit data in 20.3% of chunks where the true figure was 15.8%, a factor of 1.28, and the
  # estimate came out 1.26x above the model. The entire discrepancy was that one avoidable guess, and it
  # then had 35% added on top. A tester was told 5.3 GB where the honest figure was nearer 3.
  #
  # So: take the size from df, and spend the sampling budget where the answer actually varies.
  local dev="$1" devsz="$2" lvl="${3:-1}"
  local freeb=0 a s

  # 1. FREE space, exactly. Everything not accounted for by a filesystem -- unpartitioned gaps, anything
  #    unreadable -- stays on the data side, which is the conservative direction.
  while read -r a s; do
    case "$s" in "$dev"*) freeb=$(( freeb + ${a:-0} )) ;; esac
  done <<EOF
$(df -B1 --output=avail,source 2>/dev/null | tail -n +2)
EOF
  local datab=$(( devsz - freeb ))
  [ "$datab" -lt 0 ] && datab=0

  # 2. What free space costs once it is gzipped. Measured, not assumed, and measured at the level that
  #    will actually run: gzip -1 and -6 differ by 4.5x on runs of zeros (0.436% vs 0.097% on an Arco),
  #    so assuming either would be wrong for the other. It is not negligible at -1: 26 GB of free space
  #    is still ~115 MB in the finished file.
  local zden=$(( 16 * 1024 * 1024 )) znum
  znum=$(dd if=/dev/zero bs=1M count=16 2>/dev/null | gzip -"$lvl" | wc -c)
  [ "${znum:-0}" -gt 0 ] || znum=$(( zden / 200 ))

  # 3. WHERE the data is. A cheap coarse pass -- 256 reads of 64 KiB, 16 MiB in total -- just to find the
  #    regions worth sampling properly. Filesystems fill from the front, so an even spread wastes most of
  #    its budget on empty space: on the dev printer 51 of 64 full-size samples landed in zeros.
  local ncoarse=256 csz=65536 i=0 boff out
  local hits="" nhit=0
  while [ "$i" -lt "$ncoarse" ]; do
    boff=$(( devsz / ncoarse * i ))
    out=$(dd if="$dev" bs=$csz count=1 skip=$(( boff / csz )) 2>/dev/null | gzip -1 | wc -c)
    if [ "${out:-0}" -gt $(( csz / 50 )) ]; then hits="$hits $boff"; nhit=$(( nhit + 1 )); fi
    i=$(( i + 1 ))
  done

  # 4. Sample the data properly: up to 64 reads of 2 MiB, all of them inside regions the coarse pass
  #    found something in. Same reading time as before, five times the coverage of the part that matters.
  #    If the coarse pass found nothing at all -- a device that is genuinely empty, or unreadable -- fall
  #    back to an even spread rather than reporting a fantasy.
  local chunk=$(( 2 * 1024 * 1024 )) nsamp=0 samples=""
  local step=1; [ "$nhit" -gt 64 ] && step=$(( (nhit + 63) / 64 ))
  if [ "$nhit" -gt 0 ]; then
    i=0
    for boff in $hits; do
      i=$(( i + 1 )); [ $(( i % step )) -eq 0 ] || continue
      out=$(dd if="$dev" bs=$chunk count=1 skip=$(( boff / chunk )) 2>/dev/null | gzip -"$lvl" | wc -c)
      [ "${out:-0}" -gt 0 ] || continue
      samples="$samples$out
"; nsamp=$(( nsamp + 1 ))
    done
  fi
  if [ "$nsamp" -le 0 ]; then
    i=0
    while [ "$i" -lt 32 ]; do
      out=$(dd if="$dev" bs=$chunk count=1 skip=$(( devsz / 32 * i / chunk )) 2>/dev/null | gzip -"$lvl" | wc -c)
      [ "${out:-0}" -gt 0 ] && { samples="$samples$out
"; nsamp=$(( nsamp + 1 )); }
      i=$(( i + 1 ))
    done
  fi
  [ "$nsamp" -gt 0 ] || { echo "$(( devsz / 100 * 35 )) $(( devsz / 100 * 50 ))"; return; }

  # 5. Put it together -- in awk, which has floating point. Doing this in shell integers meant scaling
  #    everything down first to dodge a silent 64-bit overflow, and that scaling is where the upper bound
  #    was lost: it divided by 1000 one time too many, came out a thousandfold too small, and the guard
  #    below it quietly raised it back to the expected value. Both numbers then printed the same, which
  #    is the only reason it was noticed at all.
  #
  # THE UPPER BOUND IS THE ONE THAT DECIDES, so it has to be honest in the expensive direction: too high
  # costs a sentence on screen, too low costs half an hour of reading and a failed backup. Measured here:
  # expected came out 2.1 GB where the truth was 2.30 GB, a 9% miss -- normal sampling error, and exactly
  # what the bound exists to absorb.
  #
  # Mean plus two standard errors of the sampled ratio, not a flat percentage and not "the worst chunk we
  # saw". The worst chunk was the first attempt and it was useless: one incompressible 2 MiB region would
  # have predicted 5 GB here and refused a stick with 4.2 GB free that fits the real 2.3 GB easily. A
  # confidence bound tightens by itself on a uniform device and widens only where the device really is
  # uneven. The 10% floor covers the case where too few samples make the spread look artificially small.
  printf '%s' "$samples" | awk -v datab="$datab" -v freeb="$freeb" \
                               -v znum="$znum" -v zden="$zden" -v chunk="$chunk" '
    # %.0f, never %d. mawk (1.3.4, what the printer has) converts %d through a 32-bit int and SATURATES
    # at 2147483647 -- so any figure past 2.1 GB came out as exactly 2147483647, which the GB formatting
    # then rendered as "2.1 GB". Expected happened to sit just under the ceiling and looked right;
    # the upper bound sat just over it and printed the same number, which is how it was noticed. It also
    # fed that truncated value into the does-it-fit check, so on a tighter stick it would have waved
    # through a backup that does not fit. gawk has no such limit, which is why an offline test passed.
    NF { r = $1 / chunk; n++; s += r; s2 += r*r }
    END {
      if (n == 0) { printf "%.0f %.0f\n", datab*0.35, datab*0.50; exit }
      mean = s / n
      var  = s2/n - mean*mean; if (var < 0) var = 0
      se   = sqrt(var / n)
      zfree = freeb * znum / zden
      # NOT named exp: that is awk s built-in exponential, and using it as a variable is a syntax error
      # -- one that would have taken the whole estimate down on the printer rather than skewing it.
      expd = datab * mean + zfree
      hi   = datab * (mean + 2*se) + zfree
      if (hi < expd * 1.10) hi = expd * 1.10
      printf "%.0f %.0f\n", expd, hi
    }'
}

find_usb_dir() {
  local d home
  # $HOME under sudo is root's, so "$HOME/printer_data/gcodes/USB" would miss the very mount point the
  # Arco actually uses. Take the invoking user's home when there is one.
  home="$HOME"
  [ -n "${SUDO_USER:-}" ] && home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  [ -n "$home" ] || home="$HOME"
  for d in "$USBDIR" /media/usb* /media/*/* /mnt/usb* "$home/printer_data/gcodes/USB" \
           /home/mks/printer_data/gcodes/USB; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    [ "$(usb_device_of "$d")" = "$EMMC" ] && continue      # that is the eMMC itself, not a stick
    touch "$d/.arco-write-probe" 2>/dev/null || continue
    rm -f "$d/.arco-write-probe" 2>/dev/null
    echo "$d"; return 0
  done
  return 1
}

disarm() {
  hr; echo "  DISARM"; hr
  rm -f "$STATE_DIR/flash.conf" \
        "$STATE_DIR/backup.conf" \
        "$ITOOLS/hooks/arco-emmc-flash" \
        "$ITOOLS/scripts/init-premount/arco-emmc-flash"
  note "params + hooks removed"
  [ "$TEST" = 1 ] && { note "[TEST] skipping update-initramfs"; return; }
  run_update_initramfs || die "update-initramfs failed"
  note "initramfs rebuilt — flash disarmed."
}

case "$MODE" in
  inspect) disclaimer; hr; echo "  INSPECT (no changes)"; hr; plan; echo; note "looks flashable. Arm with: sudo bash $0 --arm"; ;;
  arm)     arm ;;
  backup)  backup_emmc ;;
  disarm)  disarm ;;
esac
