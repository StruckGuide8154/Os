"""Executable USB power/latch persistence contract for Track 10."""


class BoardPowerModel:
    def __init__(self):
        self.vbus = False
        self.suspended = False
        self.latch = True
        self.boot_counter = 0
        self.rollback_floor = 0

    def power_on(self):
        if self.vbus:
            return False
        self.vbus = True
        self.suspended = False
        self.latch = False
        self.boot_counter += 1
        return True

    def lock(self):
        if not self.vbus:
            return False
        self.latch = True
        return True

    def suspend(self, port_power_retained):
        if not self.vbus:
            return "absent"
        if not port_power_retained:
            self.unplug()
            return "device-loss"
        self.suspended = True
        return "retained"

    def resume(self):
        if not self.vbus:
            return "device-loss"
        self.suspended = False
        return "resumed"

    def unplug(self):
        self.vbus = False
        self.suspended = False
        self.latch = True

    def ratchet_floor(self, new_floor):
        if new_floor <= self.rollback_floor:
            return False
        self.rollback_floor = new_floor
        return True

