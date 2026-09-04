#!/bin/bash
# kaos-guard.sh — ExecStartPre guard, runs before every klipper start.
#
# Problem it solves: KAOS's Python lives in klippy/extras/phrozen_dev/, which is neither
# ours nor stable ground.
#   * A Phrozen firmware update replaces the whole phrozen_dev directory -> KAOS's dev.py
#     bootstrap and its three modules are gone.
#   * A Klipper hard recover (git reset --hard + git clean) deletes untracked files inside
#     the Klipper tree -> same result. This has already cost this project a different
#     extra once.
# In both cases the config still says [include kaos.cfg], so klippy comes up expecting
# commands that no longer exist.
#
# THE HALF-STATE IS THE DANGEROUS ONE. The two failure directions are not symmetric:
#   config present + python missing -> "Unknown command" storms; the menu is dead.
#   python present + config missing -> WORSE. dev.py's bootstrap still installs the motion
#       guard, so it arms and blocks every travel after homing — but the trust wiring that
#       would grant trust lives in the config that just disappeared. A printer that homes
#       and then refuses to move, with nothing in the config to explain why.
# So this guard does not just "reinstall things". It makes the Python match the config.
#
# Installed and removed by kaos-sideload.sh via a systemd drop-in. Wired with a leading
# "-" in ExecStartPre so that a failure here can never stop klipper from starting: a
# broken guard must degrade to "KAOS missing", never to "printer down".
#
# Idempotent and quiet on the happy path — it runs before every single klipper start.

set -u

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$SELF_DIR/.cache/upstream"
STATE="$SELF_DIR/.cache/state"
BACKUP="$SELF_DIR/.cache/backup"

HOME_DIR="${KAOS_HOME:-/home/mks}"
CONFIG_DIR="$HOME_DIR/printer_data/config"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
PGM="$CONFIG_DIR/printer_gcode_macro.cfg"
EXTRAS="$HOME_DIR/klipper/klippy/extras/phrozen_dev"
SPIT_PATCH="$SELF_DIR/scripts/kaos-spit-patch.sh"
HOME_HOOK="$SELF_DIR/scripts/kaos-home-hook.sh"

PY_FILES="kaos_logging.py kaos_motion_guard.py kaos_translations.py"

log() { echo "kaos-guard: $*"; }

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1 || true; }
state_put() {
    [ -f "$STATE" ] || return 0
    local tmp; tmp="$(mktemp)" || return 0
    grep -v "^$1=" "$STATE" > "$tmp" 2>/dev/null
    echo "$1=$2" >> "$tmp"
    mv "$tmp" "$STATE"
}

# Is the dev.py currently in place KAOS's, or the vendor's?
dev_py_is_kaos() { grep -q 'kaos_motion_guard\|install_kaos_logging' "$EXTRAS/dev.py" 2>/dev/null; }

restore_stock_dev_py() {
    [ -f "$BACKUP/dev.py" ] || { log "no stock dev.py backup — leaving as-is"; return 1; }
    cp -f "$BACKUP/dev.py" "$EXTRAS/dev.py" && log "restored the stock dev.py"
}

# --- INVARIANT: PRZ_SPITTING_END must always resolve ------------------------
# Exactly one thing may declare PRZ_SPITTING_END:
#   bridge included  -> the bridge declares it, so the STOCK section must be RENAMED
#                       to _ARCO_SPITTING_END_STOCK (else two declarations merge)
#   bridge absent    -> the stock section must be present under its own name
#                       (else NOTHING declares it and every spit -- PG102 initial load
#                        included, not just AMS changes -- dies on "Unknown command")
# The second half-state is the dangerous one: Klipper still BOOTS (an unknown command
# inside a macro body is a runtime error), so it surfaces only when a print reaches the
# spit and then aborts mid-job.
#
# Keyed on what is ACTUALLY in printer.cfg, not on our saved state, and run BEFORE every
# exit path below. State can be stale or half-written (an interrupted KAOS_ON, a restored
# printer.cfg, a Phrozen update replacing one file but not the other); the include line is
# ground truth for which macro set is loading. This is what makes every half-state
# self-heal on the next boot instead of persisting silently.
# Our own bridge configs are copied into printer_data/config when KAOS is ACTIVATED, and never
# again. A kit update refreshes $SELF_DIR/config (it is inside the kit clone) but not the copies,
# so a printer that has had KAOS on since before an update keeps running the old ones -- the same
# "the correction never reaches the printer" shape this project keeps meeting. Keyed on the include
# line actually present in printer.cfg, like sync_spit_patch above: a file whose include is gone is
# not put back, so KAOS_OFF stays off. KAOS's OWN files come from $CACHE and are not touched here.
sync_bridge_configs() {
    [ -d "$SELF_DIR/config" ] && [ -f "$PRINTER_CFG" ] || return 0
    local src name
    for src in "$SELF_DIR"/config/*.cfg; do
        [ -f "$src" ] || continue
        name="$(basename "$src")"
        grep -qE "^[[:space:]]*\[include[[:space:]]+${name//./\.}\]" "$PRINTER_CFG" 2>/dev/null || continue
        cmp -s "$src" "$CONFIG_DIR/$name" && continue
        if cp -f "$src" "$CONFIG_DIR/$name"; then
            log "refreshed $name from the kit — the installed copy was older than this kit"
        else
            log "WARNING - could not refresh $name"
        fi
    done
}

sync_spit_patch() {
    [ -f "$SPIT_PATCH" ] && [ -f "$PGM" ] && [ -f "$PRINTER_CFG" ] || return 0
    local want r
    if grep -qE '^[[:space:]]*\[include kaos-ams-bridge\.cfg\]' "$PRINTER_CFG" 2>/dev/null; then
        want=apply
    else
        want=revert
    fi
    r="$(bash "$SPIT_PATCH" "$want" "$PGM" 2>&1)"
    case "$r" in
        applied)  log "re-applied the spit patch — the bridge is included, so the stock PRZ_SPITTING_END had to be renamed" ;;
        reverted) log "reverted the spit patch — the bridge is not included, so the stock PRZ_SPITTING_END had to come back" ;;
        already*) : ;;                     # happy path, silent
        *)        log "WARNING - spit patch $want: $r" ;;
    esac
}

# --- INVARIANT: a completed home must be able to reach KAOS ------------------
# The motion guard only stands down once _SET_TRUSTED_XYZ runs, and the only caller is
# [gcode_macro _ARCO_POST_HOME_HOOK] in kaos-trust-wiring.cfg. That macro is useless
# without a CALL at the end of [homing_override] — and [homing_override] is a Klipper
# SECTION, so the call cannot be added from another file; it has to be in printer.cfg.
#
# A Phrozen update ships its own printer.cfg and takes the call with it. What is left is
# the WORST half-state this guard exists for: the trust wiring still loads, the motion
# guard still arms, and nothing can ever grant trust — the printer homes and then refuses
# to move, and every mesh calibration is rejected as "requires physical trusted XYZ" with
# nothing in the config to explain it. Observed on hardware 2026-07-27.
#
# Keyed on the include line, exactly like the spit patch, and run before every exit path.
sync_home_hook() {
    [ -f "$PRINTER_CFG" ] || return 0
    local want r
    if grep -qE '^[[:space:]]*\[include kaos-trust-wiring\.cfg\]' "$PRINTER_CFG" 2>/dev/null; then
        want=apply
    else
        want=revert
    fi
    # A bridge older than 2026-07-27 has no kaos-home-hook.sh at all. Returning quietly in that
    # case is how this guard used to walk straight past the very half-state described above: the
    # wiring is included, the motion guard arms, and there is nothing on the printer that can add
    # the call — so homing can never grant trust and every travel stays blocked, silently. The
    # missing helper cannot be conjured here; being loud about it is the whole remedy, because the
    # log is the only place the owner can find out why the printer homes and then refuses to move.
    if [ ! -f "$HOME_HOOK" ]; then
        [ "$want" = apply ] && log "WARNING - kaos-trust-wiring.cfg is included, but this bridge has no scripts/kaos-home-hook.sh. Nothing can add the post-home hook to [homing_override], so homing will NEVER grant trust and KAOS blocks every travel. Update the unleashed-x-kaos bridge."
        return 0        # want=revert: nothing to undo, silence is correct
    fi
    # The helper reports on TWO edits now -- the homing_override body and the hook call -- so it can
    # print more than one line. Matching a single word against its whole output, as this used to,
    # turned a successful body swap into a spurious WARNING. Judge by exit status, then pass through
    # what it actually did. "already ..." stays silent: this runs before every klipper start.
    if ! r="$(bash "$HOME_HOOK" "$want" "$PRINTER_CFG" 2>&1)"; then
        log "WARNING - post-home hook $want failed: $(printf '%s' "$r" | tr '\n' ' ')"
        return 0
    fi
    printf '%s\n' "$r" | grep -vE '^[[:space:]]*(already|$)' | while IFS= read -r line; do
        [ -n "$line" ] && log "$line"
    done
}

# ---------------------------------------------------------------------------
[ -d "$EXTRAS" ] || exit 0                       # not an Arco / nothing to guard

# All three run on EVERY path, including the two early exits below.
# Refresh our own bridge configs BEFORE the spit patch reconciles: that patch renames a macro in
# printer_gcode_macro.cfg to match what the bridge declares, so the bridge has to be the current
# one first or the two describe different files.
sync_bridge_configs
sync_spit_patch
sync_home_hook

active="$(state_get active || echo 0)"

if [ "$active" != "1" ]; then
    # KAOS is off. If its dev.py somehow survived a KAOS_OFF that could not complete,
    # put the vendor's back — an armed motion guard with no trust wiring is the one state
    # we must never boot into.
    if dev_py_is_kaos; then
        log "KAOS is off but its dev.py is still installed — restoring the vendor file"
        restore_stock_dev_py
    fi
    exit 0
fi

# KAOS is meant to be active. Does the config still say so?
if ! grep -qE '^[[:space:]]*\[include kaos\.cfg\]' "$PRINTER_CFG" 2>/dev/null; then
    # The config was replaced under us — almost certainly a Phrozen update shipping its
    # own printer.cfg, which also drops [include AddOn.cfg]. Do NOT silently re-add the
    # includes: that would paper over a printer.cfg that has lost far more than KAOS.
    # Make the Python match the (now KAOS-less) config instead, so the machine boots into
    # a coherent state, and record why.
    log "[include kaos.cfg] is gone from printer.cfg — the config was replaced"
    log "disabling KAOS to match; run KAOS_ON after restoring printer.cfg"
    dev_py_is_kaos && restore_stock_dev_py
    state_put active 0
    state_put disabled_reason "printer.cfg lost its includes (config replaced) - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
fi

# Config says KAOS is on. Make sure the Python is actually there.
[ -d "$CACHE/phrozen_dev" ] || { log "payload cache missing — cannot repair; run KAOS_UPDATE"; exit 0; }

repaired=0
if ! dev_py_is_kaos; then
    if [ -f "$EXTRAS/dev.py" ] && [ ! -f "$BACKUP/dev.py" ]; then
        # A Phrozen update may have shipped a NEWER vendor dev.py than the one captured at
        # install time. Grab it before we overwrite, or a later KAOS_OFF would restore a
        # stale vendor file. mkdir first: this guard runs standalone at boot and must not
        # assume kaos-sideload.sh has created the directory.
        # Log only on real success — a false "captured" here is worse than no message,
        # because KAOS_OFF depends on that backup existing.
        if mkdir -p "$BACKUP" && cp -f "$EXTRAS/dev.py" "$BACKUP/dev.py"; then
            log "captured a new stock dev.py as the restore point"
        else
            log "WARNING - could not back up the vendor dev.py; KAOS_OFF may restore a stale one"
        fi
    fi
    cp -f "$CACHE/phrozen_dev/dev.py" "$EXTRAS/dev.py" && { log "reinstalled the KAOS dev.py bootstrap"; repaired=1; }
fi

for f in $PY_FILES; do
    if [ ! -f "$EXTRAS/$f" ]; then
        cp -f "$CACHE/phrozen_dev/$f" "$EXTRAS/$f" && { log "reinstalled $f"; repaired=1; }
    fi
done

if [ ! -d "$EXTRAS/lang" ] || [ -z "$(ls -A "$EXTRAS/lang" 2>/dev/null)" ]; then
    mkdir -p "$EXTRAS/lang"
    cp -a "$CACHE/phrozen_dev/lang/." "$EXTRAS/lang/" && { log "reinstalled the language files"; repaired=1; }
fi

# (The spit patch is reconciled by sync_spit_patch at the top — it must run on every path,
# including the early exits, so it cannot live down here.)

[ "$repaired" = 1 ] && log "repair complete — KAOS python restored after an update or recover"
exit 0
