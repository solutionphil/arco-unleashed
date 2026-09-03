#!/bin/bash
# optimize-boot.sh — run as root (called via sudo from the System-prep step).
#
# KIAUH installs klipper.service + moonraker.service tied to network-online.target
# (klipper: After=; moonraker: Requires= AND After=). Neither needs the network to run:
# Klipper only talks to the local MCUs, and Moonraker + voronFDM/KlipperScreen talk over
# localhost (127.0.0.1:7125). On this board network-online (WiFi DHCP) isn't reached until
# ~13s into boot, so the After= held both services back (~1s, as much boot time as is safely
# recoverable — the rest is the inherent MCU connect).
#
# We comment out EVERY network-online dependency line (After/Requires/Wants):
#   - After=    -> the ~1s boot win (no waiting for WiFi)
#   - Requires= -> robustness: without it, Moonraker survives a network-less boot instead of
#                  being stopped if network-online ever fails (e.g. WiFi down) — the display
#                  keeps working over localhost.
#
# NOTE: a systemd drop-in with an empty "After=" does NOT reset the list on this systemd
# version — the line has to be edited in the unit file itself. A Klipper/Moonraker reinstall
# via KIAUH would re-add it; just re-run this (or the whole System-prep) afterwards. Idempotent.
set -uo pipefail
# Overridable so the drop-in logic can be exercised against a fake tree. Nothing but a test ever sets
# it: the KAOS bridge migration below rewrites unit files and a deployed config, and "it looked right
# when I read it" is not how this project has been finding its bugs.
SD="${ARCO_SYSTEMD_DIR:-/etc/systemd/system}"

# THE OWNER'S HOME, DERIVED — never $HOME. systemd does not set HOME for services, and firstrun runs
# this script directly (`bash optimize-boot.sh`), not through a login shell the way it runs
# fetch-phrozen-fw.sh (`su - mks -c ...`). With `set -u` the first $HOME reference therefore aborted
# the entire script at line ~105, and every guard after that point was silently never installed: on
# two consecutive flashes the printer came up with 13 and 14 but without 16-19 and without the
# moonraker update-manager drop-in, and nothing said why.
#
# It took a log on the USB stick to see it, because journald here is volatile and firstrun reboots.
# An earlier attempt to reproduce it ran the script under `env -i HOME=/root` — which supplied the
# very variable that was missing, and so proved the opposite of what it was asked.
KITDIR="$(cd "$(dirname "$0")/.." && pwd)"          # <home>/arco-unleashed
AHOME="$(dirname "$KITDIR")"
AUSER="$(stat -c%U "$KITDIR" 2>/dev/null || echo mks)"
# SELFDIR is assigned in seven places further down, every one of them INSIDE an `if`. Under `set -u`
# that makes it a variable which exists only when some earlier branch happened to run -- fine while the
# users all sat inside those same branches, and a trap for anything added later at top level. That is
# the identical shape as the $HOME failure above, so: set it once, here, where it cannot be skipped.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"

# ── the off switch only works if the writer respects it ──────────────────────────────────────────
# 🔴 guards-toggle.sh turns a guard off by renaming NN-x.conf to NN-x.conf.disabled, and this script
# has rewritten every drop-in unconditionally since the day it was written: `git log -S'.conf.disabled'
# -- scripts/optimize-boot.sh` returns nothing. So every kit update quietly put back what the owner had
# switched off, because ensure-imageid.sh fires this script on the boot after an update, and
# check-guards.sh --fix runs it too. Afterwards BOTH readers report the guard as on, since both test
# .conf before .conf.disabled -- so the owner is not even told. A switch that flips itself back is
# worse than no switch, and check-guards.sh already promises in writing that --fix will not do this.
#
# The heredoc must still be consumed when we stand aside, or the shell hands its body to whatever
# runs next.
dropin(){
  if [ -e "$1.disabled" ]; then
    cat >/dev/null
    echo "  $(basename "$1"): switched off by the owner — left alone"
    return 0
  fi
  install -Dm644 /dev/stdin "$1"
}

# ── ONE RUN AT A TIME ────────────────────────────────────────────────────────────────────────────
# Three callers can fire within a minute of each other: ensure-imageid's detached `systemd-run` for an
# armed reconcile, the boot-time guard repair, and an owner at an SSH prompt. A full run takes 55-70 s
# (measured from the mtimes this script leaves behind: 17.5 s for the klipper drop-ins alone), so
# "they will not overlap" is not true and was never checked.
#
# Two at once is not merely wasteful. Most of what this writes is a small install(1) and survives any
# interleaving, but the parts that are not atomic do not: `git checkout HEAD -- klippy/mcu.py` below
# contends on index.lock, and the loser takes the "could not restore mcu.py, Klipper updates stay
# blocked" branch — turning a redundant run into a printer that cannot update. Same for the sed -i
# edits further down.
#
# REFUSE rather than wait. Waiting would only move the second full run later and pay its cost anyway;
# the work is already being done by whoever holds the lock. And the lock is taken HERE, in the one
# place all three callers pass through, rather than in each of them: a caller that holds it while
# starting this script would deadlock against its own child.
# [ -w /run ] first: `exec 9>` on a path we cannot open kills a non-interactive shell outright, and
# `|| true` does not catch it. Root can always write /run; a non-root caller skips the lock and fails
# on the first install(1) anyway, which is the honest error rather than a bogus "already running".
if command -v flock >/dev/null 2>&1 && [ -w /run ]; then
  exec 9>/run/arco-optimize-boot.lock
  if ! flock -n 9; then
    echo "  another optimize-boot run is in progress — leaving the work to it."
    exit 0
  fi
fi
changed=0
for unit in klipper.service moonraker.service; do
  f="$SD/$unit"
  [ -f "$f" ] || { echo "  $unit: not found (skipped)"; continue; }
  n=$(grep -cE '^(After|Requires|Wants)=network-online\.target[[:space:]]*$' "$f" 2>/dev/null || true)
  if [ "${n:-0}" -gt 0 ]; then
    sed -i -E 's@^(After|Requires|Wants)=network-online\.target[[:space:]]*$@#&  # arco: local MCUs / localhost, no WiFi wait@' "$f"
    echo "  $unit: commented $n network-online dependency line(s)"
    changed=1
  elif grep -qE '^#(After|Requires|Wants)=network-online' "$f"; then
    echo "  $unit: already done"
  else
    echo "  $unit: no network-online dependency (nothing to do)"
  fi
done
[ "$changed" = 1 ] && { systemctl daemon-reload; echo "  daemon-reload"; }

# klippy scheduling priority: Nice=-19 so the host scheduler favours Klipper under a sudden load burst
# (helps avoid "MCU: Timer too close"). A drop-in survives a KIAUH reinstall of the unit body. Idempotent.
if [ -f "$SD/klipper.service" ]; then
  dropin "$SD/klipper.service.d/arco-nice.conf" <<'EOF'
[Service]
Nice=-19
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: Nice=-19 drop-in installed"
fi

# phrozen_dev survival guard: keeps a copy of the module outside the Klipper tree and restores it if a
# Klipper update deleted it. Moonraker's "hard recover" is `git reset --hard` + `git clean`, which wipes
# every untracked file in klippy/ — phrozen_dev with it — and printer.cfg declares [phrozen_dev], so the
# printer halts with no display and no AMS. Numbered 13 so it runs BEFORE every other guard: the module
# has to be back on disk before the core-restore and the API patches can do anything with it.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/13-arco-phrozen-restore.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 60 $SELFDIR/apply-phrozen-restore.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: phrozen_dev survival guard (ExecStartPre) installed"
fi

# Klipper-core clobber guard: voronFDM copies v0.11 mcu.py/serialhdl.py/virtual_sdcard.py over this v0.13
# core on its first start and halts Klipper ("SerialReader ... 'warn_prefix'"). fetch-phrozen-fw.sh
# neutralizes the source when Phrozen is installed via OUR menu, but a recipient who runs Phrozen's own
# installer gets clobbered unprotected (a tester hit this 2026-07-17). This heals it before EVERY start.
# MUST come before 15-arco-mcu-timing: it restores mcu.py to pristine v0.13, then the timing patch goes on
# top. Check-first (one grep for 'warn_prefix'); a no-op in ms unless actually clobbered.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/14-arco-core-restore.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-core-restore.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: v0.13 core-restore guard (ExecStartPre) installed"
fi

# MCU host timing: RETIRED as a file patch. It used to sed three values into klippy/mcu.py before every
# klipper start, which worked -- but mcu.py is TRACKED by Klipper, so the repo was permanently dirty and
# Moonraker refuses to update a dirty repo ("Update aborted, repo has been modified"). The printer could
# therefore never take a Klipper update at all. The same values now come from the untracked extra
# klippy/extras/arco_mcu_timing.py (installed by apply-arco-extras.sh, enabled via [arco_mcu_timing]),
# which leaves Klipper's tree pristine.
#
# Migration for printers built before this: drop the old ExecStartPre and put mcu.py back the way Klipper
# shipped it -- otherwise the guard keeps re-dirtying the repo on every start and nothing is gained.
# Only touched when the file really is our patched version, so a Klipper that legitimately changed those
# lines is never clobbered.
# The nice drop-in used to be called 10-arco-nice.conf. Both names set the same thing, so a printer that
# has seen both just carries a harmless duplicate — but "harmless duplicate" is how a config becomes
# unreadable. Drop the old name once the current one exists.
[ -f "$SD/klipper.service.d/arco-nice.conf" ] && rm -f "$SD/klipper.service.d/10-arco-nice.conf"

if [ -f "$SD/klipper.service.d/15-arco-mcu-timing.conf" ]; then
  rm -f "$SD/klipper.service.d/15-arco-mcu-timing.conf"
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: removed the old mcu.py timing ExecStartPre (superseded by [arco_mcu_timing])"
fi
_MCU="$AHOME/klipper/klippy/mcu.py"
if [ -f "$_MCU" ] && grep -q '^    TIMEOUT_TIME = 10.0$' "$_MCU" 2>/dev/null; then
  if git -C "$AHOME/klipper" checkout HEAD -- klippy/mcu.py 2>/dev/null; then
    echo "  klipper: mcu.py restored to pristine — repo is clean again, updates are possible"
  else
    echo "  klipper: WARN could not restore mcu.py; repo stays dirty and Klipper updates stay blocked"
  fi
fi

# Arco first-party Klipper extras (arco_tool_gate.py etc.): install-if-missing before EVERY klipper
# start. These are NEW untracked modules -> a normal Klipper update (git pull / reset --hard) leaves
# them alone, so this is only a self-heal for a full re-clone / fresh install / git clean. It also
# guarantees the module is on disk BEFORE klippy parses its [arco_tool_gate] config section (which
# would otherwise error "unable to load module"). '-' = non-fatal; runs once per start then exits.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/16-arco-extras.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-arco-extras.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: arco extras install-if-missing (ExecStartPre) installed"
fi

# printer_gcode_macro.cfg config-patch self-heal: re-assert the SHAPER_END/BED_PROBE_END cal handshakes
# + the v0.13 g_accel_to_decel fix before EVERY klipper start. That file is Phrozen's, so a Phrozen
# firmware update / OTA reverts our edits (like a Klipper update reverts mcu.py) -> this heals them
# automatically on the next start (klippy then reads the re-patched config). No-op (grep-gated) when
# already current, or when phrozen_dev isn't installed yet. '-' = non-fatal; runs once per start.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/17-arco-config-patches.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-config-patches.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: printer_gcode_macro.cfg config-patch guard (ExecStartPre) installed"
fi

# phrozen_dev v0.13 API-patch self-heal: re-assert the 3 base.py/cmds.py fixes before EVERY klipper start.
# A Phrozen firmware update clobbers phrozen_dev (restoring its v0.11-era API), which would halt klippy on
# load; this re-patches it FIRST (ExecStartPre runs before ExecStart) so it self-heals. Idempotent +
# check-first (backs up only on real drift, no per-boot .bak spam), no-op when already patched or
# phrozen_dev absent. '-' = non-fatal; runs once per start then exits.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/18-arco-phrozen-patches.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-phrozen-patches.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: phrozen_dev v0.13 API-patch guard (ExecStartPre) installed"
fi

# Test-print guard. Phrozen's FDM_TEST.gcode is a 3DBenchy sliced for THEIR demo profile; on a printer
# running this kit it measures a machine configuration that is not the one it is running. Ours is the
# same model cut for the profile this kit ships. Numbered 23 so it runs after guard 13 has put
# phrozen_dev back -- one of the two files it maintains lives inside that module, and a Phrozen firmware
# update replaces it there and re-seeds the gcodes folder from it. See apply-test-print.sh for why this
# is a guard and not a one-time copy at install.
if [ -f "$SD/klipper.service" ] && [ -f "$SELFDIR/apply-test-print.sh" ]; then
  dropin "$SD/klipper.service.d/23-arco-test-print.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-test-print.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: test-print guard (ExecStartPre) installed"
fi

# AddOn.cfg feature delivery. New features ship as new #@FEAT blocks, and AddOn.cfg is never regenerated
# on a printer that already has one -- it holds the owner's settings. The merge used to run only from
# selfupdate.sh, which Moonraker's update manager does not use: a web-interface update is a plain
# `git pull`, so the browser button delivered the scripts and skipped the config entirely. As a guard it
# runs whichever way the update arrived. Numbered 24 so it comes after 23; the wrapper exits in
# milliseconds without starting python when there is nothing new, which is every boot but a handful.
# '-' = non-fatal.
if [ -f "$SD/klipper.service" ] && [ -f "$SELFDIR/apply-addon-merge.sh" ]; then
  dropin "$SD/klipper.service.d/24-arco-addon-merge.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-addon-merge.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: AddOn.cfg feature-merge guard (ExecStartPre) installed"
fi

# ImageId self-heal: ensure /etc/ImageId.json = {"ImageId":16} before EVERY klipper start (missing/wrong
# -> phrozen work mode stuck UNKNOW). The file lives under /etc, so this ExecStartPre uses the '+' prefix
# to run as root. Idempotent (grep-gated), '-' non-fatal.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/klipper.service.d/19-arco-imageid.conf" <<EOF
[Service]
ExecStartPre=+/usr/bin/timeout 10 $SELFDIR/ensure-imageid.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: /etc/ImageId.json guard (ExecStartPre, root) installed"
fi

# ── Move an old side-by-side KAOS bridge into the kit ───────────────────────────────────────────
# Until 2026-08-05 the bridge lived at ~/unleashed-x-kaos, beside the kit. It is a subtree of the kit
# now, so every update route carries it along by itself -- but a printer set up before that still has
# the old directory, a boot-guard drop-in pointing into it, and a kaos-bridge.cfg whose shell command
# names it. A kit update alone cannot fix any of those: two are outside the kit and one needs root.
# So it happens here, in the script owners already run with sudo after every update.
#
# What must NOT be lost is .cache: the KAOS payload KAOS_ON downloaded, and the backup of Phrozen's
# own dev.py that KAOS_OFF restores. The old directory is kept, not deleted -- if any of this is
# wrong, everything needed to go back is still on disk.
OLDB="$AHOME/unleashed-x-kaos"
NEWB="$KITDIR/unleashed-x-kaos"
if [ -d "$OLDB" ] && [ -d "$NEWB" ] && [ ! -e "$OLDB/.migrated-into-kit" ]; then
  echo "  KAOS bridge: found the old side-by-side copy at $OLDB — moving it into the kit"
  if [ -d "$OLDB/.cache" ] && [ ! -d "$NEWB/.cache" ]; then
    if cp -a "$OLDB/.cache" "$NEWB/.cache" 2>/dev/null; then
      chown -R "$AUSER:$AUSER" "$NEWB/.cache" 2>/dev/null || true
      echo "    carried the cache across (KAOS payload + vendor dev.py backup)"
    else
      echo "    WARNING: could not copy $OLDB/.cache — leaving everything as it was"
      NEWB=""
    fi
  fi
  if [ -n "$NEWB" ]; then
    # Re-point the boot guard. kaos-sideload.sh writes this drop-in from its own location, so once
    # the bridge is the in-kit one it stays correct by itself; this only repairs the inherited file.
    if [ -f "$SD/klipper.service.d/21-kaos-guard.conf" ]; then
      sed -i "s#$OLDB/scripts/kaos-guard.sh#$NEWB/scripts/kaos-guard.sh#" \
        "$SD/klipper.service.d/21-kaos-guard.conf"
      echo "    boot guard now points into the kit"
    fi
    # And the console front door, whose shell command carries an absolute path.
    KBCFG="$AHOME/printer_data/config/kaos-bridge.cfg"
    if [ -f "$KBCFG" ] && grep -q "$OLDB/scripts/kaos-sideload.sh" "$KBCFG"; then
      sed -i "s#$OLDB/scripts/kaos-sideload.sh#$NEWB/scripts/kaos-sideload.sh#" "$KBCFG"
      echo "    kaos-bridge.cfg now points into the kit (KAOS_* commands need a klipper restart)"
    fi
    touch "$OLDB/.migrated-into-kit" 2>/dev/null || true
    echo "    $OLDB is no longer used. Kept as-is; delete it once KAOS_STATUS looks right."
  fi
  systemctl daemon-reload 2>/dev/null || true
fi

# Moonraker update-manager entry. The FIRST guard on moonraker.service rather than klipper -- it edits
# moonraker.conf, which only Moonraker reads, and an ExecStartPre there lands the change before it is
# read. That also makes it self-healing against anything that replaces the config (a Phrozen update
# does exactly that to printer.cfg): the entry is back on the next Moonraker start, including the one
# Moonraker performs after updating itself. The script decides for itself whether the entry belongs
# there at all -- see its header; it is a no-op while the kit is the image's flat copy.
if [ -f "$SD/moonraker.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  dropin "$SD/moonraker.service.d/22-arco-update-manager.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 20 $SELFDIR/apply-update-manager.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  moonraker: update-manager entry guard (ExecStartPre) installed"
fi

# ── Real-time isolation for the Klipper step generator (40k-accel headroom) ──
# klippy is single-threaded on its critical path; the goal is ONE fast, uninterrupted core, not more.
# Pin klippy -> CPU3 (alone), klipper-mcu -> CPU2 (with the F407 USB IRQ), background -> CPU0-1.
# Drop-ins survive a KIAUH unit-body reinstall; re-run this if KIAUH ever rewrites a unit. Idempotent.
aff() {  # $1 = unit, $2 = CPUAffinity value
  [ -f "$SD/$1" ] || return 0
  install -d "$SD/$1.d"
  printf '[Service]\nCPUAffinity=%s\n' "$2" > "$SD/$1.d/20-arco-affinity.conf"
}
aff klipper.service        "3"
aff klipper-mcu.service    "2"
aff moonraker.service      "0 1"
aff crowsnest.service      "0 1"
aff KlipperScreen.service  "0 1"
echo "  affinity drop-ins installed (klippy->CPU3, klipper-mcu->CPU2, background->CPU0-1)"

# ...and the other half of the three lines above: pinning klippy TO CPU3 and klipper-mcu TO CPU2 never kept
# anyone else OFF those cores. With no manager default every unit may roam all four, so nginx, chronyd,
# cron, journald and sshd — and, once Phrozen's parts are installed from USB, PhrozenGo, ota_control and
# voronFDM, none of which we ship a drop-in for — land wherever. Measured on hardware: phrozen-go-relay at
# ~4% ON CPU3, MCU perfectly healthy (retransmit 9, mcu_task_avg 4µs), Klipper dead with "Timer too close"
# at homing. "background -> CPU0-1" was the stated design for weeks; nothing enforced it. This does.
#
# The value must match that design EXACTLY: 0 1, not 0 1 2. Fencing to "0 1 2" looks harmless but hands
# every service klipper-mcu's core — measured: PhrozenGo, Spoolman's uvicorn, four nginx workers, voronFDM
# and journald all sharing CPU2 with the F407 comms, and homing died again the moment one more service
# (Spoolman) joined. Delaying the MCU link starves the step queue exactly like delaying klippy does.
# Each of the four cores has one job: 0+1 everything, 2 the F407 link, 3 the step generator.
#
# klipper's and klipper-mcu's own CPUAffinity= drop-ins override this default, which is what puts them on
# their reserved cores. Covers anything Phrozen adds later with no new drop-in to remember.
# TWO TRAPS: read ONLY when PID 1 starts — daemon-reexec does nothing, it needs a REBOOT; and systemd 252
# does not expose it, `systemctl show --property=CPUAffinity` prints nothing even when active. The only
# honest check is `taskset -cp 1` (must be 0-1). Kernel threads ignore it — that is arco-wq-cpumask's job.
install -Dm644 /dev/stdin /etc/systemd/system.conf.d/arco-affinity.conf <<'EOF'
[Manager]
CPUAffinity=0 1
EOF
echo "  manager-wide CPUAffinity=0 1 installed (leaves CPU2 to klipper-mcu, CPU3 to klippy; needs a reboot)"

# THE PRICE OF THE FENCE, AND WHAT TO DO ABOUT IT. The fence above is not negotiable -- it is what keeps
# "Timer too close" away -- but it means every service on this printer shares TWO cores while two sit
# reserved. A load average that looks mild against four cores is not mild: 1.67 measured on 2026-08-12
# is ~83% of what is actually available, and it showed as an ssh banner taking 7.5-9.9 s for the first
# five minutes after a flash. Same machine, 170 ms once the burst was over.
#
# The burst is Moonraker's own startup update check -- git fetches plus PackageKit. Worth being precise
# about the blame: arco-update-refresh was suspected first and is innocent. Its log that boot reads
# "nudge timed out - moonraker is busy with its own check" twice, so both of our POSTs were refused and
# contributed nothing; delaying or dropping them would change nothing at all. The work happens either
# way. What can change is who yields, and on two cores that is the only lever there is.
#
# So: PackageKit down, ssh up. Not moonraker -- KlipperScreen talks to it, and throttling it would move
# the stutter from the console to the display, which is worse. Nothing here touches CPU2 or CPU3, the
# affinities, or klipper in any way; it only orders the queue on the two cores that were already shared.
# WHAT ACTUALLY CARRIES THIS, checked rather than assumed. CPUWeight needs the cpu controller in
# system.slice and this image has it (cgroup2, controllers "cpu memory pids"); without it the line would
# be ignored in silence. IOSchedulingClass=idle, on the other hand, does NOTHING on this board, and the
# honest place to say so is beside it: /sys/block/mmcblk1/queue/scheduler is [none], and `none` ignores
# ioprio classes entirely. Only the USB stick runs bfq, and PackageKit never writes there. It stays
# because it costs nothing and would take effect under a different scheduler, but every bit of the
# measured improvement comes from Nice=10 and CPUWeight=20. Said plainly because the first version of
# this comment claimed the IO half was doing work, and a comment that promises more than the code
# delivers is worse than no comment -- the next person budgets for an effect that was never there.
install -Dm644 /dev/stdin /etc/systemd/system/packagekit.service.d/20-arco-background.conf <<'EOF'
[Service]
Nice=10
IOSchedulingClass=idle
CPUWeight=20
EOF
install -Dm644 /dev/stdin /etc/systemd/system/ssh.service.d/20-arco-interactive.conf <<'EOF'
[Service]
CPUWeight=300
EOF
# ...and user.slice, which is the half of it that is easy to miss. ssh.service covers the LOGIN -- the
# pre-auth child that sends the banner lives in its cgroup -- but the shell you get afterwards does not:
# it is moved to /user.slice/user-1000.slice/session-N.scope. Weighting only ssh.service would have made
# connecting fast and left the console exactly as slow, which was the actual complaint.
#
# Safe here specifically because of the fence above: a logged-in human now outranks background
# maintenance on cores 0-1, while the step generator on CPU3 and the F407 link on CPU2 are untouchable
# either way. Without the fence this would be a bad idea; with it, the print cannot be affected by what
# somebody does in a shell.
install -Dm644 /dev/stdin /etc/systemd/system/user.slice.d/20-arco-interactive.conf <<'EOF'
[Slice]
CPUWeight=300
EOF
systemctl daemon-reload 2>/dev/null || true
echo "  background work yields to the console (packagekit nice+idle-IO, ssh + user.slice weight 300)"

# Webcam: bound how far a viewer may fall behind. Every Arco has the same Sonix UVC camera and the same
# BCM43430 radio, so every Arco has the same arithmetic: the camera emits ~146 KB per 720p frame with no
# quality control to turn down (it exposes none), and the SoC has no JPEG encoder to re-compress with --
# only decoders. One viewer therefore costs 16-21 Mbit/s of a link that carries 37. Two viewers do not fit.
#
# The default tcp_wmem ceiling of 4 MB lets a single slow viewer queue 28 frames. Measured during a print
# with three browser tabs open: 1.6 MB backed up per connection, the picture running ~0.7 s behind and
# drifting, then the browser giving up and reconnecting -- while a fourth viewer was starved down to
# 0.4 fps because the others had already claimed the buffers.
#
# 1 MB is the measured optimum, not a guess. Under four viewers, against the 4 MB default: throughput
# unchanged (36.3 vs 37.3 Mbit/s), latency down from 0.7 s to 0.18-0.28 s, and the bandwidth shared fairly
# (5.7/7.4/11.5 fps) instead of one viewer being starved. A single viewer gets 26 fps at 0.13 s.
#
# Do NOT tighten this further. 256 KB was tried and cost two thirds of the throughput (11.3 Mbit/s,
# 9.7 frames/s total): camera-streamer serves every viewer from one capture loop and does not release a
# capture buffer until the frame is written, so too small a socket buffer stalls the capture itself and
# starves everyone. The generous buffer is what decouples the loop from a slow client; the point here is
# only to stop it from becoming a latency reservoir.
#
# Global rather than per-listener on purpose: the ceiling is the autotuner's upper bound, not an
# allocation, and 1 MB is ~20x this LAN's bandwidth-delay product -- nothing else (ssh, uploads, an eMMC
# backup over scp) can notice it.
install -Dm644 /dev/stdin /etc/sysctl.d/98-arco-webcam.conf <<'EOF'
# Cap how many frames a slow webcam viewer may queue. See optimize-boot.sh for the measurements.
net.ipv4.tcp_wmem = 4096 16384 1048576
EOF
sysctl -q -p /etc/sysctl.d/98-arco-webcam.conf 2>/dev/null || true
echo "  webcam: viewer backlog capped at 1 MB (~7 frames) instead of 4 MB (~28)"

# A short way into the setup menu: `unleashed` instead of the full path. The menu is the one thing a new
# owner is told to open, and it was a 45-character line to retype every time.
#
# A WRAPPER, deliberately not a symlink. unleashed_setup.sh finds its own library with
# `DIR="$(cd "$(dirname "$0")" && pwd)"; source "$DIR/_arco-lib.sh"` and never calls readlink -- through a
# symlink, $0 is /usr/local/bin/unleashed, so it would look for _arco-lib.sh there and abort on the first
# line. Writing the path out costs two lines and cannot break that way.
#
# The kit is located from SUDO_USER, never from $HOME. Under `sudo unleashed` HOME is /root, and a kit
# that is not there would send the wrapper to a path that does not exist -- the same trap already fixed
# in four other scripts in this kit. /home/mks stays as the fallback for the stock owner.
install -Dm755 /dev/stdin /usr/local/bin/unleashed <<'EOF'
#!/bin/sh
# Arco Unleashed setup menu. Generated by optimize-boot.sh — change it there, not here.
if [ -n "${SUDO_USER:-}" ]; then
  home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  home="${HOME:-}"
fi
for kit in "$home/arco-unleashed" /home/mks/arco-unleashed; do
  [ -f "$kit/scripts/unleashed_setup.sh" ] && exec bash "$kit/scripts/unleashed_setup.sh" "$@"
done
echo "unleashed: no kit found (looked in $home/arco-unleashed and /home/mks/arco-unleashed)" >&2
exit 1
EOF

# ...and tell people it exists. The login banner is written once at image-build time by install-motd.sh
# and nothing has touched it since, so a printer already in the field would advertise the long path
# forever. Check-first, so this is a no-op from the second run on.
# Deliberately NOT sed: the replacements contain \033 escapes, and GNU sed reads \0 in a replacement as
# "the whole match" -- \033 would come out as the matched text followed by "33". Dropping the old text
# lines and appending the new ones keeps the escapes literal. The shebang and the line that cats the
# ASCII art do not match the filter, so they survive untouched and in place.
#
# 🔴 These two lines are a COPY of what image-toolbox/install-motd.sh writes at build time. That script
# is not on the printer, and nothing else has ever touched this file after the build -- so this is the
# only way a printer already in the field gets a corrected banner. Change one, change the other.
_motd=/etc/update-motd.d/05-arco-unleashed
# The channel is appended only when it is NOT stable. Reading .git/HEAD with one sed rather than asking
# git: this runs on every SSH login, a process start is worth avoiding there, and git as the wrong user
# would refuse the directory as "dubious ownership" and print that instead of a banner. A flat copy has
# no .git and a detached HEAD holds a sha, not a ref -- both come back empty and read as stable, which
# is the right answer for both.
_edition='_ch=$(sed -n "s|^ref: refs/heads/||p" /home/mks/arco-unleashed/.git/HEAD 2>/dev/null); [ "${_ch:-main}" = main ] && _ch="" || _ch=" · $_ch"; printf "\033[1;34m   Bookworm Edition 1.0%s\033[0m\n" "$_ch"'
_menuline="printf '\\033[0;37m   For the setup menu, type \\033[1;34munleashed\\033[0;37m and press Enter\\033[0m\\n\\n'"
if [ -f "$_motd" ] && ! { grep -qF "$_edition" "$_motd" && grep -qF "$_menuline" "$_motd"; }; then
  { grep -vE 'Bookworm Edition|etup menu' "$_motd"; printf '%s\n' "$_edition" "$_menuline"; } > "$_motd.arco-new" \
    && mv -f "$_motd.arco-new" "$_motd" && chmod +x "$_motd" \
    && echo "  console: 'unleashed' opens the setup menu (login banner updated)"
  rm -f "$_motd.arco-new"
else
  echo "  console: 'unleashed' opens the setup menu"
fi

# numpy/OpenBLAS -> single thread. The input-shaper FFT is post-motion (printer idle) and would otherwise
# spawn one worker per core, stealing the cores klippy + comms need. Bundled scipy-OpenBLAS (cortexa53
# kernel) honours OPENBLAS_NUM_THREADS; the rest are harmless no-ops on aarch64 (no MKL/VECLIB/BLIS).
if [ -f "$SD/klipper.service" ]; then
  dropin "$SD/klipper.service.d/20-arco-numpy.conf" <<'EOF'
[Service]
Environment=OPENBLAS_NUM_THREADS=1
Environment=OMP_NUM_THREADS=1
Environment=MKL_NUM_THREADS=1
Environment=NUMEXPR_NUM_THREADS=1
Environment=VECLIB_MAXIMUM_THREADS=1
Environment=BLIS_NUM_THREADS=1
EOF
  echo "  numpy single-thread drop-in installed"
fi

# IRQ affinity: keep the F407 USB-comms IRQ (dwc2) on CPU2 (clean, with klipper-mcu) and shove the
# hottest background IRQs (dw-mci = WiFi-SDIO ~2400/s, ehci = webcam) onto CPU0-1, off the real-time
# cores. Matched by IRQ NAME (numbers can differ between units). oneshot, re-applies every boot.
install -Dm755 /dev/stdin /usr/local/bin/arco-irq-affinity.sh <<'EOF'
#!/bin/bash
# F407 USB comms -> CPU2 (clean, away from the WiFi-SDIO IRQ that otherwise shares CPU0)
for i in $(awk -F: '/dwc2_hsotg|ff580000\.usb/{gsub(/ /,"",$1);print $1}' /proc/interrupts); do
  echo 2 > /proc/irq/$i/smp_affinity_list 2>/dev/null
done
# hottest background IRQs (WiFi-SDIO / eMMC + webcam EHCI) -> CPU0-1, off the real-time cores
for i in $(awk -F: '/dw-mci|ehci_hcd|ohci_hcd/{gsub(/ /,"",$1);print $1}' /proc/interrupts); do
  echo 0-1 > /proc/irq/$i/smp_affinity_list 2>/dev/null
done
logger "arco: IRQ affinity set (F407->CPU2, dw-mci/ehci->CPU0-1)"
EOF
install -Dm644 /dev/stdin "$SD/arco-irq-affinity.service" <<'EOF'
[Unit]
Description=Arco Unleashed - optimal IRQ affinity (F407 USB->CPU2, hot background IRQs->CPU0-1)
After=multi-user.target klipper.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/arco-irq-affinity.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable arco-irq-affinity.service 2>/dev/null || true
echo "  IRQ-affinity service installed + enabled"

# Unbound kernel workqueues (esp. the WiFi worker brcmf_wq) IGNORE IRQ smp_affinity and land on ANY core
# by default -- including CPU3, the core klippy reserves for real-time step generation. Under WiFi load
# brcmf_wq on CPU3 preempts klippy -> the F407 sees a step scheduled "too close" -> MCU shutdown during
# homing/printing (MCU + klippy otherwise healthy; the smoking gun is a kworker on CPU3). Restrict the
# global unbound-workqueue cpumask to CPU0-1 -> off klippy (CPU3) AND klipper-mcu/F407 comms (CPU2).
# oneshot, re-applies every boot. This is a SEPARATE lever from arco-irq-affinity (IRQs vs workqueues).
install -Dm755 /dev/stdin /usr/local/bin/arco-wq-cpumask.sh <<'EOF'
#!/bin/bash
# Keep unbound workqueues (e.g. WiFi brcmf_wq) off the real-time cores. cpumask 3 = CPU0 + CPU1.
echo 3 > /sys/devices/virtual/workqueue/cpumask           2>/dev/null || true
echo 3 > /sys/devices/virtual/workqueue/writeback/cpumask 2>/dev/null || true
logger "arco: unbound workqueue cpumask -> CPU0-1 (off real-time cores)"
EOF
install -Dm644 /dev/stdin "$SD/arco-wq-cpumask.service" <<'EOF'
[Unit]
Description=Arco Unleashed - unbound workqueue cpumask off real-time cores (CPU0-1)
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/arco-wq-cpumask.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable arco-wq-cpumask.service 2>/dev/null || true
echo "  workqueue-cpumask service installed + enabled (brcmf_wq off CPU2/3)"

# SSH host keys: the image ships WITHOUT them on purpose (build-*-image.sh strips /etc/ssh/ssh_host_*, or
# every printer in the field would share one identity and no host-key warning would mean anything). Distros
# that strip them ship a regeneration unit to match -- this base image does NOT (nothing in any unit or init
# script calls ssh-keygen), so without this, the ONLY thing creating them is arco-firstrun's stage 0a. That
# runs After=network.target, i.e. alongside/after sshd's own first start attempt: sshd finds no keys, its
# ExecStartPre=sshd -t fails, Restart=on-failure burns through the start limit in under a second, and the
# unit is refused until reset-failed -- so a later "systemctl restart ssh" cannot revive it. SSH is then
# silently dead for that whole boot. Generate the keys BEFORE sshd is ever started instead, so none of that
# race exists. ConditionPathExists=! makes it a no-op once keys are present (a skipped condition still
# satisfies the Before= ordering, so sshd is never held up).
install -Dm644 /dev/stdin "$SD/arco-ssh-hostkeys.service" <<'EOF'
[Unit]
Description=Arco Unleashed - generate SSH host keys before sshd (image ships without them)
Before=ssh.service sshd.service
After=local-fs.target
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A
[Install]
WantedBy=multi-user.target
EOF
systemctl enable arco-ssh-hostkeys.service 2>/dev/null || true
echo "  ssh-hostkey service installed + enabled (generates keys before sshd's first start)"

# F407 USB MCU: never autosuspend (prevents "Got EOF when reading from device" / MCU shutdown at idle).
# Host-side udev rule keyed to the standard Klipper USB-serial VID:PID, so it survives any F407 reflash
# (the rule re-applies on every USB connect). Idempotent.
install -Dm644 /dev/stdin /etc/udev/rules.d/99-arco-f407-no-suspend.rules <<'EOF'
# Arco Unleashed: F407 Klipper MCU (1d50:614e) must never USB-autosuspend.
ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="1d50", ATTR{idProduct}=="614e", ATTR{power/control}="on"
EOF
udevadm control --reload-rules 2>/dev/null || true
echo "  F407 USB no-suspend udev rule installed"

# /etc/ImageId.json gates the phrozen_dev image-specific code. Missing -> work mode stuck
# UNKNOW(0) -> AMS/mode handling breaks right after the input-shaper step. ImageId 16 = ARCO300-MKS-RK3328.
# Create only if absent, so a phrozen FW install that ships its own copy is not clobbered. Idempotent.
if [ ! -f /etc/ImageId.json ]; then
  printf '%s\n' '{"ImageId":16,"HwId":0,"FwId":0,"NC0":0,"NC1":0,"NC2":0,"NC3":0,"NC4":0}' > /etc/ImageId.json
  echo "  /etc/ImageId.json created (ImageId=16)"
fi

# Wired / USB-Ethernet: give it an address.
# systemd-networkd only touches interfaces it has a .network for, and the image ships exactly one:
# 20-wlan.network, Name=wlan0. NetworkManager -- which brought up a wired NIC by itself on stock --
# is disabled here on purpose (one owner for wlan0, no contention). The result was that a USB
# Ethernet adapter enumerated fine, got an interface, and then sat there with no DHCP, no address
# and no route. From the outside that reads as "the adapter stopped being recognised after the
# migration", which sent a tester looking at the dongle and the hub. It was neither: the USB stick
# on the SAME hub mounted normally, which is what proves the hub and the USB path were fine.
# The match is deliberately broad. A USB NIC's name depends on udev's naming policy and on the
# adapter's own MAC, so it can be end0, eth0 or enx<mac>; pinning one name would fix exactly one
# dongle and leave the next tester in the same place. DHCP only -- no static addressing, ever.
_WN="$(cd "$(dirname "$0")" && pwd)/../config-templates/25-wired.network"
if [ ! -f "$_WN" ]; then
  echo "  wired/USB-Ethernet: SKIPPED — $_WN is missing from the kit"
elif cmp -s "$_WN" /etc/systemd/network/25-wired.network; then
  :                                  # already current — say nothing on the happy path
else
  install -Dm644 "$_WN" /etc/systemd/network/25-wired.network
  # Reload rather than restart: restarting systemd-networkd on a printer that is reachable only
  # over WiFi would drop the very connection the operator is using to run this.
  networkctl reload 2>/dev/null || true
  echo "  wired/USB-Ethernet DHCP installed (25-wired.network) — a dongle now gets an address"
fi

# ── Wi-Fi: four things the move from NetworkManager to systemd-networkd left behind ────────────────
# The full image runs systemd-networkd + systemd-resolved + wpa_supplicant@wlan0 and keeps
# NetworkManager disabled on purpose. Everything Wi-Fi-facing that still assumed NetworkManager, or that
# assumed a root-owned control socket was fine, quietly stopped working. All four found 2026-08-06.

# 1. wpa_supplicant's control socket is root:root 0750, and voronFDM runs as the printer user. So
#    `wpa_cli -i wlan0 scan_results` answers "Permission denied" and the display's network page is EMPTY
#    on EVERY Unleashed printer -- not a tester's fault, ours. The user is already in netdev; only the
#    directory never carried the group. Done as ExecStartPost rather than GROUP= in the .conf so the
#    file holding the credentials is never rewritten: getting that wrong costs the printer its network,
#    and we now know there is no easy way back.
if [ -f /lib/systemd/system/wpa_supplicant@.service ] || [ -f "$SD/wpa_supplicant@.service" ]; then
  install -Dm644 /dev/stdin "$SD/wpa_supplicant@wlan0.service.d/10-arco-netdev.conf" <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'sleep 1; chgrp -R netdev /run/wpa_supplicant 2>/dev/null; chmod 750 /run/wpa_supplicant 2>/dev/null; chmod g+rw /run/wpa_supplicant/* 2>/dev/null; true'
EOF
  # Apply it to the RUNNING supplicant too. Restarting it would drop the very connection an owner is
  # most likely running this over, and these are permissions on a runtime directory -- nothing to lose.
  if [ -d /run/wpa_supplicant ]; then
    chgrp -R netdev /run/wpa_supplicant 2>/dev/null || true
    chmod 750 /run/wpa_supplicant 2>/dev/null || true
    chmod g+rw /run/wpa_supplicant/* 2>/dev/null || true
  fi
  echo "  wpa_supplicant: ctrl-interface group netdev (display can list networks now, no restart needed)"
fi

# 2. No fallback nameserver. A router that hands out DHCP without a DNS server takes the printer off the
#    internet completely -- update manager "INVALID", no module download, and `apt` cannot fetch
#    stm32flash for the MCU flash, which is the one step nobody can skip. FallbackDNS, not DNS: it is
#    consulted only when nothing else is configured, so a working router still wins.
if [ -d /etc/systemd ] && systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
  install -Dm644 /dev/stdin /etc/systemd/resolved.conf.d/arco-fallback-dns.conf <<'EOF'
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9 8.8.8.8
EOF
  systemctl try-restart systemd-resolved 2>/dev/null || true
  echo "  systemd-resolved: FallbackDNS installed (DHCP without a nameserver no longer kills the network)"
fi

# 3. /boot/arco-wifi.txt -- the PC-editable last way in -- was driven by nmcli only, so on the full image
#    it did nothing whatsoever. The kit's replacement detects the stack and is correct on both.
_FW="$SELFDIR/arco-firstwifi"
if [ -f "$_FW" ]; then
  if ! cmp -s "$_FW" /usr/local/sbin/arco-base-firstwifi; then
    install -Dm755 "$_FW" /usr/local/sbin/arco-base-firstwifi
    echo "  /boot/arco-wifi.txt: helper replaced with the stack-aware one (nmcli-only version was a no-op here)"
  fi
fi

# 4. Nothing ever re-armed the setup portal. See arco-wifi-rearm.sh for what it does and, just as
#    important, what it deliberately refuses to do.
if [ -f "$SELFDIR/arco-wifi-rearm.sh" ]; then
  install -Dm644 /dev/stdin "$SD/arco-wifi-rearm.service" <<EOF
[Unit]
Description=Arco Unleashed - re-arm the Wi-Fi setup portal when no network is configured
After=network.target wpa_supplicant@wlan0.service
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/bin/bash $SELFDIR/arco-wifi-rearm.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-wifi-rearm.service 2>/dev/null || true
  echo "  wifi-rearm service installed + enabled (setup portal returns if the config is ever lost)"
fi

# 5. unleashed.local — so nobody has to go hunting in a router's device list.
#    Finding the printer is the first wall a new owner hits: at that point in the manual the display is
#    still sitting on the "Error occurred" screen (Klipper cannot start until the MCUs are flashed), so
#    the IP cannot be read there, and the router's list is all that is left. systemd-resolved already
#    speaks mDNS -- it is simply switched off per-link, so nothing answers for the host name. Turning it
#    on makes `ssh mks@unleashed.local` work from Windows, macOS and Linux alike, with no extra package
#    and no avahi.
#
#    The name published is the HOST NAME, and resolved has no notion of an alias -- so the host name is
#    what changes. Stock is `mkspi`, which is Makerbase's board, not this printer. Renaming is safe here:
#    nothing in the kit, the Klipper config or phrozen_dev refers to it (checked 2026-08-08); only
#    /etc/hostname and /etc/hosts do, and they must move together or every sudo waits on a name that no
#    longer resolves.
#
#    🔴 ONLY when it is still the factory name. An owner who named their printer themselves keeps it --
#    we are replacing a manufacturer default, not claiming the field.
if [ "$(cat /etc/hostname 2>/dev/null)" = "mkspi" ]; then
  if hostnamectl set-hostname unleashed 2>/dev/null || printf 'unleashed\n' > /etc/hostname; then
    # 127.0.1.1 is what sudo and friends resolve; leave 127.0.0.1/localhost alone.
    sed -i -e 's/^\(127\.0\.1\.1[[:space:]]\+\)mkspi\b/\1unleashed/' \
           -e 's/\bmkspi\b/unleashed/g' /etc/hosts 2>/dev/null || true
    hostname unleashed 2>/dev/null || true
    echo "  host name mkspi -> unleashed (so the printer answers to unleashed.local)"
  fi
fi

#    And the belt to that brace: a note on the USB stick. mDNS is blocked on plenty of routers and on
#    nearly every guest network, and then the router's device list is the only way left — which assumes
#    the owner can get into their router. The stick is already in the printer during setup and is read on
#    the machine they are sitting at, so it is the one channel that always works.
if [ -f "$SELFDIR/arco-write-ip.sh" ]; then
  install -Dm644 /dev/stdin "$SD/arco-write-ip.service" <<EOF
[Unit]
Description=Arco Unleashed - write the printer's address onto the USB stick
After=network.target
Wants=network.target

[Service]
# simple, for the same reason as arco-update-refresh: the script polls for an address up to 40 times
# at 3 s, so as a oneshot under multi-user.target it can hold the boot for two minutes -- and it does
# that precisely on the printer that has no Wi-Fi yet, which is the first boot of every new owner.
# Nothing waits on this unit's result; the file it writes is read later, by a human, off the stick.
Type=simple
ExecStart=/bin/bash $SELFDIR/arco-write-ip.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-write-ip.service 2>/dev/null || true
  systemctl start --no-block arco-write-ip.service 2>/dev/null || true
  echo "  write-ip service installed + started (drops ip.txt on the stick, refreshed every boot)"
fi

if [ -f /etc/systemd/network/20-wlan.network ]; then
  install -Dm644 /dev/stdin /etc/systemd/network/20-wlan.network.d/10-arco-mdns.conf <<'EOF'
[Network]
MulticastDNS=yes
EOF
  networkctl reload 2>/dev/null || true
  # resolved reads the per-link setting from networkd, so it needs to be told to look again.
  systemctl try-restart systemd-resolved 2>/dev/null || true
  echo "  mDNS on wlan0 (the printer answers to unleashed.local — no router lookup needed)"
fi

# 6. The update manager shows INVALID after every fresh flash, and stays that way. Moonraker's first
#    update check runs before Wi-Fi and DNS are up, fails on "Could not resolve host: github.com", and
#    CACHES that. It never retries by itself. Proven on hardware 2026-08-07: DNS resolving fine while
#    the panel still said INVALID, one refresh flipping both components to valid with real versions.
#    Two testers reported it as a fault. The danger is not the label -- it is that INVALID is exactly
#    the state in which Moonraker offers "Hard Recover", which deletes phrozen_dev.
# 6b. Seed the console filter that hides phrozen_dev's self-narration in Mainsail and Fluidd. Both keep
#     their settings in Moonraker's database rather than a file, so this cannot be dropped in at bake
#     time -- it needs Moonraker answering. Same unit shape as the refresh watcher below and for the same
#     reason: Type=simple, so waiting for Moonraker never holds up the boot.
if [ -f "$SELFDIR/apply-console-filters.sh" ]; then
  install -Dm644 /dev/stdin "$SD/arco-console-filters.service" <<EOF
[Unit]
Description=Arco Unleashed - seed the Phrozen-noise console filter into Mainsail and Fluidd
After=moonraker.service network.target
Wants=moonraker.service

[Service]
# oneshot rather than simple, so a SECOND ExecStart is allowed: the macro groups need exactly the same
# preconditions as the filters -- Moonraker up, its database reachable over HTTP -- and waiting for that
# twice, in two units, would be two chances to get the ordering wrong. RemainAfterExit stays off; both
# jobs are one-shot seeds and the unit going inactive afterwards is the correct end state.
Type=oneshot
ExecStart=/bin/bash $SELFDIR/apply-console-filters.sh
ExecStart=-/usr/bin/python3 $SELFDIR/apply-macro-groups.py
# Third seed, same preconditions, same one-shot nature: Fluidd ships the card our AMS and
# USB-stick indicators are drawn on DISABLED, so installing the indicators left them invisible on
# the second interface. --seed refuses the moment a layout exists, so it fills an untouched
# dashboard and never edits somebody's arrangement.
ExecStart=-/usr/bin/python3 $SELFDIR/../fluidd-theme/show-runout-card.py --seed
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-console-filters.service >/dev/null 2>&1 || true
  echo "  web-interface seeder installed + enabled (console filter + macro groups, both UIs)"
fi

# ── heal a truncated guard set BEFORE klipper starts ─────────────────────────────────────────────
# The drop-ins above are what makes this kit self-healing, and commit=120 plus the power-cycle we ask
# for can leave them present and empty -- taking out the only root-privileged ExecStartPre and with it
# the ability to reinstall anything. The sync at the end of this script stops that happening again;
# this unit is what fixes it when it already has. It is a FULL unit file on purpose: that is exactly
# the shape the failure does not touch.
#
# Ordered Before=klipper so a damaged printer is whole in the SAME boot rather than the next one. On a
# healthy printer it is a stat over a dozen files and klipper waits microseconds for it. TimeoutStartSec
# is not decoration: a repair that hung would otherwise hold up the boot with no way to see why.
#
# repair-guards.sh is ALSO called from apply-console-filters.sh, and that is not redundancy -- it is
# the only way onto a printer that is already broken, because installing this unit needs the root path
# that is missing there. The two are kept apart by ORDER and by a LOCK, not by hope: a full run takes
# 55-70 s and console-filters starts ~45 s into the boot, so the second caller genuinely would still
# see zero-length files and start a competing run. Before= settles the ordering; the flock at the top
# of this script settles the rest, including ensure-imageid's detached reconcile run.
if [ -f "$SELFDIR/repair-guards.sh" ]; then
  install -Dm644 /dev/stdin "$SD/arco-guard-repair.service" <<EOF
[Unit]
Description=Arco Unleashed - put the self-heal guards back if a power-cycle truncated them
After=local-fs.target
Before=klipper.service
Before=arco-console-filters.service

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=-/bin/bash $SELFDIR/repair-guards.sh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-guard-repair.service >/dev/null 2>&1 || true
  echo "  guard self-repair installed + enabled (runs before klipper)"
fi

if [ -f "$SELFDIR/arco-update-refresh.sh" ]; then
  install -Dm644 /dev/stdin "$SD/arco-update-refresh.service" <<EOF
[Unit]
Description=Arco Unleashed - re-check the update manager once the network is really up
After=moonraker.service network.target
Wants=moonraker.service

[Service]
# Type=simple, NOT oneshot -- and this is the whole point of the unit's shape. A oneshot pulled in by
# multi-user.target holds that target until the process exits, and this process is a WATCHER that may
# legitimately sit for twelve minutes. Measured on the first boot after the 2026-08-11 flash:
# "Startup finished in 5.067s (kernel) + 8min 36.217s (userspace)", of which 8min 22.156s was this
# unit alone -- the printer felt broken for the whole window (an ssh login took 15 s), and the only
# thing wrong was that we were waiting for ourselves. The --no-block below already guarded the manual
# start against exactly this and the reasoning was written down there; the boot path was missed.
# With simple, systemd calls the unit started the moment it is exec'd, the boot carries on, and the
# watcher keeps watching in the background where its patience costs nobody anything.
Type=simple
ExecStart=/bin/bash $SELFDIR/arco-update-refresh.sh
# It talks to the network and to git the whole time it runs. Off the boot's critical path it is no
# longer urgent, so let everything else have the machine first.
Nice=10
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable arco-update-refresh.service 2>/dev/null || true
  # ...and start it NOW, not only from the next boot. An owner who updates the kit on a printer that is
  # already showing INVALID would otherwise have to reboot before the fix they just installed does
  # anything -- which is the one thing they were trying to avoid. The unit stamps itself done, so this
  # costs nothing on a printer that is already fine.
  # --no-block matters: this same script also runs inside arco-firstrun, and a plain `start` on a
  # oneshot WAITS for it. That unit can legitimately sit for minutes waiting for moonraker and for name
  # resolution, and blocking the first-boot setup behind it would be a self-inflicted stall.
  systemctl start --no-block arco-update-refresh.service 2>/dev/null || true
  echo "  update-refresh service installed + started (clears the post-flash INVALID by itself)"
fi

# THE RELAY IS DEPLOYED ONCE AND NEVER AGAIN, which makes every improvement to it unreachable for a
# printer that already exists. install-wsrelay.sh is called from arco-firstrun.sh and from nowhere else,
# so relay.py is copied to ~/wsrelay on the FIRST boot and a later kit update leaves that copy untouched
# for good -- the fix sits in the kit, the printer keeps running the old file, and nothing says so.
# This is the same shape as the guards: the kit knows better than the machine, and something has to
# carry it across. optimize-boot runs as root and is what the post-update reconcile executes, which
# makes it the one place that can.
#
# Copy only, deliberately NOT a restart. Restarting the relay drops voronFDM's socket without the clean
# CLOSE that its reconnect is gated on, and voronFDM does not come back from that on its own -- measured
# 2026-08-12. The new file is a boot-time robustness fix anyway, so it may as well take effect at the
# next boot together with everything else here.
if [ -f "$SELFDIR/wsrelay/relay.py" ] && [ -f "$AHOME/wsrelay/relay.py" ] \
   && ! cmp -s "$SELFDIR/wsrelay/relay.py" "$AHOME/wsrelay/relay.py"; then
  install -o "$AUSER" -g "$AUSER" -m 644 "$SELFDIR/wsrelay/relay.py" "$AHOME/wsrelay/relay.py"
  echo "  wsrelay: relay.py refreshed from the kit (active after the next boot; not restarted on purpose)"
fi

# Reconcile guard: install it, and record which kit version root has now seen.
#
# The stamp is the whole mechanism. apply-reconcile-check.sh compares the kit's current commit against
# it before every klipper start and arms the reconcile when they differ -- which is how a kit updated
# from Mainsail or Fluidd (a plain `git pull`, never calling after_update()) still gets its root-side
# work done. Written LAST, so it only ever records a run that actually reached the end.
if [ -f "$SD/klipper.service" ] && [ -f "$SELFDIR/apply-reconcile-check.sh" ]; then
  dropin "$SD/klipper.service.d/25-arco-reconcile-check.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 20 $SELFDIR/apply-reconcile-check.sh
EOF
  echo "  klipper: reconcile check (ExecStartPre) installed"
fi

# Mainsail theme refresh. Deliberately LAST of the drop-ins and outside the config chain: it writes
# nothing klippy reads, so a slow or failing run must not stand between the printer and its start.
#
# It closes the delivery gap the theme had from the beginning. Mainsail reads the theme from
# printer_data/config/.theme/ -- which is exactly why it survives a Mainsail update -- but the kit
# only ever copied it there ONCE, at install. Every later change to mainsail-theme/variants/ reached
# the clone and stopped, while the printer went on serving its old copy and the update reported
# success. The script only refreshes a theme that is already installed, and never deletes.
if [ -f "$SD/klipper.service" ] && [ -f "$SELFDIR/apply-theme-variants.sh" ]; then
  dropin "$SD/klipper.service.d/26-arco-theme.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 20 $SELFDIR/apply-theme-variants.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: Mainsail theme refresh (ExecStartPre) installed"
fi

# ── git over HTTPS: force HTTP/1.1 ─────────────────────────────────────────────────────────────────
# WHAT BREAKS WITHOUT IT. git's protocol v2 over HTTP/2 gets a 401 from GitHub on the second request.
# The ref listing succeeds anonymously, and then the POST that actually fetches is answered with
# "www-authenticate: Basic realm=GitHub" -- so git asks for a username and password for a PUBLIC
# repository. Every git operation on the printer is affected, not just ours: Klipper, Moonraker and
# KlipperScreen all fail the same way, which takes Moonraker's update manager down with them. What the
# owner sees is a credential prompt every time they open the setup menu, and updates that never arrive.
#
# ISOLATED RATHER THAN GUESSED, on 2026-09-02:
#   curl, same POST, anonymous            -> HTTP 200
#   git -c protocol.version=0             -> works
#   git -c protocol.version=2             -> 401, asks for credentials
#   git -c protocol.version=2 http/1.1    -> works
# So it is neither the repository, nor credentials, nor the network -- it is that one combination.
# Forcing HTTP/1.1 keeps protocol v2 and everything it gives; the only cost is a slightly less
# efficient transport, which for a handful of fetches is nothing.
#
# WRITTEN INTO THE OWNER'S FILE, NOT ROOT'S. This script runs as root, so `git config --global` would
# land in /root/.gitconfig and help nobody: every git command that matters here runs as the printer
# user, from the menu, from Moonraker, or from a guard.
if [ -n "${AHOME:-}" ] && command -v git >/dev/null 2>&1; then
  _gcfg="$AHOME/.gitconfig"
  if [ "$(git config --file "$_gcfg" --get http.version 2>/dev/null)" != "HTTP/1.1" ]; then
    if git config --file "$_gcfg" http.version HTTP/1.1 2>/dev/null; then
      chown "$AUSER:$AUSER" "$_gcfg" 2>/dev/null || true
      echo "  git: http.version=HTTP/1.1 for $AUSER (GitHub refuses git's protocol-v2 POST over HTTP/2)"
    else
      echo "  git: WARN could not write $_gcfg — fetches may still ask for GitHub credentials"
    fi
  fi
fi

# ── Retire the TFT reprint bridge ──────────────────────────────────────────────────────────────────
# WHAT IT WAS. A helper that read voronFDM's stdout, recovered the filename the display printed there,
# and sent the printer.print.start the display itself was not sending. It treated a symptom: the
# display was waiting for a message our own G30 override had stopped producing. That is fixed in
# AddOn.cfg now and the display starts its own prints again -- verified end to end on 2026-08-28, with
# the helper stopped: G30 went out and print.start followed five seconds later.
#
# WHY IT HAS TO BE UNWOUND RATHER THAN JUST DELETED FROM THE KIT. It was launched from
# apply-phrozen-patches.sh on every klipper start, so it has been running on every printer in the
# field -- not, as first assumed, only where somebody started it by hand. It needed voronFDM's stdout,
# which it obtained by rewriting Phrozen's KlipperScreen-start.sh to send that output to a capture file
# instead of /dev/null. The logrotate rule that was meant to cap the file was installed only by a
# script nothing ever called, so the file has been growing unbounded -- roughly 18 MB a day, with
# nobody reading it. Deleting the helper alone would leave the redirect and the file behind for ever.
#
# The capture file is unlinked rather than truncated: voronFDM holds it open without O_APPEND, so
# truncating would leave it writing past a hole. The space comes back when the display next restarts.
if [ -n "${AHOME:-}" ]; then
  _KS="$AHOME/klipper/klippy/extras/phrozen_dev/KlipperScreen-start.sh"
  _rb=0
  pkill -f "[a]rco-reprint-bridge" 2>/dev/null && _rb=1
  if [ -f "$_KS" ] && grep -q 'serial-screen/voronFDM >[^ ]*vfdm-capture\.log' "$_KS" 2>/dev/null; then
    sed -i 's#serial-screen/voronFDM >[^ ]*vfdm-capture\.log 2>&1 #serial-screen/voronFDM >/dev/null 2>\&1 #' "$_KS" \
      && { _rb=1; echo "  reprint bridge: voronFDM stdout redirect reverted to /dev/null"; }
  fi
  for _f in "$AHOME/wsrelay/arco-reprint-bridge.py" "$AHOME/vfdm-capture.log" "$AHOME/arco-reprint-bridge.out"; do
    [ -e "$_f" ] && { rm -f "$_f" && _rb=1; }
  done
  if [ -f "$SD/arco-reprint-bridge.service" ]; then
    systemctl disable --now arco-reprint-bridge.service >/dev/null 2>&1 || true
    rm -f "$SD/arco-reprint-bridge.service"
    systemctl daemon-reload 2>/dev/null || true
    _rb=1
  fi
  if [ -f /etc/logrotate.d/arco-vfdm-capture ]; then rm -f /etc/logrotate.d/arco-vfdm-capture; _rb=1; fi
  [ "$_rb" = 1 ] && echo "  reprint bridge retired (helper, capture log and unit removed)"
fi
_kit_commit=""
if [ -d "$SELFDIR/../.git" ] && command -v git >/dev/null 2>&1; then
  git config --global --add safe.directory "$(cd "$SELFDIR/.." && pwd)" 2>/dev/null || true
  # -c safe.directory, not just the --global write above. This runs as ROOT against a clone owned by
  # the printer's user, and git refuses that as "dubious ownership" unless it is allowed. The --global
  # write needs a HOME to land in, and under systemd-run there need not be one -- so it did nothing,
  # rev-parse returned nothing, and the fallback below stamped the flat .kit-commit that ships INSIDE
  # the image. That value never changes, so the stamp could never match the kit, and once drop-in 25
  # existed the reconcile re-armed on EVERY klipper start -- a full optimize-boot run each time.
  # Found on a printer stamped 5d1efdfa (the full/1.0 commit) while its kit was 89 commits further on.
  _kit_commit="$(git -c safe.directory='*' -C "$SELFDIR/.." rev-parse HEAD 2>/dev/null || true)"
  [ -n "$_kit_commit" ] || echo "  WARNING: clone present but HEAD unreadable -- .kit-commit is stale"
fi
[ -n "$_kit_commit" ] || _kit_commit="$(tr -dc '0-9a-f' < "$SELFDIR/../.kit-commit" 2>/dev/null | head -c 40)"
if [ -n "$_kit_commit" ] && [ -d "$AHOME/printer_data" ]; then
  printf '%s' "$_kit_commit" > "$AHOME/printer_data/.arco-reconcile-done" 2>/dev/null \
    && chown "$AUSER":"$AUSER" "$AHOME/printer_data/.arco-reconcile-done" 2>/dev/null
  rm -f "$AHOME/printer_data/.arco-reconcile-pending" 2>/dev/null
  echo "  kit: root-side setup recorded for ${_kit_commit:0:8}"
fi

# 🔴 SYNC BEFORE SAYING DONE. Every drop-in above was written with install(1), and / is mounted with
# commit=120 -- so ext4 may hold the contents for up to two minutes while the directory entry is
# already visible. The kit then asks the owner for a POWER-CYCLE, which is exactly the wrong moment:
# on 02.09.2026 the dev printer came back with SIX guard drop-ins present and 0 bytes long, written
# 90 seconds before the boot. The file names survive, the ExecStartPre lines do not, and the guards
# silently stop running. Worse, 19-arco-imageid is the only root-privileged one, so its loss removes
# the consumer of the reconcile marker while 25 keeps re-arming it -- a dead end whose only exit is
# running this script by hand. One sync costs nothing and closes it. Same reason apply-reconcile-check
# and channel.sh already sync their markers.
sync 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
echo "  done (takes effect on next boot)."
