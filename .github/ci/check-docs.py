#!/usr/bin/env python3
"""check-docs.py — the two ways this project's documents drift apart, as a gate.

Both failures below have already happened here, which is why they are checked rather than trusted.

1. DEAD ANCHORS.  The documents cross-reference each other by anchor: QUICKSTART sends you to
   MANUAL Step 6, README sends you to its own OrcaSlicer section.  Rename or renumber the target
   heading and the link keeps rendering perfectly while pointing at nothing -- GitHub simply scrolls
   nowhere.  Nobody notices until a reader following the install is dropped at the top of a 1900-line
   manual.

   Anchors resolve two ways and both are honoured here: an explicit <a id="..."></a> above a heading,
   and GitHub's own slug of the heading text.  The explicit ids exist because GitHub and pandoc
   disagree about what an em-dash does to a slug (GitHub keeps both surrounding spaces as hyphens,
   pandoc collapses them), so a link written against one renderer dead-ends in the other.  The kit
   ships the pandoc-rendered HTML on a USB stick; this check covers the GitHub side of that pair.

2. STEP NUMBERS OUT OF SYNC.  MANUAL is the source and carries Steps 1-11.  QUICKSTART is a checklist
   that reuses those numbers and deliberately skips some of them (5, 7, 9, 11 are optional or
   folded into a neighbour).  The gaps are fine.  What is not fine is QUICKSTART naming a Step 12
   that MANUAL does not have, which is what happens the first time someone inserts a step.

   Titles are NOT compared: the two documents describe the same step in different voices on purpose
   ("Save what only your printer has" vs "Rescue your AMS data").  Only the numbers must line up.

Exit code 1 on any finding, with the file and line to fix.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ["README.md", "MANUAL.md", "QUICKSTART.md", "INSTALL-FLOWCHARTS.md"]


def strip_fences(text):
    """Blank out fenced code blocks, keeping line numbers intact.

    Mandatory, not tidiness: INSTALL-FLOWCHARTS is mostly ```mermaid, and README's console blocks are
    full of '#' comment lines that would otherwise be read as headings.
    """
    out, fence = [], None
    for line in text.splitlines():
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if m:
            tok = m.group(1)[0] * 3
            if fence is None:
                fence = tok
                out.append("")
                continue
            if line.strip().startswith(fence):
                fence = None
                out.append("")
                continue
        out.append("" if fence else line)
    return "\n".join(out)


def slugify(heading):
    """GitHub's heading-to-anchor rule, as far as this project uses it.

    Lowercase; inline markup removed; everything that is not a word character, space or hyphen
    dropped; spaces to hyphens.  Punctuation vanishes but the spaces around it do not, which is why
    'Step 1 - Rescue' produces two consecutive hyphens.
    """
    s = heading.strip()
    s = re.sub(r"<[^>]+>", "", s)                       # inline html
    s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)      # [text](link) -> text
    s = re.sub(r"[`*]", "", s)                          # code ticks, bold/italic
    s = s.lower()
    s = re.sub(r"[^\w\s-]", "", s, flags=re.UNICODE)    # punctuation, em-dash, emoji
    return s.strip().replace(" ", "-")


def anchors_of(path):
    """Every anchor a link may legitimately target in this file."""
    text = strip_fences(path.read_text(encoding="utf-8"))
    found = set(re.findall(r'<a\s+[^>]*id="([^"]+)"', text))
    seen = {}
    for line in text.splitlines():
        m = re.match(r"^(#{1,6})\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        base = slugify(m.group(2))
        if not base:
            continue
        # GitHub disambiguates a repeated heading by appending -1, -2, ...
        n = seen.get(base, 0)
        seen[base] = n + 1
        found.add(base if n == 0 else f"{base}-{n}")
    return found


def links_of(path):
    """(target file, anchor, line number) for every markdown link carrying a '#'."""
    out = []
    for i, line in enumerate(strip_fences(path.read_text(encoding="utf-8")).splitlines(), 1):
        for target, anchor in re.findall(r"\]\(([A-Za-z0-9_./-]*)#([A-Za-z0-9_-]+)\)", line):
            out.append((target or path.name, anchor, i))
    return out


def main():
    problems = []
    docs = [d for d in DOCS if (ROOT / d).exists()]
    anchors = {d: anchors_of(ROOT / d) for d in docs}

    # 1 -- anchors
    for doc in docs:
        for target, anchor, line in links_of(ROOT / doc):
            name = Path(target).name
            if name not in anchors:
                continue        # link into a file this gate does not own; not our business
            if anchor not in anchors[name]:
                problems.append(
                    f"{doc}:{line}: dead anchor '#{anchor}' -> {name}\n"
                    f"    fix: add <a id=\"{anchor}\"></a> above the target heading in {name}"
                )

    # 2 -- step numbers
    def steps(doc):
        text = strip_fences((ROOT / doc).read_text(encoding="utf-8"))
        out = {}
        for i, line in enumerate(text.splitlines(), 1):
            m = re.match(r"^#{1,6}\s+Step\s+(\d+)\b", line)
            if m:
                out.setdefault(int(m.group(1)), i)
        return out

    if "MANUAL.md" in docs and "QUICKSTART.md" in docs:
        manual, quick = steps("MANUAL.md"), steps("QUICKSTART.md")
        for n, line in sorted(quick.items()):
            if n not in manual:
                problems.append(
                    f"QUICKSTART.md:{line}: Step {n} does not exist in MANUAL.md "
                    f"(MANUAL has {', '.join(str(s) for s in sorted(manual))})"
                )
        if not manual:
            problems.append("MANUAL.md: no '## Step N' headings found — has the format changed?")

    if problems:
        print("Documentation gate failed:\n")
        for p in problems:
            print("  " + p)
        print(f"\n{len(problems)} problem(s).")
        return 1

    counts = ", ".join(f"{d} {len(anchors[d])} anchors" for d in docs)
    print(f"Documentation gate passed — {counts}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
