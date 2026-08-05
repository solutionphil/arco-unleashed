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
  git branch -q -f main "$base" 2>/dev/null || true
  git symbolic-ref HEAD refs/heads/main
  git branch -q --set-upstream-to=origin/main main 2>/dev/null || true
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
    chmod +x scripts/*.sh image-toolbox/*.sh 2>/dev/null || true
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
  if [ -x scripts/check-guards.sh ]; then
    if bash scripts/check-guards.sh >"/tmp/.arco-guards.$$" 2>&1; then
      echo "Self-heal guards: all present."
    else
      echo "Self-heal guards: SOMETHING IS MISSING — this update may have added one."
      tail -6 "/tmp/.arco-guards.$$" | sed 's/^/  /'
      echo "  Wire them up with:  sudo bash $(pwd)/scripts/optimize-boot.sh"
    fi
    rm -f "/tmp/.arco-guards.$$"
  fi
  state=$(curl -s --max-time 4 http://127.0.0.1:7125/printer/objects/query?print_stats 2>/dev/null \
          | tr ',{}' '\n' | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)
  case "${state:-}" in
    printing|paused)
      echo "Config fixes land when the klipper service restarts. The printer is $state right now, so"
      echo "leave it alone — run this once the print has finished:  sudo systemctl restart klipper";;
    *)
      echo "Config fixes land when the klipper SERVICE starts (Klipper's own RESTART does not):"
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
