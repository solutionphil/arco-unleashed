# arco_virtual_pins.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here.
#
# Give Mainsail a real toggle switch for something that is not a pin.
#
# WHY. Mainsail renders an [output_pin] as a switch and a [gcode_macro] as a button, and the
# difference is not cosmetic: a switch shows its state, a button only offers an action. Two things
# on this printer are switches by nature and had only buttons -- the chamber light, which is driven
# by a vendor command rather than a GPIO, and the AMS auto-refeed, which is a stored setting.
# Neither has a pin to point [output_pin] at.
#
# HOW. Klipper lets an extra register a pin CHIP (pins.register_chip), and resolves "chip:name" by
# handing the request to it. A chip whose pins do nothing electrical is therefore all it takes:
# [output_pin light] pin: arco:light gives a switch in the interface, and the value change arrives
# here instead of at a GPIO.
#
# WHAT HAPPENS ON A CHANGE. The pin looks for a macro called _ARCO_PIN_<name> and runs it with
# VALUE=0 or VALUE=1. That is the whole interface: the config decides what a switch means, this file
# only carries the flip across. No macro of that name means the switch is inert, which is a
# deliberate outcome rather than an error -- somebody may want the state without an action.
#
# 🔴 NOT RUN FROM set_digital ITSELF. Klipper calls that from the motion queue, and running G-code
# there occupies the reactor for as long as the G-code takes -- the same mistake that produced
# "Reactor busy for 0.132 with ArcoFilaStatus._poll" on this machine. The flip is handed to its own
# reactor callback, so the queue is released immediately.
#
# 🔴 THE SWITCH DOES NOT REMEMBER ITSELF. [output_pin] starts every session at its configured
# `value:`, so whatever the switch meant is gone after a restart. Anything that has to persist has
# to be stored by the macro behind it, and the position resynced from there -- see the AMS refeed
# switch in AddOn.cfg, which does exactly that.
#
# Config:
#   [arco_virtual_pins]          # must come BEFORE any [output_pin] that uses arco:
#   #chip_name: arco             # prefix used in pin names
#
# Update survival: untracked in Klipper's tree, so a git pull leaves it alone; a hard recover is
# repaired by scripts/apply-arco-extras.sh before klipper starts.

import logging


class VirtualMcu:
    """What output_pin's request queue asks of an MCU, for a pin that has none.

    🔴 NOT the real MCU object. Returning printer.lookup_object('mcu') looks tidier and depends on
    load order: AddOn.cfg is included near the top of printer.cfg, so [mcu] may not exist yet when
    these sections are parsed. Nothing here schedules anything electrical, so the numbers only have
    to be sane -- the queue uses min_schedule_time as a margin, and max_nominal_duration bounds a
    pwm pin's hold time."""
    def min_schedule_time(self):
        return 0.100

    def max_nominal_duration(self):
        return 5.


class VirtualPin:
    """Everything [output_pin] asks of a pin, and nothing more."""
    def __init__(self, owner, name):
        self.owner = owner
        self.name = name
        self.value = 0.

    # -- EVERY call output_pin.py makes on its pin, enumerated from the file rather than guessed:
    #    get_mcu, setup_max_duration, setup_start_value, setup_cycle_time, set_digital, set_pwm.
    #    The first version implemented the three that seemed obvious, because they were looked for
    #    by grep instead of read out of output_pin.py, and klippy halted at connect with
    #    "'VirtualPin' object has no attribute 'get_mcu'". Re-derive the list from the file if a
    #    Klipper update changes it: grep -o 'mcu_pin\.[a-z_]*' klippy/extras/output_pin.py
    def get_mcu(self):
        return self.owner.mcu

    def setup_max_duration(self, max_duration):
        pass

    def setup_start_value(self, start_value, shutdown_value):
        self.value = start_value

    def setup_cycle_time(self, cycle_time, hardware_pwm=False):
        pass

    def set_digital(self, print_time, value):
        self._changed(float(value))

    def set_pwm(self, print_time, value, cycle_time=None):
        self._changed(float(value))

    def _changed(self, value):
        if value == self.value:
            return
        self.value = value
        self.owner.notify(self.name, value)

    def get_status(self, eventtime=None):
        return {'value': self.value}


class ArcoVirtualPins:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.chip_name = config.get('chip_name', 'arco')
        self.reactor = self.printer.get_reactor()
        self.pins = {}
        self.mcu = VirtualMcu()
        self._queue = []
        ppins = self.printer.lookup_object('pins')
        ppins.register_chip(self.chip_name, self)

    def setup_pin(self, pin_type, pin_params):
        if pin_type not in ('digital_out', 'pwm'):
            raise self.printer.config_error(
                "%s pins can only be digital_out or pwm, not '%s'"
                % (self.chip_name, pin_type))
        name = pin_params['pin']
        if name not in self.pins:
            self.pins[name] = VirtualPin(self, name)
        return self.pins[name]

    def notify(self, name, value):
        # Queued rather than run: set_digital arrives from the motion queue, and G-code started
        # there holds the reactor for its whole duration.
        self._queue.append((name, value))
        self.reactor.register_callback(self._run_queue)

    def _run_queue(self, eventtime):
        while self._queue:
            name, value = self._queue.pop(0)
            macro = 'gcode_macro _ARCO_PIN_%s' % (name,)
            if self.printer.lookup_object(macro, None) is None:
                logging.info("arco_virtual_pins: %s changed to %s, no %s to act on it",
                             name, value, macro.split(' ', 1)[1])
                continue
            try:
                self.printer.lookup_object('gcode').run_script(
                    "_ARCO_PIN_%s VALUE=%d" % (name, 1 if value else 0))
            except Exception:
                logging.exception("arco_virtual_pins: _ARCO_PIN_%s failed", name)

    def get_status(self, eventtime=None):
        return {'pins': {n: p.value for n, p in self.pins.items()}}


def load_config(config):
    return ArcoVirtualPins(config)
