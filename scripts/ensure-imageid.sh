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
    systemd-run --unit=arco-reconcile --description="Arco Unleashed: apply what the last kit update needs" \
                -p "StandardOutput=append:$_log" -p "StandardError=append:$_log" \
                /bin/bash "$_kit/scripts/optimize-boot.sh" >/dev/null 2>&1 \
      && echo "ensure-imageid: kit update needed setup — running optimize-boot.sh (log: $_log)" \
      || echo "ensure-imageid: could not start the post-update setup (systemd-run refused)"
  else
    echo "ensure-imageid: post-update setup pending, but systemd-run is missing — run: sudo bash $_kit/scripts/optimize-boot.sh"
  fi
fi
