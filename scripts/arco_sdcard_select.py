# Arco Unleashed - SDCARD_SELECT_FILE
#
# Copyright (C) 2026  Arco Unleashed contributors
#
# The command body below is adapted from cmd_SDCARD_PRINT_FILE in Klipper's
# klippy/extras/virtual_sdcard.py, Copyright (C) 2018 Kevin O'Connor
# <kevin@koconnor.net>, GNU GPLv3 -- it is that sequence minus the final
# do_resume(). That portion therefore stays GPL-3.0; the rest of this file may
# be distributed under the GNU AGPLv3 license (see LICENSE), which GPL-3.0
# section 13 expressly permits combining with.
#
# Re-adds the SDCARD_SELECT_FILE gcode command: load a virtual-SD gcode file
# WITHOUT starting the print (select-only; a following M24 starts it). Phrozen's
# stock display firmware expects this command; mainline Klipper v0.13 ships only
# SDCARD_PRINT_FILE (load-and-start) and SDCARD_RESET_FILE, so the select-only
# command is missing after the migration.
#
# Delivered as a standalone extra so virtual_sdcard.py stays vanilla v0.13 - the
# SDCARD_PRINT_FILE path used by Moonraker / Orca ("Upload & Print") is byte-for-
# byte untouched. This only reuses virtual_sdcard's own _reset_file / _load_file
# helpers; it is identical to SDCARD_PRINT_FILE minus the final do_resume() start.

class ArcoSdcardSelect:
    def __init__(self, config):
        self.printer = config.get_printer()
        gcode = self.printer.lookup_object('gcode')
        gcode.register_command(
            "SDCARD_SELECT_FILE", self.cmd_SDCARD_SELECT_FILE,
            desc=self.cmd_SDCARD_SELECT_FILE_help)

    cmd_SDCARD_SELECT_FILE_help = ("Load a virtual SD file without starting it "
                                   "(use M24 to start). May include subdirectories.")

    def cmd_SDCARD_SELECT_FILE(self, gcmd):
        vsd = self.printer.lookup_object('virtual_sdcard')
        if vsd.work_timer is not None:
            raise gcmd.error("SD busy")
        vsd._reset_file()
        filename = gcmd.get("FILENAME")
        if filename and filename[0] == '/':
            filename = filename[1:]
        vsd._load_file(gcmd, filename, check_subdirs=True)


def load_config(config):
    return ArcoSdcardSelect(config)
