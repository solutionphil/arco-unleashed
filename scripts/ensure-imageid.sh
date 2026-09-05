#!/bin/sh
# ensure-imageid.sh — guarantee /etc/ImageId.json = {"ImageId":16}.
#
# phrozen_dev gates its image-specific code on the ImageId value (read from /etc/ImageId.json). If the file is
# missing or wrong, the AMS work mode is stuck UNKNOW(0) and image-specific paths misfire. This restores
# it before klipper starts, so anything that removes/rewrites it self-heals. Idempotent; needs root
# (the file is under /etc), so the ExecStartPre guard uses the '+' prefix.
F=/etc/ImageId.json
if ! grep -q '"ImageId":16' "$F" 2>/dev/null; then
  printf '{"ImageId":16}' > "$F"
  echo "ensure-imageid: wrote $F = {\"ImageId\":16}"
fi

# ── and, while we are the only thing here that runs as root ──────────────────────────────────────────
#
# 🔴 THIS DOES NOT BELONG IN A FILE CALLED ensure-imageid.sh, and it is here on purpose.
#
# A kit update can bring something that needs root to install -- a new self-heal guard, a system setting
# like the hostname or mDNS. ARCO_UPDATE runs as the klipper user and cannot do it, so until now the
# owner was asked to SSH in and run optimize-boot.sh, which is the step that gets skipped. Now the
# update leaves a marker and asks for a power-cycle, and this picks it up.
#
# It lives HERE because it has to reach printers that are already in the field, and this is the only
# ExecStartPre with a '+' prefix -- the only root hook those printers already have. A new unit of its
# own would be cleaner and would reach nobody, since installing it needs the very thing it is meant to
# install. Once every printer in use has a dedicated hook, this moves out.
#
# systemd-run, not a direct call: this guard is wrapped in `timeout 10`, and optimize-boot.sh takes
# longer than that. A transient unit is detached from the timeout and from the ExecStartPre cleanup,
# runs as root, and does not hold up the klipper start behind it.
_kit="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
_mark="$(cd "$_kit/.." 2>/dev/null && pwd)/printer_data/.arco-reconcile-pending"
# ARM IT FROM HERE TOO, or the guard that notices a web update reaches nobody who needs it.
# apply-reconcile-check.sh is what spots that a `git pull` from Mainsail or Fluidd moved the kit without
# ever calling after_update(). But it is installed as klipper drop-in 25 by optimize-boot.sh, which puts
# it out of reach of precisely the printers it exists for: an image older than that guard can only
# receive it through a web update, and a web update is the one path that never applies it.
#
# Not a theory. A printer flashed from an older image and updated through Mainsail on 2026-08-21 had no
# macro groups in either interface, no dashboard layout, and a two-month-old theme -- every file present
# on disk, nothing root-side ever applied, and no stamp at all, because optimize-boot.sh had never once
# run there.
#
# Drop-in 19 is the way back in: it has been installed far longer, it already runs with '+', and THIS
# file arrives by a plain `git pull` like any other. So the check is called from here, where the old
# printers actually see it, and acted on in the same pass rather than one klipper start later.
# The owner can switch this check off (guards-toggle.sh: reconcile_check, drop-in 25). Calling it by
# path here is deliberate -- it is how printers without drop-in 25 are reached at all -- but a path
# call that ignores the switch makes the switch a lie. So: honour the .disabled the owner left behind.
_rc_off="${ARCO_SYSTEMD_DIR:-/etc/systemd/system}/klipper.service.d/25-arco-reconcile-check.conf.disabled"
if [ -n "$_kit" ] && [ ! -f "$_mark" ] && [ -x "$_kit/scripts/apply-reconcile-check.sh" ] && [ ! -e "$_rc_off" ]; then
  # bash, not sh: it declares bash and is not dash-clean -- the same trap as optimize-boot.sh below.
  # Its output is dropped on purpose. It ends by asking for a power-cycle, which is untrue here: the
  # block below does the work in this very pass.
  /bin/bash "$_kit/scripts/apply-reconcile-check.sh" >/dev/null 2>&1 || true
  # Armed as root here, but as the owner from selfupdate.sh. A root-owned marker the owner cannot
  # rewrite would break that other path silently, so hand ownership straight back.
  if [ -f "$_mark" ]; then
    chown --reference="$_kit" "$_mark" 2>/dev/null || true
  fi
fi
if [ -n "$_kit" ] && [ -f "$_mark" ] && [ -x "$_kit/scripts/optimize-boot.sh" ]; then
  # Consumed FIRST. If optimize-boot.sh fails or the power goes out mid-run it must not re-arm itself
  # into a loop that runs on every single boot -- the next update will notice and ask again.
  rm -f "$_mark" 2>/dev/null
  if command -v systemd-run >/dev/null 2>&1; then
    # /bin/bash, not /bin/sh. optimize-boot.sh declares bash and is not dash-clean; started with sh it
    # died on a syntax error with exit 2, and the marker had already been consumed -- so the repair
    # silently did not happen and nothing said so. Found on the first real reboot test.
    #
    # Its output goes to a file the OWNER can read, not only to the journal: journald here is volatile
    # and root-only, so a failed repair would otherwise be invisible to the one person who needs to
    # know. It is the same place klipper keeps its logs, so it travels with every log bundle.
    _log="$(cd "$_kit/.." 2>/dev/null && pwd)/printer_data/logs/arco-reconcile.log"
    # --nice=19 and idle I/O: this is a 60 s run with 22 daemon-reloads, on the same two cores the boot
    # path shares (Spoolman, Moonraker, nginx, voronFDM). At default priority it stretched a Spoolman
    # cold start to 46 s and with it Moonraker and the display (measured 2026-09-05). Nothing waits on
    # this run -- it takes effect on the next boot -- so it can yield to everything that does.
    systemd-run --unit=arco-reconcile --description="Arco Unleashed: apply what the last kit update needs" \
                --nice=19 -p IOSchedulingClass=idle \
                -p "StandardOutput=append:$_log" -p "StandardError=append:$_log" \
                /bin/bash "$_kit/scripts/optimize-boot.sh" >/dev/null 2>&1 \
      && echo "ensure-imageid: kit update needed setup — running optimize-boot.sh (log: $_log)" \
      || echo "ensure-imageid: could not start the post-update setup (systemd-run refused)"
  else
    echo "ensure-imageid: post-update setup pending, but systemd-run is missing — run: sudo bash $_kit/scripts/optimize-boot.sh"
  fi
fi

# The ExecStartPre that runs this is prefixed '+' but NOT '-', so a non-zero exit here does not
# merely get logged -- it stops klipper from starting at all. Every job in this file is a
# best-effort self-heal, and none of them is worth trading a printer that boots for one that does
# not. The block above deliberately ends in commands that are allowed to fail.
exit 0
