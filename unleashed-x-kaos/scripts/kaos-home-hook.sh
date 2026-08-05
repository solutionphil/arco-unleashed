#!/bin/bash
# kaos-home-hook.sh — make sure a completed home actually reaches KAOS.
#
# KAOS's motion guard blocks travel until trust is granted, and _SET_TRUSTED_XYZ is the
# ONLY thing that grants it. Our kaos-trust-wiring.cfg defines [gcode_macro
# _ARCO_POST_HOME_HOOK] to call it — but defining the macro is only half the wiring. The
# other half is a CALL, and that call lives inside [homing_override], which is a Klipper
# SECTION: it cannot be wrapped from another file the way a macro can, so it has to be
# edited in printer.cfg itself.
#
# The kit's config-templates/printer.cfg.template carries that call. The deployed
# printer.cfg does NOT get regenerated from the template (the bake validates it, it does
# not rewrite it), so on every printer flashed before the template gained the hook — and
# on any printer whose printer.cfg a Phrozen update has replaced — the call is simply
# absent. Symptom, observed on hardware 2026-07-27: homing succeeds, _TRUSTED_HOME stays
# 0, and every mesh calibration dies with "KAOS blocked - BED_MESH_CALIBRATE requires
# physical trusted XYZ". From the display that looks like the printer crashing.
#
#   kaos-home-hook.sh apply  <printer.cfg>
#   kaos-home-hook.sh revert <printer.cfg>
#   kaos-home-hook.sh status <printer.cfg>   -> applied|ours|foreign|clean|unknown
#
# Idempotent. Shared by kaos-sideload.sh (KAOS_ON/OFF) and kaos-guard.sh (re-apply after a
# Phrozen update replaced printer.cfg). Kept small and side-effect-light: the boot guard
# runs it before every klipper start.
#
# ASYMMETRY THAT MATTERS: apply is satisfied by ANY call to the hook, ours or the kit's
# own; revert removes ONLY the block we marked. A future image ships the call from the
# template, unmarked — deleting that on KAOS_OFF would break the base install to undo an
# add-on, which is exactly backwards.

set -u
ACTION="${1:-}"; CFG="${2:-}"

err() { echo "kaos-home-hook: $*" >&2; }

[ -n "$CFG" ] && [ -f "$CFG" ] || { err "printer.cfg not found: ${CFG:-<none>}"; exit 1; }

BEGIN_MARK='    # >>> unleashed-x-kaos: post-home hook (managed — KAOS_OFF removes this) >>>'
END_MARK='    # <<< unleashed-x-kaos: post-home hook (managed) <<<'

# Any call at all (the kit's own template writes it unmarked).
has_call()   { grep -qE '^[[:space:]]*_ARCO_POST_HOME_HOOK[[:space:]]*$' "$CFG"; }
# Specifically the block this script inserted.
has_ours()   { grep -qF 'unleashed-x-kaos: post-home hook (managed' "$CFG"; }

# Line number of the homing_override_end anchor, but only if it really sits inside
# [homing_override]. Guessing a location in printer.cfg is not acceptable: a call placed in
# the wrong section is either dead or fires at the wrong moment.
anchor_line() {
    awk '
        /^\[homing_override\]/ { inblk = 1; next }
        /^\[/                  { inblk = 0 }
        inblk && /action_respond_info\("homing_override_end/ { print NR; exit }
    ' "$CFG"
}

case "$ACTION" in
    apply)
        if has_call; then echo "already applied"; exit 0; fi
        n="$(anchor_line)"
        [ -n "$n" ] || { err "no homing_override_end anchor inside [homing_override] — not editing blind"; exit 2; }

        tmp="$(mktemp)" || { err "mktemp failed"; exit 3; }
        awk -v n="$n" -v b="$BEGIN_MARK" -v e="$END_MARK" 'NR==n{
            print b;
            print "    {% if printer[\047gcode_macro _ARCO_POST_HOME_HOOK\047] is defined %}";
            print "        _ARCO_POST_HOME_HOOK";
            print "    {% endif %}";
            print e;
        } {print}' "$CFG" > "$tmp" || { rm -f "$tmp"; err "rewrite failed"; exit 3; }

        # Verify on the REWRITTEN file before it replaces anything: a printer.cfg that lost
        # its homing_override to a botched edit is a printer that will not start.
        if ! grep -qE '^[[:space:]]*_ARCO_POST_HOME_HOOK[[:space:]]*$' "$tmp" \
           || ! grep -q '^\[homing_override\]' "$tmp" \
           || [ "$(wc -l < "$tmp")" -ne "$(( $(wc -l < "$CFG") + 5 ))" ]; then
            rm -f "$tmp"; err "post-edit check failed — printer.cfg left untouched"; exit 3
        fi

        cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; err "could not write $CFG"; exit 3; }
        echo "applied"
        ;;
    revert)
        if ! has_ours; then
            # Either nothing to do, or the call came from the kit template — not ours to remove.
            if has_call; then echo "already clean (call is the base config's, left in place)"; else echo "already clean"; fi
            exit 0
        fi
        tmp="$(mktemp)" || { err "mktemp failed"; exit 3; }
        # Toggle on each marker and drop the markers themselves, so exactly our block goes
        # and nothing else can be caught by it.
        awk '
            /unleashed-x-kaos: post-home hook \(managed/ { skip = 1 - skip; next }
            !skip
        ' "$CFG" > "$tmp" || { rm -f "$tmp"; err "rewrite failed"; exit 3; }

        if ! grep -q '^\[homing_override\]' "$tmp" \
           || grep -qF 'unleashed-x-kaos: post-home hook (managed' "$tmp" \
           || [ "$(wc -l < "$tmp")" -ne "$(( $(wc -l < "$CFG") - 5 ))" ]; then
            rm -f "$tmp"; err "post-edit check failed — printer.cfg left untouched"; exit 3
        fi

        cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; err "could not write $CFG"; exit 3; }
        echo "reverted"
        ;;
    status)
        if   has_ours; then echo ours
        elif has_call; then echo foreign
        elif [ -n "$(anchor_line)" ]; then echo clean
        else echo unknown
        fi
        ;;
    *)
        err "usage: $(basename "$0") {apply|revert|status} <printer.cfg>"; exit 1
        ;;
esac
