#!/bin/bash
# install-reprint-bridge.sh - install the TFT History reprint bridge.
# Run as root at image build / setup time. Installs the tail-and-inject helper, its systemd
# service, and a logrotate rule for the capture log. The voronFDM-stdout -> capture-log redirect
# that feeds the bridge is ensured separately by apply-phrozen-patches.sh (ExecStartPre), because
# phrozen_dev/KlipperScreen-start.sh is not present yet at build time (it arrives via the USB FW).
set -euo pipefail
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
KITSCRIPTS="$(cd "$SELFDIR/.." && pwd)"
HELPER_DST=/home/mks/wsrelay/arco-reprint-bridge.py

install -Dm755 "$KITSCRIPTS/arco-reprint-bridge.py" "$HELPER_DST"
chown mks:mks "$HELPER_DST" 2>/dev/null || true
install -Dm644 "$SELFDIR/arco-reprint-bridge.service" /etc/systemd/system/arco-reprint-bridge.service
install -Dm644 "$SELFDIR/vfdm-capture.logrotate" /etc/logrotate.d/arco-vfdm-capture
systemctl daemon-reload
systemctl enable arco-reprint-bridge.service
echo "  reprint-bridge installed + enabled (starts on boot; 'systemctl start arco-reprint-bridge' to run now)"
