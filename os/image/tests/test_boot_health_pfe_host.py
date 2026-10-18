#!/usr/bin/env python3
"""PC test of untrash-boot-health (slot confirmation only with a working
network) and untrash-pfe-firmware (PE firmware from the stock rootfs).

boot health, against a fake /sys and fake bootstate/reboot commands:
- carrier + received packets -> mark-good
- carrier without received packets is not healthy (PHY link only)
- unconfirmed slot without network -> reboot; confirmed slot -> no reboot
pfe firmware (needs inputs/test/stock-rootfs/lib/firmware, else skipped):
- the stock pfe_12_00_2 set is copied and the firmware path set
- a pfe_13 set is refused; a cached set is used without a source
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
LIB = os.path.join(HERE, "..", "untrash-files", "usr", "lib", "untrash")
FAIL = 0


def check(name, ok):
    global FAIL
    print(("ok   " if ok else "FAIL ") + name, flush=True)
    FAIL += 0 if ok else 1


def health(w, carrier, rx, state):
    sysd = os.path.join(w, "sys")
    shutil.rmtree(sysd, ignore_errors=True)
    n = os.path.join(sysd, "class", "net", "eth0")
    os.makedirs(os.path.join(n, "statistics"))
    open(os.path.join(n, "carrier"), "w").write(carrier)
    open(os.path.join(n, "statistics", "rx_packets"), "w").write(str(rx))
    log = os.path.join(w, "calls")
    open(log, "w").close()
    bs = os.path.join(w, "bootstate")
    open(bs, "w").write('#!/bin/sh\necho "bootstate $*" >>%s\n[ "$1" = show ] && echo "%s"\nexit 0\n' % (log, state))
    os.chmod(bs, 0o755)
    rb = os.path.join(w, "reboot")
    open(rb, "w").write("#!/bin/sh\necho reboot >>%s\n" % log)
    os.chmod(rb, 0o755)
    env = dict(os.environ, ZT_HEALTH_SYS=sysd, ZT_HEALTH_WAIT="2", ZT_HEALTH_STEP="1", ZT_HEALTH_BOOTSTATE=bs,
               ZT_HEALTH_REBOOT=rb)
    subprocess.run(["sh", os.path.join(LIB, "untrash-boot-health")], env=env, capture_output=True, timeout=30)
    return open(log).read()


def pfe(src, cache, fwpath):
    env = dict(os.environ, ZT_PFE_SRC=src, ZT_PFE_FWPATH=fwpath)
    return subprocess.run(["sh", os.path.join(LIB, "untrash-pfe-firmware"), cache], env=env, capture_output=True).returncode


def main():
    with tempfile.TemporaryDirectory() as w:
        new = "pref=b a=3 b=2 good=a booting=b"
        c = health(w, "1", 50, new)
        check("carrier + packets: slot confirmed", "bootstate mark-good" in c and "reboot" not in c)
        c = health(w, "1", 0, new)
        check("carrier without received packets: not healthy, new slot reboots", "mark-good" not in c and "reboot" in c)
        c = health(w, "0", 50, new)
        check("no carrier, new slot: reboot", "reboot" in c)
        c = health(w, "0", 0, "pref=b a=3 b=3 good=b booting=b")
        check("no network, confirmed slot: no reboot", "reboot" not in c and "mark-good" not in c)

        stock = os.path.join(ROOT, "inputs", "test", "stock-rootfs")
        if not os.path.isfile(os.path.join(stock, "lib", "firmware", "class_c2000.elf")):
            print("skip PE firmware tests (needs inputs/test/stock-rootfs)")
        else:
            cache, fwp = os.path.join(w, "cache"), os.path.join(w, "fwpath")
            rc = pfe(stock, cache, fwp)
            check("stock pfe_12_00_2 copied, firmware path set", rc == 0 and open(fwp).read() == cache and
                  sorted(os.listdir(cache)) == ["class_c2000.elf", "tmu_c2000.elf", "util_c2000.elf", "util_c2000_revA0.elf"])
            check("cached set used without a source", pfe("/nonexistent", cache, fwp) == 0)
            p13 = os.path.join(ROOT, "inputs", "pfe-firmware")
            if os.path.isdir(p13):
                fake = os.path.join(w, "p13")
                os.makedirs(os.path.join(fake, "lib", "firmware"))
                for f in os.listdir(p13):
                    shutil.copy(os.path.join(p13, f), os.path.join(fake, "lib", "firmware", f))
                check("pfe_13 set refused", pfe(fake, os.path.join(w, "c13"), os.path.join(w, "fp13")) != 0)
    print("FAILURES %d" % FAIL)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
