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

# ── THE BODY SWAP ────────────────────────────────────────────────────────────────────────────────
#
# The hook above is a patch on a symptom. The cause is that Phrozen's [homing_override] carries
# "axes: z" AND a body that always homes all three axes and probes: it never sees "G28 X", and when
# it does see a home it can only report "everything is trusted now". KAOS's own printer.cfg carries
# a homing_override that is axis-aware end to end -- it homes only what was asked, skips the probe
# and the trip to bed centre unless Z is involved, tracks _TRUSTED_AXIS_HOME per axis, and calls
# _SET_TRUSTED_XY / _SET_TRUSTED_Z / _SET_TRUSTED_XYZ at the moments each is actually earned.
#
# On a stock KAOS install that is what runs, and it is why Phrozen's own cutter routine -- which
# homes with "G28 Y0" then "G28 X0" -- ends up trusted there and not here. Installing KAOS's section
# is therefore not a workaround; it is the difference between our setup and the one KAOS is
# developed against.
#
# THE HOOK AND THE SWAP ARE ALTERNATIVES, NEVER BOTH. _ARCO_POST_HOME_HOOK calls _SET_TRUSTED_XYZ
# unconditionally. Left in place alongside KAOS's body it would grant full XYZ trust after a home of
# X alone -- defeating precisely the guarantee this exists to provide. So apply installs the section
# and drops the hook; revert puts the vendor section back, hook included.
#
# THE SOURCE IS THE INSTALLED PAYLOAD, not a copy frozen into this repository, so the body always
# matches the KAOS version actually on the printer. No payload means no swap: falling back to the
# hook is correct, guessing at a body is not.
#
# WHAT REVERT DEPENDS ON. The vendor section is preserved inside the managed block itself, one
# commented line per original line, rather than in .cache -- a cache can be orphaned by a kit swap,
# and it was, once. A revert that needs a file outside the config it is repairing is not a revert.
BEGIN_BODY='# >>> unleashed-x-kaos: homing_override replaced with KAOS'"'"'s (managed — KAOS_OFF restores the vendor section preserved below) >>>'
END_BODY='# <<< unleashed-x-kaos: homing_override replaced with KAOS'"'"'s (managed) <<<'
KEEP='#|'                                   # prefix marking a preserved vendor line

has_body_ours() { grep -qF "unleashed-x-kaos: homing_override replaced with KAOS" "$CFG"; }

# Where KAOS's own printer.cfg lives once KAOS_ON has fetched it.
kaos_src() {
    local d
    d="$(cd "$(dirname "$0")/.." && pwd)/.cache/upstream/config/printer.cfg"
    [ -f "$d" ] && printf '%s' "$d"
}

# First and last line of the [homing_override] section currently in $CFG. "Last" means the line
# before the next real section header -- not the next line starting with '[', because Phrozen's file
# has commented-out headers, and not the axes line, because option order is not ours to assume.
#
# `done = 1` before the exit is not decoration: awk runs END even after exit, so without it this
# printed a SECOND line ("186 286"), and taking the field after the last space picked up 286 -- the
# header line of the following section. That header was swallowed into the preserved block and its
# options were left orphaned inside the new homing_override, which klippy rejects with
# "Option 'pin' is not valid in section 'homing_override'". Cost one broken config on hardware.
section_range() {
    awk '
        /^\[homing_override\]/ { s = NR; next }
        s && /^\[[a-zA-Z_]/     { print s, NR - 1; done = 1; exit }
        END { if (s && !done) print s, NR }
    ' "$CFG"
}

apply_body() {
    has_body_ours && return 0
    local src rng s e tmp n_before n_after
    src="$(kaos_src)"
    [ -n "$src" ] && grep -q '^\[homing_override\]' "$src" || return 2   # no payload -> caller falls back
    rng="$(section_range)"; s="${rng%% *}"; e="${rng##* }"
    [ -n "$s" ] && [ -n "$e" ] && [ "$e" -ge "$s" ] || { err "could not delimit [homing_override]"; return 1; }
    tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
    n_before="$(wc -l < "$CFG")"
    {
        sed -n "1,$((s-1))p" "$CFG"
        printf '%s\n' "$BEGIN_BODY"
        # awk, not sed: the prefix contains '|', which collides with sed's delimiter and silently
        # turned the whole preservation step into an error the first time this ran.
        sed -n "${s},${e}p" "$CFG" | awk -v k="$KEEP" '{ print k $0 }'
        printf '%s\n' '# --- KAOS'"'"'s section, taken from the installed payload ---'
        awk '/^\[homing_override\]/ { s = 1 } s && /^\[[a-zA-Z_]/ && !/homing_override/ { exit } s { print }' "$src"
        printf '%s\n' "$END_BODY"
        sed -n "$((e+1)),\$p" "$CFG"
    } > "$tmp" || { rm -f "$tmp"; err "body rewrite failed"; return 1; }

    # Verify on the rewritten file. Exactly one live section header, the vendor copy present, and the
    # file must have grown -- a printer.cfg that lost its homing_override does not start.
    n_after="$(wc -l < "$tmp")"
    if [ "$(grep -c '^\[homing_override\]' "$tmp")" -ne 1 ] \
       || [ "$(grep -cF "$KEEP[homing_override]" "$tmp")" -ne 1 ] \
       || [ "$n_after" -le "$n_before" ]; then
        rm -f "$tmp"; err "body post-edit check failed — $CFG left untouched"; return 1
    fi
    cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; err "could not write $CFG"; return 1; }
    echo "homing_override replaced with KAOS's (axis-aware; grants trust per axis)"
}

revert_body() {
    has_body_ours || return 0
    local tmp
    tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
    awk -v k="$KEEP" -v kl="${#KEEP}" '
        index($0, "unleashed-x-kaos: homing_override replaced with KAOS") { skip = 1 - skip; next }
        skip && substr($0, 1, kl) == k { print substr($0, kl + 1); next }   # vendor line, unwrapped
        skip { next }                                                        # KAOS body / notes: drop
        { print }
    ' "$CFG" > "$tmp" || { rm -f "$tmp"; err "body rewrite failed"; return 1; }
    if [ "$(grep -c '^\[homing_override\]' "$tmp")" -ne 1 ] \
       || grep -qF 'unleashed-x-kaos: homing_override replaced with KAOS' "$tmp" \
       || ! awk '/^\[homing_override\]/{s=1;next} s && /^\[[a-zA-Z_]/{exit} s && /^axes[[:space:]]*:/{f=1} END{exit !f}' "$tmp"; then
        rm -f "$tmp"; err "body post-edit check failed — $CFG left untouched"; return 1
    fi
    cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; err "could not write $CFG"; return 1; }
    echo "vendor homing_override restored"
}

# Remove only the hook block this script inserted. Factored out because the swap needs it too: with
# KAOS's section in place the hook is not merely redundant, it is wrong.
strip_hook() {
    has_ours || return 0
    local tmp
    tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
    awk '
        /unleashed-x-kaos: post-home hook \(managed/ { skip = 1 - skip; next }
        !skip
    ' "$CFG" > "$tmp" || { rm -f "$tmp"; err "rewrite failed"; return 1; }
    if ! grep -q '^\[homing_override\]' "$tmp" \
       || grep -qF 'unleashed-x-kaos: post-home hook (managed' "$tmp" \
       || [ "$(wc -l < "$tmp")" -ne "$(( $(wc -l < "$CFG") - 5 ))" ]; then
        rm -f "$tmp"; err "post-edit check failed — $CFG left untouched"; return 1
    fi
    cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; err "could not write $CFG"; return 1; }
}

case "$ACTION" in
    apply)
        apply_body; _rc=$?
        if [ "$_rc" = 0 ]; then
            # KAOS's section is in place and grants trust itself, per axis. Our hook would grant
            # full XYZ after a home of X alone, so it goes.
            if has_ours; then
                strip_hook && echo "post-home hook removed — KAOS's section grants trust itself"
            fi
            exit 0
        fi
        if [ "$_rc" = 2 ]; then
            echo "no KAOS payload cached yet — using the post-home hook instead"
        else
            err "body swap failed — falling back to the post-home hook"
        fi
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
        # Order matters. Restoring the vendor section brings back whatever it contained when it was
        # preserved -- including the hook block, if one was there. Removing the hook afterwards
        # therefore operates on the restored text, which is the state KAOS_OFF must leave behind.
        revert_body || err "vendor homing_override could not be restored — see above"
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
        if   has_body_ours; then echo "body=kaos"
        elif has_ours;      then echo "body=vendor hook=ours"
        elif has_call;      then echo "body=vendor hook=foreign"
        elif [ -n "$(anchor_line)" ]; then echo "body=vendor hook=none"
        else echo unknown
        fi
        ;;
    *)
        err "usage: $(basename "$0") {apply|revert|status} <printer.cfg>"; exit 1
        ;;
esac
