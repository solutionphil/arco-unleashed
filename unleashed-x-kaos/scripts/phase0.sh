#!/bin/bash
# phase0.sh — the on-printer Phase 0 helper for the Unleashed x KAOS bridge.
#
# Phase 0 does NOT test whether KAOS works. It tests one thing only: that turning the
# bridge on and off again is CLEAN and REVERSIBLE — that after KAOS_OFF the printer is
# byte-for-byte the machine it was before KAOS was ever installed. Everything behavioural
# (motion guard, menu, magic_ams) is a later phase, gated on Phase 0 passing.
#
# It is read-only. It never activates, deactivates or edits anything — the toggles are
# console commands (KAOS_ON / KAOS_OFF) that you run yourself. This script only captures a
# "today" snapshot and, later, tells you whether you are back to it.
#
#   phase0.sh preflight   read-only checks before you touch anything
#   phase0.sh baseline    snapshot the current (KAOS-never-installed) state
#   phase0.sh compare     diff the current state against the baseline
#
# Run baseline FIRST, before the very first KAOS_ON. Run compare after each KAOS_OFF.

set -u

HOME_DIR="${KAOS_HOME:-/home/mks}"
CONFIG_DIR="$HOME_DIR/printer_data/config"
PRINTER_CFG="$CONFIG_DIR/printer.cfg"
EXTRAS="$HOME_DIR/klipper/klippy/extras/phrozen_dev"
SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="$SELF_DIR/.cache/phase0-baseline"

ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; RC=1; }
note() { echo "  [ ..]  $*"; }

# A stable fingerprint of everything that must return to baseline after KAOS_OFF.
fingerprint() {
    echo "## printer.cfg includes"
    grep -nE '^[[:space:]]*\[include' "$PRINTER_CFG" 2>/dev/null | sed 's/^/include: /'
    echo "## printer.cfg sha"
    sha256sum "$PRINTER_CFG" 2>/dev/null | awk '{print $1}'
    # printer_gcode_macro.cfg carries the magic_ams spit-patch rename (stock PRZ_SPITTING_END
    # -> _ARCO_SPITTING_END_STOCK). Without this line the single most dangerous leftover of a
    # bad removal — a renamed section with nothing declaring PRZ_SPITTING_END — would pass
    # `compare` unnoticed, because it lives in a file the fingerprint never looked at.
    echo "## printer_gcode_macro.cfg sha"
    sha256sum "$CONFIG_DIR/printer_gcode_macro.cfg" 2>/dev/null | awk '{print $1}'
    echo "## dev.py sha"
    sha256sum "$EXTRAS/dev.py" 2>/dev/null | awk '{print $1}'
    echo "## phrozen_dev listing"
    ls -1 "$EXTRAS" 2>/dev/null | sort
    echo "## config dir listing"
    ls -1 "$CONFIG_DIR" 2>/dev/null | sort
    echo "## kaos state"
    echo "active=$(sed -n 's/^active=//p' "$SELF_DIR/.cache/state" 2>/dev/null | head -1)"
}

cmd_preflight() {
    RC=0
    echo "Phase 0 preflight — read-only"
    [ -f "$PRINTER_CFG" ] && ok "printer.cfg present" || bad "printer.cfg missing"
    [ -d "$EXTRAS" ]      && ok "phrozen_dev present" || bad "phrozen_dev missing (is this an Arco?)"

    # The trust wiring only fires if the DEPLOYED printer.cfg carries the kit's post-home
    # hook. The kit template has it, but printer.cfg is not auto-redeployed, so a printer
    # baked before that change will not have it — and KAOS's motion guard would then block
    # travel after homing with nothing to grant trust. Check for it explicitly.
    if grep -q '_ARCO_POST_HOME_HOOK' "$PRINTER_CFG" 2>/dev/null; then
        ok "post-home hook present in the deployed printer.cfg"
    else
        bad "post-home hook MISSING in printer.cfg — add the _ARCO_POST_HOME_HOOK block before"
        echo "         homing_override_end, or the motion guard will block travel after homing."
        echo "         (see docs/phase0-runbook.md, Prerequisite P2)"
    fi

    command -v git >/dev/null && ok "git available" || bad "git missing — KAOS_ON cannot fetch"
    if systemctl is-active --quiet klipper 2>/dev/null; then ok "klipper service is active"; else note "klipper not active right now"; fi

    # Never run the toggle mid-print.
    local st; st="$(printf '%s' "$(command -v curl >/dev/null && curl -s http://localhost:7125/printer/objects/query?print_stats 2>/dev/null)")"
    case "$st" in
        *'"state": "printing"'*|*'"state":"printing"'*|*'"state": "paused"'*|*'"state":"paused"'*)
            bad "a print is running or paused — do NOT run Phase 0 now" ;;
        *)  ok "no print running (or status unavailable — confirm the printer is idle by hand)" ;;
    esac
    echo; [ "$RC" = 0 ] && echo "preflight PASSED" || echo "preflight FAILED — resolve the above first"
    return "$RC"
}

cmd_baseline() {
    if [ -f "$SNAP" ]; then
        echo "A baseline already exists ($SNAP)."
        echo "Delete it only if you are re-establishing 'today' on a KAOS-free printer:"
        echo "    rm '$SNAP'"
        return 1
    fi
    # Match the TOGGLE includes only, not kaos-bridge.cfg. kaos-bridge.cfg is the permanent
    # console front door (KAOS_ON/OFF/STATUS) and is present in the clean, KAOS-off state by
    # design; the toggle includes below are what activation adds and deactivation removes.
    if grep -qE '^[[:space:]]*\[include (kaos\.cfg|kaos-unleashed-shims\.cfg|kaos-trust-wiring\.cfg|kaos-ams-bridge\.cfg)\]' "$PRINTER_CFG" 2>/dev/null; then
        echo "REFUSING: printer.cfg already has KAOS active (a toggle include is present)."
        echo "Baseline must be captured with KAOS off — run KAOS_OFF first."
        return 1
    fi
    mkdir -p "$(dirname "$SNAP")"
    fingerprint > "$SNAP"
    echo "Baseline captured: $SNAP"
    echo "This is the state the printer must return to after KAOS_OFF."
}

cmd_compare() {
    [ -f "$SNAP" ] || { echo "No baseline. Run 'phase0.sh baseline' first (before any KAOS_ON)."; return 1; }
    local now; now="$(mktemp)"; fingerprint > "$now"
    # Verdict on the LOAD-BEARING fields only: everything up to (not including) the phrozen_dev
    # listing — i.e. printer.cfg includes, printer.cfg sha, dev.py sha. Those are what KAOS_OFF
    # actively restores and must return byte-for-byte. The two listings and 'active=' deliberately
    # gain the cached payload KAOS_OFF leaves for instant re-activation, so comparing them would
    # flag a clean toggle as dirty — they are excluded from the pass/fail.
    crit() { awk '/^## phrozen_dev listing/{exit} {print}' "$1"; }
    if diff <(crit "$SNAP") <(crit "$now") > /tmp/phase0.crit.diff 2>&1; then
        echo "PASS — printer.cfg (includes + sha) and dev.py are byte-identical to baseline."
        echo "The reversal is clean. (Cached kaos*.cfg / kaos_*.py and 'active=' remain by design,"
        echo " so KAOS_ON re-activates with no download.)"
        rm -f "$now"; return 0
    else
        echo "FAIL — a load-bearing field changed after KAOS_OFF (this is a real leak):"
        sed 's/^/    /' /tmp/phase0.crit.diff
        rm -f "$now"; return 1
    fi
}

case "${1:-}" in
    preflight) cmd_preflight ;;
    baseline)  cmd_baseline ;;
    compare)   cmd_compare ;;
    *) echo "usage: $(basename "$0") {preflight|baseline|compare}" >&2; exit 1 ;;
esac
