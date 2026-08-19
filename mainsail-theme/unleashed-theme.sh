#!/bin/sh
# ──────────────────────────────────────────────────────────────
# Arco Unleashed — Mainsail theme switcher
#   unleashed-theme.sh light     → Voron Light (navy, default)
#   unleashed-theme.sh dark      → Voron Dark  (darker)
#   unleashed-theme.sh stock     → stock Mainsail (theme off)
#   unleashed-theme.sh next      → cycle  light → dark → stock → light …
#   unleashed-theme.sh           → show active state
#
# Last state is stored in .theme-state (survives restarts/reboots and
# survives 'stock', which removes .theme/). The look is rebuilt into a
# temp dir and swapped atomically (race-safe vs. rapid clicks).
# ──────────────────────────────────────────────────────────────
set -e

CFG="${HOME}/printer_data/config"
VAR="${CFG}/.theme-variants"
DEST="${CFG}/.theme"
STATE="${CFG}/.theme-state"

current() {
    if [ -f "$STATE" ]; then cat "$STATE"
    elif [ -d "$DEST" ]; then cat "${DEST}/.active" 2>/dev/null || echo light
    else echo stock; fi
}

apply() {
    if [ "$1" = "stock" ]; then
        rm -rf "$DEST"
    else
        TMP="${DEST}.tmp.$$"
        rm -rf "$TMP"; mkdir -p "$TMP"
        cp -r "${VAR}/shared/"* "$TMP/"
        cp "${VAR}/voron-$1/"* "$TMP/"
        # The owner's own CSS, appended LAST so it wins over the variant. It lives beside the
        # variants rather than inside one, so it applies to both and belongs to nobody but the
        # owner: apply-theme-variants.sh only ever copies out of the kit's variants/ subfolders
        # and therefore never touches it.
        #
        # It exists because the refresh guard made personal edits volatile. Editing a variant's
        # custom.css used to stick forever; now the guard replaces that file whenever the kit's
        # copy differs, so a hand-written rule would vanish at some later klipper start with
        # nothing to explain where it went.
        #
        # if/then rather than `[ -f x ] && cat x`. MEASURED, because the obvious claim about it is
        # wrong: under `set -e` a failing && list is exempt everywhere EXCEPT as the last command
        # of a function -- there the function returns 1 and the script dies at the call site. Here
        # the line sits mid-function, so the && form would have worked; it becomes a silent trap
        # only if someone later moves it or appends after it. if/then costs one line and cannot.
        if [ -f "${VAR}/local.css" ]; then
            printf '\n/* ---- local.css (yours, appended by unleashed-theme.sh) ---- */\n' \
                >> "${TMP}/custom.css"
            cat "${VAR}/local.css" >> "${TMP}/custom.css"
        fi
        printf '%s\n' "$1" > "${TMP}/.active"
        rm -rf "$DEST"; mv "$TMP" "$DEST"
    fi
    printf '%s\n' "$1" > "$STATE"
}

cmd="$1"

if [ -z "$cmd" ]; then
    echo "Active: $(current)"
    echo "Switch:  $0 light | dark | stock | next"
    exit 0
fi

if [ "$cmd" = "next" ]; then
    case "$(current)" in
        light) cmd=dark ;;
        dark)  cmd=stock ;;
        *)     cmd=light ;;
    esac
fi

case "$cmd" in
    light|dark|stock) ;;
    *) echo "Invalid: '$1'. Use: $0 light|dark|stock|next"; exit 1 ;;
esac

if [ "$cmd" != "stock" ] && [ ! -d "${VAR}/voron-${cmd}" ]; then
    echo "Variant '${cmd}' missing in ${VAR}/voron-${cmd}"; exit 1
fi

apply "$cmd"

if [ "$cmd" = "stock" ]; then
    echo "Stock Mainsail active. Reload Mainsail (Ctrl+F5)."
else
    echo "Voron ${cmd} is now active. Reload Mainsail (Ctrl+F5)."
fi
