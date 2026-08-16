#!/bin/bash
# kaos-sideload.sh — the Unleashed x KAOS bridge worker.
#
#   kaos-sideload.sh on         fetch (if needed), verify, install, activate
#   kaos-sideload.sh off        deactivate; payload stays cached for an instant re-activation
#   kaos-sideload.sh update [ref]  pull upstream (default main), re-verify, re-activate if it was on
#   kaos-sideload.sh status     what is installed, which commit, active or not
#   kaos-sideload.sh magic-on   enable the opt-in magic_ams purge (persisted)
#   kaos-sideload.sh magic-off  disable it again
#
# DESIGN RULES (see docs/integration-spec.md):
#   * We NEVER run KAOS's own installer. It cp -f's printer.cfg and
#     printer_gcode_macro.cfg over the target, which on Unleashed silently removes
#     [include AddOn.cfg] and with it every feature we add.
#   * The base never deletes anything. All removal happens on the overlay side, so that
#     switching KAOS off leaves a complete, working Unleashed.
#   * We re-derive the collision set from the ACTUAL fetched files every time and refuse
#     to activate on anything we do not know how to resolve. Upstream moves under us.
#   * Failures are loud. A half-installed overlay is worse than a refused one.
#
# Exit codes: 0 ok · 1 usage/precondition · 2 verification refused · 3 install error

set -u

UPSTREAM_URL="https://gitlab.com/sanders.chris/phrozenarco.git"
# Which upstream branch/tag to pull. main unless someone asks otherwise, either through KAOS_REF in
# the environment or as the argument to `update` (which is how KAOS_UPDATE BRANCH=... reaches it,
# since a gcode macro cannot export an environment variable). Deliberately NOT persisted: a plain
# update always means the released version, so nobody ends up stuck on a branch they forgot they
# picked, and "which code is my printer running" has one answer rather than a stored one.
UPSTREAM_REF="${KAOS_REF:-main}"

HOME_DIR="${KAOS_HOME:-/home/mks}"
SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$SELF_DIR/.cache/upstream"
STATE="$SELF_DIR/.cache/state"
BACKUP="$SELF_DIR/.cache/backup"

CONFIG_DIR="$HOME_DIR/printer_data/config"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
PGM="$CONFIG_DIR/printer_gcode_macro.cfg"
EXTRAS="$HOME_DIR/klipper/klippy/extras/phrozen_dev"
SPIT_PATCH="$SELF_DIR/scripts/kaos-spit-patch.sh"
HOME_HOOK="$SELF_DIR/scripts/kaos-home-hook.sh"

# Modules we install. kaos_system_prep is excluded (host mutator; upstream main no longer
# includes it either). magic_ams is opt-in — see MAGIC_AMS below.
MODULES="kaos_logging kaos_fans kaos_lights kaos_safety kaos_steppers kaos_beeper
         kaos_mesh kaos_z_tilt kaos_screws_tilt kaos_print_features kaos_tools
         kaos_filament_service kaos_menu"
# magic_ams: resolved authoritatively just before the command dispatch (see bottom of
# file) — explicit KAOS_MAGIC_AMS env wins, else the persisted state (so MAGIC_AMS_OFF
# sticks), else ON by default. Default-on matches what KAOS users expect: upstream has no
# switch at all, so installing KAOS there always replaces the purge. This line is only the
# pre-resolution default. See docs/magic-ams-adaptation.md.
MAGIC_AMS="${KAOS_MAGIC_AMS:-1}"

# Declarations Unleashed owns. Stripped from the fetched KAOS files so the base wins.
# Format: "type|name" — type is section, delayed_gcode or gcode_macro.
STRIP="section|respond
section|exclude_object
section|save_variables
section|z_tilt
section|screws_tilt_adjust
section|temperature_fan board_fan
section|output_pin beeper
delayed_gcode|startup_beep
gcode_macro|Z_TILT_ADJUST
gcode_macro|SCREWS_TILT_CALCULATE"

# Pins Unleashed owns. A KAOS section claiming one of these must be in STRIP above;
# this list is the belt-and-braces check, because a renamed section still clashes by pin.
OUR_PINS="PA2 PB2"

# Container variables our bridge declares. If upstream's magic_ams starts using one we do
# not declare, the mismatch is silent until a colour change mid-print — so we check.
BRIDGE_VARS_PRZ_RUNTIME_STATE="target_extruder_temp cooling_fan_speed assist_fan_value"
BRIDGE_VARS_PRZ_GEOMETRY="z_lift_safety_margin toolchange_z_lift safe_x_offset"
BRIDGE_VARS_TOOLCHANGE_PENDING="active flush retract lifted next_temp"

say()  { echo "KAOS: $*"; }
warn() { echo "KAOS: WARNING - $*" >&2; }
# $1 = message, $2 = exit code. Must be "$1", not "$*": with $* the exit code is echoed as
# part of the message, so every guarded failure ended with a stray digit.
die()  { echo "KAOS: ERROR - $1" >&2; exit "${2:-3}"; }

# ---------------------------------------------------------------- preconditions
require_paths() {
    [ -d "$CONFIG_DIR" ] || die "config dir not found: $CONFIG_DIR" 1
    [ -f "$PRINTER_CFG" ] || die "printer.cfg not found: $PRINTER_CFG" 1
    [ -d "$EXTRAS" ]      || die "phrozen_dev not found: $EXTRAS — is this an Arco?" 1
    mkdir -p "$SELF_DIR/.cache" "$BACKUP" || die "cannot create $SELF_DIR/.cache" 1
}

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1 || true; }
state_put() {
    mkdir -p "$(dirname "$STATE")"
    local tmp; tmp="$(mktemp)"
    [ -f "$STATE" ] && grep -v "^$1=" "$STATE" > "$tmp" 2>/dev/null
    echo "$1=$2" >> "$tmp"
    mv "$tmp" "$STATE"
}

# ---------------------------------------------------------------- fetch
# We pull ONLY config/ and phrozen_dev/, shallow. The full repo is ~67 MB, of which 44 MB
# is reference/Arco_FW_V199/ — a copy of Phrozen's firmware. We need ~1.1 MB. Dragging the
# rest onto every recipient's eMMC would be wasteful and would put a third-party copy of
# Phrozen's code on printers for no reason. Sparse checkout needs git >= 2.25 (Bookworm has
# 2.39); on anything older we fall back to a shallow full checkout, which still works.
SPARSE_PATHS="config phrozen_dev"

fetch() {
    if [ -d "$CACHE/.git" ]; then
        say "updating cached upstream ($UPSTREAM_REF)"
        git -C "$CACHE" fetch --quiet --depth 1 origin "$UPSTREAM_REF" \
            || die "git fetch failed - no network?" 3
        git -C "$CACHE" reset --quiet --hard "origin/$UPSTREAM_REF" \
            || die "git reset failed" 3
    else
        say "fetching upstream (first run, needs network)"
        rm -rf "$CACHE"; mkdir -p "$(dirname "$CACHE")"
        if git clone --quiet --depth 1 --filter=blob:none --sparse \
                     --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$CACHE" 2>/dev/null \
           && git -C "$CACHE" sparse-checkout set $SPARSE_PATHS 2>/dev/null; then
            say "sparse checkout: $SPARSE_PATHS only"
        else
            warn "sparse checkout unavailable (old git?) - falling back to a shallow full clone"
            rm -rf "$CACHE"
            git clone --quiet --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$CACHE" \
                || die "git clone failed - no network?" 3
        fi
    fi
    [ -d "$CACHE/config/kaos" ]   || die "fetched tree has no config/kaos - wrong ref?" 3
    [ -d "$CACHE/phrozen_dev" ]   || die "fetched tree has no phrozen_dev - wrong ref?" 3
    UPSTREAM_COMMIT="$(git -C "$CACHE" rev-parse --short HEAD)"
    say "upstream at $UPSTREAM_REF ($UPSTREAM_COMMIT), $(du -sh "$CACHE" 2>/dev/null | cut -f1) on disk"
}

have_cache() { [ -d "$CACHE/config/kaos" ]; }

# ---------------------------------------------------------------- verification
# Everything below REFUSES rather than guesses. Upstream can change under us at any time.

# Which module files will we actually install?
selected_modules() {
    local m
    for m in $MODULES; do echo "$m"; done
    [ "$MAGIC_AMS" = "1" ] && echo "magic_ams_by_chris"
    return 0
}

# All declarations present in the files we intend to install.
fetched_declarations() {
    local files="$CACHE/config/kaos.cfg" m
    while read -r m; do
        [ -n "$m" ] && files="$files $CACHE/config/kaos/$m.cfg"
    done <<< "$(selected_modules)"
    grep -h '^\[' $files 2>/dev/null | sed 's/#.*//; s/;.*//; s/[[:space:]]*$//; s/^\[//; s/\]$//'
}

is_stripped() {   # $1 = declaration line without brackets, e.g. "gcode_macro Z_TILT_ADJUST"
    local d="$1" t n
    while IFS='|' read -r t n; do
        [ -z "$t" ] && continue
        case "$t" in
            section)      [ "$d" = "$n" ] && return 0 ;;
            *)            [ "$d" = "$t $n" ] && return 0 ;;
        esac
    done <<< "$STRIP"
    return 1
}

# Declarations Unleashed already owns, from the deployed config.
our_declarations() {
    local f
    for f in "$PRINTER_CFG" "$CONFIG_DIR/AddOn.cfg" "$CONFIG_DIR/printer_gcode_macro.cfg"; do
        [ -f "$f" ] && grep -h '^\[' "$f" 2>/dev/null
    done | sed 's/#.*//; s/;.*//; s/[[:space:]]*$//; s/^\[//; s/\]$//'
}

verify_collisions() {
    local ours d unknown=0
    ours="$(our_declarations | sort -u)"
    while read -r d; do
        [ -z "$d" ] && continue
        case "$d" in include*) continue ;; esac
        if grep -qxF "$d" <<< "$ours"; then
            if ! is_stripped "$d"; then
                warn "unhandled collision: [$d] exists on both sides and is not in the strip-list"
                unknown=1
            fi
        fi
    done <<< "$(fetched_declarations | sort -u)"

    # Pin check — a section renamed upstream no longer collides by NAME but still by PIN.
    local p kf
    for p in $OUR_PINS; do
        kf="$(grep -rlE "^[[:space:]]*pin:[[:space:]]*[!^~]*$p([[:space:]]|$)" \
              "$CACHE/config/kaos.cfg" "$CACHE/config/kaos/"*.cfg 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')"
        if [ -n "$kf" ]; then
            local owner sec_ok=1
            for owner in $kf; do
                case "$owner" in
                    kaos_beeper.cfg|kaos_fans.cfg) ;;                 # their sections are stripped
                    *) warn "pin $p is claimed by an unexpected KAOS file: $owner"; sec_ok=0 ;;
                esac
            done
            [ "$sec_ok" = 0 ] && unknown=1
        fi
    done

    [ "$unknown" = 0 ] || die "refusing to activate — resolve the collisions above first (see docs/integration-spec.md)" 2
    say "collision check passed"
}

# The silent one: magic_ams reading a container variable our bridge does not declare.
verify_container_drift() {
    [ "$MAGIC_AMS" = "1" ] || return 0
    local f="$CACHE/config/kaos/magic_ams_by_chris.cfg" macro declared used v bad=0
    [ -f "$f" ] || die "magic_ams requested but $f is missing" 2

    for macro in PRZ_RUNTIME_STATE PRZ_GEOMETRY _TOOLCHANGE_PENDING; do
        case "$macro" in
            PRZ_RUNTIME_STATE)   declared="$BRIDGE_VARS_PRZ_RUNTIME_STATE" ;;
            PRZ_GEOMETRY)        declared="$BRIDGE_VARS_PRZ_GEOMETRY" ;;
            _TOOLCHANGE_PENDING) declared="$BRIDGE_VARS_TOOLCHANGE_PENDING" ;;
        esac
        # Three access forms, and the aliased one is the common case — magic_ams does
        #   {% set GEO = printer["gcode_macro PRZ_GEOMETRY"] %}  … GEO.toolchange_z_lift
        # so a check that only looked for printer["…"].var would find almost nothing and
        # pass silently. That is a false negative in the one place we cannot afford one.
        local aliases
        aliases="$(grep -oE "set [A-Za-z_][A-Za-z_0-9]* *= *printer\[\"gcode_macro $macro\"\]" "$f" \
                   | sed -E 's/^set +([A-Za-z_][A-Za-z_0-9]*).*/\1/' | sort -u)"
        used="$( { grep -oE "gcode_macro $macro\"\]\.[a-zA-Z_0-9]+" "$f" | sed 's/.*\.//'
                   grep -oE "MACRO=$macro[[:space:]]+VARIABLE=[a-zA-Z_0-9]+" "$f" | sed 's/.*VARIABLE=//'
                   for a in $aliases; do grep -oE "\b$a\.[a-zA-Z_0-9]+" "$f" | sed 's/.*\.//'; done
                 } | sort -u )"
        for v in $used; do
            grep -qw -- "$v" <<< "$declared" || { warn "container drift: magic_ams uses $macro.$v, which config/kaos-ams-bridge.cfg does not declare"; bad=1; }
        done
    done
    [ "$bad" = 0 ] || die "refusing to activate magic_ams — update kaos-ams-bridge.cfg to match upstream" 2
    say "container check passed"
}

# ---------------------------------------------------------------- install
strip_file() {    # remove the sections Unleashed owns from a copied cfg
    local f="$1" t n
    while IFS='|' read -r t n; do
        [ -z "$t" ] && continue
        local hdr; case "$t" in section) hdr="$n" ;; *) hdr="$t $n" ;; esac
        # delete from the header up to (not including) the next section header
        awk -v h="[$hdr]" '
            $0 == h { skip=1; next }
            /^\[/   { skip=0 }
            !skip   { print }
        ' "$f" > "$f.stripped" && mv "$f.stripped" "$f"
    done <<< "$STRIP"
}

install_payload() {
    local m
    say "installing payload"
    mkdir -p "$CONFIG_DIR/kaos" || die "cannot create $CONFIG_DIR/kaos" 3

    cp -f "$CACHE/config/kaos.cfg" "$CONFIG_DIR/kaos.cfg" || die "copy kaos.cfg failed" 3
    while read -r m; do
        [ -z "$m" ] && continue
        cp -f "$CACHE/config/kaos/$m.cfg" "$CONFIG_DIR/kaos/$m.cfg" || die "copy $m failed" 3
        strip_file "$CONFIG_DIR/kaos/$m.cfg"
    done <<< "$(selected_modules)"
    strip_file "$CONFIG_DIR/kaos.cfg"

    # Drop includes and boot-restore calls for modules we did not install — otherwise every
    # boot throws an unknown-command error.
    local keep; keep="$(selected_modules | tr '\n' '|' | sed 's/|$//')"
    grep -vE "^\[include kaos/" "$CONFIG_DIR/kaos.cfg" > "$CONFIG_DIR/kaos.cfg.t"
    while read -r m; do
        [ -n "$m" ] && echo "[include kaos/$m.cfg]" >> "$CONFIG_DIR/kaos.cfg.t"
    done <<< "$(selected_modules)"
    mv "$CONFIG_DIR/kaos.cfg.t" "$CONFIG_DIR/kaos.cfg"
    grep -q 'kaos_fans'   <<< "$keep" || sed -i '/_KAOS_LOAD_PERSISTED_FAN_OPTIONS/d'   "$CONFIG_DIR/kaos.cfg"
    grep -q 'kaos_beeper' <<< "$keep" || sed -i '/_KAOS_LOAD_PERSISTED_STARTUP_SOUND/d' "$CONFIG_DIR/kaos.cfg"

    # Python. dev.py is the one VENDOR file KAOS replaces — back it up before overwriting.
    if [ ! -f "$BACKUP/dev.py" ] && [ -f "$EXTRAS/dev.py" ]; then
        cp -f "$EXTRAS/dev.py" "$BACKUP/dev.py" || die "could not back up dev.py" 3
        say "backed up the stock dev.py"
    fi
    cp -f "$CACHE/phrozen_dev/dev.py"              "$EXTRAS/dev.py"              || die "copy dev.py failed" 3
    cp -f "$CACHE/phrozen_dev/kaos_logging.py"     "$EXTRAS/"                    || die "copy kaos_logging.py failed" 3
    cp -f "$CACHE/phrozen_dev/kaos_motion_guard.py" "$EXTRAS/"                   || die "copy kaos_motion_guard.py failed" 3
    cp -f "$CACHE/phrozen_dev/kaos_translations.py" "$EXTRAS/"                   || die "copy kaos_translations.py failed" 3
    mkdir -p "$EXTRAS/lang" && cp -a "$CACHE/phrozen_dev/lang/." "$EXTRAS/lang/" || die "copy lang failed" 3

    # Drop stale bytecode. Python keys a cached .pyc on the source mtime, and a full service
    # restart could otherwise recompile-or-not inconsistently after we swap the .py files.
    # Belt-and-braces with the full restart in restart_klipper — cheap, and removes a whole
    # class of "ran the old code" confusion.
    rm -rf "$EXTRAS/__pycache__" 2>/dev/null || true

    # Our bridge files travel with the payload.
    cp -f "$SELF_DIR/config/kaos-unleashed-shims.cfg" "$CONFIG_DIR/" 2>/dev/null || true
    cp -f "$SELF_DIR/config/kaos-trust-wiring.cfg"    "$CONFIG_DIR/" || die "copy trust wiring failed" 3
    # Copy the bridge only; the printer_gcode_macro.cfg rename is done by
    # reconcile_spit_patch at the END of activate(), so the file edit always follows the
    # include edit it depends on.
    [ "$MAGIC_AMS" = "1" ] && { cp -f "$SELF_DIR/config/kaos-ams-bridge.cfg" "$CONFIG_DIR/" || die "copy ams bridge failed" 3; }
    return 0
}

# One-time move of any pre-existing standalone KAOS settings into OUR variable store,
# so a user who ran KAOS before does not silently lose their preferences.
migrate_variables() {
    local old="$CONFIG_DIR/kaos/kaos_variables.cfg" ours="$CONFIG_DIR/variables.cfg"
    [ -f "$old" ] || return 0
    [ "$(state_get migrated)" = "1" ] && return 0
    local n=0 line
    while IFS= read -r line; do
        case "$line" in kaos_*)
            grep -q "^${line%%[ =]*}" "$ours" 2>/dev/null || { echo "$line" >> "$ours"; n=$((n+1)); } ;;
        esac
    done < "$old"
    [ "$n" -gt 0 ] && say "migrated $n saved KAOS setting(s) into variables.cfg"
    state_put migrated 1
}

# ---------------------------------------------------------------- magic_ams config patch
# The ONE file edit magic_ams needs: rename the stock PRZ_SPITTING_END so the bridge's
# own PRZ_SPITTING_END is the sole declaration. Idempotent + reversible; the boot guard
# re-applies it if a Phrozen update reverts printer_gcode_macro.cfg. PHROZEN_TOOLCHANGE
# needs NO file edit — the bridge re-declares it and wins by last-include-wins because
# its include sits AFTER AddOn.cfg (see activate()).
# INVARIANT (identical to kaos-guard.sh's): the rename is applied IFF the bridge include is
# present, because exactly one thing may declare PRZ_SPITTING_END.
#   include present -> bridge declares it -> stock MUST be renamed (else the two merge)
#   include absent  -> stock MUST be present (else NOTHING declares it and every spit,
#                      PG102 initial load included, dies on "Unknown command")
# Derived from printer.cfg rather than from a flag, and always called AFTER the include
# edits, so the file edit follows the thing it depends on. If we die in between, we leave
# the loud half-state (both declared -> bridge wins, its fallback RESPONDs) rather than the
# silent-until-mid-print one; the boot guard reconciles either way.
reconcile_spit_patch() {
    [ -f "$PGM" ] && [ -f "$SPIT_PATCH" ] || { warn "cannot reconcile spit patch (missing $PGM or helper)"; return 0; }
    local want r
    if [ -n "$(include_line 'kaos-ams-bridge.cfg')" ]; then want=apply; else want=revert; fi
    r="$(bash "$SPIT_PATCH" "$want" "$PGM" 2>&1)"
    case "$r" in
        applied)  say "spit patch applied (stock PRZ_SPITTING_END renamed to _ARCO_SPITTING_END_STOCK)" ;;
        reverted) say "spit patch reverted (stock PRZ_SPITTING_END restored)" ;;
        already*) : ;;
        *)        warn "spit patch $want: $r" ;;
    esac
}

# ------------------------------------------------------------- post-home hook config patch
# The second file edit, and the one whose absence is silent. KAOS's motion guard only lets
# the machine move once _SET_TRUSTED_XYZ has run, and the only thing that calls it is
# [gcode_macro _ARCO_POST_HOME_HOOK] in our kaos-trust-wiring.cfg. But defining that macro
# does nothing on its own — something has to CALL it at the end of a home, and that call
# belongs in [homing_override], a Klipper SECTION, which cannot be wrapped from another
# file. It therefore has to exist in printer.cfg itself.
#
# The kit's printer.cfg.template carries it. The deployed printer.cfg does not get
# regenerated from that template, so every printer flashed before the template gained the
# hook — and every printer whose printer.cfg a Phrozen update has since replaced — lacks
# it. Found on hardware 2026-07-27: homing succeeded, _TRUSTED_HOME stayed 0, and the
# display's auto-mesh died on "KAOS blocked - BED_MESH_CALIBRATE requires physical trusted
# XYZ" every time. Nothing in the config explained why, because the config was not wrong
# — it was incomplete.
# INVARIANT: the call is present IFF the trust wiring is included. Keyed on printer.cfg for
# the same reason as the spit patch: state can be stale, the include line cannot.
reconcile_home_hook() {
    [ -f "$PRINTER_CFG" ] && [ -f "$HOME_HOOK" ] || { warn "cannot reconcile the post-home hook (missing $PRINTER_CFG or helper)"; return 0; }
    local want r
    if [ -n "$(include_line 'kaos-trust-wiring\.cfg')" ]; then want=apply; else want=revert; fi
    # Possibly two lines now: the homing_override body and the hook call. Exit status decides
    # success; everything reported is passed through. Same reasoning as in kaos-guard.sh.
    if ! r="$(bash "$HOME_HOOK" "$want" "$PRINTER_CFG" 2>&1)"; then
        warn "post-home hook $want: $(printf '%s' "$r" | tr '\n' ' ')"
        return 0
    fi
    printf '%s\n' "$r" | grep -vE '^[[:space:]]*(already|$)' | while IFS= read -r line; do
        [ -n "$line" ] && say "$line"
    done
}

# ---------------------------------------------------------------- activation
include_line()   { grep -nE "^[[:space:]]*\[include $1\]" "$PRINTER_CFG" | head -1 | cut -d: -f1; }
activate() {
    local anchor; anchor="$(include_line 'AddOn.cfg')"
    [ -n "$anchor" ] || die "[include AddOn.cfg] not found in printer.cfg — refusing to touch it" 3
    # Capture the pre-KAOS printer.cfg ONCE. activate() runs again on every KAOS_UPDATE and
    # MAGIC_AMS_ON, and an unguarded copy would overwrite the clean snapshot with one that
    # already carries the KAOS includes — so the emergency restore would re-inject them.
    # Same one-shot rule as the dev.py backup below.
    [ -f "$BACKUP/printer.cfg.pre-kaos" ] || cp -f "$PRINTER_CFG" "$BACKUP/printer.cfg.pre-kaos"

    # BEFORE AddOn.cfg: the base KAOS includes, so any residual duplicate section resolves
    # last-include-wins in Unleashed's favour.
    local ins=""
    [ -z "$(include_line 'kaos.cfg')" ] && ins="[include kaos.cfg]"
    [ -z "$(include_line 'kaos-unleashed-shims.cfg')" ] && ins="$ins\\n[include kaos-unleashed-shims.cfg]"
    # Trust wiring fills the kit's generic _ARCO_POST_HOME_HOOK. Without it the motion
    # guard blocks the first travel after every home.
    [ -z "$(include_line 'kaos-trust-wiring.cfg')" ] && ins="$ins\\n[include kaos-trust-wiring.cfg]"
    if [ -n "$ins" ]; then
        anchor="$(include_line 'AddOn.cfg')"
        sed -i "${anchor}i ${ins#\\n}" "$PRINTER_CFG" || die "could not add the base includes" 3
        say "base includes added before AddOn.cfg"
    fi

    # AFTER AddOn.cfg: the magic_ams bridge MUST load after AddOn.cfg so its re-declared
    # PHROZEN_TOOLCHANGE wins by last-include-wins. Inserted right after the AddOn.cfg line
    # — never appended at end-of-file (a real section after the SAVE_CONFIG block stops
    # Klipper reading the saved values, e.g. heater_bed control=pid).
    if [ "$MAGIC_AMS" = "1" ]; then
        if [ -z "$(include_line 'kaos-ams-bridge.cfg')" ]; then
            anchor="$(include_line 'AddOn.cfg')"
            sed -i "${anchor}a [include kaos-ams-bridge.cfg]" "$PRINTER_CFG" \
                || die "could not add the ams-bridge include" 3
            say "magic_ams bridge include added after AddOn.cfg"
        fi
    elif [ -n "$(include_line 'kaos-ams-bridge.cfg')" ]; then
        sed -i -E '/^[[:space:]]*\[include kaos-ams-bridge\.cfg\][[:space:]]*$/d' "$PRINTER_CFG"
        say "magic_ams bridge include removed (magic off)"
    fi

    # Includes are settled — now make printer_gcode_macro.cfg and printer.cfg match them.
    reconcile_spit_patch
    reconcile_home_hook
}
deactivate() {
    # The bridge MUST go with KAOS: its PRZ_SPITTING_END re-declaration calls ORCA_PURGE and
    # reads _USER_CONFIG / _REQUIRE_TRUSTED_XY (all from the KAOS payload), and it depends on
    # the stock section being renamed. Remove the includes AND revert the rename together, or
    # a spit would fire into a half-wired state.
    # ORDER IS DELIBERATE: the vendor dev.py goes back FIRST, while the config still matches
    # the installed Python. The two failure directions are not symmetric (see kaos-guard.sh):
    #   python restored + includes still there -> "Unknown command" storm; annoying, self-heals
    #   KAOS python left + trust wiring removed -> the motion guard arms with nothing able to
    #       grant trust: the printer homes and then refuses every travel, with a config that
    #       contains no explanation. That is the state we must never create.
    # So if we cannot restore the vendor file, refuse the whole deactivation rather than walk
    # into it. Nothing has been changed at this point, so refusing is safe.
    if [ -f "$BACKUP/dev.py" ]; then
        cp -f "$BACKUP/dev.py" "$EXTRAS/dev.py" || die "could not restore the vendor dev.py" 3
        say "restored the stock dev.py"
    elif grep -q 'kaos_motion_guard\|install_kaos_logging' "$EXTRAS/dev.py" 2>/dev/null; then
        die "KAOS's dev.py is installed but .cache/backup/dev.py is missing — refusing to
       remove the trust wiring, which would arm the motion guard with no way to grant trust.
       Restore a vendor dev.py first (kit: scripts/apply-phrozen-restore.sh, or your own
       Arco_FW_V*.zip), then run this again. See docs/removal.md." 3
    fi

    sed -i -E '/^[[:space:]]*\[include (kaos\.cfg|kaos-unleashed-shims\.cfg|kaos-trust-wiring\.cfg|kaos-ams-bridge\.cfg)\][[:space:]]*$/d' \
        "$PRINTER_CFG" || die "could not remove the includes" 3
    # Includes gone -> the invariant now demands the stock PRZ_SPITTING_END back, and the
    # post-home hook has nothing left to call. Same script run, no restart in between, so the
    # window where neither declares it is never observed.
    reconcile_spit_patch
    reconcile_home_hook
    # Same reason as install: drop stale bytecode so the restored vendor dev.py is not
    # shadowed by a cached KAOS .pyc after the full restart.
    rm -rf "$EXTRAS/__pycache__" 2>/dev/null || true
    say "payload left cached; KAOS_ON re-activates without a download"
}

# ---------------------------------------------------------------- boot guard
# kaos-guard.sh runs before every klipper start and repairs the Python that a Phrozen update
# or a Klipper hard-recover would have wiped. The leading "-" is deliberate: a failing guard
# must degrade to "KAOS missing", never to "printer will not start". Numbered 21 so it lands
# after the kit's own drop-ins (13..20).
#
# It is a PERMANENT, root-installed-once drop-in — NOT installed per toggle. Two reasons:
#   * klipper.service runs as our unprivileged user, so KAOS_ON/OFF cannot write to
#     /etc/systemd/system without a password we must never handle. Installing the guard once,
#     as root, keeps the toggle root-free.
#   * The guard is safe in every state: when KAOS is off it just ensures the vendor dev.py is
#     in place, so there is nothing to remove when KAOS is switched off.
DROPIN_DIR="/etc/systemd/system/klipper.service.d"
DROPIN="$DROPIN_DIR/21-kaos-guard.conf"

boot_guard_present() { [ -f "$DROPIN" ]; }

cmd_install_boot_guard() {
    [ "$(id -u)" = 0 ] || die "run this once as root: sudo $0 install-boot-guard" 1
    mkdir -p "$DROPIN_DIR" || die "cannot create $DROPIN_DIR" 3
    cat > "$DROPIN" <<EOF
# Arco Unleashed x KAOS — repair KAOS's klippy extras before klipper starts, and keep the
# vendor dev.py in place whenever KAOS is off. Safe in every state; leave it installed.
# Managed by: kaos-sideload.sh {install,uninstall}-boot-guard.
[Service]
ExecStartPre=-$SELF_DIR/scripts/kaos-guard.sh
EOF
    systemctl daemon-reload 2>/dev/null || true
    say "boot guard installed permanently ($DROPIN)"
}

cmd_uninstall_boot_guard() {
    [ "$(id -u)" = 0 ] || die "run this once as root: sudo $0 uninstall-boot-guard" 1
    rm -f "$DROPIN" && systemctl daemon-reload 2>/dev/null || true
    say "boot guard removed"
}

restart_klipper() {
    # A FULL klipper SERVICE restart, not FIRMWARE_RESTART. This is load-bearing and cost a
    # whole debugging session to find: KAOS_ON/OFF swap Python files in klippy/extras, and
    # Klipper's FIRMWARE_RESTART does NOT re-import Python modules — it reuses sys.modules and
    # whatever .pyc is cached. So a firmware restart leaves the OLD bytecode running and the
    # freshly-installed KAOS python (dev.py bootstrap, motion guard, _KAOS_T) never loads,
    # which manifests as an "Unknown command _KAOS_T" storm with no obvious cause. Moonraker's
    # service restart spawns a fresh klippy process that re-imports everything, and it needs no
    # root from us (Moonraker holds the privilege via polkit). Detached with a short delay so
    # the RUN_SHELL_COMMAND that invoked us returns before klipper goes down.
    say "requesting a full klipper restart (fresh python process)"
    setsid sh -c 'sleep 2; curl -s -X POST "http://localhost:7125/machine/services/restart?service=klipper" >/dev/null 2>&1' >/dev/null 2>&1 &
}

# ---------------------------------------------------------------- commands
cmd_status() {
    echo "KAOS: active   = $(state_get active || echo 0)"
    echo "KAOS: ref      = ${UPSTREAM_REF}"
    echo "KAOS: commit   = $(state_get commit || echo '(none)')"
    echo "KAOS: magic_ams= $MAGIC_AMS"
    echo "KAOS: cached   = $(have_cache && echo yes || echo no)"
    echo "KAOS: installed= $(state_get installed_at || echo '(never)')"
}

cmd_on() {
    require_paths
    have_cache || fetch
    [ -n "${UPSTREAM_COMMIT:-}" ] || UPSTREAM_COMMIT="$(git -C "$CACHE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    verify_collisions
    verify_container_drift
    install_payload
    migrate_variables
    activate
    state_put active 1; state_put commit "$UPSTREAM_COMMIT"
    state_put magic_ams "$MAGIC_AMS"        # so the boot guard knows to keep the spit patch applied
    state_put installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    boot_guard_present || warn "boot guard is NOT installed — KAOS will not survive a Phrozen update or a Klipper hard-recover. Install it once: sudo $SELF_DIR/scripts/kaos-sideload.sh install-boot-guard"
    if [ "$MAGIC_AMS" = "1" ]; then
        say "magic_ams is ON — colour changes use KAOS's ORCA_PURGE (MAGIC_AMS_STAGE STAGE=1 keeps the proven purge, MAGIC_AMS_OFF removes it)"
    else
        say "magic_ams is off — the proven bucket purge stays in place"
    fi
    say "activated (upstream $UPSTREAM_COMMIT)"
    restart_klipper
}

cmd_off() {
    require_paths
    deactivate
    state_put active 0
    say "deactivated"
    restart_klipper
}

cmd_update() {
    require_paths
    # Optional branch/tag, defaulting to main. Deliberately NOT persisted: with no stored state,
    # a plain `update` always means "the released version", and there is no way to be stuck on a
    # branch you forgot you selected. The cost is retyping it, which is the right cost for a
    # setting that decides which code the printer runs.
    if [ -n "${1:-}" ]; then
        case "$1" in
            *[!A-Za-z0-9._/-]*) die "refusing branch '$1': a branch name has no shell metacharacters" 1 ;;
        esac
        UPSTREAM_REF="$1"
        say "tracking '$UPSTREAM_REF' for this update (a plain update returns to main)"
    fi
    local was; was="$(state_get active || echo 0)"
    fetch
    verify_collisions
    verify_container_drift
    if [ "$was" = "1" ]; then
        install_payload; migrate_variables; activate
        state_put commit "$UPSTREAM_COMMIT"
        state_put magic_ams "$MAGIC_AMS"
        state_put installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        say "updated to $UPSTREAM_COMMIT and re-activated"
        restart_klipper
    else
        state_put commit "$UPSTREAM_COMMIT"
        say "updated the cache to $UPSTREAM_COMMIT — KAOS is off; run KAOS_ON to activate"
    fi
}

# Toggle the magic_ams feature on its own, without touching whether KAOS itself is on.
# The setting is persisted, so a later KAOS_ON / KAOS_UPDATE keeps it. If KAOS is active
# we re-run the install so the include + the spit patch follow immediately; if it is off
# we only record the choice, and KAOS_ON applies it.
cmd_magic() {                     # $1 = 1 (on) | 0 (off)
    require_paths
    # Same gate as the MAGIC_AMS_ON macro, for the SSH path. magic_ams only runs on the AMS
    # tool-change path, which does not exist while ams=0 (M600 fallback, T1-T15 unregistered),
    # so enabling it there restarts Klipper and patches a config file to no observable effect.
    # KAOS_FORCE=1 for the prepare-before-the-AMS-is-attached case.
    if [ "$1" = "1" ] && [ "${KAOS_FORCE:-0}" != "1" ]; then
        local ams; ams="$(sed -nE 's/^[[:space:]]*ams[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
                          "$CONFIG_DIR/variables.cfg" 2>/dev/null | head -1)"
        if [ "${ams:-0}" != "1" ]; then
            die "magic_ams needs the AMS flag on, but ams=${ams:-unset}. With no AMS every tool
       change falls back to M600 and T1-T15 are unregistered, so magic_ams cannot do anything.
       Attach the AMS, wait a few seconds for it to be detected, then retry. To install it anyway
       is attached): KAOS_FORCE=1 $0 magic-on" 1
        fi
    fi
    MAGIC_AMS="$1"                # override the dispatch-time resolution for this run
    state_put magic_ams "$MAGIC_AMS"
    if [ "$(state_get active || echo 0)" != "1" ]; then
        say "magic_ams = $MAGIC_AMS recorded — KAOS is off; run KAOS_ON to apply it"
        return 0
    fi
    have_cache || fetch
    verify_collisions
    verify_container_drift        # only meaningful (and only runs) when MAGIC_AMS=1
    install_payload
    activate                      # adds/removes the include, then reconciles the spit patch
    state_put installed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$MAGIC_AMS" = "1" ]; then
        say "magic_ams ENABLED (stage: set with MAGIC_AMS_STAGE; default 1 = per-tool temp only)"
    else
        say "magic_ams disabled — the kit's proven bucket purge is back"
    fi
    restart_klipper
}

# Verify-only: fetch and run BOTH gates, but install and activate NOTHING. Lets you see
# whether the current upstream would pass before you touch the printer — the safe first
# move in a Phase 0 test. Exit 0 = would activate cleanly, 2 = a gate refused.
cmd_check() {
    require_paths
    have_cache || fetch
    [ -n "${UPSTREAM_COMMIT:-}" ] || UPSTREAM_COMMIT="$(git -C "$CACHE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    say "verify-only against $UPSTREAM_COMMIT — nothing will be installed"
    verify_collisions
    verify_container_drift
    say "OK: this upstream would activate cleanly (nothing was changed)"
}

# Resolve magic_ams authoritatively (state_get is defined by here). Precedence:
#   1. explicit KAOS_MAGIC_AMS env
#   2. the persisted state — so an explicit MAGIC_AMS_OFF survives every later KAOS_ON
#      and KAOS_UPDATE, and is NOT overridden by the default below
#   3. unset (fresh install) -> ON, matching upstream KAOS where there is no switch at all
# state_get prints nothing for an absent key and still exits 0, so test for empty rather
# than relying on its exit status.
MAGIC_AMS="${KAOS_MAGIC_AMS:-$(state_get magic_ams 2>/dev/null)}"
[ -n "$MAGIC_AMS" ] || MAGIC_AMS=1
[ "$MAGIC_AMS" = "1" ] || MAGIC_AMS=0

# Same precedence for the upstream ref. The cache handles a changed ref by itself -- cmd_fetch does
# `fetch origin $REF` then `reset --hard origin/$REF` -- so switching branches needs no extra cleanup,
# and the two "wrong ref?" guards right after it catch a branch whose tree is not a KAOS tree.
UPSTREAM_REF="${KAOS_REF_ENV:-$(state_get ref 2>/dev/null)}"
[ -n "$UPSTREAM_REF" ] || UPSTREAM_REF=main

# Set the tracked branch. Deliberately does NOT fetch: switching branch and pulling it are separate
# decisions, and doing both at once would mean a typo'd branch name takes the printer's KAOS with it
# before anyone can read the error.
cmd_ref() {
    local want="${1:-}"
    if [ -z "$want" ]; then
        echo "tracking: $UPSTREAM_REF$([ -n "$KAOS_REF_ENV" ] && echo '  (from KAOS_REF in the environment)')"
        echo "set with:  kaos-sideload.sh ref <branch-or-tag>      then: kaos-sideload.sh update"
        return 0
    fi
    case "$want" in
        *[!A-Za-z0-9._/-]*) echo "refusing '$want': a branch name has no shell metacharacters" >&2; return 1 ;;
    esac
    if [ "$want" = main ]; then state_put ref ""; else state_put ref "$want"; fi
    echo "now tracking: $want"
    echo "nothing fetched yet — run 'update' (or KAOS_UPDATE) to pull it."
}

case "${1:-}" in
    on)                   cmd_on ;;
    off)                  cmd_off ;;
    update)               cmd_update "" ;;
    status)               cmd_status ;;
    check)                cmd_check ;;
    magic-on)             cmd_magic 1 ;;
    magic-off)            cmd_magic 0 ;;
    ref)                  cmd_ref "${2:-}" ;;
    install-boot-guard)   cmd_install_boot_guard ;;    # one-time, as root
    uninstall-boot-guard) cmd_uninstall_boot_guard ;;  # one-time, as root
    *) echo "usage: $(basename "$0") {on|off|update|status|check|magic-on|magic-off|install-boot-guard|uninstall-boot-guard}" >&2; exit 1 ;;
esac
