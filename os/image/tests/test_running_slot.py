#!/usr/bin/env python3
"""untrash-desk running_slot(): which system slot runs, so an update never
writes over it (2026-10-25: a partition boot has no boot.env; the old code
then always chose slot a and overwrote the running slot of untrash-2)."""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = os.path.join(HERE, "..", "untrash-files")
R = tempfile.mkdtemp(prefix="ut-slot-")
L = os.path.join(FILES, "usr/lib/untrash")
os.environ.update(ZT_DESK_TEST="1", ZT_DESK_ROOT=R, ZT_IMPORT_TOOL=os.path.join(FILES, "usr/sbin/untrash-import-zyxel"),
                  ZT_ADBLOCK_TOOL=os.path.join(L, "untrash-adblock"), ZT_TV_DIR=os.path.join(R, "tv"))
sys.path.insert(0, os.path.join(FILES, "usr/lib/untrash/pylib"))
loader = importlib.machinery.SourceFileLoader("desk", os.path.join(FILES, "usr/lib/untrash/untrash-desk"))
spec = importlib.util.spec_from_loader("desk", loader)
desk = importlib.util.module_from_spec(spec)
loader.exec_module(desk)

fails = 0


def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name)
    fails += not ok


def setup(cmdline=None, bootenv=None):
    for p, v in ((R + "/proc/cmdline", cmdline), (R + "/run/untrash/boot.env", bootenv)):
        if os.path.exists(p):
            os.unlink(p)
        if v is not None:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(v)


setup()
check("nothing known: no slot (an update is refused)", desk.running_slot() == (None, "partition"))
setup("console=ttyS0 init=/usr/lib/untrash/untrash-init untrash.verity=1,x,y untrash.part=ut-sys-a\n")
check("partition boot through the initrd: untrash.part=ut-sys-a", desk.running_slot() == ("a", "partition"))
setup('root=/dev/dm-0 dm-mod.waitfor=PARTLABEL=ut-sys-b dm-mod.create="untrash-root,,,ro,0 1 verity"\n')
check("partition boot without initrd: dm-mod.waitfor=PARTLABEL=ut-sys-b", desk.running_slot() == ("b", "partition"))
setup("untrash.part=ut-sys-c\n")
check("an unknown partition name is not a slot", desk.running_slot() == (None, "partition"))
setup("untrash.part=ut-sys-a\n", "ZT_BOOT=file\nZT_SLOT=b\nZT_HOST=/run/untrash/host\n")
check("slot file boot: boot.env wins", desk.running_slot() == ("b", "file"))
setup(None, "ZT_BOOT=file\nZT_SLOT=stick\n")
check("started from the stick: no slot", desk.running_slot() == (None, "file"))
print("RUNNING SLOT TEST %s (%d failures)" % ("PASS" if not fails else "FAIL", fails))
sys.exit(1 if fails else 0)
