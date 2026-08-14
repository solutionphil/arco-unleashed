# Security policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting instead: the **Security** tab of this repository →
*Report a vulnerability*. That opens a private thread visible only to the maintainer.

Tell us what you found, how to reproduce it, and what an attacker gets out of it. If you have a fix,
attach it — but do not push it to a public branch before we have talked.

Expect a first reply within a week. This is a one-person community project, not a vendor with an
on-call rotation, so please read that number as a realistic average rather than an SLA.

## What is in scope

The things this project builds and ships:

- **The WiFi setup portal** (`scripts/wifi-portal/`) — it handles the network passphrase of whoever is
  setting the printer up, over an open access point, before any network exists.
- **The self-flash and backup/restore path** (`selfflash/`) — it writes the eMMC, and its one-time
  token is what stands between "restore my own backup" and "anyone on the network reflashes my
  printer".
- **The fetch-and-verify of third-party parts** — the pinned commit and checksum that decide whether
  what lands in `klipper/klippy/extras/` is really Phrozen's published module.
- **Anything in the pre-built image that should not be there**: leftover credentials, keys, host
  identity, or per-device data carried over from the machine the image was made on.
- **The update mechanism** — anything that lets a third party influence what a printer installs.

## What is not

- **Bricking your own printer.** Flashing firmware, replacing the OS and voiding the warranty are the
  documented purpose of this project, not a vulnerability.
- **A printer exposed directly to the internet.** Klipper, Moonraker and Mainsail assume a trusted
  local network. Putting the web interface on a public IP is outside what this kit can defend.
- **Upstream projects.** Klipper, Moonraker, Mainsail, Fluidd, Armbian and KAOS have their own
  security contacts — a flaw in their code should go to them. If our *configuration* of one of them is
  what creates the problem, that is ours and in scope.
- **Phrozen's own software.** We neither ship nor modify it. Report those to Phrozen.

## Supported versions

The `main` branch and the most recent release. There are no backports to older images: the supported
fix for a security problem is to update the kit, or to reflash from a corrected image.
