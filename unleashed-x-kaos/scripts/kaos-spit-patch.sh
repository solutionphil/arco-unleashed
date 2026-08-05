#!/bin/bash
# kaos-spit-patch.sh — the ONE file edit Option B makes to enable magic_ams.
#
# Renames the kit's stock [gcode_macro PRZ_SPITTING_END] section in
# printer_gcode_macro.cfg to [gcode_macro _ARCO_SPITTING_END_STOCK], so the
# magic_ams bridge's own PRZ_SPITTING_END becomes the sole declaration (no
# same-named-section merge) while the stock body survives verbatim under the new
# name for the non-magic spit path. Only the section HEADER line is touched.
#
#   kaos-spit-patch.sh apply  <printer_gcode_macro.cfg>
#   kaos-spit-patch.sh revert <printer_gcode_macro.cfg>
#   kaos-spit-patch.sh status <printer_gcode_macro.cfg>   -> applied|clean|unknown
#
# Fully idempotent: apply-when-applied and revert-when-clean are no-ops. Shared by
# kaos-sideload.sh (on KAOS_ON/OFF) and kaos-guard.sh (re-apply after a Phrozen
# update reverted printer_gcode_macro.cfg). Kept tiny and side-effect-light because
# the boot guard runs it before every klipper start.

set -u
ACTION="${1:-}"; PGM="${2:-}"

err() { echo "kaos-spit-patch: $*" >&2; }

[ -n "$PGM" ] && [ -f "$PGM" ] || { err "printer_gcode_macro.cfg not found: ${PGM:-<none>}"; exit 1; }

# `[[:space:]]*$` tolerates a trailing CR if the file ever arrives CRLF.
has_stock()   { grep -qE '^\[gcode_macro PRZ_SPITTING_END\][[:space:]]*$'        "$PGM"; }
has_renamed() { grep -qE '^\[gcode_macro _ARCO_SPITTING_END_STOCK\][[:space:]]*$' "$PGM"; }

case "$ACTION" in
    apply)
        if has_stock; then
            sed -i -E 's/^\[gcode_macro PRZ_SPITTING_END\][[:space:]]*$/[gcode_macro _ARCO_SPITTING_END_STOCK]/' "$PGM" \
                && has_renamed && ! has_stock && { echo "applied"; exit 0; }
            err "rename failed"; exit 3
        elif has_renamed; then
            echo "already applied"; exit 0
        else
            err "no [gcode_macro PRZ_SPITTING_END] section to rename — unexpected file"; exit 2
        fi
        ;;
    revert)
        if has_renamed; then
            sed -i -E 's/^\[gcode_macro _ARCO_SPITTING_END_STOCK\][[:space:]]*$/[gcode_macro PRZ_SPITTING_END]/' "$PGM" \
                && has_stock && ! has_renamed && { echo "reverted"; exit 0; }
            err "revert failed"; exit 3
        else
            echo "already clean"; exit 0
        fi
        ;;
    status)
        if has_renamed; then echo applied; elif has_stock; then echo clean; else echo unknown; fi
        ;;
    *)
        err "usage: $(basename "$0") {apply|revert|status} <printer_gcode_macro.cfg>"; exit 1
        ;;
esac
