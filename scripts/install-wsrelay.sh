#!/bin/bash
# install-wsrelay.sh — deploy the voronFDM<->moonraker WebSocket relay that prevents the freeze where
# voronFDM hangs on the cal page after a SAVE_CONFIG-triggered klippy restart.
#
# How it works (proven on a full 40k Auto-Cal: voronFDM never froze, the watchdog never had to act):
#   - relay.py (tornado, moonraker-env) listens on 127.0.0.1:7126 and bridges to moonraker on 7125.
#     It ALWAYS reads from moonraker, so moonraker never sees voronFDM stall -> never drops it ->
#     voronFDM's connection survives voronFDM's ~5s restart block -> no reconnect needed -> no freeze.
#   - connshim.so (LD_PRELOAD) redirects voronFDM's connect(127.0.0.1:7125) -> 7126, injected via a
#     KlipperScreen.service.d Environment= drop-in. moonraker stays 100% vanilla (update-neutral), and
#     the drop-in survives Phrozen voronFDM updates (Phrozen clobbers phrozen_dev, not systemd units).
#   - The voronFDM watchdog (install-watchdog.sh) stays as the backup, with its health check on 7126.
#
# On the printer:  sudo bash scripts/install-wsrelay.sh
set -e
[ "$EUID" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-mks}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
RT="$HOME_DIR/wsrelay"
PYENV="$HOME_DIR/moonraker-env/bin/python"

[ -x "$PYENV" ] || { echo "moonraker-env python not found at $PYENV — install Moonraker first."; exit 1; }
command -v gcc >/dev/null || { echo "gcc not found (needed to build the connect-shim)."; exit 1; }

install -d -o "$USER_NAME" -g "$USER_NAME" "$RT"
install -o "$USER_NAME" -g "$USER_NAME" -m 644 "$DIR/wsrelay/relay.py" "$RT/relay.py"
gcc -shared -fPIC -O2 -o "$RT/connshim.so" "$DIR/wsrelay/connshim.c" -ldl
chown "$USER_NAME:$USER_NAME" "$RT/connshim.so"
echo "  shim built: $(file "$RT/connshim.so" | grep -oiE 'aarch64' | head -1) shared object"

cat > /etc/systemd/system/arco-wsrelay.service <<EOF
[Unit]
Description=Arco Unleashed - voronFDM<->moonraker WS relay (prevents SAVE_CONFIG-restart freeze)
After=moonraker.service
Wants=moonraker.service
Before=KlipperScreen.service
[Service]
Type=simple
User=$USER_NAME
ExecStart=$PYENV $RT/relay.py
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

# update-proof shim injection into voronFDM (a systemd drop-in is NOT clobbered by Phrozen updates)
mkdir -p /etc/systemd/system/KlipperScreen.service.d
cat > /etc/systemd/system/KlipperScreen.service.d/arco-wsrelay.conf <<EOF
[Service]
Environment=LD_PRELOAD=$RT/connshim.so
EOF

systemctl daemon-reload
systemctl enable --now arco-wsrelay.service
echo "  arco-wsrelay.service: $(systemctl is-active arco-wsrelay.service) (listening 127.0.0.1:7126)"
echo "  LD_PRELOAD drop-in installed on KlipperScreen.service."
echo "  Restart KlipperScreen (or reboot) so voronFDM picks up the shim:  sudo systemctl restart KlipperScreen"
