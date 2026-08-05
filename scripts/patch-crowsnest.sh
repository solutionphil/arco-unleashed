#!/bin/bash
# patch-crowsnest.sh — make a crowsnest.conf correct for this hardware.
#
#   patch-crowsnest.sh <crowsnest.conf>
#
# ONE definition, two callers, deliberately:
#   * fetch-phrozen-fw.sh, on the running printer during the Phrozen install;
#   * rebake.sh, against the mounted image at build time.
# The second one exists because of a real complaint: a freshly flashed printer showed a badly
# stuttering webcam. The image carries the donor's crowsnest.conf, which said `mode: ustreamer` and
# `max_fps: 5`, and the only thing that ever corrected it ran during the Phrozen install -- so anyone
# who flashed, looked at the camera and had not yet installed Phrozen's firmware saw the slow path
# with no reason to suspect two config lines. Applying it at bake time closes that window.
#
# It is emphatically NOT a second copy of the rules: duplicating them into the bake is exactly the
# failure this project keeps hitting (a staged PDF five days stale, a printer.cfg the template never
# reached). One file, two callers.
#
# Environment, both optional:
#   ARCO_ROOT   prefix to look under for the camera-streamer binary. The bake passes the mounted
#               rootfs, because `command -v` on the build host would answer for the WRONG system --
#               and answering "absent" there would write the ustreamer fallback into every image.
#   CAM_BYID    by-id capture node to write into `device:`. Empty leaves the line untouched, which is
#               what a bake wants: no camera is attached to the build host, and the by-id path the
#               donor already carries is correct for the same camera model.
#
# Idempotent: every edit is an exact-value rewrite, so running it twice changes nothing.

set -u
CFG="${1:-}"
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo "patch-crowsnest: no such crowsnest.conf: ${CFG:-<none>}" >&2; exit 1; }

ROOT="${ARCO_ROOT:-}"

# Existence, not executability, when probing a mounted root: the failure direction is asymmetric.
# A false "absent" writes the slow ustreamer path into every image built from then on, silently --
# which is the very bug this script exists to stop. A false "present" makes crowsnest fail loudly on
# a binary it cannot run, which someone notices immediately. So -e, and let the loud failure win.
have_camera_streamer() {
    if [ -n "$ROOT" ]; then
        [ -e "$ROOT/usr/bin/camera-streamer" ] || [ -e "$ROOT/usr/local/bin/camera-streamer" ]
    else
        command -v camera-streamer >/dev/null 2>&1
    fi
}

# Webcam backend: camera-streamer, not ustreamer. Measured on hardware 2026-07-17 over WiFi at 720p:
# ustreamer delivered ~3 fps, camera-streamer ~20 through the same nginx proxy -- nearly 8x. The
# bottleneck was ustreamer's HTTP/buffering layer, NOT the WiFi chip / firmware / SDIO clock (all three
# checked and ruled out). crowsnest v5 has a built-in camera-streamer backend
# (crowsnest/components/streamer/camera-streamer.py), so switching the mode is all it takes: crowsnest
# stays the manager (device detection, MJPG passthrough, CPU 0-1 via its own service drop-in), and
# camera-streamer answers the ustreamer URLs (/?action=stream) so nginx's /webcam/ and moonraker's
# [webcam cam1] are untouched. Fall back to ustreamer only if camera-streamer is genuinely absent.
if have_camera_streamer; then
    sed -i 's/^mode:.*/mode: camera-streamer/' "$CFG"
else
    sed -i 's/^mode: *mjpg.*/mode: ustreamer/' "$CFG"     # mjpg was removed in crowsnest v5
fi

# 1280x720 -- the resolution the stock Arco uses. Phrozen's Buster runs [cam 1] at 1280x720 (read from
# crowsnest's own startup logs in the stock image), and so did our own June builds. The kit forced
# 640x480 from its first commit with the claim "720p+ leaves the UVC cam at 1-3 fps" -- measured wrong
# (720p is fine; camera-streamer streams it smoothly). Ship stock's resolution.
sed -i 's/^\(resolution:[[:space:]]*\)[0-9]*x[0-9]*/\11280x720/' "$CFG"

# 15 fps runs smooth on this camera (5 fps caused visible stutter -- that is precisely what a recipient
# reported off a fresh flash); the real-time margin at 40k accel is set by max_accel, not the webcam (a
# full Auto-Cal ran clean with the cam on at 15 fps). max_fps=15 -> ~16-20 fps in practice, and there is
# NO way to set it lower. Confirmed with v4l2-ctl --list-formats-ext (2026-07-18): this UVC cam offers
# 1280x720 at 30 fps ONLY -- no 15/20/10 mode -- and camera-streamer has no output frame-drop option. So
# neither the camera nor the streamer can cap the rate, and v4l2-ctl --set-parm cannot either (one mode
# only). The ~16-20 fps is simply the WiFi throttling the 30; max_fps is effectively cosmetic here
# (repeated measures of the same config ranged 16-20). 15 kept to match Phrozen's stock crowsnest.conf.
sed -i 's/^\([[:space:]]*max_fps:\)[[:space:]]*[0-9]\+/\1 15/' "$CFG"

# Phrozen hardcodes `device: /dev/video4`, which was the capture node on their Buster kernel. On ours the
# rockchip codecs (rga, iep, rkvdec, vpu-dec) claim more /dev/video* slots, so the camera shifts -- and a
# UVC camera registers TWO nodes, of which only *-video-index0 delivers frames (index1 is metadata).
# A fixed number is both wrong here and fragile across kernels; the by-id capture node is stable.
[ -n "${CAM_BYID:-}" ] && sed -i "s|^device:.*|device: $CAM_BYID|" "$CFG"

exit 0
