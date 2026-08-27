#!/bin/bash
# check-guards-toggle.sh — every self-heal guard must have an off switch.
#
# THE DEFECT THIS EXISTS FOR. Two files describe the same set of guards and only one of them is
# derived. check-guards.sh READS optimize-boot.sh to learn which guards to expect, so it can never
# fall behind. guards-toggle.sh carries a hand-written table instead, because each entry answers two
# questions no parser can answer -- what breaks without this guard, and why someone would legitimately
# want it off. A hand-written list beside a generated one drifts, and this one had: four guards
# (test-print, addon-merge, reconcile-check, theme) were installed on every printer with no way to
# switch any of them off, while guards-toggle.sh's own header stated the opposite rule --
# "one that cannot be switched off is not a guard, it is a decision made for the owner".
#
# Same shape as the drifted copy of collect_data_arco.sh and the six-day-stale QUICKSTART.html: one
# subject, two hand-kept copies, no gate. Both were cured with a gate rather than with a correction,
# because a correction fixes today and a gate fixes every day after it.
#
# SCOPE, STATED RATHER THAN IMPLIED. This reads scripts/optimize-boot.sh only. That is where the kit
# installs its guards, and it is the file check-guards.sh already treats as the reference. The KAOS
# bridge installs 21-kaos-guard from its own sideloader in a different shape entirely (`cat > "$DROPIN"`
# against a variable, not a literal path), so it is not parsed here -- it is in the table by hand and
# stays there. If a guard is ever added by a third installer, this gate will not see it, and that is a
# known limit rather than a claim of completeness.
#
# THE TEST. A drop-in is a guard when it carries an ExecStartPre. Drop-ins that only set Environment=
# or Nice= are tuning, not guards, and are deliberately absent from the toggle screen: offering "CPU
# affinity" in a list of guards invites someone to switch it off looking for something they can live
# without, and hands them a printer with timing problems instead.
set -uo pipefail
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OB="$DIR/scripts/optimize-boot.sh"
GT="$DIR/scripts/guards-toggle.sh"
for f in "$OB" "$GT"; do
  [ -f "$f" ] || { echo "ERROR: missing $f"; exit 1; }
done

# Block-scoped on purpose. An earlier attempt at this tracked "the last drop-in name seen" and then
# looked for an ExecStartPre anywhere after it, which credited 20-arco-numpy -- a drop-in that sets
# four Environment= lines and nothing else -- with the ExecStartPre belonging to the NEXT block. It
# reported a bug that was not there. So: the name is taken from the `install ... <<EOF` line, and only
# an ExecStartPre before that heredoc's own terminator counts.
installed=$(awk '
  /^[[:space:]]*install .*\.service\.d\/[^"]*\.conf"[[:space:]]*<<'"'"'?EOF'"'"'?[[:space:]]*$/ {
      if (match($0, /[^"]+\.service\.d\/[^"]+\.conf/)) {
          spec = substr($0, RSTART, RLENGTH)
          i = index(spec, ".service.d/")
          name = substr(spec, i + length(".service.d/"))
          sub(/\.conf$/, "", name)
          inblock = 1; has = 0
      }
      next
  }
  inblock && /^EOF$/            { if (has) print name; inblock = 0; next }
  inblock && /ExecStartPre=/    { has = 1 }
' "$OB" | sort -u)

[ -n "$installed" ] || { echo "ERROR: parsed no guards out of optimize-boot.sh -- the gate itself is broken."; exit 1; }

offered=$(sed -n '/^GUARDS=(/,/^)/p' "$GT" | grep '|' | cut -d'|' -f2 | sort -u)
[ -n "$offered" ] || { echo "ERROR: parsed no entries out of the GUARDS table -- the gate itself is broken."; exit 1; }

missing=$(comm -23 <(printf '%s\n' "$installed") <(printf '%s\n' "$offered"))
if [ -n "$missing" ]; then
  echo "Guards installed by optimize-boot.sh with no off switch in guards-toggle.sh:"
  printf '%s\n' "$missing" | sed 's/^/  /'
  echo
  echo "Add each one to the GUARDS table in scripts/guards-toggle.sh, with a detail_of entry"
  echo "saying what breaks without it and why someone would want it off."
  echo "If it is tuning rather than a guard, it should not carry an ExecStartPre in the first place."
  exit 1
fi

echo "All $(printf '%s\n' "$installed" | grep -c .) guards installed by optimize-boot.sh have an off switch."
