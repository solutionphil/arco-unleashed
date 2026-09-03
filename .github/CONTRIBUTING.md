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

## 2. Internal names from the factory software stay out of public files

Some of what this kit works around is undocumented behaviour of the software the printer shipped with.
Whatever anyone has worked out about its internals — symbols, addresses, generated identifiers,
function names — stays out of everything published here: code, comments, commit messages and
documentation alike.

Write about what the machine *does* ("the display re-requests the file list after a reconnect"), not
about the internals behind it. If you cannot describe a fix without naming one, open an issue and
describe the symptom instead; there is usually a way to say it that works.

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
  On a **pull request** the mismatch is a warning. On a **push to a branch** it is a hard failure, so
  a change that lands without its regenerated `.html` turns that branch red. See "Where a change
  lands" below: work through a pull request and this cannot happen to you.

Anchors: GitHub and pandoc disagree about how a heading with an em-dash becomes an anchor. That is why
link targets carry an explicit `<a id="..."></a>` above the heading. If you add a cross-reference,
point it at one of those, and CI will confirm it resolves.

## Where a change lands

There are three branches and they are a chain, not alternatives: **`alpha` → `beta` → `main`**. A
printer's update channel is simply the branch its copy of the kit sits on, so moving a branch changes
what real machines download.

**Open every pull request against `alpha`.** Not against `main`, and not against `beta`. Proven work
is carried downwards afterwards by a maintainer, as a fast-forward.

**Never push straight to `main`, `beta` or `alpha`.** CI enforces the chain: `main` must be an
ancestor of `beta`, and `beta` of `alpha`. A direct push to `main` puts commits there that the other
two do not have, and the next push to either of them fails with

```
main carries N commit(s) that beta does not, so beta -> main is no longer a fast-forward
```

If it happens anyway, **repair downwards, never by rewriting**. Every clone in the field depends on
these branches not moving underneath it, so a force-push is not an option even when it would be
tidier. Merge in order — the first merge necessarily breaks the second link, which is why it has to be
walked rather than done in one step:

```bash
git checkout -B _sync origin/beta && git merge --no-ff origin/main && git push origin _sync:refs/heads/beta
git checkout -B _sync2 origin/alpha && git merge --no-ff origin/beta && git push origin _sync2:refs/heads/alpha
```

### Before you commit

- Touching `README.md`, `MANUAL.md` or `QUICKSTART.md`? The matching `.html` has to move with it, or
  the branch goes red. Open a pull request and say so rather than pushing.
- Adding a Klipper extra under `scripts/`? Add it to the list in `scripts/apply-arco-extras.sh` in the
  same change. Its config section arrives with the same update, and a section whose module is missing
  is not a missing feature — klippy refuses the whole config.
- Changing `config-templates/AddOn.cfg.template`? Read the header of `scripts/addon_merge.py` first.
  That file is never regenerated on a printer that already has one, so a new `#@FEAT` block is what
  normally reaches existing machines. A change *inside* a block reaches nobody unless the template
  also names that block in a `#@REVISE`, which replaces the printer's copy of it in place — read what
  that costs before reaching for it.

## Version numbers

Three numbers, and the first one does not move.

| position | when it changes | example |
| --- | --- | --- |
| major | never — this stays at `1` | `1.x.x` |
| minor | new functionality | `1.1` → `1.2` |
| patch | bug fixes, and anything a printer gains no behaviour from | `1.1.1` → `1.1.2` |

The minor is reserved for functionality a printer actually gains. Documentation, CI, build
tooling, repository housekeeping — anything that changes nothing about what runs on a machine —
is a patch, however large the diff.

**A version bundles several commits.** Tags are cut when an image is built, not once per commit --
numbering every merge would be noise rather than diligence. Between two tags a printer reports
`vX.Y.Z-<n>-g<sha>`, which says exactly what it is: that version plus n commits.

Tags are annotated, named `vMAJOR.MINOR.PATCH`, and **never moved** — printers in the field clone
this repository, and a tag that moves under them is the same breach as a rewritten branch.

**Tag the commit an image is baked from, and tag it before building the kit bundle.** The version
Moonraker shows in the update manager comes from `git describe` run against the clone inside the
image, so an untagged commit leaves it nothing to describe against and it falls back to an inferred
`v0.0.0-<count>-g<sha>`. Both halves of that have bitten already: a bundle built without `--tags`
carried no tags at all, and before `v1.1.0` existed the nearest tag was `full/1.0`.

`full/1.0` is a **release name, not a version**, and it is the reason a printer once reported
`v0.0.0-231-gfull/1.0-89-g7421520e-inferred`. It stays where it is because the published release
points at it. Do not add more tags that are not versions.

## Licence

This project is **AGPL-3.0**. By contributing you agree your contribution is licensed the same way.
Third-party components keep their own licences — see [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).

*Phrozen*, *Arco* and *PhrozenGo* are trademarks of Phrozen Tech Co., Ltd.; this project is not
affiliated with, endorsed by or supported by them.
