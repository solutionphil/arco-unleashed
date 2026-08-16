# arco_fila_status.py — Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here.
#
# Make the toolhead filament sensor VISIBLE, and refuse to print into thin air.
#
# Detection stays where it belongs -- inside phrozen_dev, which owns the pin. This publishes what that
# module keeps to itself, and adds the one thing nothing on this printer does: notice, ONCE, shortly
# after a job starts, that the sensor says there is no filament, and pause. phrozen_dev's runout logic
# is a timer that watches for a CHANGE during the job, so a print that begins with nothing loaded is
# not a runout to it and never triggers. In AMS mode it does not look at the toolhead sensor at all.
# A printer whose AMS was not feeding therefore printed air for hours, silently, on 2026-08-15.
#
# Why it is needed: phrozen_dev has no get_status(), so its filament state exists purely as a
# Python attribute. Consequences on a stock Unleashed printer:
#   * Mainsail/Fluidd show no filament sensor at all (the object name is 'phrozen_dev', and it
#     reports nothing), so there is no panel, no state, no history.
#   * Runout protection is gated on 'P0 Mn' having been sent (phrozen_dev dev.py: work mode 0 =
#     UNKNOW returns immediately from the runout timer). A print started from a slicer profile
#     that never sends P0 runs with NO runout protection AND NO indication of that -- for hours.
# 'protection_active' below closes exactly that gap, and the print-start warning surfaces it at
# the only moment it still matters.
#
# Deliberately read-only, and that is the whole design:
#   * It does NOT claim the ADC pin. phrozen_dev already owns MKS_THR:PA2 (base.py setup_pin),
#     and Klipper refuses a second claim on the same pin ("pin ... used multiple times in
#     config") -- klippy would not start. The raw value is read back through query_adc, which
#     phrozen_dev registers as 'prz_adc'; that is the same path QUERY_ADC itself uses.
#   * It does NOT register or override any existing command, and it is not in phrozen_dev's own
#     pause path -- the one pause it can cause is its own, from a definite EMPTY reading.
# Worst case at every failure mode below: the status reads 'unknown' and the printer runs on.
#
# Update survival: this file is untracked in Klipper's tree, so a git pull / reset --hard leaves
# it alone; a 'git clean' (hard recover) is repaired by scripts/apply-arco-extras.sh, which runs
# as an ExecStartPre before klipper starts. It touches nothing Phrozen ships, so a Phrozen
# firmware update cannot revert it. The one thing an update CAN change is phrozen_dev's internal
# attribute names -- hence every read below goes through getattr() with a default: renamed
# internals degrade this to 'unknown', they do not raise.
#
# Config:
#   [arco_fila_status]
#   #adc_name: prz_adc            # query_adc name phrozen_dev registers (base.py)
#   #warn_on_print_start: True    # console warning when a print runs unprotected
#   #warn_delay: 300.0            # seconds into the job before that check runs
#   #check_interval: 2.0          # seconds between job-state polls
#   #pause_on_empty: True         # pause a job that starts with an empty toolhead sensor
#   #pause_delay: 90.0            # seconds into the job before THAT check runs (see below)
#   #ams_port: /dev/ttyACM1       # its existence is what "an AMS is attached" means
#
# Status (printer['arco_fila_status'] / Moonraker):
#   available, filament_present, adc, threshold, mode, mode_name, protection_active,
#   ams_present (an AMS is attached), ams_answered (it has actually replied — see _read)
# Command:
#   FILA_STATUS  -- print all of the above to the console

import logging
import os

PHROZEN_OBJECT = 'phrozen_dev'

# phrozen_dev work modes (base.py: AMS_WORK_MODE_*). 0 disables its runout timer outright.
MODE_NAMES = {
    0: 'unknown (no P0 sent — no runout protection)',
    1: 'AMS multicolor',
    2: 'AMS single-color refill',
    3: 'standalone runout',
}


class ArcoFilaStatus:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.adc_name = config.get('adc_name', 'prz_adc')
        self.warn_on_print_start = config.getboolean('warn_on_print_start', True)
        self.warn_delay = config.getfloat('warn_delay', 300., above=0.)
        self.check_interval = config.getfloat('check_interval', 2., above=0.)
        self.ams_port = config.get('ams_port', '/dev/ttyACM1')
        self.pause_on_empty = config.getboolean('pause_on_empty', True)
        # 90 s, not 0. print_stats says "printing" the moment the job is accepted, and the start
        # G-code then heats, homes and -- in AMS mode -- has the AMS feed the toolhead. The sensor is
        # legitimately EMPTY for part of that. Checking at the transition would abort good prints; the
        # cost of waiting is a minute and a half of air in the case it is meant to catch, against
        # hours of it today.
        self.pause_delay = config.getfloat('pause_delay', 90., above=0.)
        self._phrozen = None
        self._mcu_adc = None
        self._deadline = None
        self._warned = False
        self._pause_deadline = None
        self._pause_checked = False
        # phrozen_dev may be constructed after us (config order is not ours to dictate), so
        # resolve both objects at ready rather than here.
        self.printer.register_event_handler('klippy:ready', self._handle_ready)
        self.gcode.register_command('FILA_STATUS', self.cmd_FILA_STATUS,
                                    desc=self.cmd_FILA_STATUS_help)

    def _handle_ready(self):
        self._phrozen = self.printer.lookup_object(PHROZEN_OBJECT, None)
        query_adc = self.printer.lookup_object('query_adc', None)
        if query_adc is not None:
            self._mcu_adc = getattr(query_adc, 'adc', {}).get(self.adc_name)
        if self._phrozen is None:
            logging.info("arco_fila_status: no [%s] in the config — filament state "
                         "unavailable (status reports available=False)", PHROZEN_OBJECT)
        elif self._mcu_adc is None:
            logging.info("arco_fila_status: query_adc has no '%s' — raw ADC unavailable "
                         "(presence/protection still reported)", self.adc_name)
        # Either feature needs the poll. Gating it on warn_on_print_start alone meant switching the
        # warning off silently switched the pause off with it.
        if self.warn_on_print_start or self.pause_on_empty:
            self.reactor.register_timer(self._poll, self.reactor.NOW + 5.)

    # --- reading phrozen_dev ------------------------------------------------------------
    def _read(self):
        ph = self._phrozen
        st = {'available': ph is not None, 'filament_present': None, 'adc': None,
              'threshold': None, 'mode': None, 'mode_name': 'unavailable',
              'protection_active': False,
              # Two different questions, deliberately both published.
              #
              # ams_present — is an AMS attached? The serial node exists from the moment it is plugged
              # in and enumerated, needs no conversation, and is available at any time including at
              # boot. This is the one macros should gate on.
              #
              # ams_answered — has it actually replied? phrozen_dev only learns that inside P8 (the
              # feed), by sending "SD" and checking for a full status frame, so it stays False until an
              # AMS print has begun. Useful to report, useless to gate on: a gate reading it at
              # klippy:connect would conclude "no AMS" on every printer that has one.
              'ams_present': self._ams_present(),
              'ams_answered': False}
        if ph is None:
            return st
        st['ams_answered'] = bool(getattr(ph, 'G_AMSDevice1IfNormal', False)
                                  or getattr(ph, 'G_AMSDevice2IfNormal', False))
        present = getattr(ph, 'G_ToolheadIfHaveFilaFlag', None)
        st['filament_present'] = None if present is None else bool(present)
        threshold = getattr(ph, 'G_ToolheadFilaAdcThresholdValue', None)
        if threshold is not None:
            st['threshold'] = round(float(threshold), 4)
        mode = getattr(ph, 'G_AMSDeviceWorkMode', None)
        if mode is not None:
            st['mode'] = int(mode)
            st['mode_name'] = MODE_NAMES.get(int(mode), 'mode %d' % (mode,))
            st['protection_active'] = self._protection_active(ph, int(mode))
        if self._mcu_adc is not None:
            try:
                # MCU_adc.get_last_value() -> (timestamp, value)
                last = self._mcu_adc.get_last_value()
                st['adc'] = round(float(last[1]), 4)
            except Exception:
                logging.exception("arco_fila_status: reading '%s' failed", self.adc_name)
        return st

    def _ams_present(self):
        # The AMS is a serial device on /dev/ttyACM1. voronFDM decides the same question the same way
        # -- by whether that node exists -- so this agrees with what the panel shows rather than
        # inventing a second opinion.
        try:
            return os.path.exists(self.ams_port)
        except Exception:
            return False

    def _protection_active(self, ph, mode):
        # Mirrors the gates in phrozen_dev's runout timer (dev.py Device_TimmerRunoutCheck):
        #   mode 0        -> returns immediately, nothing is watched
        #   mode 3 (M3)   -> only runs once P0 M3 set G_P0M3Flag
        #   mode 2 (M2/MA)-> only runs once P8 feeding set G_P0M2MAStartPrintFlag
        #   mode 1 (M1/MC)-> AMS-driven, handled over the AMS serial
        if mode == 3:
            return bool(getattr(ph, 'G_P0M3Flag', False))
        if mode == 2:
            return bool(getattr(ph, 'G_P0M2MAStartPrintFlag', 0))
        if mode == 1:
            # 🔴 NOT an unconditional True, which is what this returned until 2026-08-16. In AMS mode
            # the toolhead sensor is deliberately ignored -- the AMS watches its own slots and reports
            # over the serial link -- so "protected" here means "an AMS is there to do the watching".
            # Without that check the status claimed protection on a printer whose AMS was not feeding
            # at all: it printed air for hours while FILA_STATUS said ACTIVE. A wrong reassurance is
            # worse than no answer, because it is the one somebody acts on.
            return self._ams_present()
        return False

    # --- unprotected-print warning ------------------------------------------------------
    # Two traps decide the shape of this, and both were paid for elsewhere in this kit:
    #
    # 1) NOT idle_timeout. Verified on hardware (see the P114 gate in AddOn.cfg): a bare G4
    #    dwell with print_stats "standby" already reports idle_timeout.state == "Printing".
    #    That signal means "the toolhead is executing", not "a job is running" -- using it
    #    here would fire on every home, probe and manual move. print_stats is job-scoped,
    #    which is exactly (and only) what this warning is about.
    # 2) Not at job start either. The mode is set by the start G-code (PHROZEN_AMS_START runs
    #    after heating and homing), so 'protection_active' is legitimately False for the first
    #    minutes of every print. Warning there would cry wolf on a correctly configured
    #    machine. So: arm a deadline when the job starts, evaluate ONCE when it expires.
    # A 'paused' job counts as the same job (no re-arm, no second warning); the state going
    # back to standby/complete/cancelled/error is what re-arms for the next print.
    def _poll(self, eventtime):
        print_stats = self.printer.lookup_object('print_stats', None)
        if print_stats is None:
            return self.reactor.NEVER
        try:
            state = print_stats.get_status(eventtime).get('state')
        except Exception:
            logging.exception("arco_fila_status: print_stats read failed")
            return eventtime + self.check_interval
        if state not in ('printing', 'paused'):
            self._deadline = None
            self._warned = False
            self._pause_deadline = None
            self._pause_checked = False
        elif state == 'printing':
            if self.pause_on_empty and not self._pause_checked:
                if self._pause_deadline is None:
                    self._pause_deadline = eventtime + self.pause_delay
                elif eventtime >= self._pause_deadline:
                    self._pause_deadline = None
                    self._pause_checked = True
                    self._pause_if_empty()
            if not self._warned:
                if self._deadline is None:
                    self._deadline = eventtime + self.warn_delay
                elif eventtime >= self._deadline:
                    self._deadline = None
                    self._warned = True
                    self._warn_if_unprotected()
        return eventtime + self.check_interval

    # --- printing into thin air -----------------------------------------------------------
    # Nothing on this printer refuses to start a job with no filament: phrozen_dev's runout logic is a
    # timer that watches for a CHANGE during the job, and in AMS mode it does not look at the toolhead
    # sensor at all. So a printer whose AMS is not feeding lays down nothing for hours and says
    # nothing. That happened on 2026-08-15.
    #
    # 🔴 ONLY ON A DEFINITE READING. Pausing a good print is a worse failure than the one being
    # prevented, so this acts only when phrozen_dev is loaded AND reports the sensor as empty. Unknown,
    # unavailable, or a sensor that cannot be read all mean "say nothing and let it run" -- the same
    # rule the rest of this module follows.
    def _pause_if_empty(self):
        st = self._read()
        if not st['available'] or st['filament_present'] is not False:
            return
        adc = 'n/a' if st['adc'] is None else '%.4f' % st['adc']
        thr = 'n/a' if st['threshold'] is None else '%.4f' % st['threshold']
        msg = ("arco_fila_status: PAUSING — the toolhead sensor reports NO filament "
               "%.0f s into this print (adc %s, threshold %s; at or above the threshold means empty). "
               "Mode: %s." % (self.pause_delay, adc, thr, st['mode_name']))
        # What to do about it depends on who was supposed to supply the filament, so say that rather
        # than leaving the owner to work out which of their two possible problems this is.
        if st['mode'] in (1, 2):
            if self._ams_present():
                msg += (" The AMS is connected but nothing reached the toolhead — check that the "
                        "slot for this print actually has filament in it. Resuming will not help "
                        "until it does.")
            else:
                msg += (" The printer is in AMS mode but no AMS is answering on %s, so nothing was "
                        "watching for this." % (self.ams_port,))
        else:
            msg += " Load filament, then RESUME."
        self.gcode.respond_info(msg)
        logging.info("arco_fila_status: pausing an empty print (%s)", st)
        try:
            self.gcode.run_script("PAUSE")
        except Exception:
            logging.exception("arco_fila_status: PAUSE failed")

    def _warn_if_unprotected(self):
        st = self._read()
        if st['protection_active']:
            return
        if not st['available']:
            self.gcode.respond_info(
                "arco_fila_status: WARNING — no filament runout protection "
                "(phrozen_dev is not loaded).")
        else:
            self.gcode.respond_info(
                "arco_fila_status: WARNING — this print has NO runout protection "
                "(mode: %s). The start G-code sent no P0 M1/M2/M3 — use the kit's "
                "PHROZEN_AMS_START, or add P0 M3 for standalone printing."
                % (st['mode_name'],))
        logging.info("arco_fila_status: unprotected print detected (%s)", st)

    # --- reporting ----------------------------------------------------------------------
    def get_status(self, eventtime):
        return self._read()

    cmd_FILA_STATUS_help = "Report the toolhead filament sensor state (phrozen_dev, read-only)"

    def cmd_FILA_STATUS(self, gcmd):
        st = self._read()
        if not st['available']:
            gcmd.respond_info("Filament sensor: unavailable — [%s] is not loaded, so nothing "
                              "reads the toolhead sensor." % (PHROZEN_OBJECT,))
            return
        present = {True: 'LOADED', False: 'EMPTY', None: 'unknown'}[st['filament_present']]
        adc = 'n/a' if st['adc'] is None else '%.4f' % st['adc']
        thr = 'n/a' if st['threshold'] is None else '%.4f' % st['threshold']
        gcmd.respond_info(
            "Filament: %s (adc %s, threshold %s — below threshold = loaded)\n"
            "Mode: %s\n"
            "Runout protection: %s"
            % (present, adc, thr, st['mode_name'],
               'ACTIVE' if st['protection_active']
               else 'NOT active — a runout would NOT pause this print'))


def load_config(config):
    return ArcoFilaStatus(config)
