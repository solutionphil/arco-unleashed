#!/bin/sh
# Revert Mainsail to its STOCK look (theme off). Delegates to the
# switcher so .theme-state stays consistent with the cycle macro.
# Re-enable the theme with:  unleashed-theme.sh light
exec sh "${HOME}/printer_data/config/unleashed-theme.sh" stock
