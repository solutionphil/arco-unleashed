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
        self.slots_name = config.get('slots_variable', 'ams_slots')
        self.refeed_name = config.get('refeed_variable', 'ams_refeed')
        self.max_tool = config.getint('map_tools', 16, minval=1, maxval=16)
        self._applied = {}      # what WE last wrote, so the panel's values are never overwritten
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
        self.gcode.register_command(
            'ARCO_AMS_SLOTS', self.cmd_ARCO_AMS_SLOTS,
            desc="Which AMS slot serves which tool, e.g. ARCO_AMS_SLOTS T0=2 T1=1")
        self.gcode.register_command(
            'ARCO_AMS_REFEED', self.cmd_ARCO_AMS_REFEED,
            desc="Auto-refeed from another slot when one runs out: ENABLE=0|1")

    def _ams_present(self):
        # The device node, not a reply. Asking the AMS to identify itself needs the serial
        # port, a command and an answer, none of which are available at connect; the node is
        # there the moment the kernel has enumerated it.
        try:
            return os.path.exists(self.ams_port)
        except OSError:
            return False

    # --- tool-to-slot map and auto-refeed ---------------------------------------------------
    # phrozen_dev keeps a tool->channel table (one entry per Tn) and an auto-refeed flag. Both are
    # normally filled in by the DISPLAY, which sends them over its serial link when a print is
    # started there -- which is why the checkbox and the slot assignment exist on the panel and
    # nowhere else. A print started from Mainsail or a slicer never sends that block, so the table
    # stays unset and every Tn simply uses channel n, and the refeed never happens.
    #
    # Filling the same fields in from here gives the web side the same two features. It is a
    # runtime assignment, not a change to phrozen_dev.
    #
    # 🔴 THE PANEL ALWAYS WINS. A value is only written when the field is still unset, or when it
    # holds exactly what we put there last time. Start a print at the display and its table stands;
    # nothing here fights it.
    def _pd(self):
        return self.printer.lookup_object('phrozen_dev', None)

    def _stored(self, name, default=''):
        sv = self.printer.lookup_object('save_variables', None)
        if sv is None:
            return default
        return sv.allVariables.get(name, default)

    def _wanted_map(self):
        """{tool index: channel} from the stored list; entries <= 0 mean "leave it to phrozen_dev"."""
        # SAVE_VARIABLE stores whatever ast.literal_eval() makes of the text, so a single entry comes
        # back as an int and a comma list as a tuple. Normalise all three shapes rather than assuming
        # the one this happens to write today.
        stored = self._stored(self.slots_name, '')
        if isinstance(stored, (list, tuple)):
            raw = ",".join(str(x) for x in stored)
        else:
            raw = str(stored or '')
        out = {}
        for i, part in enumerate(raw.split(',')):
            if i >= self.max_tool:
                break
            part = part.strip()
            if not part:
                continue
            try:
                v = int(part)
            except ValueError:
                continue
            if v > 0:
                out[i] = v
        return out

    def _apply_map(self):
        ph = self._pd()
        if ph is None:
            return
        for tool, chan in self._wanted_map().items():
            attr = 'G_ChromaKitAccessT%d' % tool
            cur = getattr(ph, attr, None)
            if cur is None:
                continue
            if cur > 0 and cur != self._applied.get(attr):
                continue                      # the display put that there -- leave it alone
            if cur != chan:
                setattr(ph, attr, chan)
                logging.info("arco_tool_gate: T%d -> AMS channel %d", tool, chan)
            self._applied[attr] = chan
        try:
            want = int(self._stored(self.refeed_name, 0) or 0)
        except (TypeError, ValueError):
            want = 0
        cur = getattr(ph, 'G_AutoReplaceState', None)
        if cur is None:
            return
        if cur > 0 and cur != self._applied.get('G_AutoReplaceState'):
            return
        if want == 1 and cur != 1:
            ph.G_AutoReplaceState = 1
            self._applied['G_AutoReplaceState'] = 1
            logging.info("arco_tool_gate: auto-refeed on")
        elif want != 1 and self._applied.get('G_AutoReplaceState') == 1 and cur == 1:
            ph.G_AutoReplaceState = -1
            self._applied.pop('G_AutoReplaceState', None)
            logging.info("arco_tool_gate: auto-refeed off")

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

    def _describe_map(self):
        m = self._wanted_map()
        if not m:
            return "not set (every Tn uses AMS channel n)"
        return ", ".join("T%d->%d" % (k, m[k]) for k in sorted(m))

    def _save(self, name, value):
        # 🔴 NEVER an empty VALUE, and always double-quoted. save_variables runs the text through
        # ast.literal_eval, which raises SyntaxError on an empty string -- and an exception inside a
        # G-code command SHUTS THE PRINTER DOWN. That is what clearing the last slot entry did on
        # 2026-08-18: AMS_SLOTS T0=0 emptied the list, sent VALUE='', and took klippy with it.
        # Single quotes are no help either; the value has to survive literal_eval as a string, so it
        # is double-quoted and never blank.
        value = str(value)
        if not value:
            value = "0"
        self.gcode.run_script_from_command(
            'SAVE_VARIABLE VARIABLE=%s VALUE="%s"' % (name, value))

    def cmd_ARCO_AMS_SLOTS(self, gcmd):
        m = self._wanted_map()
        cur = [str(m.get(i, 0)) for i in range(self.max_tool)]
        changed = []
        for tool in range(self.max_tool):
            v = gcmd.get_int('T%d' % tool, None)
            if v is None:
                continue
            if v < 0:
                raise gcmd.error("T%d must be an AMS channel (1 and up), or 0 to clear it" % tool)
            cur[tool] = str(v)
            changed.append(tool)
        if changed:
            # Trailing zeros trimmed for readability, but never to nothing -- see _save.
            while len(cur) > 1 and cur[-1] == '0':
                cur.pop()
            self._save(self.slots_name, ",".join(cur))
            self._apply_map()
        gcmd.respond_info("AMS slots: %s%s" % (
            self._describe_map(),
            "" if changed else "  (nothing changed — pass e.g. T0=2 to set one, T0=0 to clear it)"))

    def cmd_ARCO_AMS_REFEED(self, gcmd):
        want = gcmd.get_int('ENABLE', None, minval=0, maxval=1)
        if want is not None:
            self._save(self.refeed_name, want)
            self._apply_map()
        on = str(self._stored(self.refeed_name, 0)) == '1'
        gcmd.respond_info(
            "AMS auto-refeed is %s. When a slot runs out mid-print the AMS carries on from "
            "another one; which one it picks is the AMS's own decision, not a setting here."
            % ("ON" if on else "OFF"))

    def get_status(self, eventtime=None):
        return {'ams_present': self._ams_present(),
                'tools_hidden': bool(self._stashed),
                'ams_port': self.ams_port,
                'slot_map': self._describe_map(),
                'refeed': str(self._stored(self.refeed_name, 0)) == '1'}

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
        self._apply_map()
        if self.poll_interval:
            self.reactor.register_timer(self._poll,
                                        self.reactor.monotonic() + self.poll_interval)

    def _poll(self, eventtime):
        # Re-applied every tick rather than once: the fields are re-read from the display's block
        # whenever one arrives, and a print started at the panel legitimately replaces them. Cheap --
        # it is a handful of attribute comparisons.
        self._apply_map()
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
