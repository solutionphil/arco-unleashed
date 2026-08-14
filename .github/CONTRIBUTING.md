# Contributing

Patches, corrections and field reports are welcome. Two rules are not negotiable, and one habit
matters more here than in most repositories — please read those three sections before you open a PR.

## 1. Nothing proprietary enters this repository

Arco Unleashed ships **no** Phrozen or ThroughTek software. That is not a stylistic choice; it is the
condition under which this project can exist publicly at all.

Phrozen's parts reach a printer one of two ways, both of which keep this repository clean:

- from the owner's own `Arco_FW_V*.zip`, obtained from official Phrozen sources and supplied on a USB
  stick, or
- after an explicit confirmation, downloaded from **Phrozen's own public repository**
  ([phrozen3d/klipper](https://github.com/phrozen3d/klipper), GPL-3.0), pinned to a fixed commit and
  checksum-verified.

So: **do not add `phrozen_dev`, `phrozen_master`, `slave_ota`, `device_table`, `hdlDat` contents,
firmware blobs, or any file extracted from a printer's factory image** — not as a fixture, not as a
test asset, not "temporarily". The same goes for [KAOS](https://gitlab.com/sanders.chris/phrozenarco):
it is sideloaded from Chris Sanders' own GitLab at install time and never vendored here.

If a change genuinely cannot be made without one of those files, open an issue and describe the
problem instead — there is usually a fetch-and-verify shape that works.

## 2. Nothing from reverse engineering enters a public file

Parts of this project were understood by decompiling firmware that had no documentation. Symbols,
addresses, decompiler artefacts and internal names from that work stay out of anything published
here — code, comments, commit messages and documentation alike.

Describe *behaviour* ("the display re-requests the file list after a reconnect"), not the decompiled
internals you learned it from.

## 3. Say honestly how it was tested

This kit runs as root on other people's printers, flashes eMMC modules and moves a toolhead. "Looks
right" is not a test. The pull request template asks which of these applies — please answer it
accurately, including "file-level only, not on hardware". That answer is useful; a wrong one is not.

Two environments bite specifically:

- **Stock Buster.** The rescue and revert tooling runs on the factory OS, which has klibc tools, mawk
  1.3.3 without POSIX character classes, and no `wpa_cli` or `iw`. Anything that must work there has
  to be tested there — it will not be caught anywhere else.
- **The initramfs** (self-flash / restore). Only the shell and a handful of klibc applets exist. Every
  convenience you reach for is probably absent.

## Shell and Python

- Every shell script must pass `bash -n`. CI enforces this.
- CI also runs `shellcheck` at error severity, and reports the warning-level backlog without failing.
  New scripts should not add to that backlog.
- Python files must pass `python -m py_compile`. The Klipper extras in `scripts/` are loaded by
  Klipper itself — a syntax error there means the printer does not start.
- Match the surrounding style. The scripts in this kit explain *why* in comments, at length, wherever
  the reason is not obvious from the code. That is deliberate: most of these workarounds exist because
  of a specific hardware or firmware behaviour that is invisible from the source.

## Documentation

Three documents, with different jobs — keep them in their lanes:

| File | Role |
|---|---|
| `MANUAL.md` | The source. Every step, in full: Steps 1–11 plus Appendices A/B/C. |
| `README.md` | The entry point and reference. Deliberately contains no installation walkthrough. |
| `QUICKSTART.md` | A checklist that reuses the MANUAL's step numbers. The gaps are intentional. |
| `INSTALL-FLOWCHARTS.md` | The same paths as diagrams. Mermaid, rendered by GitHub directly. |

Two things to watch:

- **Step numbers are shared.** QUICKSTART points at MANUAL step numbers. Renumber a MANUAL step and
  QUICKSTART silently points at nothing. CI checks this.
- **The `.html` files are generated**, not written. They are built from the markdown with pandoc. If
  you change a `.md`, leave the `.html` alone and say so in the PR — a maintainer regenerates it.
  CI will note the mismatch; on a pull request that is a warning, not a failure.

Anchors: GitHub and pandoc disagree about how a heading with an em-dash becomes an anchor. That is why
link targets carry an explicit `<a id="..."></a>` above the heading. If you add a cross-reference,
point it at one of those, and CI will confirm it resolves.

## Licence

This project is **AGPL-3.0**. By contributing you agree your contribution is licensed the same way.
Third-party components keep their own licences — see [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).

*Phrozen*, *Arco* and *PhrozenGo* are trademarks of Phrozen Tech Co., Ltd.; this project is not
affiliated with, endorsed by or supported by them.
