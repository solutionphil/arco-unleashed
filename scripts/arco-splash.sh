#!/bin/bash
# arco-splash.sh — brand the serial display during the boot/screensaver window, BEFORE voronFDM
# switches to the main menu. Cosmetic only. Run as a oneshot ordered Before=KlipperScreen.service,
# so /dev/ttyS1 is still free. Once voronFDM takes over, the splash is replaced by the UI.
#
# Draw uses TJC/Nextion xstr with sta=3 (transparent — no background box):
#   xstr x,y,w,h,font,pco,bco,xcen,ycen,sta,"text"   (only Font 0 renders text on this .tft)
# Colors RGB565: logo-blue 8764, white 65535.
DEV=/dev/ttyS1
[ -e "$DEV" ] || exit 0
stty -F "$DEV" 115200 raw -echo 2>/dev/null || true
s(){ printf '%b\xff\xff\xff' "$1" > "$DEV" 2>/dev/null || true; }

# Layout (verified on hardware): "ARCO UNLEASHED" big in Font 4 (logo-blue) bottom-left, and
# "Bookworm Edition 1.0" in Font 0 (white) bottom-right. Font 4 = largest readable font on this
# .tft (Font 1 is a symbol font, Font 2 is empty). Font 0's box needs h>=34 or it clips.
#
# Redraw a few times so the loading-page animation can't permanently clobber it. The loop duration
# is roughly how long the splash stays visible before voronFDM starts and switches to the main menu.
end=$(( $(date +%s) + ${ARCO_SPLASH_SECONDS:-3} ))
while [ "$(date +%s)" -lt "$end" ]; do
  s 'xstr 8,425,640,50,4,8764,0,0,1,3,"ARCO UNLEASHED"'
  s 'xstr 470,432,322,34,0,65535,0,2,1,3,"Bookworm Edition 1.0"'
  sleep 0.5
done
exit 0
