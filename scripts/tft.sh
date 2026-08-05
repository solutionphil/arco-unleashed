#!/bin/bash
# tft.sh — draw the first-boot install progress screen on the Arco serial display (/dev/ttyS1).
#
# Used by arco-firstrun + fetch-phrozen-fw WHILE voronFDM is not yet running (serial port free).
# The functions self-disable as soon as KlipperScreen/voronFDM is active, so they never fight it
# (e.g. when fetch is run manually for recovery on a working printer) — voronFDM then owns the UI.
#
# Source it and call:   tft_init ; tft_status "<text>" <pct> ; tft_done "<text>"
# Or standalone:        bash tft.sh status "<text>" <pct>
#
# Layout: deep-navy bg, white title/status/percent, brand-blue progress bar on a slate track, and the
# ARCO UNLEASHED (blue, Font 4) / Bookworm Edition 1.0 (white, Font 0) branding.
#
# Palette — the SAME one selfflash/initramfs/arco-emmc-flash uses, so the install screens and the flash
# screen are one design. They were not: this file shipped 2114 (#080810 — black, despite a comment
# claiming "dark navy, verified on hardware"), 8764 (#2044E6 indigo, not the brand blue) and 33808
# (#838183 grey) from the initial commit onward, while the flash screen had a documented palette all
# along. Nothing linked the two, so nothing caught the drift.
TFT_DEV="${TFT_DEV:-/dev/ttyS1}"
C_BG=4359      # #10233B deep navy   (page background + every text box behind our own text)
C_ACC=11294    # #2F81F7 brand blue  (progress fill + ARCO UNLEASHED wordmark)
C_TRK=10731    # #2B3E5C empty track (a darker slate vanished into the background)
C_TXT=65535    # white

_tft_s(){ printf '%b\xff\xff\xff' "$1" > "$TFT_DEV" 2>/dev/null || true; }

# draw only when the panel exists AND voronFDM (KlipperScreen.service) is NOT running
tft_avail(){ [ -e "$TFT_DEV" ] && ! systemctl is-active --quiet KlipperScreen 2>/dev/null; }

tft_init(){
  tft_avail || return 0
  stty -F "$TFT_DEV" 115200 raw -echo 2>/dev/null || true
  # The panel keeps its page-6 contents across a host reboot (it isn't power-cycled), so the previous
  # WiFi-portal screen lingers. Switch + settle, then a full repaint clears it reliably.
  _tft_s "page 6"; sleep 0.4
  _tft_s "fill 0,0,800,480,$C_BG"; sleep 0.15
  _tft_s "fill 0,0,800,480,$C_BG"
  _tft_s "xstr 0,70,800,30,0,$C_TXT,$C_BG,1,1,1,\"Setting up Arco Unleashed\""
  _tft_s "xstr 8,420,640,50,4,$C_ACC,$C_BG,0,1,1,\"ARCO UNLEASHED\""
  _tft_s "xstr 470,432,322,34,0,$C_TXT,$C_BG,2,1,1,\"Bookworm Edition 1.0\""
}

tft_status(){  # $1=text  $2=percent (0-100)
  tft_avail || return 0
  local msg="$1" pct="${2:-0}" w
  [ "$pct" -ge 0 ] 2>/dev/null || pct=0; [ "$pct" -le 100 ] 2>/dev/null || pct=100
  # The status + percent boxes are sized so that, together with the bar, they TILE the content band
  # (y=150..306) with NO gaps — leftover portal text (e.g. the green "Arco-Unleashed-Setup" at y=255)
  # is painted over by their navy backgrounds. These boxes are drawn every update anyway, so there is
  # no extra fill and no flicker.
  #
  # The band ABOVE them was the exception. Nothing repainted y100..150: tft_init writes the title at
  # y70..100 and the first status box starts at 150, so whatever page 6 had there survived. And it
  # does have something — the panel carries static elements in the .tft that reappear after
  # tft_init's two full-screen fills, which is why those fills exist and still are not enough.
  # Photographed on hardware 2026-08-05: a fragment of the panel's own layout sat above the status
  # line for the entire first boot. Cleared here rather than in tft_init on purpose — init runs once,
  # this runs on every update, and the panel redraws its own content at moments we do not control.
  _tft_s "fill 0,100,800,50,$C_BG"
  _tft_s "xstr 0,150,800,62,0,$C_TXT,$C_BG,1,1,1,\"$msg\""  # status band: y150..212
  _tft_s "fill 0,210,800,42,$C_BG"                         # clear the FULL bar row (sides + just above/below) -> no gap around the bar
  _tft_s "fill 100,213,600,36,$C_TRK"                      # bar track (inset in the cleared row)
  w=$((600*pct/100)); [ "$w" -gt 0 ] && _tft_s "fill 100,213,$w,36,$C_ACC"
  _tft_s "xstr 0,252,800,54,0,$C_TXT,$C_BG,1,1,1,\"$pct%\"" # percent band: y252..306
}

tft_done(){ tft_status "${1:-Done - starting interface...}" 100; }

# A second line UNDER the content band, for a hint that belongs with the status but isn't the status
# itself ("wait for restart..."). y=310 sits below the percent band (which ends at 306) and above the
# branding (y=420), so it survives tft_status repaints and is cleared by tft_init's full fill.
tft_hint(){
  tft_avail || return 0
  _tft_s "xstr 0,310,800,34,0,$C_TXT,$C_BG,1,1,1,\"${1:-}\""
}

# standalone CLI (only when executed directly, not when sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    init)   tft_init;;
    status) tft_status "${2:-}" "${3:-0}";;
    done)   tft_done "${2:-}";;
    *) echo 'Usage: bash tft.sh [init | status "<text>" <pct> | done "<text>"]';;
  esac
fi
