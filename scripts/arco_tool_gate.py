# arco_tool_gate.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here.
#
# Hide phantom AMS tools (T1..T15) from Mainsail/Fluidd when no AMS is present.
#
# phrozen_dev registers T0..T15 as gcode commands (Orca colour-change / Chroma Kit AMS
# channels -- cmds.py Cmds_RegisterCmds). The web UI renders one tool button per Tn
# command, so a printer with a single physical [extruder] and NO AMS still shows 16
# "extruders" (== 4 AMS worth of channels). Klipper cannot un-register a command from
# the config layer, so we do it here in a tiny first-party extra (phrozen_dev stays
# vanilla): at klippy:connect -- after phrozen_dev's __init__ has registered T0..T15 --
# we drop T1..T15 from the command table AND from the gcode-help dict when no AMS is
# attached. With one attached we leave them intact so multi-colour tool-change keeps
# working. This only edits the Klipper command registry; phrozen's internal
# colour-change goes over the AMS serial (Cmds_AMSSerial*Send), not these gcode
# commands, so it is unaffected.
#
# WHAT "ATTACHED" MEANS, AND WHY IT IS NOT A SETTING ANY MORE. This used to read an
# 'ams' save-variable that the owner flipped from the setup menu. That was the wrong
# question to ask a person: the printer's own firmware works the AMS out for itself and
# switches its work mode accordingly, so the menu entry could only ever agree or be
# wrong -- and when it was wrong it was silently wrong. The AMS enumerates as a USB
# serial device, so its device node is the fact, available at boot, needing no
# conversation with anything.
#
# Because a device node can appear and disappear while Klipper runs, this reconciles on
# a slow timer rather than once at connect: plug an AMS in and the tools appear, unplug
# it and they go, no restart and no menu. Hiding is skipped mid-print -- a tool that
# vanished under a running multi-colour job would be a far worse outcome than a stale
# button -- while restoring is always allowed, since it can only add.
#
# The original phrozen handlers are stashed on hide, so they can be put back LIVE.
# ARCO_TOOLS_SHOW / ARCO_TOOLS_HIDE remain for forcing either state by hand.

import logging
import os


class ArcoToolGate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.first_tool = config.getint('hide_from', 1, minval=0)
        self.last_tool = config.getint('hide_to', 15, minval=0)
        self.ams_port = config.get('ams_port', '/dev/ttyACM1')
        self.flag_name = config.get('ams_variable', 'ams')
        # 5 s: this exists so plugging an AMS in is noticed without a restart, and nobody
        # plugs one in and expects an instant result. 0 turns the timer off and leaves the
        # single check at connect.
        self.poll_interval = config.getfloat('poll_interval', 5., minval=0.)
        self._stashed = {}   # cmd -> (handler, desc) for commands we removed
        self._last_seen = None
        self.reactor = self.printer.get_reactor()
        self.printer.register_event_handler('klippy:connect',
                                             self._handle_connect)
        self.printer.register_event_handler('klippy:ready', self._handle_ready)
        self.gcode.register_command(
            'ARCO_TOOLS_SHOW', self.cmd_ARCO_TOOLS_SHOW,
            desc="Re-register AMS tools T1-T15 live (no restart)")
        self.gcode.register_command(
            'ARCO_TOOLS_HIDE', self.cmd_ARCO_TOOLS_HIDE,
            desc="Hide AMS tools T1-T15 live (no restart)")

    def _ams_present(self):
        # The device node, not a reply. Asking the AMS to identify itself needs the serial
        # port, a command and an answer, none of which are available at connect; the node is
        # there the moment the kernel has enumerated it.
        try:
            return os.path.exists(self.ams_port)
        except OSError:
            return False

    def _stored_flag(self):
        sv = self.printer.lookup_object('save_variables', None)
        if sv is None:
            return None
        try:
            return int(sv.allVariables.get(self.flag_name, 0))
        except (ValueError, TypeError):
            return None

    def _sync_flag(self, present):
        # The macros in AddOn.cfg have always read this variable, and AddOn.cfg is the one file a
        # printer keeps across updates -- it is never regenerated, so a rewrite of those macros
        # would only ever reach NEW printers. Keeping the variable and taking the pen away from the
        # owner fixes every printer already out there, from the extra alone.
        want = 1 if present else 0
        if self._stored_flag() == want:
            return
        try:
            self.gcode.run_script("SAVE_VARIABLE VARIABLE=%s VALUE=%d"
                                  % (self.flag_name, want))
            logging.info("arco_tool_gate: %s=%d (%s %s)"
                         % (self.flag_name, want, self.ams_port,
                            "is present" if present else "is not there"))
        except Exception:
            logging.exception("arco_tool_gate: could not store %s", self.flag_name)

    def _printing(self):
        ps = self.printer.lookup_object('print_stats', None)
        return ps is not None and getattr(ps, 'state', None) == 'printing'

    def get_status(self, eventtime=None):
        return {'ams_present': self._ams_present(),
                'tools_hidden': bool(self._stashed),
                'ams_port': self.ams_port}

    def _hide(self):
        help_dict = getattr(self.gcode, 'gcode_help', None)
        removed = []
        for n in range(self.first_tool, self.last_tool + 1):
            cmd = 'T%d' % n
            if cmd in self._stashed:
                continue                       # already hidden
            desc = help_dict.get(cmd) if isinstance(help_dict, dict) else None
            # register_command(cmd, None) unregisters and returns the old handler
            # (or None if it was never registered -- then it is a harmless no-op).
            prev = self.gcode.register_command(cmd, None)
            if prev is not None:
                self._stashed[cmd] = (prev, desc)
                removed.append(cmd)
            if isinstance(help_dict, dict):
                help_dict.pop(cmd, None)
        return removed

    def _show(self):
        restored = []
        for n in range(self.first_tool, self.last_tool + 1):
            cmd = 'T%d' % n
            entry = self._stashed.pop(cmd, None)
            if entry is None:
                continue
            handler, desc = entry
            self.gcode.register_command(cmd, handler, desc=desc or cmd)
            restored.append(cmd)
        return restored

    def _handle_connect(self):
        # AMS present -> keep every tool so Orca multi-colour tool-change works.
        present = self._ams_present()
        self._last_seen = present
        if present:
            return
        removed = self._hide()
        if removed:
            logging.info("arco_tool_gate: hid AMS tools %s (nothing on %s)"
                         % (', '.join(removed), self.ams_port))

    def _handle_ready(self):
        # Not at connect: SAVE_VARIABLE is a gcode command, and gcode does not run that early.
        self._sync_flag(self._ams_present())
        if self.poll_interval:
            self.reactor.register_timer(self._poll,
                                        self.reactor.monotonic() + self.poll_interval)

    def _poll(self, eventtime):
        present = self._ams_present()
        if present != self._last_seen:
            if present:
                # Restoring can only add, so it never waits.
                restored = self._show()
                self._last_seen = True
                self._sync_flag(True)
                if restored:
                    logging.info("arco_tool_gate: %s appeared, restored %s"
                                 % (self.ams_port, ', '.join(restored)))
            elif not self._printing():
                # Both halves of this wait for the print to end. Taking T1..T15 away under a
                # running multi-colour job would break it outright, and dropping the flag to 0
                # would send PHROZEN_TOOLCHANGE down its standalone branch mid-print -- which is
                # the worse of the two, because it would not look like a failure.
                removed = self._hide()
                self._last_seen = False
                self._sync_flag(False)
                if removed:
                    logging.info("arco_tool_gate: %s went away, hid %s"
                                 % (self.ams_port, ', '.join(removed)))
        return eventtime + self.poll_interval

    def cmd_ARCO_TOOLS_SHOW(self, gcmd):
        restored = self._show()
        gcmd.respond_info("arco_tool_gate: restored %s"
                          % (', '.join(restored) if restored
                             else "nothing (tools already present)"))

    def cmd_ARCO_TOOLS_HIDE(self, gcmd):
        removed = self._hide()
        gcmd.respond_info("arco_tool_gate: hid %s"
                          % (', '.join(removed) if removed else "nothing"))


def load_config(config):
    return ArcoToolGate(config)
