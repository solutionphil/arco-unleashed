#!/bin/bash
# channel.sh — switch this kit between the stable channel (main) and the beta channel.
#
#   bash channel.sh            what channel am I on, and what would the other one change?
#   bash channel.sh beta       follow the beta branch from now on
#   bash channel.sh stable     go back to main
#
# HOW LITTLE THIS HAS TO DO. The update path already follows whatever branch the clone is on:
# selfupdate.sh computes BRANCH from HEAD, and apply-update-manager.sh writes `primary_branch:` into
# moonraker.conf from the same place -- as an ExecStartPre guard, so it re-asserts it before every
# klipper start. Switching the branch is therefore the whole job; Moonraker's update manager and the
# setup menu both follow by themselves at the next start. Nothing here writes moonraker.conf.
#
# WHY A BETA CHANNEL AT ALL. Everything that reached a printer used to reach every printer at once, so
# the first person to find a problem was an owner rather than a tester. beta is main plus the commits
# that have not earned their way over yet: no parallel history, no duplicated merges, and `stable` is
# always an ancestor of `beta` rather than a fork of it.
#
# 🔴 beta MUST NEVER BE FORCE-PUSHED. On 2026-08-14 main's history was rewritten and every clone made
# before it stopped being able to pull -- two testers' printers had to be repaired by hand, and Moonraker
# reported it only as "INVALID" with no reason. A channel that does that to the people testing for you is
# worse than no channel. Same repository rule as main: no force push, no deletion.
#
# WHAT SWITCHING BACK DOES NOT UNDO. Files come back, configuration does not. A beta feature that was
# merged into AddOn.cfg stays there, because that file belongs to the owner and this script will not
# edit it. Going back to stable therefore LISTS what beta added instead of removing it -- switch those
# features off in the menu if you do not want them.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$DIR/.." && pwd)"
cd "$KIT"

C0=$'\033[0m'; CG=$'\033[0;32m'; CY=$'\033[1;33m'; CW=$'\033[1;37m'; CR=$'\033[0;31m'
STABLE=main
BETA=beta

[ -d .git ] || {
  echo "This kit is a flat copy from the image, not a clone, so it has no channels yet."
  echo "Adopt it first:  bash $DIR/selfupdate.sh adopt"
  exit 1; }

now(){ git rev-parse --abbrev-ref HEAD 2>/dev/null; }

# Refuse rather than stash. A channel switch is not the moment to quietly pocket somebody's edits --
# selfupdate.sh stashes because an update is expected to carry local changes along, but here the honest
# answer is to say what is in the way and let the owner decide.
dirty_check(){
  local m; m="$(git status --porcelain --untracked-files=no 2>/dev/null)"
  [ -z "$m" ] && return 0
  echo "${CR}   Local changes to tracked files — not switching:${C0}"
  printf '%s\n' "$m" | sed 's/^/     /'
  echo "   Keep them (git stash) or discard them (git checkout -- .), then run this again."
  return 1
}

fetch(){
  git fetch --quiet --tags --force origin 2>/dev/null || {
    echo "${CR}   Could not reach GitHub.${C0} A channel switch needs the network."; return 1; }
}

# Features that live in AddOn.cfg but are NOT in the channel we are moving to. These are what a beta
# feature left behind -- named, never removed.
leftovers(){ # $1 = ref whose template to compare against
  local cfg="$HOME/printer_data/config/AddOn.cfg"
  [ -f "$cfg" ] || return 0
  local tpl; tpl="$(git show "$1:config-templates/AddOn.cfg.template" 2>/dev/null)" || return 0
  [ -n "$tpl" ] || return 0
  local have want extra
  have="$(grep -oE '^#@FEAT[[:space:]]+[^[:space:]]+' "$cfg" | awk '{print $2}' | sort -u)"
  want="$(printf '%s\n' "$tpl" | grep -oE '^#@FEAT[[:space:]]+[^[:space:]]+' | awk '{print $2}' | sort -u)"
  extra="$(comm -23 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))"
  [ -n "$extra" ] || return 0
  echo "${CY}   Your AddOn.cfg carries features this channel does not ship:${C0}"
  printf '%s\n' "$extra" | sed 's/^/     /'
  echo "   They are left exactly as they are. Switch them off under 'AddOn features' if you"
  echo "   do not want them — nothing here edits your config."
}

status(){
  local b; b="$(now)"
  case "$b" in
    "$BETA")   echo "   Channel: ${CY}beta${C0}  (branch $b)";;
    "$STABLE") echo "   Channel: ${CG}stable${C0}  (branch $b)";;
    *)         echo "   Channel: ${CW}$b${C0} — neither $STABLE nor $BETA. Updates follow this branch.";;
  esac
  echo "   Version: $(git describe --tags 2>/dev/null || echo '?')"
  fetch || return 0
  local other; [ "$b" = "$BETA" ] && other="$STABLE" || other="$BETA"
  git rev-parse --verify -q "origin/$other" >/dev/null || {
    echo "   (no origin/$other on GitHub yet)"; return 0; }
  local ahead behind
  ahead="$(git rev-list --count "HEAD..origin/$other" 2>/dev/null || echo 0)"
  behind="$(git rev-list --count "origin/$other..HEAD" 2>/dev/null || echo 0)"
  echo "   Against ${other}: $ahead commit(s) it has that you do not, $behind that you have and it does not."
  [ "$ahead" -gt 0 ] && git log --oneline --no-decorate "HEAD..origin/$other" 2>/dev/null | head -10 | sed 's/^/     /'
  return 0
}

switch_to(){ # $1 = branch
  local target="$1"
  [ "$(now)" = "$target" ] && { echo "   Already on $target."; status; return 0; }
  dirty_check || return 1
  fetch || return 1
  git rev-parse --verify -q "origin/$target" >/dev/null || {
    echo "${CR}   There is no '$target' branch on GitHub.${C0}"; return 1; }
  # -B, not reset --hard: it creates or moves the local branch AND attaches HEAD to it. A reset on a
  # detached HEAD leaves it detached, which Moonraker reports as INVALID with no explanation.
  git checkout -B "$target" "origin/$target" 2>&1 | sed 's/^/   /' || return 1
  git branch -q --set-upstream-to="origin/$target" "$target" 2>/dev/null || true
  sync
  echo "${CG}   Now on $target — $(git describe --tags 2>/dev/null || echo '?')${C0}"
  leftovers "origin/$target"
  echo
  echo "${CW}   Restart klipper to finish:  sudo systemctl restart klipper${C0}"
  echo "   That is when the guard rewrites moonraker.conf, so the update manager"
  echo "   follows this channel too. Until then it still shows the old one."
}

case "${1:-status}" in
  status|"") status;;
  beta)      switch_to "$BETA";;
  stable|main) switch_to "$STABLE";;
  *) echo "usage: bash channel.sh [status|beta|stable]"; exit 1;;
esac
