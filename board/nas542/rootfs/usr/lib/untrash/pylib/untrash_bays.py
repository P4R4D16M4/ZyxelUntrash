"""Disk bays of the NAS540/NAS542 (stock DISKX_BUS_MAP: disk1..disk4) and the
NAS520 (disk1, disk2: the same board without the ASM1061, untrash_model.py).

Known on hardware: bay N is present when GPIO N-1 reads low (detect), its
power is GPIO N+7 (the loader switches it on like the stock platform_init),
and bay 1 is AHCI port 1 = ata2.  The other two bays are the ASMedia
ASM1061 PCIe AHCI controller.  On the NAS520 both bays are SoC AHCI ports
(stock intern_disk_chker: SCSI hosts 0 and 1); which one is bay 1 there is
not confirmed, the default table assumes the NAS542 wiring.  Mapping: fixed table
entries first (default ata2 -> disk1, override in
/etc/untrash/bays.json {"ata2": "disk1", "ata1.1": "disk2", ...}), then the
other internal disks in ATA port / PMP link order onto the remaining
populated bays (detect GPIOs), so a single disk or a monotonic wiring comes
out right without a table.  To be confirmed with several disks on hardware.
"""
import glob
import json
import os
import re

import untrash_model

SYS = os.environ.get("ZT_BAYS_SYSFS", "/sys")
TABLE = os.environ.get("ZT_BAYS_TABLE", "/etc/untrash/bays.json")
DEFAULT = {"ata2": "disk1"}


def bay_count():
    """2 on the NAS520, 4 on the NAS540/NAS542 and when the model is unknown."""
    return untrash_model.model()["bays"]


def bay_names():
    return tuple("disk%d" % (i + 1) for i in range(bay_count()))


def link_of(sd):
    """Internal ATA path key, None for USB/other."""
    real = os.path.realpath(os.path.join(SYS, "block", sd, "device"))
    if "/usb" in real:
        return None
    # NAS542 backplane: ASM1061 endpoint is PCI 0000:01:00.0.  Its
    # host number identifies its two SATA ports and makes ordering stable.
    if "/0000:01:00.0/" in real:
        m = re.search(r"/host(\\d+)/", real)
        return "asm1061.%s" % (m.group(1) if m else sd)
    m = re.search(r"/ata(\d+)/", real)
    if not m:
        return None
    pmp = re.search(r"/link%s\.(\d+)/" % m.group(1), real)
    return "ata%s" % m.group(1) + (".%s" % pmp.group(1) if pmp else "")


def _gpio_value(n):
    """Value of board GPIO n via sysfs (exported on demand), None if unknown."""
    try:
        base = int(open(sorted(glob.glob(os.path.join(SYS, "class/gpio/gpiochip*/base")))[0]).read())
    except (OSError, IndexError, ValueError):
        return None
    g = os.path.join(SYS, "class/gpio/gpio%d" % (base + n))
    try:
        if not os.path.isdir(g):
            with open(os.path.join(SYS, "class/gpio/export"), "w") as f:
                f.write(str(base + n))
        return int(open(os.path.join(g, "value")).read().strip())
    except (OSError, ValueError):
        return None


def populated():
    """Bays with a disk (detect GPIO low); None if the GPIOs are not readable."""
    out = []
    for i, bay in enumerate(bay_names()):
        v = _gpio_value(i)
        if v is None:
            return None
        if v == 0:
            out.append(bay)
    return out


def table():
    try:
        t = json.load(open(TABLE))
        return {k: v for k, v in t.items() if v in bay_names()}
    except (OSError, ValueError):
        return dict(DEFAULT)


def bays():
    """{"disk1": "/dev/sdb", ...} of the internal SATA disks."""
    disks = {}
    for d in sorted(glob.glob(os.path.join(SYS, "block", "sd*"))):
        sd = os.path.basename(d)
        ln = link_of(sd)
        if ln:
            disks[ln] = "/dev/" + sd
    out, fixed = {}, table()
    for ln, bay in fixed.items():
        if ln in disks:
            out[bay] = disks.pop(ln)
    names = bay_names()
    free = [b for b in (populated() or list(names)) if b not in out]
    free += [b for b in names if b not in out and b not in free]

    def key(ln):
        if ln.startswith("asm1061."):
            return (100, int(ln.partition(".")[2]) if ln.partition(".")[2].isdigit() else 0)
        a, _, p = ln[3:].partition(".")
        return (int(a), int(p or -1))
    for ln in sorted(disks, key=key):
        if free:
            out[free.pop(0)] = disks[ln]
    return dict(sorted(out.items()))
