#!/usr/bin/env python3
"""check-docs-drift.py — catch the same fact being told twice, and told differently.

The four documents overlap on purpose: MANUAL is the procedure, QUICKSTART is that procedure
condensed, README is the reference, INSTALL-FLOWCHARTS draws it. Overlap is the design. Drift is what
happens to overlap when nobody looks, and this project has been caught by it four times in one day:

  * a 17-line OrcaSlicer G-code block byte-identical in README and MANUAL,
  * the AMS-rescue command in three documents at once,
  * a warning MANUAL had explicitly withdrawn ("that is no longer true") still stated as fact in
    QUICKSTART and in two flowchart nodes,
  * a prose cross-reference -- "the block below" -- that outlived the block it pointed at.

Two checks, because those failures are not one problem.

── 1. EXACT DUPLICATION (blocking) ────────────────────────────────────────────────────────────────
Text that appears verbatim in two documents has two owners and no gate between them. Worst for code:
a G-code block has to match a running printer, and a stale copy looks perfectly plausible. Measured
before this was written, the repository had 0 multi-line duplicates, 1 duplicated command and 2
duplicated prose lines -- so the baseline is small and honest, and anything new is a real finding.

── 2. THE TWIN THAT DID NOT FOLLOW (reporting) ────────────────────────────────────────────────────
The print-test case would not have been caught above: QUICKSTART's wording was never identical to
MANUAL's, only equivalent. What is detectable is the *change*: when a line changes in one document,
look for lines elsewhere that closely matched the version being replaced. Those are the sentences
that just became someone else's stale copy.

This reports rather than fails, and the reason is measured too: at a 0.80 threshold the documents
already contain ~24 near-identical pairs, nearly all legitimate -- QUICKSTART restating MANUAL is
the point of QUICKSTART. A gate on that would cry wolf until it was ignored. A gate on what *just
changed* is quiet until it is not.

WHAT NEITHER CHECK CAN DO: notice that a correct paragraph sits under the wrong heading, or that a
true sentence has stopped being true because the world moved. Both happened here; both were found by
a second reader. This does not replace that.

    check-docs-drift.py [--base <git-ref>]

Without --base only check 1 runs. Exit 1 on a new exact duplicate.
"""
import argparse
import difflib
import hashlib
import itertools
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ["README.md", "MANUAL.md", "QUICKSTART.md", "INSTALL-FLOWCHARTS.md"]
BASELINE = Path(__file__).parent / "docs-drift-baseline.txt"

MIN_PROSE = 60      # shorter lines repeat by coincidence, not by copying
MIN_CODE = 20
SIMILAR = 0.80      # measured: below this the pairs are unrelated, above it mostly legitimate


def fingerprint(s):
    return hashlib.sha1(" ".join(s.split()).encode("utf-8")).hexdigest()[:12]


def code_blocks(text):
    return [b.strip() for b in re.findall(r"```[a-z]*\n(.*?)```", text, re.S) if b.strip()]


def prose_sentences(text):
    """Sentences, not lines.

    These documents are hard-wrapped, and the same sentence wraps at different columns in each of
    them. Comparing lines compares wrapping, not meaning: replayed against the real print-test drift,
    a line-level comparison scored zero because MANUAL broke the sentence after "for the old" and
    QUICKSTART after "cannot run, so". Unwrapping first is what makes the check see the claim.
    """
    out, fence, para = [], False, []

    def flush():
        if not para:
            return
        joined = " ".join(para)
        joined = re.sub(r"\s+", " ", joined).strip()
        for s in re.split(r"(?<=[.!?])\s+(?=[A-Z0-9`*—“\"(\U0001F300-\U0001FAFF])", joined):
            s = s.strip()
            if len(s) >= MIN_PROSE:
                out.append(s)
        para.clear()

    for line in text.split("\n"):
        if line.startswith("```"):
            fence = not fence
            flush()
            continue
        if fence:
            continue
        s = line.strip().lstrip(">-*| ").strip()
        if not s or s.startswith(("#", "<", "|")):
            flush()
            continue
        para.append(s)
    flush()
    return out


def load_baseline():
    known = {}
    if not BASELINE.exists():
        return known
    for line in BASELINE.read_text(encoding="utf-8").split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 3)
        if len(parts) >= 3:
            known[(parts[0], parts[1], parts[2])] = parts[3] if len(parts) > 3 else ""
    return known


def read(ref, path):
    if ref is None:
        return (ROOT / path).read_text(encoding="utf-8")
    r = subprocess.run(["git", "show", f"{ref}:{path}"], cwd=ROOT,
                       capture_output=True, text=True, encoding="utf-8")
    return r.stdout if r.returncode == 0 else ""


def check_exact(docs, known):
    """Blocking: the same text, word for word, in two documents."""
    findings = []
    for a, b in itertools.combinations(DOCS, 2):
        pairs = []
        ba, bb = code_blocks(docs[a]), code_blocks(docs[b])
        for x in ba:
            if x in bb:
                lines = len(x.split("\n"))
                if lines > 1 or len(x) >= MIN_CODE:
                    pairs.append(("code", x, f"{lines} line(s)"))
        sa, sb = set(prose_sentences(docs[a])), set(prose_sentences(docs[b]))
        for x in sorted(sa & sb):
            pairs.append(("prose", x, f"{len(x)} chars"))
        for kind, txt, size in pairs:
            fp = fingerprint(txt)
            if (a, b, fp) in known:
                continue
            findings.append((a, b, fp, kind, size, txt.split("\n")[0][:70]))
    return findings


def check_twins(base, docs):
    """Reporting: a line changed here; something over there looked just like the old one."""
    old = {d: read(base, d) for d in DOCS}
    reports = []
    for doc in DOCS:
        if not old[doc]:
            continue
        before, after = set(prose_sentences(old[doc])), set(prose_sentences(docs[doc]))
        removed = before - after
        if not removed:
            continue
        for other in DOCS:
            if other == doc:
                continue
            still = prose_sentences(docs[other])
            for gone in removed:
                for line in still:
                    if line == gone:
                        continue
                    r = difflib.SequenceMatcher(None, gone, line).ratio()
                    if r >= SIMILAR:
                        reports.append((doc, other, r, gone, line))
    return reports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", help="git ref to compare against for the twin report")
    args = ap.parse_args()

    docs = {d: (ROOT / d).read_text(encoding="utf-8") for d in DOCS if (ROOT / d).exists()}
    missing = [d for d in DOCS if d not in docs]
    if missing:
        print(f"::error::missing document(s): {', '.join(missing)}")
        return 1

    known = load_baseline()
    findings = check_exact(docs, known)

    if findings:
        print("Text that now exists in two documents at once:\n")
        for a, b, fp, kind, size, preview in findings:
            print(f"  {a} == {b}  ({kind}, {size})")
            print(f"      {preview}")
            print(f"      baseline line, if this is deliberate:  {a} {b} {fp}")
            print()
        print("Keep one copy and point at it, or record the pair in "
              ".github/ci/docs-drift-baseline.txt with the reason.")
    else:
        print(f"No unrecorded duplication across {len(docs)} documents "
              f"({len(known)} deliberate pair(s) on record).")

    if args.base:
        reports = check_twins(args.base, docs)
        if reports:
            print(f"\nLines changed here whose near-twin elsewhere did not change "
                  f"({len(reports)}):\n")
            for doc, other, r, gone, line in reports:
                print(f"  ::warning file={other}::{other} still says something {r:.0%} like the "
                      f"line just changed in {doc}")
                print(f"      was in {doc}:  {gone[:96]}")
                print(f"      still in {other}: {line[:96]}")
                print()
            print("Not necessarily wrong -- QUICKSTART restating MANUAL is the point of QUICKSTART.")
            print("Worth one look: did this change need to reach the other document too?")
        else:
            print("\nNo changed line has an unchanged near-twin in another document.")

    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
