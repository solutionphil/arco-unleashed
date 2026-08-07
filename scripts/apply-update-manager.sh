#!/bin/bash
# apply-update-manager.sh — put Arco Unleashed into Moonraker's update manager, but only while that
# entry can actually work.
#
# WHY AN ENTRY AT ALL. Mainsail and Fluidd already show Klipper, Moonraker and the web interface in
# one panel with an Update button each. The kit was the one thing on the printer you could only
# update by leaving that panel — ARCO_UPDATE moved it into the console, and this moves it into the
# panel itself. The payoff is not just the button: `managed_services: klipper` makes Moonraker
# restart the klipper SERVICE when the update finishes, which is exactly when this project's
# self-heal guards run. Every other update route ends with "now run sudo systemctl restart klipper",
# and that is the step people skip.
#
# WHY IT IS CONDITIONAL. The image ships the kit as a FLAT COPY with no .git. Moonraker would list
# that entry as invalid and show an error in the panel to every recipient, forever, for a feature
# they never asked for. So the entry exists only once the kit is a real clone.
#
# WHY THE TEST IS LOCAL AND NOT A NETWORK PROBE. A boot without internet would fail the probe, the
# entry would be removed, and the next boot would put it back — flapping a config file that Moonraker
# re-reads on every start. The local test is also the more honest one: adoption only ever completes
# when the remote actually answered (selfupdate.sh aborts and cleans up otherwise), so a clone that
# has an origin has already proved the entry can work.
#
#   apply-update-manager.sh [moonraker.conf]
#
# Idempotent, offline, and quiet on the happy path — it runs before every Moonraker start.
# Installed by optimize-boot.sh as an ExecStartPre drop-in on moonraker.service.
set -u

CFG="${1:-$HOME/printer_data/config/moonraker.conf}"
KIT="${ARCO_KIT:-$(cd "$(dirname "$0")/.." && pwd)}"

BEGIN='# >>> arco-unleashed: update manager entry (managed) >>>'
END='# <<< arco-unleashed: update manager entry (managed) <<<'

log() { echo "  update-manager: $*"; }

[ -f "$CFG" ] || { log "$CFG not present yet — skipped"; exit 0; }

# Present anywhere, ours or not. A user who wrote their own entry keeps it: appending a second
# [update_manager arco-unleashed] is a duplicate-section error and Moonraker would refuse to start.
has_entry() { grep -qE '^\[update_manager[[:space:]]+arco-unleashed\][[:space:]]*$' "$CFG"; }
has_ours()  { grep -qF 'arco-unleashed: update manager entry (managed' "$CFG"; }

# ── enable_auto_refresh: Moonraker's own long-term net under the first-boot race ───────────────────
# Moonraker's first update check runs before the network is up, fails, and caches the result; nothing
# retries it. arco-update-refresh.service fixes that in seconds, but it is a one-shot -- a printer that
# was still offline four minutes after boot keeps the stale INVALID until someone presses refresh.
# This option (default off) registers Moonraker's own hourly timer, which is the supported way to have
# it re-check itself. Costs are bounded by Moonraker's own code, which is why it is safe to switch on:
#   * it aborts outright while Klippy is printing (`if self.kconn.is_printing()`), and
#   * after the first attempt it only runs inside refresh_window, default 00:00-05:00,
#   * and moonraker is pinned to CPU 0/1 while klippy owns CPU 3 alone -- git inherits that mask.
# Idempotent, and only ever touches the bare [update_manager] section, never a named one.
ensure_auto_refresh() {
    grep -qE '^\[update_manager\][[:space:]]*$' "$CFG" || return 0
    # Already set either way -> leave the owner's choice alone.
    awk '
        /^\[update_manager\][[:space:]]*$/ { inblk = 1; next }
        /^\[/                              { inblk = 0 }
        inblk && /^[[:space:]]*enable_auto_refresh[[:space:]]*:/ { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$CFG" && return 0
    local t; t="$(mktemp)" || return 0
    awk -v line="enable_auto_refresh: True" '
        { print }
        /^\[update_manager\][[:space:]]*$/ && !done {
            print "# Added by Arco Unleashed: Moonraker re-checks itself, so a first boot that came up"
            print "# without a network does not leave the update manager stuck on INVALID for good."
            print "# It never refreshes while a print is running, and after the first attempt only"
            print "# inside refresh_window (default 00:00-05:00)."
            print line
            done = 1
        }
    ' "$CFG" > "$t" || { rm -f "$t"; return 0; }
    # Same paranoia as below: a moonraker.conf that will not parse stops the printer's web stack dead.
    if [ "$(grep -cE '^\[update_manager\][[:space:]]*$' "$t")" -eq 1 ] \
       && [ "$(grep -c . "$t")" -ge "$(grep -c . "$CFG")" ]; then
        cat "$t" > "$CFG"; log "enabled Moonraker's own auto-refresh (hourly, never during a print)"
    fi
    rm -f "$t"
}
ensure_auto_refresh

want=absent
ORIGIN=""
if [ -d "$KIT/.git" ]; then
    ORIGIN="$(git -C "$KIT" remote get-url origin 2>/dev/null || true)"
    [ -n "$ORIGIN" ] && want=present
fi

if [ "$want" = present ]; then
    has_entry && exit 0                       # already there — ours or the owner's, either is fine
    # `|| echo main` is NOT enough here: in a repository with no commits yet, rev-parse prints "HEAD"
    # AND exits non-zero, so both sides run and BRANCH becomes two lines -- which lands a bare "main"
    # in moonraker.conf as an option with no key, and Moonraker then refuses to start at all. Take the
    # first line only, then decide. Caught by the offline test, not by a printer.
    BRANCH="$(git -C "$KIT" rev-parse --abbrev-ref HEAD 2>/dev/null | head -1)"
    case "$BRANCH" in ''|HEAD) BRANCH=main;; esac   # unborn or detached: name the release branch

    tmp="$(mktemp)" || { log "mktemp failed"; exit 0; }
    cp "$CFG" "$tmp" || { rm -f "$tmp"; log "could not read $CFG"; exit 0; }
    # A file that does not end in a newline would otherwise glue the section onto the last line.
    [ -n "$(tail -c1 "$tmp")" ] && printf '\n' >> "$tmp"
    cat >> "$tmp" <<EOF

$BEGIN
# Added automatically because the kit is a git clone. Removed again if it stops being one.
# managed_services overrides is_system_service, so klipper — not a service named after this
# section — is what gets restarted, and the self-heal guards run with it.
[update_manager arco-unleashed]
type: git_repo
path: $KIT
origin: $ORIGIN
primary_branch: $BRANCH
managed_services: klipper
$END
EOF

    # Verify on the REWRITTEN file. A moonraker.conf with a duplicate or malformed section stops
    # Moonraker from starting, which takes the whole web interface down with it.
    #
    # The line check is the one that earns its keep. Counting section headers passed a block that had
    # a stray bare word in it -- an option with no key, fatal to Moonraker, invisible to a header
    # count. So every line of OUR block must be a marker, a comment, the section header, or a
    # "key: value" pair; anything else and the file is left exactly as it was.
    if [ "$(grep -cE '^\[update_manager[[:space:]]+arco-unleashed\][[:space:]]*$' "$tmp")" -ne 1 ] \
       || ! grep -qE '^\[update_manager\][[:space:]]*$' "$tmp"; then
        rm -f "$tmp"; log "post-edit check failed (sections) — $CFG left untouched"; exit 0
    fi
    if awk '
        /arco-unleashed: update manager entry \(managed/ { inblk = 1 - inblk; next }
        inblk && !/^#/ && !/^\[update_manager[[:space:]]+arco-unleashed\][[:space:]]*$/ \
              && !/^[a-z_]+:[[:space:]]*[^[:space:]]/ && !/^[[:space:]]*$/ { bad = 1 }
        END { exit bad ? 1 : 0 }
    ' "$tmp"; then :; else
        rm -f "$tmp"; log "post-edit check failed (malformed line in the block) — $CFG left untouched"; exit 0
    fi
    cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; log "could not write $CFG"; exit 0; }
    log "added [update_manager arco-unleashed] — the kit now appears in Mainsail/Fluidd"
    exit 0
fi

# want=absent: take back only what we put there. An entry someone wrote themselves is theirs.
has_ours || exit 0
tmp="$(mktemp)" || { log "mktemp failed"; exit 0; }
awk '
    /arco-unleashed: update manager entry \(managed/ { skip = 1 - skip; next }
    !skip
' "$CFG" > "$tmp" || { rm -f "$tmp"; log "rewrite failed"; exit 0; }

if grep -qF 'arco-unleashed: update manager entry (managed' "$tmp" \
   || ! grep -qE '^\[update_manager\][[:space:]]*$' "$tmp"; then
    rm -f "$tmp"; log "post-edit check failed — $CFG left untouched"; exit 0
fi
cat "$tmp" > "$CFG" && rm -f "$tmp" || { rm -f "$tmp"; log "could not write $CFG"; exit 0; }
log "removed [update_manager arco-unleashed] — the kit is no longer a git clone"
