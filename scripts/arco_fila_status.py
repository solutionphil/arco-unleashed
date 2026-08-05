# arco_fila_status.py — Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here.
#
# Make the toolhead filament sensor VISIBLE. This module detects nothing and pauses nothing:
# both already happen inside phrozen_dev. It only publishes what that module keeps to itself.
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
#   * It does NOT register or override any existing command, and it is not in the pause path.
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
#
# Status (printer['arco_fila_status'] / Moonraker):
#   available, filament_present, adc, threshold, mode, mode_name, protection_active
# Command:
#   FILA_STATUS  -- print all of the above to the console

import logging

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
        self._phrozen = None
        self._mcu_adc = None
        self._deadline = None
        self._warned = False
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
        if self.warn_on_print_start:
            self.reactor.register_timer(self._poll, self.reactor.NOW + 5.)

    # --- reading phrozen_dev ------------------------------------------------------------
    def _read(self):
        ph = self._phrozen
        st = {'available': ph is not None, 'filament_present': None, 'adc': None,
              'threshold': None, 'mode': None, 'mode_name': 'unavailable',
              'protection_active': False}
        if ph is None:
            return st
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
            return True
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
        elif state == 'printing' and not self._warned:
            if self._deadline is None:
                self._deadline = eventtime + self.warn_delay
            elif eventtime >= self._deadline:
                self._deadline = None
                self._warned = True
                self._warn_if_unprotected()
        return eventtime + self.check_interval

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
