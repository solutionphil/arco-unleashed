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
