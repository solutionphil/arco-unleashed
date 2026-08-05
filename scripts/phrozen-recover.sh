#!/bin/bash
# phrozen-recover.sh — survive a Phrozen display "Update" on a Klipper v0.13 system.
#
# A Phrozen update is v0.11-oriented and clobbers things:
#   - Klipper CORE (klippy/mcu.py, virtual_sdcard.py) -> "SerialReader ... warn_prefix" -> halted
#   - phrozen_dev base.py/cmds.py -> the v0.13 patches reverted
#   - printer.cfg -> minimum_cruise_ratio->max_accel_to_decel, includes removed, YOUR calibration reset
#   (Katapult protects the F103 toolhead — that survives.)
#
# This restores the working v0.13 state while KEEPING the new feature files
# (voronFDM, PhrozenGo, new .tft, ota_control).
#
# It is also the general "keep my settings" tool, not only an update-survival one -- most people who
# need it have not touched a Phrozen update at all; they reflashed, swapped an eMMC, or want their
# machine back the way they had it.
#
# Usage:
#   bash phrozen-recover.sh backup           # everything you configured (config, web UI, WiFi, module)
#   bash phrozen-recover.sh usb [dir]        # copy that backup onto a USB stick (survives a reflash)
#   bash phrozen-recover.sh import [file]    # read a stick archive back onto this printer
#   bash phrozen-recover.sh restore-settings # put your settings back
#   bash phrozen-recover.sh restore          # repair a printer an update broke
#   bash phrozen-recover.sh pre-patch <usb_phrozen_dev_dir>
#                                     # inject our fixes into the USB BEFORE the install, so a
#                                     # Phrozen update carries them and never clobbers (needs a backup)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$DIR/.." && pwd)"
KLIPPER="$HOME/klipper"
PD="$KLIPPER/klippy/extras/phrozen_dev"
CFGDIR="$HOME/printer_data/config"
BK="$HOME/phrozen-recover-backup"
SYSBK="$BK/system"

# ── user settings that do NOT live in printer_data/config ──────────────────────────────────────────
# "Back up your config" is the standard advice everywhere, and it quietly loses half of what a user
# actually set. Moonraker's database is where Mainsail and Fluidd keep the theme, the temperature
# presets, the macro groups, the job history and the per-object settings -- none of it in config/.
# Hostname and timezone are two more things a person set once and would have to rediscover.
capture_user_state(){
  mkdir -p "$SYSBK"
  if [ -d "$HOME/printer_data/database" ]; then
    rm -rf "$SYSBK/database"
    cp -r "$HOME/printer_data/database" "$SYSBK/database" && echo "  + web-interface settings and history (Moonraker database)"
  fi
  for f in /etc/hostname /etc/timezone; do
    [ -f "$f" ] && cp -f "$f" "$SYSBK/$(basename "$f")" 2>/dev/null
  done
  echo "  + hostname and timezone"
  # WiFi comes last and is kept apart on purpose: wpa_supplicant.conf holds the pre-shared key in
  # CLEAR TEXT. Keeping it in a backup on this machine changes nothing -- the file is already here.
  # Copying it onto a removable stick is a genuinely different decision, so pack_usb asks first
  # rather than deciding for the owner.
  # Reading it needs root, and root may not be available without a password prompt. If that fails the
  # backup MUST say so: a silently WiFi-less backup looks complete and is discovered to be incomplete
  # at the worst possible moment, on a freshly flashed printer with no network to ask for help on.
  if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    echo "  - no WiFi config here (wired, or set up another way) — nothing to save"
  elif sudo cp -f /etc/wpa_supplicant/wpa_supplicant.conf "$SYSBK/wpa_supplicant.conf" 2>/dev/null; then
    sudo chown "$(id -u):$(id -g)" "$SYSBK/wpa_supplicant.conf" 2>/dev/null || true
    chmod 600 "$SYSBK/wpa_supplicant.conf" 2>/dev/null || true
    echo "  + WiFi credentials (kept local; you are asked before they go on a stick)"
  else
    rm -f "$SYSBK/wpa_supplicant.conf"
    echo "  ! WiFi NOT saved — reading it needs root and sudo was refused."
    echo "    Everything else was saved. To include WiFi, run the backup again from"
    echo "    the setup menu (it can ask for your password there)."
  fi
}

# Put the captured user state back. Separate from restore() because that one repairs a printer a
# Phrozen update broke, while this one is "give me my settings again" -- different intent, different
# blast radius, and mixing them would mean you cannot ask for one without the other.
restore_user_state(){
  [ -d "$SYSBK" ] || { echo "No user-settings backup found in $SYSBK."; return 1; }
  local did=0
  if [ -d "$SYSBK/database" ]; then
    # Moonraker holds the database open; writing under it corrupts the file rather than updating it.
    echo "  stopping moonraker to swap its database safely..."
    sudo systemctl stop moonraker 2>/dev/null || true
    rm -rf "$HOME/printer_data/database"
    cp -r "$SYSBK/database" "$HOME/printer_data/database" && { echo "  web-interface settings restored"; did=1; }
    sudo systemctl start moonraker 2>/dev/null || true
  fi
  if [ -f "$SYSBK/wpa_supplicant.conf" ]; then
    printf "  Restore WiFi too? It overwrites the network this printer uses now [y/N]: "
    read -r w
    case "$w" in
      y|Y) sudo cp -f "$SYSBK/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf \
             && { echo "  WiFi restored — takes effect after a reboot"; did=1; };;
      *)   echo "  WiFi left as it is";;
    esac
  fi
  [ -f "$SYSBK/hostname" ] && ! diff -q "$SYSBK/hostname" /etc/hostname >/dev/null 2>&1 \
    && echo "  note: the backup has hostname '$(cat "$SYSBK/hostname")' — not applied automatically"
  [ "$did" = 1 ] || echo "  nothing to restore."
}

# Pack the whole backup into ONE portable archive on a USB stick. This is the copy that matters: the
# local backup lives on the same eMMC it is supposed to protect, so it dies with it. A reflash, a
# dead chip or a failed self-flash all take the local copy with them and leave the stick untouched.
pack_usb(){
  local dest="${1:-$HOME/printer_data/gcodes/USB}"
  [ -d "$BK" ] || { echo "No backup to copy yet — run the backup first."; return 1; }
  # "The directory exists" is NOT "a stick is there". ~/printer_data/gcodes/USB is a permanent mount
  # POINT: it exists whether or not anything is mounted on it, so a -d test happily writes the archive
  # onto the eMMC and reports success. That is precisely the failure this whole feature exists to
  # prevent -- a backup the owner believes is safe on a stick, dying with the chip it was protecting
  # against. Found by testing with no stick inserted; it wrote 21 MB and said "Saved".
  # Compare device numbers instead: a real mount is a different filesystem from $HOME.
  if [ ! -d "$dest" ]; then
    echo "No such directory: $dest"
    echo "Insert the stick, or find it with 'lsblk' and mount it there:"
    echo "  sudo mkdir -p $dest && sudo mount /dev/sda1 $dest"
    return 1
  fi
  if [ "$(stat -c %d "$dest" 2>/dev/null)" = "$(stat -c %d "$HOME" 2>/dev/null)" ]; then
    echo "NOT SAVED — $dest is on the printer's own eMMC, not on a stick."
    echo "That directory exists even with no stick in, so writing there gives you"
    echo "a backup that dies with the very chip you are backing up against."
    echo
    echo "Insert the stick and try again. If it does not mount by itself, find it with"
    echo "'lsblk' and mount it:   sudo mount /dev/sda1 $dest"
    echo "Or pass a different path if you keep backups on a network share."
    return 1
  fi
  local excl=()
  if [ -f "$SYSBK/wpa_supplicant.conf" ]; then
    printf "Include WiFi credentials? The file holds your WiFi PASSWORD IN CLEAR TEXT,\n"
    printf "and a stick is easy to lose. Say no and the rest is still saved. [y/N]: "
    read -r w
    case "$w" in
      y|Y) echo "  including WiFi — treat this stick as a password.";;
      *)   excl=( --exclude=./system/wpa_supplicant.conf ); echo "  WiFi excluded from the stick.";;
    esac
  fi
  local out="$dest/arco-user-settings-$(date +%Y%m%d-%H%M).tar.gz"
  if tar czf "$out" "${excl[@]}" -C "$BK" . 2>/dev/null; then
    sync
    echo "Saved -> $out  ($(du -h "$out" | cut -f1))"
    echo "Keep it off the printer. Restore it with:  bash phrozen-recover.sh import <file>"
  else
    echo "Writing to the stick FAILED — is it full or read-only?"; return 1
  fi
}

# Read a stick archive back into the local backup directory, so every restore path below works
# exactly as if the backup had been made on this machine.
import_backup(){
  local src="${1:-}"
  if [ -z "$src" ]; then
    src=$(ls -1t "$HOME/printer_data/gcodes/USB"/arco-user-settings-*.tar.gz 2>/dev/null | head -1)
    [ -n "$src" ] && echo "Using the newest archive on the stick: $src"
  fi
  [ -f "$src" ] || { echo "No archive given and none found on the stick."; return 1; }
  # Never overwrite a local backup without keeping the old one -- the person importing is already
  # having a bad day.
  [ -d "$BK" ] && mv -f "$BK" "$BK.replaced-$(date +%Y%m%d-%H%M)" \
    && echo "Existing local backup kept as $BK.replaced-*"
  mkdir -p "$BK"
  tar xzf "$src" -C "$BK" && echo "Imported -> $BK" || { echo "Extract FAILED — bad or truncated archive."; return 1; }
  echo "Now: bash phrozen-recover.sh restore-settings"
echo "     (or restore, for a printer a Phrozen update broke)"
}

backup(){
  [ -d "$PD" ] || { echo "ERROR: $PD not found"; exit 1; }
  mkdir -p "$BK"
  rm -rf "$BK/config" "$BK/phrozen_dev"
  cp -r "$CFGDIR" "$BK/config"
  cp -r "$PD" "$BK/phrozen_dev"
  # snapshot the pristine v0.13 Klipper core (matches this install) for a git-independent restore
  CORE_BK="$HOME/.arco-unleashed/klipper-core-v0.13"; mkdir -p "$CORE_BK"
  for rel in klippy/mcu.py klippy/serialhdl.py klippy/extras/virtual_sdcard.py; do
    bn="$(basename "$rel")"
    if git -C "$KLIPPER" show "HEAD:$rel" > "$CORE_BK/$bn" 2>/dev/null && [ -s "$CORE_BK/$bn" ]; then :
    elif [ -f "$KLIPPER/$rel" ]; then cp -f "$KLIPPER/$rel" "$CORE_BK/$bn"; else rm -f "$CORE_BK/$bn"; fi
  done
  echo "  + printer configuration and the phrozen_dev module"
  capture_user_state
  echo "Backup saved -> $BK   (pristine Klipper core -> $CORE_BK)"
  echo "This copy is on the printer's own eMMC, so it does NOT survive a reflash."
  echo "Put it on a USB stick as well:  bash phrozen-recover.sh usb"
  echo "Restore it later with:          bash phrozen-recover.sh restore-settings"
}

# Surgically re-apply ONLY the structural values a Phrozen update breaks (the includes, the v0.13
# minimum_cruise_ratio key, [mcu rpi], the host sensor) — values read from the backup. Your re-tuned
# calibration and any new Phrozen content are left untouched. python3 only, no external deps.
fix_structural_configs(){
  python3 - "$BK/config" "$CFGDIR" <<'PY'
import sys, re, os
gold_dir, cfg_dir = sys.argv[1], sys.argv[2]
def read(p):  return open(p).read() if os.path.isfile(p) else ""
def write(p, s): open(p, "w").write(s)
def get_line(t, key):
    for ln in t.splitlines():
        if ln.strip().startswith(key): return ln
    return None
def get_section(t, hdr):
    out, grab = [], False
    for ln in t.splitlines():
        if ln.strip() == hdr:
            grab, out = True, [ln]; continue
        if grab:
            if ln.startswith("[") and ln.strip() != hdr: break
            out.append(ln)
    while out and not out[-1].strip(): out.pop()
    return "\n".join(out) if out else None

pc, gpc = cfg_dir + "/printer.cfg", gold_dir + "/printer.cfg"
cur, gold = read(pc), read(gpc); ch = []
for inc in ["[include AddOn.cfg]", "[include unleashed-theme-macros.cfg]"]:
    if cur and inc not in cur:
        lines = cur.splitlines()
        idx = max((i for i, l in enumerate(lines) if l.strip().startswith("[include")), default=-1)
        lines.insert(idx + 1, inc); cur = "\n".join(lines); ch.append("+ " + inc)
if "max_accel_to_decel" in cur and "minimum_cruise_ratio" not in cur:
    g = get_line(gold, "minimum_cruise_ratio:") or "minimum_cruise_ratio: 0.75"
    cur = re.sub(r"(?m)^\s*max_accel_to_decel\s*:.*$", g, cur); ch.append("max_accel_to_decel -> " + g.strip())
if cur and "[temperature_sensor host]" not in cur:
    sec = get_section(gold, "[temperature_sensor host]")
    if sec: cur = cur.rstrip() + "\n\n" + sec + "\n"; ch.append("+ [temperature_sensor host]")
# AddOn.cfg drives the board fan as [temperature_fan board_fan] on PA2; Phrozen's stock
# [output_pin board_fan] (same PA2) must stay commented or the pin collides. A Phrozen update
# re-adds it uncommented -> comment its header + option lines (until a blank line / next section).
if re.search(r"(?m)^\[output_pin board_fan\]\s*$", cur):
    nl, blk = [], False
    for ln in cur.splitlines():
        if ln.strip() == "[output_pin board_fan]":
            blk = True; nl.append("#" + ln); continue
        if blk:
            if ln.strip() == "" or ln.lstrip().startswith("["):
                blk = False; nl.append(ln)
            else:
                nl.append(ln if ln.lstrip().startswith("#") else "#" + ln)
        else:
            nl.append(ln)
    cur = "\n".join(nl); ch.append("commented [output_pin board_fan] (PA2 conflicts with AddOn temperature_fan)")
if ch:
    write(pc + ".pre-fix.bak", read(pc)); write(pc, cur)
print("   printer.cfg:", "; ".join(ch) if ch else "already correct")

mc, gmc = cfg_dir + "/printer_MCU.cfg", gold_dir + "/printer_MCU.cfg"
cur, gold = read(mc), read(gmc); ch = []
if cur and "[mcu rpi]" not in cur:
    sec = get_section(gold, "[mcu rpi]")
    if sec:
        cur = cur.rstrip() + "\n\n" + sec + "\n"
        write(mc + ".pre-fix.bak", read(mc)); write(mc, cur); ch.append("+ [mcu rpi]")
print("   printer_MCU.cfg:", "; ".join(ch) if ch else "already correct")
PY
}

restore(){
  echo ">> Stopping Klipper..."
  sudo systemctl stop klipper

  echo ">> 1) Restore v0.13 Klipper core..."
  # Prefer the pristine snapshot taken at install time (matches THIS Klipper, git-independent —
  # a Phrozen update may itself break the klipper git tree). Then a best-effort git checkout on top.
  CORE_BK="$HOME/.arco-unleashed/klipper-core-v0.13"
  restored=0
  if [ -d "$CORE_BK" ]; then
    for rel in klippy/mcu.py klippy/serialhdl.py klippy/extras/virtual_sdcard.py; do
      bn="$(basename "$rel")"
      [ -f "$CORE_BK/$bn" ] && cp -f "$CORE_BK/$bn" "$KLIPPER/$rel" && restored=1
    done
  fi
  [ "$restored" = 1 ] && echo "   core restored from pristine backup ($CORE_BK)" \
                      || echo "   (no core backup found — relying on git)"
  ( cd "$KLIPPER" && git checkout -- klippy/ ) 2>/dev/null && echo "   + git checkout (rest of klippy)" || true
  # The MCU host-timing loosening is NOT re-applied here any more, and must not be: it no longer lives
  # in klippy/mcu.py. Editing that tracked file is what kept Klipper's repo dirty and blocked its
  # update button. The three values now come from klippy/extras/arco_mcu_timing.py — untracked, so the
  # git checkout above leaves it alone, and it reasserts them on the next start by itself. Restoring a
  # STOCK mcu.py here is therefore exactly right; check the result with ARCO_MCU_TIMING.
  if [ -f "$KLIPPER/klippy/extras/arco_mcu_timing.py" ]; then
    echo "   mcu timing: in klippy/extras/arco_mcu_timing.py (mcu.py stays clean)"
  else
    echo "   WARN: arco_mcu_timing.py missing — run apply-arco-extras.sh, or"
    echo "         homing may hit 'MCU: Timer too close' with Klipper's stock timeouts."
  fi

  echo ">> 2) Restore patched phrozen_dev module (base.py + cmds.py)..."
  if [ -f "$BK/phrozen_dev/base.py" ]; then
    cp "$BK/phrozen_dev/base.py" "$BK/phrozen_dev/cmds.py" "$PD/" && echo "   from backup"
  elif [ -f "$KIT/patches/base.py" ]; then
    cp "$KIT/patches/base.py" "$KIT/patches/cmds.py" "$PD/" && echo "   from kit/patches"
  else
    echo "   WARN: no patched base.py/cmds.py (backup or kit) — module NOT restored!"
  fi
  rm -rf "$PD/__pycache__"

  echo ">> 3) Restore configs..."
  if [ -d "$BK/config" ]; then
    # printer.cfg + printer_MCU.cfg: SURGICAL — re-apply only the structural values the update breaks
    # (includes, v0.13 minimum_cruise_ratio, [mcu rpi], host sensor). Your re-tuned calibration is kept.
    echo "   surgical structural fix (calibration left as-is):"
    fix_structural_configs
    # our own feature files (no per-printer calibration in them) -> restored as whole files
    for f in AddOn.cfg unleashed-theme-macros.cfg printer_gcode_macro.cfg crowsnest.conf; do
      [ -f "$BK/config/$f" ] && cp "$BK/config/$f" "$CFGDIR/" && echo "   $f <- backup (whole file)"
    done
  else
    echo "   WARN: no config backup at $BK/config — fix printer.cfg by hand:"
    echo "   max_accel_to_decel -> minimum_cruise_ratio; re-add [include"
echo "   AddOn.cfg] + [temperature_sensor host] + [mcu rpi]."
  fi

  echo ">> 4) Restart Klipper..."
  sudo systemctl restart klipper
  sleep 5
  grep -E "Loaded MCU|warn_prefix|Internal error|Printer is ready" ~/printer_data/logs/klippy.log | tail -6
  echo ""
  echo "Done. New feature files (voronFDM, PhrozenGo, .tft) kept. Test the"
echo "display and the light."
}

pre_patch(){
  local usb="${1:-}"
  [ -d "$usb" ] || { echo "ERROR: USB phrozen_dev folder not found: $usb"; \
    echo "  e.g. bash phrozen-recover.sh pre-patch \\"
        echo "         $HOME/printer_data/gcodes/USB/phrozen_dev"; exit 1; }
  [ -d "$BK/config" ] || { echo "ERROR: no backup yet — run 'backup' first (it captures your good config + patched module)"; exit 1; }

  echo ">> Pre-patching the USB so a Phrozen install carries our v0.13 fixes + config..."
  # 1) top-level configs the installer copies outright
  for f in printer.cfg printer_MCU.cfg printer_gcode_macro.cfg; do
    [ -f "$BK/config/$f" ] && cp "$BK/config/$f" "$usb/$f" && echo "   USB/$f  <- backup"
  done
  # 2) nested module zip: our patched cmds.py + base.py + the serial-screen/printer.cfg voronFDM syncs.
  #    Rewritten with python3's zipfile so no external 'zip' binary is needed (armbian-mkspi lacks it).
  local zip="$usb/phrozen_dev.zip"
  if [ -f "$zip" ]; then
    python3 - "$zip" "$BK" <<'PY'
import sys, os, zipfile, shutil
zippath, bk = sys.argv[1], sys.argv[2]
want = {
    "phrozen_dev/cmds.py":                   bk + "/phrozen_dev/cmds.py",
    "phrozen_dev/base.py":                   bk + "/phrozen_dev/base.py",
    "phrozen_dev/serial-screen/printer.cfg": bk + "/config/printer.cfg",
}
repl = {a: s for a, s in want.items() if os.path.isfile(s)}
tmp = zippath + ".new"
with zipfile.ZipFile(zippath) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
    present = set(zin.namelist())
    for it in zin.infolist():
        if it.filename in repl:
            with open(repl[it.filename], "rb") as f:
                data = f.read()
        else:
            data = zin.read(it.filename)
        zout.writestr(it, data)
    for a, s in repl.items():
        if a not in present:
            zout.write(s, a)
shutil.move(tmp, zippath)
print("   USB/phrozen_dev.zip patched: " + ", ".join(sorted(repl)))
PY
  else
    echo "   (no phrozen_dev.zip on the stick — only the top-level configs were patched)"
  fi
  echo "Done — installing from this USB now keeps our fixes; nothing gets clobbered."
}

# restore-calibration — put the SAVE_CONFIG block back from the backup.
#
# `restore` above fixes printer.cfg only STRUCTURALLY and deliberately leaves the calibration alone, so
# that anything re-tuned since the backup is not thrown away. That is right when the update merely broke
# the includes — and wrong in the case the backup exists for: an update that RESET the calibration. Then
# the backup holds the only copy of your PID values and bed mesh, and nothing put them back. This does.
#
# Only the trailing `#*# ... SAVE_CONFIG ...` block is touched; everything above it stays exactly as it
# is, so structural fixes and any manual edits survive. Klipper owns that block, which is why replacing
# it wholesale is safe — but it is also why this asks first: if you re-tuned after the backup, the backup
# is the older truth.
restore_calibration(){
  local cur="$CFGDIR/printer.cfg" bak="$BK/config/printer.cfg"
  local marker='^#\*# <-* SAVE_CONFIG'
  [ -f "$bak" ] || { echo "ERROR: no backup at $bak — run 'backup' first (it is what this restores from)."; exit 1; }
  [ -f "$cur" ] || { echo "ERROR: no $cur"; exit 1; }
  grep -q "$marker" "$bak" || { echo "ERROR: the backup has no SAVE_CONFIG block — nothing to restore."; exit 1; }

  local bl cl
  bl=$(grep -c '^#\*#' "$bak"); cl=$(grep -c '^#\*#' "$cur")
  echo "Calibration block:  backup $bl lines   ·   current $cl lines"
  if [ "$cl" -gt 0 ] && diff -q <(grep '^#\*#' "$cur") <(grep '^#\*#' "$bak") >/dev/null; then
    echo "Identical — nothing to restore."; return 0
  fi
  echo
  echo "What the backup has that differs (first 12 lines):"
  diff <(grep '^#\*#' "$cur") <(grep '^#\*#' "$bak") | head -12 | sed 's/^/   /'
  echo
  printf "Replace the current calibration with the backup's? [y/N]: "; read -r a
  case "$a" in y|Y) : ;; *) echo "Cancelled — nothing changed."; return 0;; esac

  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  cp -a "$cur" "$cur.pre-calrestore-$stamp"
  # everything before the marker from the CURRENT file + the whole block from the backup
  { sed "/$marker/,\$d" "$cur"; sed -n "/$marker/,\$p" "$bak"; } > "$cur.new" \
    && mv -f "$cur.new" "$cur" \
    || { rm -f "$cur.new"; echo "ERROR: rewrite failed — $cur untouched."; exit 1; }
  echo "Restored. Previous file kept as $(basename "$cur.pre-calrestore-$stamp")."
  echo "Now:  sudo systemctl restart klipper     (or FIRMWARE_RESTART in Mainsail)"
}

case "${1:-}" in
  backup)              backup;;
  restore)             restore;;
  restore-calibration) restore_calibration;;
  restore-settings)    restore_user_state;;
  usb)                 pack_usb "${2:-}";;
  import)              import_backup "${2:-}";;
  pre-patch)           pre_patch "${2:-}";;
  *) echo "Usage: bash phrozen-recover.sh backup|restore|restore-calibration|pre-patch <usb_phrozen_dev_dir>";;
esac
