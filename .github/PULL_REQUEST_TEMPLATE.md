<!-- Thanks for sending this. CONTRIBUTING.md explains the two rules that are not negotiable
     (nothing proprietary, nothing from reverse engineering) — worth a look before you fill this in. -->

## What this changes

<!-- One or two sentences. What was wrong or missing, and what the printer does differently now. -->

## Why

<!-- What made you hit this. A symptom on a real printer beats a hypothetical. -->

## How it was tested

<!-- Be specific about which of these is true — "looks right" is not a test on a machine that
     flashes eMMCs and moves a toolhead. -->

- [ ] Ran on a real Arco (say which: stock Buster / Unleashed image / base image + KIAUH)
- [ ] Only file-level / offline verification, not on hardware
- [ ] Documentation only

Details:

## Checklist

- [ ] No Phrozen or ThroughTek files, and nothing derived from decompiled firmware, are added by this PR
- [ ] `bash -n` passes on every shell script I touched
- [ ] If I changed `README.md`, `MANUAL.md` or `QUICKSTART.md`, I regenerated the matching `.html`
- [ ] If I renumbered or moved a MANUAL step, I checked QUICKSTART still points at steps that exist
