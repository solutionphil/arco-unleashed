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
import re


# The display's own light button, as it arrives here. voronFDM sends "P0 LED_State=<n>"; the kit's
# switch sends "P0 LED_SetState=<n>". The two spellings are not a typo to be tidied away -- they are
# what tells the echo apart from the original, and neither string is a substring of the other, so
# matching one can never catch the other. The lookbehind only guards against a longer word ending in
# the same letters.
P0_LED_RE = re.compile(r'(?<![A-Za-z0-9_])LED_State\s*=\s*([0-9]+)')


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

        # Mirror the DISPLAY's light button back into the switch. Set to an empty value to switch the
        # mirroring off; naming a pin that does not exist simply does nothing.
        self.led_pin = config.get('mirror_led_pin', 'chamber_light').strip()
        self._suppress = {}
        self._p0_prev = None
        if self.led_pin:
            self.printer.register_event_handler('klippy:ready', self._wrap_p0)

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
            if self._suppress.get(name) == value:
                del self._suppress[name]
                continue      # the display did this; the switch has followed, nothing to send back
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

    # ── the display owns the light, so the switch has to be told ────────────────────────────────
    #
    # The chamber light is not Klipper's. "P0 LED_SetState=<n>" is passed straight through to the
    # display program, which is what actually drives it -- phrozen_dev has no LED code at all, no
    # get_status(), and no object anywhere reports the lamp. So there is nothing to poll: the switch
    # was synced once at boot and then drifted the moment somebody touched the display.
    #
    # What IS observable is the button press. The display sends its command through Moonraker like any
    # other client, so it arrives here as an ordinary "P0 LED_State=<n>" -- confirmed on hardware in
    # both directions. Wrapping P0 is therefore enough, and no relay traffic has to be parsed.
    #
    # 🔴 P0 IS THE MOST LOAD-BEARING COMMAND ON THE MACHINE -- every AMS mode change goes through it.
    # The original runs FIRST and the mirror is wrapped in its own try/except, so no fault of ours can
    # stop a P0 from reaching the AMS. Python rather than a rename_existing macro for the same reason,
    # plus cost: this runs on every P0 during a print, and a Jinja template would not be free.
    def _wrap_p0(self):
        gcode = self.printer.lookup_object('gcode')
        prev = gcode.register_command('P0', None)      # unregisters and hands back the old handler
        if prev is None:
            logging.info("arco_virtual_pins: no P0 to wrap — display light mirroring is off")
            return
        self._p0_prev = prev
        gcode.register_command('P0', self._cmd_P0,
                               desc="Phrozen P0, plus mirroring the display's light button")
        logging.info("arco_virtual_pins: mirroring the display's light button into '%s'",
                     self.led_pin)

    def _cmd_P0(self, gcmd):
        self._p0_prev(gcmd)
        try:
            self._mirror_led(gcmd)
        except Exception:
            logging.exception("arco_virtual_pins: mirroring the light failed (P0 itself was fine)")

    def _mirror_led(self, gcmd):
        m = P0_LED_RE.search(gcmd.get_commandline() or '')
        if m is None:
            return
        pin = self.pins.get(self.led_pin)
        if pin is None:
            return
        value = 1 if int(m.group(1)) else 0
        if int(bool(pin.value)) == value:
            return
        self.reactor.register_callback(
            lambda et, n=self.led_pin, v=value: self._apply_mirror(n, v))

    def _apply_mirror(self, name, value):
        # Marked before the write, consumed in _run_queue: the switch must follow, but the light must
        # NOT be commanded again -- the display has already set it, and echoing it back would have us
        # arguing with the device that owns it.
        self._suppress[name] = float(value)
        try:
            self.printer.lookup_object('gcode').run_script(
                "SET_PIN PIN=%s VALUE=%d" % (name, value))
        except Exception:
            self._suppress.pop(name, None)
            logging.exception("arco_virtual_pins: could not move the '%s' switch", name)

    def get_status(self, eventtime=None):
        return {'pins': {n: p.value for n, p in self.pins.items()}}


def load_config(config):
    return ArcoVirtualPins(config)
