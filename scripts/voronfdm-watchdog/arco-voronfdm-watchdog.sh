#!/bin/bash
# arco-voronfdm-watchdog
# -----------------------------------------------------------------------------
# Restart voronFDM when its Moonraker websocket is dead and does not recover in
# place. Cause: after a SAVE_CONFIG -> klippy restart, Moonraker (v0.10) sends
# the slow-reading voronFDM a burst of notifications, overflows its write buffer
# and closes the socket ABRUPTLY (no WS CLOSE frame). voronFDM only reconnects on
# a clean CLOSE frame (ws_com_receive == 4), so it otherwise stays dead and the
# display is stuck on the calibration page instead of returning to the home page.
#
# Strategy: every ~15s, verify that EXACTLY ONE voronFDM instance is running AND
# that it holds an ESTABLISHED connection to 127.0.0.1:7126 (the wsrelay, which
# bridges to Moonraker; pre-relay setups connected to 7125 directly). If that
# is not true for longer than GRACE seconds (a real hang; brief normal restarts
# are ignored), kill every voronFDM instance and start exactly one fresh (the
# same way KlipperScreen-start.sh does).
set -u

STATE=/run/arco-voronfdm-watchdog.since
GRACE=20                                                   # seconds it must stay unhealthy before acting
VFDM_DIR=/home/mks/klipper/klippy/extras/phrozen_dev/serial-screen
LOG=/home/mks/voronfdm-boot.log

# On a clean (pre-USB-install) image voronFDM is stripped out — nothing to watch yet. No-op until it is
# installed, to avoid churn + failed relaunches before the first-run USB install brings voronFDM.
[ -x "$VFDM_DIR/voronFDM" ] || exit 0

# pgrep -x voronFDM = EXACT process name (comm), NOT the command line.
# Important: -f "serial-screen/voronFDM" would also match debug/SSH sessions
# whose command line contains that string -> dangerous collateral kills.
pids=$(pgrep -x voronFDM || true)
n=$(printf '%s\n' "$pids" | grep -c . || true)

healthy=0
if [ "$n" -eq 1 ]; then
    # Match by NAME (grep voronFDM) instead of by PID: robust against fd sharing,
    # where Moonraker's socket fd is inherited by ota_control/PhrozenGo and ss
    # attributes the connection to several PIDs.
    if ss -tnpH state established "dst 127.0.0.1:7126" 2>/dev/null | grep -q '"voronFDM"'; then
        healthy=1
    fi
fi

if [ "$healthy" -eq 1 ]; then
    rm -f "$STATE"
    exit 0
fi

# unhealthy: record the timestamp, wait out the grace period (ignores brief restarts)
now=$(date +%s)
if [ -f "$STATE" ]; then
    since=$(cat "$STATE" 2>/dev/null || echo "$now")
else
    since=$now
    echo "$now" > "$STATE"
fi
[ -z "${since:-}" ] && since=$now

if [ $((now - since)) -lt "$GRACE" ]; then
    exit 0
fi

# unhealthy longer than GRACE -> restart voronFDM
logger -t arco-voronfdm-watchdog "voronFDM unhealthy (instances=$n, moonraker ws dead) for >${GRACE}s -> restart"
pkill -9 -x voronFDM 2>/dev/null
sleep 2
# Launch with the FULL path and detached (setsid), exactly like KlipperScreen-start.sh -- INCLUDING
# the wsrelay connshim (LD_PRELOAD) that KlipperScreen.service sets via Environment=. Without it the
# restarted voronFDM connects DIRECT to 7125, the 7126 health-check above can never pass, and the
# watchdog restarts it forever (relay + display-print bridge silently bypassed).
SHIM=/home/mks/wsrelay/connshim.so
if [ -f "$SHIM" ]; then
    runuser -u mks -- bash -c "cd '$VFDM_DIR' && LD_PRELOAD='$SHIM' setsid '$VFDM_DIR/voronFDM' >'$LOG' 2>&1 </dev/null &"
else
    runuser -u mks -- bash -c "cd '$VFDM_DIR' && setsid '$VFDM_DIR/voronFDM' >'$LOG' 2>&1 </dev/null &"
fi
rm -f "$STATE"
exit 0
