#!/bin/bash
# channel.sh — switch this kit between the stable channel (main) and the beta channel.
#
#   bash channel.sh            what channel am I on, and what would the other one change?
#   bash channel.sh beta       follow the beta branch from now on
#   bash channel.sh alpha      experimental; asks for the access phrase
#   bash channel.sh stable     go back to main
#   bash channel.sh phrase     (maintainer) turn a new access phrase into the line to commit
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
# Same marker selfupdate.sh uses, and deliberately outside the kit: an untracked file in the repository
# is what makes the next pull refuse.
RECONCILE_MARK="$(cd "$KIT/.." && pwd)/printer_data/.arco-reconcile-pending"
cd "$KIT"

C0=$'\033[0m'; CG=$'\033[0;32m'; CY=$'\033[1;33m'; CW=$'\033[1;37m'; CR=$'\033[0;31m'
STABLE=main
BETA=beta
ALPHA=alpha

# ── the alpha gate, and what it is honestly worth ─────────────────────────────────────────────────
# This repository is PUBLIC. `git checkout -B alpha origin/alpha` works for anybody, so nothing here
# can be access control and it is not written as if it were. What it is: a lock against activating an
# experimental channel by accident or on a whim, and a way to make switching a deliberate act somebody
# had to be invited into. That is the actual risk -- not somebody reading the code, but somebody's
# working printer quietly following a branch built for breaking things.
#
# The salt is not a secret either; it only stops the hash being looked up in a table. Rotate the phrase
# with `channel.sh phrase`, which prints the replacement line without ever storing the phrase anywhere.
ALPHA_SALT="arco-alpha-2026"
ALPHA_HASH="d31a679b6b4f543b1de4d3c7b452c0e52c337695b5c50b1da8973df2a97a15da"

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

hash_of(){ printf '%s' "$ALPHA_SALT:$1" | sha256sum | cut -d' ' -f1; }

# Reads with -s so the phrase is not left on screen or in the scrollback of whoever is watching.
# Three tries, then it stops -- not because that defeats anybody (see the note on the gate above), but
# because a prompt that keeps asking reads as broken rather than as refused.
alpha_gate(){
  echo "${CR}   ALPHA is experimental.${C0} It carries changes that have not been tried anywhere else"
  echo "   and it can break a printer that works today. beta is the channel for helping test;"
  echo "   this one is for helping build."
  local try ans
  for try in 1 2 3; do
    printf "   Access phrase: "; read -rs ans; echo
    [ -n "$ans" ] || { echo "   (nothing entered)"; continue; }
    [ "$(hash_of "$ans")" = "$ALPHA_HASH" ] && return 0
    echo "${CR}   Not that one.${C0}"
  done
  echo "   Ask whoever runs the project for the phrase."
  return 1
}

# Maintainer helper. Prints the line to commit and never writes the phrase anywhere -- not to a file,
# not to the shell history, not to the screen.
phrase(){
  local a b
  printf "   New access phrase: "; read -rs a; echo
  printf "   Again:             "; read -rs b; echo
  [ -n "$a" ] || { echo "   Empty — nothing to do."; return 1; }
  [ "$a" = "$b" ] || { echo "${CR}   They do not match.${C0}"; return 1; }
  echo
  echo "   Replace this line in scripts/channel.sh and commit it:"
  echo "${CW}ALPHA_HASH=\"$(hash_of "$a")\"${C0}"
  echo
  echo "   The salt stays as it is. Everyone already on alpha keeps working until they switch again."
}

status(){
  local b; b="$(now)"
  case "$b" in
    "$ALPHA")  echo "   Channel: ${CR}alpha${C0}  (branch $b) — experimental";;
    "$BETA")   echo "   Channel: ${CY}beta${C0}  (branch $b)";;
    "$STABLE") echo "   Channel: ${CG}stable${C0}  (branch $b)";;
    *)         echo "   Channel: ${CW}$b${C0} — none of $STABLE/$BETA/$ALPHA. Updates follow this branch.";;
  esac
  echo "   Version: $(git describe --tags 2>/dev/null || echo '?')"
  fetch || return 0
  # Compare against the next channel DOWN the promotion chain (alpha → beta → main), because that is
  # the one whose difference is meaningful: it is what this printer is carrying ahead of the calmer
  # channel. From stable the useful comparison is the other way, towards beta.
  local other
  case "$b" in
    "$ALPHA") other="$BETA";;
    "$BETA")  other="$STABLE";;
    *)        other="$BETA";;
  esac
  git rev-parse --verify -q "origin/$other" >/dev/null || {
    echo "   (no origin/$other on GitHub yet)"; return 0; }
  local ahead behind
  ahead="$(git rev-list --count "HEAD..origin/$other" 2>/dev/null || echo 0)"
  behind="$(git rev-list --count "origin/$other..HEAD" 2>/dev/null || echo 0)"
  # One sentence per case, in plain words. The first version said "$ahead commit(s) it has that you do
  # not, $behind that you have and it does not" -- correct, and nobody should have to parse a sentence
  # to learn whether they are behind.
  if   [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then echo "   Same as ${other}."
  elif [ "$behind" -eq 0 ]; then echo "   ${other} is $ahead commit(s) further on:"
  elif [ "$ahead" -eq 0 ];  then echo "   You are $behind commit(s) ahead of ${other}."
  else echo "   ${other} is $ahead commit(s) further on, and you have $behind it does not:"
  fi
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

  # ARM THE ROOT-SIDE SETUP. The first version of this script did not, and the hole showed up the first
  # time it was used on a real printer: the switch worked, moonraker.conf followed, and the login banner
  # still said nothing about the channel -- because that line lives under /etc and only optimize-boot.sh
  # writes it, as root, from the reconcile at boot. "Restart klipper to finish" was true for everything a
  # guard owns and quietly false for everything else.
  #
  # It arms UNCONDITIONALLY rather than asking check-guards.sh first. A channel switch can move the kit
  # any distance in either direction, and check-guards only sees systemd drop-ins -- it once reported
  # "all present" on a printer whose hostname had never been set. Guessing wrong here is silent, and
  # optimize-boot.sh is idempotent, so arming when nothing changed costs one boot's worth of no-ops.
  # The subshell is not decoration. `: > "$f" 2>/dev/null` does NOT silence a failing redirection: the
  # shell reports that itself, before the command runs, so the 2>/dev/null never applies to it. Without
  # the parentheses an unwritable path prints a raw "No such file or directory" with a line number
  # immediately above the sentence explaining the same thing in words.
  if ( : > "$RECONCILE_MARK" ) 2>/dev/null; then
    sync                        # the marker is seconds old when the plug is pulled; commit=120
    echo
    echo "${CW}   Two things finish this:${C0}"
    # MOONRAKER, not klipper. apply-update-manager.sh is an ExecStartPre on moonraker.service --
    # it edits moonraker.conf, which only Moonraker reads. Restarting klipper does nothing for it,
    # and this line said otherwise for as long as it existed: on 2026-08-23 a switch to alpha left
    # the clone on alpha and the update manager tracking main, because the advice was followed.
    echo "     1) sudo systemctl restart moonraker  — moonraker.conf follows the channel"
    echo "        (its update panel keeps showing the old channel until the next refresh)"
    echo "     2) power-cycle the printer once     — everything that needs root, e.g. the"
    echo "        login banner, which lives under /etc and no guard touches"
    echo "   In a hurry, 2) can be done now instead:"
    echo "     sudo bash $DIR/optimize-boot.sh"
  else
    echo
    echo "${CR}   Could not arm the root-side setup${C0} ($RECONCILE_MARK is not writable)."
    echo "   Run it by hand:  sudo bash $DIR/optimize-boot.sh"
    echo "   Then:            sudo systemctl restart moonraker"
  fi
}

case "${1:-status}" in
  status|"") status;;
  beta)      switch_to "$BETA";;
  # The gate runs BEFORE anything is fetched or moved, so a wrong phrase leaves the printer exactly
  # where it was and costs nothing but the prompt.
  alpha)     alpha_gate && switch_to "$ALPHA";;
  stable|main) switch_to "$STABLE";;
  phrase)    phrase;;
  *) echo "usage: bash channel.sh [status|beta|alpha|stable|phrase]"; exit 1;;
esac
