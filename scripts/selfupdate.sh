#!/bin/bash
# selfupdate.sh — check for / apply updates to this migration kit from GitHub.
# Requires the kit to be a GIT CLONE on the printer:
#   git clone https://github.com/solutionphil/arco-unleashed ~/arco-unleashed
#
# Usage:
#   bash selfupdate.sh check        # is a newer version on GitHub? (show changelog)
#   bash selfupdate.sh update       # pull the latest (fast-forward)
#   bash selfupdate.sh adopt        # make the image's flat copy updatable (one time, keeps your files)
#   bash selfupdate.sh auto on|off  # daily auto-update via systemd timer
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$DIR/.." && pwd)"
SVC=/etc/systemd/system/arco-kit-update.service
TMR=/etc/systemd/system/arco-kit-update.timer
# "This kit needs optimize-boot.sh run once, and it needs root." Written here as the klipper user,
# acted on at the next boot by ensure-imageid.sh, which is the one guard that runs as root.
#
# Deliberately NOT inside the kit: an untracked file in the repository is what makes the next `git pull`
# refuse, and we have already lost an update to exactly that. printer_data is beside the kit, is the
# owner's, and survives kit updates.
RECONCILE_MARK="$(cd "$KIT/.." && pwd)/printer_data/.arco-reconcile-pending"
cd "$KIT"

# Overridable so a fork can be adopted instead, and so the adoption path can be exercised against a
# local repository without a network -- which is the only way to test it before the repo is public.
REMOTE_URL="${ARCO_KIT_REMOTE:-https://github.com/solutionphil/arco-unleashed}"

# ── adoption ──────────────────────────────────────────────────────────────────────────────────────
# The kit inside the shipped image is a FLAT COPY (git archive output; there is deliberately no .git,
# because bundling the full history would bloat the image and hand every recipient the project's whole
# past). The consequence went unnoticed for a long time: this script requires a clone, so menu item 6
# dead-ended for EVERY image user with "not a git clone -> updates not possible". Making the repository
# public would not have changed that -- there was nothing on the printer to pull into.
#
# Adoption turns the flat copy into a clone in place, without re-downloading the kit: init, add the
# remote, fetch, then point HEAD at the commit the copy was built from. That last part is why the bake
# stamps .kit-commit -- see image-toolbox/build-kit-tar.sh. Knowing it means `check` can show a real
# changelog ("14 new commits, here they are") instead of an undifferentiated diff, and any local edits
# the owner made stay visible as modifications rather than being silently reverted.
#
# `reset --mixed`, never --hard: it moves HEAD and the index but does not touch a single file on disk.
# A wrong guess about the baseline therefore costs a confusing `git status`, not somebody's work.
adopt(){
  if [ -d .git ]; then echo "Already a git clone — nothing to adopt."; return 0; fi
  command -v git >/dev/null 2>&1 || { echo "git is not installed."; return 1; }
  echo "This kit is a flat copy, so it cannot pull updates yet."
  echo "Adopting it: the files stay exactly as they are, and git is taught where they came from."
  git init -q . || { echo "git init failed"; return 1; }
  local created_git=1          # we made it in this run, so we may remove it again on failure
  git remote add origin "$REMOTE_URL" 2>/dev/null || git remote set-url origin "$REMOTE_URL"
  echo "  fetching $REMOTE_URL ..."
  # GIT_TERMINAL_PROMPT=0 is not optional here. Against a private or moved repository git otherwise
  # asks for a username on the terminal and the setup menu simply stops, with no indication that it is
  # waiting for input rather than working. Fail fast and say why instead.
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true git fetch --quiet origin 2>/dev/null; then
    echo "  fetch FAILED — no internet, or the repository is not publicly reachable."
    # Leave NOTHING behind. A half-initialised .git is worse than none: the next attempt would see a
    # directory that looks like a clone, skip adoption entirely, and then fail in 'check' against a
    # repository with no refs -- an error much harder to read than this one. Only ever removes the
    # .git this function created moments ago, never a real clone.
    if [ "$created_git" = 1 ] && [ ! -e .git/refs/remotes/origin/HEAD ]; then
      rm -rf .git && echo "  Left exactly as it was; run this again when online."
    fi
    return 1
  fi
  local base=""
  if [ -f .kit-commit ]; then
    base="$(tr -dc '0-9a-f' < .kit-commit | head -c 40)"
    git cat-file -e "$base^{commit}" 2>/dev/null || {
      echo "  the stamped commit ${base:0:8} is not in the fetched history — falling back"; base=""; }
  fi
  if [ -z "$base" ]; then
    base="$(git rev-parse origin/main 2>/dev/null)"
    echo "  no usable build stamp; assuming this copy matches the latest published version."
    echo "  If it does not, 'git status' will show the difference — nothing is overwritten."
  else
    echo "  this copy was built from ${base:0:8}"
  fi
  git reset --mixed -q "$base" || { echo "  could not set the baseline"; return 1; }
  # update-ref, NOT `git branch -f`: git refuses to force-move a branch that is currently checked out,
  # and after `git init` with init.defaultBranch=main that is precisely the branch being created here.
  # The old line hid that behind `2>/dev/null || true`, and the next line then pointed HEAD at a branch
  # that had never been written. update-ref has no such restriction.
  git update-ref refs/heads/main "$base" || { echo "  could not create the main branch"; return 1; }
  git symbolic-ref HEAD refs/heads/main
  git branch -q --set-upstream-to=origin/main main 2>/dev/null || true
  # Never report success without checking it. This function used to print "Adopted. Updates work from
  # now on." unconditionally -- and on 2026-08-14 a tester's printer had a .git/refs/heads/main that a
  # power cut had left as an EMPTY FILE. Every git command answered "reference broken", Moonraker showed
  # the kit as version "?" and INVALID, and nothing anywhere connected the two. One cheap check turns an
  # hour of guessing into a sentence, and names the repair instead of describing the damage.
  if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    echo "  ADOPTION INCOMPLETE — HEAD does not resolve to a commit." >&2
    echo "  The branch reference is missing or unreadable. Repair it with:" >&2
    echo "    cd $PWD && rm -f .git/refs/heads/main \\" >&2
    echo "      && git update-ref refs/heads/main origin/main \\" >&2
    echo "      && git symbolic-ref HEAD refs/heads/main && git reset --hard main" >&2
    return 1
  fi
  echo "Adopted. Updates work from now on."
  if ! git diff --quiet 2>/dev/null; then
    echo "Note: some files differ from that baseline — your own edits, or files the image adjusted."
    echo "They are untouched; 'update' stashes them before pulling. See them with: git -C $KIT status"
  fi
  return 0
}

if [ ! -d .git ]; then
  case "${1:-check}" in
    adopt) adopt; exit $?;;
    # `console` is what ARCO_UPDATE calls: adopt if needed, then update, in ONE run. Two separate
    # RUN_SHELL_COMMAND calls cannot do this, because Klipper's macro layer never sees the exit
    # code -- a failed adopt was followed by an update that explained the same problem in different
    # words, which reads like two unrelated errors. Failing here stops before that second message.
    console) adopt || exit 1;;
    # Name the CONSOLE route first. ARCO_UPDATE_CHECK prints this message verbatim into Mainsail
    # and Fluidd, so it is read at least as often from there as from a shell -- and sending someone
    # to a shell prompt they are not standing at is the exact dead end those commands exist to
    # remove. ARCO_UPDATE adopts on its own, so from the console there is nothing else to do.
    *) echo "This kit is a flat copy from the image, so it has nothing to pull from yet."
       echo "Turn it into an updatable clone — keeps your files, downloads no kit:"
       echo "  in the Mainsail/Fluidd console:  ARCO_UPDATE     (adopts, then updates)"
       echo "  in a shell:                      bash selfupdate.sh adopt"
       echo "(The setup menu also offers it under 'Check for updates'.)"; exit 1;;
  esac
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

check(){
  # ARCO_UPDATE_CHECK prints this straight into the Mainsail/Fluidd console, which is where a beta
  # tester actually lives. The setup menu warns once, at the moment of switching, and after that nothing
  # does -- from then on an unvalidated change arrives through the same button as any other. On beta,
  # "update available" means something different, so say which channel every single time.
  [ "$BRANCH" = main ] || {
    echo "Channel: $BRANCH — changes here are NOT validated yet."
    echo "Back to stable:  bash ~/arco-unleashed/scripts/channel.sh stable"; }
  git fetch --quiet origin "$BRANCH" || { echo "fetch failed (no network / remote?)"; exit 1; }
  local l r; l=$(git rev-parse HEAD); r=$(git rev-parse "origin/$BRANCH")
  if [ "$l" = "$r" ]; then
    echo "Kit is up to date ($BRANCH @ ${l:0:7})."
    return 1
  fi
  echo "Update available: $(git rev-list --count "HEAD..origin/$BRANCH") new commit(s)."
  echo "--- changes ---"; git log --oneline "HEAD..origin/$BRANCH"
  echo "Apply with:  bash selfupdate.sh update"
  return 0
}

update(){
  git fetch --quiet origin "$BRANCH"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Local changes present -> stashing..."; git stash push -u -m "selfupdate-$(date +%s)" || true
  fi
  if git merge --ff-only "origin/$BRANCH"; then
    chmod +x scripts/*.sh image-toolbox/*.sh unleashed-x-kaos/scripts/*.sh 2>/dev/null || true
    # Get the pull onto the eMMC before anything invites a power-cycle. The rootfs is mounted
    # commit=120, so up to TWO MINUTES of writes live only in page cache -- and after_update() below
    # ends by asking for exactly that power-cycle. arco-firstrun.sh has synced around this hazard from
    # the start; this path did not, and on 2026-08-14 a tester's printer came back from an update with
    # a cmds.py of 800422 bytes instead of 800809, the tail of it NUL bytes, which klippy refuses
    # outright. Files written just before a plug-pull do not come back short by accident.
    sync
    echo "Updated to ${BRANCH} @ $(git rev-parse --short HEAD)."
    after_update
  else
    echo "Fast-forward failed (history diverged). Resolve manually: git pull --rebase"
  fi
}

# Pulling new files is not the same as putting them to work, and this used to stop at the pull.
# Two things do not happen by themselves:
#   * a NEW self-heal guard is a systemd drop-in written by optimize-boot.sh -- an update that adds one
#     leaves it unwired, with no symptom until the day it was meant to save the printer;
#   * config fixes are applied by an ExecStartPre, so they land when the klipper SERVICE starts.
#     Klipper's own RESTART and FIRMWARE_RESTART do not run it -- a distinction nobody should have to
#     know, and the reason a bed-mesh fix once looked as though it had not been delivered.
# Nothing is restarted here unasked: a restart during a print ends the print, and this can run from a
# daily timer. So it checks, reports, and hands over the exact command.
after_update(){
  echo
  # The bridge needs nothing here. `unleashed-x-kaos/` is part of this repository AND the directory
  # the printer runs it from, so a pull updates the live copy directly -- which is exactly why it was
  # moved inside the kit. It used to sit beside it, and then a git pull updated a copy nobody ran
  # while the live one fell silently further behind with every update. Its .cache is gitignored, so
  # the KAOS payload and the vendor dev.py backup are never touched by a pull.
  if [ -x scripts/check-guards.sh ]; then
    if bash scripts/check-guards.sh >"/tmp/.arco-guards.$$" 2>&1; then
      echo "Self-heal: everything this update needs is already wired up."
    else
      # WHY THIS ARMS INSTEAD OF ADVISING. Installing what is missing needs root, and this runs as the
      # klipper user from a macro -- so the line that stood here asked the owner to open an SSH session
      # and run optimize-boot.sh themselves. That asks them to know what optimize-boot.sh is, and it is
      # exactly the step that gets skipped. On 2026-08-09 a tester updated a printer, was told nothing
      # was wrong (this check could not see one-time settings yet), and was left with a machine that
      # would not answer to its own name. Arming and asking for a power-cycle is the shape everything
      # else here already uses -- the backup, the flash -- and it asks the owner to know nothing.
      echo "Self-heal: this update brought something that is not set up on this printer yet:"
      grep -E '^  MISSING|^Missing' "/tmp/.arco-guards.$$" | sed 's/^/  /'
      # Parenthesised on purpose: a failing redirection is reported by the SHELL, before the command
      # runs, so `2>/dev/null` on the command never silences it. Without the subshell an unwritable
      # printer_data prints a raw "No such file or directory" with a line number, directly above the
      # sentence that explains the same thing in words.
      if ( : > "$RECONCILE_MARK" ) 2>/dev/null; then
        # The marker is the whole point of this branch, and it is the one file guaranteed to be seconds
        # old when the plug is pulled. Unsynced, commit=120 loses it and the reconcile silently never
        # happens -- the printer comes back looking updated and is not.
        sync
        echo
        echo "  >> Please POWER-CYCLE the printer once."
        echo "     It is applied automatically on the next start. Nothing else to do, and"
        echo "     nothing is lost if you leave it until later."
      else
        echo "  Could not arm it ($RECONCILE_MARK is not writable)."
        echo "  Run it by hand instead:  sudo bash $(pwd)/scripts/optimize-boot.sh"
      fi
    fi
    rm -f "/tmp/.arco-guards.$$"
  fi
  # New features arrive as new #@FEAT blocks, and AddOn.cfg is never regenerated on a printer that
  # already has one -- it holds the owner's settings. Without this step an update therefore reached
  # fresh flashes only, which is how the startup banner and the welcome dialog shipped to nobody who
  # already had a printer. This adds blocks that are ABSENT and never edits one that is present; it
  # refuses anything that would redefine a section the owner already declares. Safe during a print:
  # it only writes the file, and klipper reads it at the next service start.
  if [ -f scripts/addon_merge.py ] && command -v python3 >/dev/null 2>&1; then
    echo "Config features:"
    python3 scripts/addon_merge.py apply 2>&1 | sed 's/^/  /'
    sync
  fi
  state=$(curl -s --max-time 4 http://127.0.0.1:7125/printer/objects/query?print_stats 2>/dev/null \
          | tr ',{}' '\n' | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)
  case "${state:-}" in
    # 🔴 NOT "config fixes". That wording is why an owner on 19.08.2026 updated, saw no change and
    # reasonably concluded the update had not worked: they had pulled a THEME change, which is not
    # "config", so nothing suggested a restart was needed. Every guard this kit installs is an
    # ExecStartPre on klipper.service -- the extras, the AddOn.cfg merge, the Mainsail theme -- so
    # the honest sentence names what actually arrives rather than one part of it.
    printing|paused)
      echo "This lands when the klipper service restarts — config features, Klipper extras and the"
      echo "Mainsail theme all arrive then. The printer is $state right now, so leave it alone and"
      echo "run this once the print has finished:  sudo systemctl restart klipper";;
    *)
      echo "This lands when the klipper SERVICE starts (Klipper's own RESTART does not) — config"
      echo "features, Klipper extras and the Mainsail theme all arrive then:"
      echo "  sudo systemctl restart klipper";;
  esac
}

auto_on(){
  sudo tee "$SVC" >/dev/null <<EOF
[Unit]
Description=Arco migration kit auto-update
[Service]
Type=oneshot
User=$USER
ExecStart=/bin/bash $DIR/selfupdate.sh update
EOF
  sudo tee "$TMR" >/dev/null <<EOF
[Unit]
Description=Daily Arco kit update
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now arco-kit-update.timer
  echo "Auto-update ENABLED (daily). Next runs:"; systemctl list-timers arco-kit-update.timer --no-pager 2>/dev/null | head -2
  echo "Note: auto-pulls from YOUR GitHub repo and runs the scripts — only as safe as that repo."
}
auto_off(){
  sudo systemctl disable --now arco-kit-update.timer 2>/dev/null || true
  sudo rm -f "$SVC" "$TMR"; sudo systemctl daemon-reload
  echo "Auto-update DISABLED."
}

case "${1:-check}" in
  check)  check || true;;
  update) update;;
  adopt)  adopt;;
  console) update;;          # ARCO_UPDATE; adoption, if it was needed, already happened above
  auto)   case "${2:-}" in on) auto_on;; off) auto_off;; *) echo "Usage: selfupdate.sh auto on|off";; esac;;
  *) echo "Usage: bash selfupdate.sh check|update|auto on|off";;
esac
