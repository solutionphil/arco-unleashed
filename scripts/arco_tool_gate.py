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
# we drop T1..T15 from the command table AND from the gcode-help dict when our 'ams'
# save-variable is off. With ams=1 (set by AMS_ON) we leave them intact so multi-colour
# tool-change keeps working. This only edits the Klipper command registry; phrozen's
# internal colour-change goes over the AMS serial (Cmds_AMSSerial*Send), not these
# gcode commands, so it is unaffected.
#
# The original phrozen handlers are stashed on hide, so ARCO_TOOLS_SHOW can put them
# back LIVE (no Klipper restart) -- AMS_ON calls it after setting ams=1, so tools appear
# the moment an AMS is enabled without disturbing the just-made P28 connection. AMS_OFF
# already ends with RESTART, which re-hides them via klippy:connect.

import logging


class ArcoToolGate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.first_tool = config.getint('hide_from', 1, minval=0)
        self.last_tool = config.getint('hide_to', 15, minval=0)
        self.flag_name = config.get('ams_variable', 'ams')
        self._stashed = {}   # cmd -> (handler, desc) for commands we removed
        self.printer.register_event_handler('klippy:connect',
                                             self._handle_connect)
        self.gcode.register_command(
            'ARCO_TOOLS_SHOW', self.cmd_ARCO_TOOLS_SHOW,
            desc="Re-register AMS tools T1-T15 live (used by AMS_ON; no restart)")
        self.gcode.register_command(
            'ARCO_TOOLS_HIDE', self.cmd_ARCO_TOOLS_HIDE,
            desc="Hide AMS tools T1-T15 live (no restart)")

    def _ams_enabled(self):
        sv = self.printer.lookup_object('save_variables', None)
        if sv is None:
            return False
        try:
            return int(sv.allVariables.get(self.flag_name, 0)) == 1
        except (ValueError, TypeError):
            return False

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
        if self._ams_enabled():
            return
        removed = self._hide()
        if removed:
            logging.info("arco_tool_gate: hid AMS tools %s (no AMS; AMS_ON restores "
                         "them live via ARCO_TOOLS_SHOW)" % (', '.join(removed),))

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
