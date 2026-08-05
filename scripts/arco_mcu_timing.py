# arco_mcu_timing.py — widen Klipper's MCU host-timing windows at RUNTIME instead of editing mcu.py.
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# This file may be distributed under the terms of the GNU AGPLv3 license (see LICENSE). It is a
# Klipper extra and therefore runs inside Klipper (GPL-3.0); GPL-3.0 section 13 expressly permits
# that combination. No Klipper code is copied here -- only three of its module-level values are
# reassigned at runtime, which is the whole point of the module.
#
# The UART toolhead MCU (MKS_THR / STM32F103) is sensitive to host-scheduling jitter; Klipper's stock
# timeouts can trip "MCU shutdown: Timer too close" during homing/probing under transient load. The
# three widened values below are Phrozen's own.
#
# Why this module exists at all: those values used to be sed'ed into klippy/mcu.py, a file Klipper
# TRACKS. That left the repo permanently dirty, and Moonraker refuses to update a dirty repo
# ("Update aborted, repo has been modified") -- so the printer could never take a Klipper update. This
# module sets the same values from klippy/extras/, which is untracked, leaving Klipper's tree pristine.
#
# Verified against the shipped Klipper (v0.13.0-699) before relying on it:
#   * mcu.RetryAsyncCommand.TIMEOUT_TIME / .RETRY_TIME are CLASS attributes, looked up per use, so
#     rebinding them affects instances created later as well as existing ones.
#   * mcu.TRSYNC_TIMEOUT is a module global read at call time (mcu.py: "expire_timeout =
#     TRSYNC_TIMEOUT"), not captured at import.
#   * No module does "from mcu import TRSYNC_TIMEOUT" -- everything does "import mcu", so there is no
#     second copy that would keep the stock value.
#
# The failure mode this guards against: if a future Klipper renames or moves any of these, a plain
# assignment would silently create a NEW unused attribute and the printer would quietly run with stock
# timings -- i.e. "Timer too close" during the next homing, with nothing pointing at the cause. So each
# target is checked to EXIST first, and Klipper refuses to start with a clear message if it does not.
# Loud and stopped beats quiet and wrong.
#
# Config:
#   [arco_mcu_timing]
#   #timeout_time: 10.0     # mcu.RetryAsyncCommand.TIMEOUT_TIME  (stock 5.0)
#   #retry_time: 1.0        # mcu.RetryAsyncCommand.RETRY_TIME    (stock 0.500)
#   #trsync_timeout: 0.1    # mcu.TRSYNC_TIMEOUT                  (stock 0.025)

import logging
import mcu

DEFAULT_TIMEOUT_TIME = 10.0
DEFAULT_RETRY_TIME = 1.0
DEFAULT_TRSYNC_TIMEOUT = 0.1


class ArcoMcuTiming:
    def __init__(self, config):
        timeout_time = config.getfloat('timeout_time', DEFAULT_TIMEOUT_TIME, above=0.)
        retry_time = config.getfloat('retry_time', DEFAULT_RETRY_TIME, above=0.)
        trsync_timeout = config.getfloat('trsync_timeout', DEFAULT_TRSYNC_TIMEOUT, above=0.)

        # Check the targets exist BEFORE writing to them. Assigning to a name Klipper no longer uses
        # would succeed silently and leave the machine on stock timings.
        missing = []
        if not hasattr(mcu, 'TRSYNC_TIMEOUT'):
            missing.append('mcu.TRSYNC_TIMEOUT')
        retry_cls = getattr(mcu, 'RetryAsyncCommand', None)
        if retry_cls is None:
            missing.append('mcu.RetryAsyncCommand')
        else:
            for attr in ('TIMEOUT_TIME', 'RETRY_TIME'):
                if not hasattr(retry_cls, attr):
                    missing.append('mcu.RetryAsyncCommand.%s' % attr)
        if missing:
            raise config.error(
                "[arco_mcu_timing]: this Klipper version no longer defines %s. The MCU timing "
                "widening was NOT applied, and homing would likely fail with 'Timer too close'. "
                "Update the arco-unleashed kit, or remove [arco_mcu_timing] and accept stock timings."
                % ', '.join(missing))

        mcu.TRSYNC_TIMEOUT = trsync_timeout
        retry_cls.TIMEOUT_TIME = timeout_time
        retry_cls.RETRY_TIME = retry_time

        # Read the values back through the same path Klipper will use, so the log proves what is
        # actually in effect rather than what we intended.
        logging.info(
            "arco_mcu_timing: TIMEOUT_TIME=%.3f RETRY_TIME=%.3f TRSYNC_TIMEOUT=%.4f (applied)",
            mcu.RetryAsyncCommand.TIMEOUT_TIME, mcu.RetryAsyncCommand.RETRY_TIME,
            mcu.TRSYNC_TIMEOUT)

        printer = config.get_printer()
        gcode = printer.lookup_object('gcode')
        gcode.register_command('ARCO_MCU_TIMING', self.cmd_ARCO_MCU_TIMING,
                               desc=self.cmd_ARCO_MCU_TIMING_help)

    cmd_ARCO_MCU_TIMING_help = "Report the MCU host-timing values currently in effect"

    def cmd_ARCO_MCU_TIMING(self, gcmd):
        gcmd.respond_info(
            "MCU host timing in effect: TIMEOUT_TIME=%.3f s, RETRY_TIME=%.3f s, "
            "TRSYNC_TIMEOUT=%.4f s (stock: 5.0 / 0.500 / 0.0250)"
            % (mcu.RetryAsyncCommand.TIMEOUT_TIME, mcu.RetryAsyncCommand.RETRY_TIME,
               mcu.TRSYNC_TIMEOUT))


def load_config(config):
    return ArcoMcuTiming(config)
