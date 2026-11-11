#!/usr/bin/env python3
"""PC test of pylib/untrash_bays.py (bay mapping) on fake sysfs trees:
ata2 = bay 1, detect GPIOs, PMP links, USB disks ignored,
table override, NAS520 (two bays, untrash_model.py)."""
import importlib.util
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PYLIB = os.path.join(HERE, "../rootfs/usr/lib/untrash/pylib")
sys.path.insert(0, PYLIB)
MODEL_ROOT = tempfile.mkdtemp()                 # no model: four bays, like before
os.environ["ZT_MODEL_ROOT"] = MODEL_ROOT
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


def tree(W, disks, detect):
    """disks: {sd: device path below /sys/devices}; detect: GPIO 0..3 values."""
    for sd, path in disks.items():
        os.makedirs(W + "/sys/devices/" + path, exist_ok=True)
        os.makedirs(W + "/sys/block/" + sd, exist_ok=True)
        os.symlink(W + "/sys/devices/" + path, W + "/sys/block/%s/device" % sd)
    os.makedirs(W + "/sys/class/gpio/gpiochip0", exist_ok=True)
    open(W + "/sys/class/gpio/gpiochip0/base", "w").write("0\n")
    open(W + "/sys/class/gpio/export", "w").close()
    for i, v in enumerate(detect):
        os.makedirs(W + "/sys/class/gpio/gpio%d" % i, exist_ok=True)
        open(W + "/sys/class/gpio/gpio%d/value" % i, "w").write("%d\n" % v)


def model(mid):
    """Boot cache of untrash-model for model id MID (None: unknown)."""
    os.makedirs(MODEL_ROOT + "/run/untrash", exist_ok=True)
    open(MODEL_ROOT + "/run/untrash/device.env", "w").write("MODEL_ID=%s\n" % mid if mid else "")
    import untrash_model
    untrash_model.write(MODEL_ROOT)


def load(W, table=None):
    os.environ["ZT_BAYS_SYSFS"] = W + "/sys"
    os.environ["ZT_BAYS_TABLE"] = W + "/bays.json"
    if table is not None:
        json.dump(table, open(W + "/bays.json", "w"))
    spec = importlib.util.spec_from_file_location("b", os.path.join(HERE, "../rootfs/usr/lib/untrash/pylib/untrash_bays.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


AHCI = "platform/9d000000.sata/ata%d/host%d/target%d:0:0/%d:0:0:0"
with tempfile.TemporaryDirectory() as W:
    tree(W, {"sda": AHCI % (2, 1, 1, 1), "sdb": "platform/usb/1-1/host5/target5:0:0/5:0:0:0"}, [0, 1, 1, 1])
    check("single disk on ata2 = disk1, USB ignored", load(W).bays() == {"disk1": "/dev/sda"})
with tempfile.TemporaryDirectory() as W:
    tree(W, {"sda": AHCI % (1, 0, 0, 0), "sdb": AHCI % (2, 1, 1, 1)}, [0, 1, 0, 1])
    check("ata2 = disk1, the ata1 disk onto the other populated bay (3)", load(W).bays() == {"disk1": "/dev/sdb", "disk3": "/dev/sda"})
with tempfile.TemporaryDirectory() as W:
    pmp = "platform/9d000000.sata/ata1/link1.%d/dev1.%d.0/ata_device/x/host0/target0:%d:0/0:%d:0:0"
    tree(W, {"sda": pmp % (0, 0, 0, 0), "sdb": pmp % (1, 1, 1, 1), "sdc": pmp % (2, 2, 2, 2), "sdd": AHCI % (2, 1, 1, 1)}, [0, 0, 0, 0])
    check("PMP links on ata1 in link order onto bays 2-4", load(W).bays() == {"disk1": "/dev/sdd", "disk2": "/dev/sda",
                                                                            "disk3": "/dev/sdb", "disk4": "/dev/sdc"})
    check("table override", load(W, {"ata2": "disk1", "ata1.0": "disk4", "ata1.2": "disk2"}).bays() ==
          {"disk1": "/dev/sdd", "disk2": "/dev/sdc", "disk3": "/dev/sdb", "disk4": "/dev/sda"})
with tempfile.TemporaryDirectory() as W:
    asm = "devices/platform/98000000.pcie/0000:00:00.0/0000:01:00.0/host%d/target%d:0:0/%d:0:0:0"
    tree(W, {"sda": AHCI % (1, 0, 0, 0), "sdb": AHCI % (2, 1, 1, 1),
             "sdc": asm % (2, 2, 2), "sdd": asm % (3, 3, 3)}, [0, 0, 0, 0])
    check("ASM1061 adds the two PCIe bays after SoC AHCI", load(W).bays() ==
          {"disk1": "/dev/sdb", "disk2": "/dev/sda", "disk3": "/dev/sdc", "disk4": "/dev/sdd"})
model("B203")
with tempfile.TemporaryDirectory() as W:
    tree(W, {"sda": AHCI % (1, 0, 0, 0), "sdb": AHCI % (2, 1, 1, 1)}, [0, 0, 1, 1])
    b = load(W)
    check("NAS520: two bays", b.bay_count() == 2 and b.bay_names() == ("disk1", "disk2"))
    check("NAS520: ata2 = disk1, ata1 = disk2", b.bays() == {"disk1": "/dev/sdb", "disk2": "/dev/sda"})
with tempfile.TemporaryDirectory() as W:
    tree(W, {"sda": AHCI % (1, 0, 0, 0)}, [1, 0, 0, 0])
    check("NAS520: detect GPIOs 2/3 are not bays, ata1 alone -> disk2", load(W).bays() == {"disk2": "/dev/sda"})
    check("NAS520: a table entry for bay 3 is ignored", load(W, {"ata1": "disk3"}).bays() == {"disk2": "/dev/sda"})
model("B403")
with tempfile.TemporaryDirectory() as W:
    check("NAS542: four bays", load(W).bay_count() == 4)
shutil.rmtree(MODEL_ROOT)
print("FAILURES %d" % fails)
sys.exit(1 if fails else 0)
