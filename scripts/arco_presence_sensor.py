# arco_presence_sensor.py -- Arco Unleashed
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here.
#
# A permanent, non-clickable "is it plugged in?" light in Mainsail and Fluidd.
#
# WHY. Two things on this printer are plugged in or they are not -- the AMS, and a USB stick -- and
# the web interface said nothing about either. The obvious answer, SET_DISPLAY_TEXT / M117, is the
# wrong one: that is the single shared status line, and this kit's own macros write to it, so any
# indicator parked there is overwritten within minutes. A permanent widget would mean forking
# Mainsail, which mainsail-theme/README.md rejects on the grounds that every Mainsail update
# deletes the fork.
#
# HOW. Mainsail does not read the config to find filament sensors. It walks the printer objects and
# takes every key beginning "filament_switch_sensor " that reports 'enabled' and 'filament_detected'
# (src/store/printer/getters.ts, getFilamentSensors) -- then renders name, state text and a COLOUR:
# green when detected, amber when not. Fluidd reads the same objects. So an object registered under
# that name is rendered natively by both, with no fork, no patch and no pin.
#
# 🔴 NO PIN, AND THAT IS THE WHOLE POINT. A real [filament_switch_sensor] cannot do this job:
# switch_pin goes to buttons.register_debounce_button -> register_buttons, which builds an
# MCU_buttons from pin_params['chip'] and calls create_oid / add_config_cmd /
# register_serial_response on it. That needs a real microcontroller pin. AMS presence is a device
# node and a USB stick is a mount -- neither is a voltage. [arco_virtual_pins] cannot help either;
# it serves 'digital_out' and 'pwm' only, and a fake chip could not answer the MCU button protocol
# anyway. Registering the printer object directly is the only route that does not involve lying to
# Klipper about hardware.
#
# 🔴 IT REFUSES TO BE SWITCHED OFF, on purpose. Mainsail draws a toggle next to every filament
# sensor and sends SET_FILAMENT_SENSOR SENSOR=<name> ENABLE=0 when it is clicked. On a real sensor
# that suppresses the runout script. Here there is no script to suppress -- but Mainsail's own
# colour logic is `if (!enabled) return 'gray'`, so one stray click would grey out the indicator
# while the state underneath carried on updating, and nothing would tell the owner why. The theme
# CSS makes the toggle unclickable; this makes that cosmetic rather than load-bearing, because a
# Mainsail release that renames the CSS class must not be able to break the indicator. The command
# is still ACCEPTED and answered -- refusing to register it would leave the click reporting
# "Unknown command" in the console, which is worse than a polite no. Set allow_disable: True for
# stock Klipper semantics.
#
# 🔴 IT DOES NOT DECIDE WHETHER AN AMS IS THERE. That question already has an owner --
# [arco_tool_gate], which polls the device node and publishes 'ams_present' -- and a fact with two
# addresses is a fact someone will read from the wrong one (the same rule arco_fila_status follows).
# So the AMS indicator is configured with printer_object/status_field and reads that answer. Only
# the USB stick, which nothing else tracks, is measured here.
#
# Config -- exactly ONE source per section:
#   [arco_presence_sensor AMS]
#   printer_object: arco_tool_gate   # read a boolean from another Klipper object
#   status_field: ams_present
#
#   [arco_presence_sensor USB_Stick]
#   mount_point: /home/mks/printer_data/gcodes/USB   # present when something is MOUNTED there
#
#   [arco_presence_sensor Something]
#   device_path: /dev/ttyACM1        # present when the path exists
#
#   #display_name: USB_Stick         # defaults to the section name; must contain no spaces
#   #poll_interval: 5.0              # seconds; 0 checks once at startup and never again
#   #allow_disable: False            # True restores the stock enable/disable toggle
#   #mounts_file: /proc/self/mounts  # where mount_point is looked up (see below)
#
# 🔴 mount_point is answered from /proc/self/mounts, NOT with os.path.ismount(), and NOT with
# os.path.exists(). Each was rejected for its own reason:
#
#   exists()   -- wrong answer. The automount's target directory (system/arco-usb-mount) is created
#                 once and stays behind when the stick is pulled, so exists() reports a stick that
#                 left an hour ago.
#   ismount()  -- right answer, wrong risk. It costs 2.3 us when all is well (measured), but it
#                 works by lstat()ing the mount point and its parent, and those calls go to the
#                 FILESYSTEM DRIVER. A stick pulled without unmounting, or one that is dying, leaves
#                 lstat blocked in uninterruptible sleep until the SCSI layer times out. This poll
#                 runs on Klipper's reactor, which is single-threaded and does not pause for a
#                 print -- so that block is a stalled reactor mid-job, i.e. the "Timer too close"
#                 family of failures this printer has already paid for once.
#   /proc      -- 27.8 us (measured, 12x ismount) and it CANNOT block on the device: the kernel
#                 answers from its own mount table without touching the filesystem. At a 5 s tick
#                 that is a millionth of one core, which is the right price for removing a failure
#                 mode that ends a print.
#
# Update survival: untracked in Klipper's tree, so a git pull leaves it alone; a hard recover is
# repaired by scripts/apply-arco-extras.sh before klipper starts.

import logging
import os

# What Mainsail and Fluidd look for. Not configurable: it is their contract, not a preference.
ALIAS_PREFIX = 'filament_switch_sensor'

# The kernel escapes these four characters in the mount-point field of /proc/self/mounts. A path
# with a space in it is not likely here, but a silently wrong comparison is worse than four
# replacements.
MOUNT_ESCAPES = (('\\040', ' '), ('\\011', '\t'), ('\\012', '\n'), ('\\134', '\\'))


def unescape_mount(field):
    for esc, ch in MOUNT_ESCAPES:
        field = field.replace(esc, ch)
    return field


class ArcoPresenceSensor:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        section = config.get_name().split()
        self.name = config.get('display_name', section[-1]).strip()
        if not self.name or len(self.name.split()) != 1:
            raise config.error(
                "%s: display_name must be a single word with no spaces -- the interfaces "
                "split the object name on the space and would show only its first half"
                % (config.get_name(),))
        self.printer_object = config.get('printer_object', None)
        self.status_field = config.get('status_field', None)
        self.mount_point = config.get('mount_point', None)
        self.device_path = config.get('device_path', None)
        sources = [s for s in (self.printer_object, self.mount_point,
                               self.device_path) if s is not None]
        if len(sources) != 1:
            raise config.error(
                "%s: give exactly one of printer_object, mount_point or device_path "
                "(found %d)" % (config.get_name(), len(sources)))
        if self.printer_object is not None and not self.status_field:
            raise config.error("%s: printer_object needs status_field"
                               % (config.get_name(),))
        self.poll_interval = config.getfloat('poll_interval', 5., minval=0.)
        self.allow_disable = config.getboolean('allow_disable', False)
        # Configurable so the offline test suite can point it at a fixture, which is the only way
        # to exercise the parser without mounting anything.
        self.mounts_file = config.get('mounts_file', '/proc/self/mounts')
        self._present = False
        self._enabled = True
        self._source = None      # resolved at ready, for printer_object only
        self._source_missing = False
        self._mounts_warned = False

        # The alias IS the feature. Registering the same instance under the name the interfaces
        # look for costs nothing and keeps one object with one state; the section's own name stays
        # valid too, so a macro can still read printer["arco_presence_sensor AMS"].
        #
        # 🔴 Guarded. Printer.add_object raises config_error on a name already taken, and an
        # unguarded raise here would refuse the WHOLE config -- a printer that booted yesterday
        # stops booting because somebody added a real sensor of the same name. Losing the indicator
        # is the correct cost; losing the printer is not.
        self.alias = '%s %s' % (ALIAS_PREFIX, self.name)
        self.registered = self.printer.lookup_object(self.alias, None) is None
        if self.registered:
            self.printer.add_object(self.alias, self)
            # register_mux_command shares one command name across sensors, exactly as Klipper's own
            # filament sensors do, so these sit alongside a real sensor's rather than fighting it.
            #
            # 🔴 UNDER THE SAME GUARD, and an offline test is why. Guarding only add_object moved
            # the halt one line down instead of preventing it: register_mux_command raises
            # config_error too ("mux command ... already registered"), so a duplicate name still
            # refused the whole config. Whatever owns the name owns both.
            self.gcode.register_mux_command(
                'QUERY_FILAMENT_SENSOR', 'SENSOR', self.name,
                self.cmd_QUERY_FILAMENT_SENSOR,
                desc="Report whether %s is connected" % (self.name,))
            self.gcode.register_mux_command(
                'SET_FILAMENT_SENSOR', 'SENSOR', self.name,
                self.cmd_SET_FILAMENT_SENSOR,
                desc="Display-only indicator: accepted, but %s cannot be switched off"
                     % (self.name,))
        else:
            logging.warning(
                "arco_presence_sensor: '%s' is already taken, so %s will not appear in "
                "Mainsail/Fluidd and registers no commands. Give this section a different "
                "display_name.", self.alias, config.get_name())
        self.printer.register_event_handler('klippy:ready', self._handle_ready)

    # --- reading the world --------------------------------------------------------------
    def _handle_ready(self):
        if self.printer_object is not None:
            self._source = self.printer.lookup_object(self.printer_object, None)
            if self._source is None or not hasattr(self._source, 'get_status'):
                self._source = None
                self._source_missing = True
                logging.info(
                    "arco_presence_sensor %s: no printer object '%s' with a status -- the "
                    "indicator will read 'not connected' and never change", self.name,
                    self.printer_object)
        self._present = self._measure()
        if self.poll_interval and not self._source_missing:
            self.reactor.register_timer(self._poll,
                                        self.reactor.monotonic() + self.poll_interval)

    def _measure(self):
        # Every branch answers False on failure rather than raising. This runs on the reactor, and
        # an exception out of a timer takes klippy down -- never worth it for an indicator.
        try:
            if self.mount_point is not None:
                return self._is_mounted()
            if self.device_path is not None:
                return os.path.exists(self.device_path)
            if self._source is None:
                return False
            value = self._source.get_status(self.reactor.monotonic()).get(
                self.status_field)
            return bool(value)
        except Exception:
            logging.exception("arco_presence_sensor %s: reading the source failed",
                              self.name)
            return False

    def _is_mounted(self):
        """Is anything mounted at mount_point? Answered from the kernel's mount table.

        Never touches the mounted filesystem — see the header for why that matters on a reactor
        thread that keeps running through a print."""
        want = os.path.normpath(self.mount_point)
        try:
            with open(self.mounts_file, 'r') as fh:
                for line in fh:
                    fields = line.split(' ')
                    if len(fields) > 1 and os.path.normpath(
                            unescape_mount(fields[1])) == want:
                        return True
            return False
        except (IOError, OSError):
            # No /proc is not a situation this printer can be in, so this is for a developer
            # machine rather than a printer. Falling back to ismount() keeps the answer correct
            # there; reporting False instead would be a confident lie.
            if not self._mounts_warned:
                self._mounts_warned = True
                logging.warning(
                    "arco_presence_sensor %s: cannot read %s — falling back to os.path.ismount(), "
                    "which can block on a stalled device", self.name, self.mounts_file)
            return os.path.ismount(self.mount_point)

    def _poll(self, eventtime):
        present = self._measure()
        if present != self._present:
            self._present = present
            # klippy.log only. A console line on every plug and unplug would be noise on a
            # machine whose owner is standing there holding the stick they just removed.
            logging.info("arco_presence_sensor %s: %s", self.name,
                         'connected' if present else 'disconnected')
        return eventtime + self.poll_interval

    # --- reporting ----------------------------------------------------------------------
    # The first two keys are Mainsail's and Fluidd's contract. 'source' is ours, and exists so that
    # an indicator reading False can be told apart from one that never had a source to read.
    def get_status(self, eventtime=None):
        return {'filament_detected': bool(self._present),
                'enabled': bool(self._enabled),
                'source': self._source_description()}

    def _source_description(self):
        if self.mount_point is not None:
            return 'mount:%s' % (self.mount_point,)
        if self.device_path is not None:
            return 'device:%s' % (self.device_path,)
        if self._source_missing:
            return 'unavailable:%s' % (self.printer_object,)
        return '%s.%s' % (self.printer_object, self.status_field)

    def cmd_QUERY_FILAMENT_SENSOR(self, gcmd):
        gcmd.respond_info("%s: %s (%s)" % (
            self.name, 'connected' if self._present else 'NOT connected',
            self._source_description()))

    def cmd_SET_FILAMENT_SENSOR(self, gcmd):
        enable = gcmd.get_int('ENABLE', 1)
        if self.allow_disable:
            self._enabled = bool(enable)
            return
        if not enable:
            gcmd.respond_info(
                "%s is a connection indicator, not a sensor -- there is no runout script to "
                "switch off, so it stays on. Set allow_disable: True in its "
                "[arco_presence_sensor] section to change that." % (self.name,))


def load_config_prefix(config):
    return ArcoPresenceSensor(config)
