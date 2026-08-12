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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/arco-nice.conf" <<'EOF'
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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/13-arco-phrozen-restore.conf" <<EOF
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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/14-arco-core-restore.conf" <<EOF
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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/16-arco-extras.conf" <<EOF
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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/17-arco-config-patches.conf" <<EOF
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
  install -Dm644 /dev/stdin "$SD/klipper.service.d/18-arco-phrozen-patches.conf" <<EOF
[Service]
ExecStartPre=-/usr/bin/timeout 30 $SELFDIR/apply-phrozen-patches.sh
EOF
  systemctl daemon-reload 2>/dev/null || true
  echo "  klipper: phrozen_dev v0.13 API-patch guard (ExecStartPre) installed"
fi

# ImageId self-heal: ensure /etc/ImageId.json = {"ImageId":16} before EVERY klipper start (missing/wrong
# -> phrozen work mode stuck UNKNOW). The file lives under /etc, so this ExecStartPre uses the '+' prefix
# to run as root. Idempotent (grep-gated), '-' non-fatal.
if [ -f "$SD/klipper.service" ]; then
  SELFDIR="$(cd "$(dirname "$0")" && pwd)"
  install -Dm644 /dev/stdin "$SD/klipper.service.d/19-arco-imageid.conf" <<EOF
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
  install -Dm644 /dev/stdin "$SD/moonraker.service.d/22-arco-update-manager.conf" <<EOF
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

# numpy/OpenBLAS -> single thread. The input-shaper FFT is post-motion (printer idle) and would otherwise
# spawn one worker per core, stealing the cores klippy + comms need. Bundled scipy-OpenBLAS (cortexa53
# kernel) honours OPENBLAS_NUM_THREADS; the rest are harmless no-ops on aarch64 (no MKL/VECLIB/BLIS).
if [ -f "$SD/klipper.service" ]; then
  install -Dm644 /dev/stdin "$SD/klipper.service.d/20-arco-numpy.conf" <<'EOF'
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

systemctl daemon-reload 2>/dev/null || true
echo "  done (takes effect on next boot)."
