#!/usr/bin/env python3
"""PC test of untrash-boot-health (slot confirmation only with a working
network) and untrash-pfe-firmware (PE firmware from the stock rootfs).

boot health, against a fake /sys and fake bootstate/reboot commands:
- carrier + received packets -> mark-good
- carrier without received packets is not healthy (PHY link only)
- unconfirmed slot without network -> reboot; confirmed slot -> no reboot
pfe firmware (needs inputs/test/uImage-stock-kernel1, else skipped):
- the stock pfe_12_00_2 set is extracted from the stock kernel's initramfs
  (as on NAND kernel1) and the firmware path set
- a kernel with a pfe_13 set, a broken uImage and rootfs-style input are
  refused; a cached set is used without a source
"""
import os
import gzip
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

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


def pfe(kernel, cache, fwpath):
    env = dict(os.environ, ZT_PFE_KERNEL=kernel, ZT_PFE_FWPATH=fwpath)
    return subprocess.run(["sh", os.path.join(LIB, "untrash-pfe-firmware"), cache], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def fake_kernel(path, files):
    """uImage like the stock one: stub + gzip(image with gzip(newc cpio))"""
    def entry(name, data):
        h = "070701" + "".join("%08x" % v for v in (0, 0o100644, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(name) + 1, 0))
        b = h.encode() + name.encode() + b"\0"
        b += b"\0" * (-len(b) % 4) + data
        return b + b"\0" * (-len(b) % 4)
    cpio = b"".join(entry(n, d) for n, d in files) + entry("TRAILER!!!", b"")
    image = b"\0" * 4096 + gzip.compress(cpio) + b"\0" * 64
    data = b"\xde\xad" * 512 + gzip.compress(image)
    hdr = struct.pack(">IIIIIIIBBBB32s", 0x27051956, 0, 0, len(data), 0x8000, 0x8000, zlib.crc32(data),
                      5, 2, 2, 0, b"Linux-test")
    hdr = hdr[:4] + struct.pack(">I", zlib.crc32(hdr)) + hdr[8:]
    open(path, "wb").write(hdr + data)


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

        kernel1 = os.path.join(ROOT, "inputs", "test", "uImage-stock-kernel1")
        if not os.path.isfile(kernel1):
            print("skip PE firmware tests (needs inputs/test/uImage-stock-kernel1)")
        else:
            cache, fwp = os.path.join(w, "cache"), os.path.join(w, "fwpath")
            rc = pfe(kernel1, cache, fwp)
            check("stock pfe_12_00_2 extracted from the stock kernel, firmware path set", rc == 0 and open(fwp).read() == cache and
                  sorted(os.listdir(cache)) == ["class_c2000.elf", "tmu_c2000.elf", "util_c2000.elf", "util_c2000_revA0.elf"])
            check("log on the state", "copied from the stock kernel" in open(cache + ".log").read())
            check("cached set used without a source", pfe("/nonexistent", cache, fwp) == 0)
            # rootfs1 does not contain the firmware, only the stock kernel does
            check("a stock rootfs instead of the kernel is refused",
                  pfe(os.path.join(ROOT, "inputs", "test", "stock-rootfs"), os.path.join(w, "cr"), os.path.join(w, "fpr")) != 0)
            broken = os.path.join(w, "broken.uImage")
            b = bytearray(open(kernel1, "rb").read())
            b[100000] ^= 1
            open(broken, "wb").write(b)
            check("uImage with a bad data CRC refused", pfe(broken, os.path.join(w, "cb"), os.path.join(w, "fpb")) != 0)
            p13 = os.path.join(ROOT, "inputs", "pfe-firmware")
            if os.path.isdir(p13):
                k13 = os.path.join(w, "k13.uImage")
                fake_kernel(k13, [("lib/firmware/" + f, open(os.path.join(p13, f), "rb").read()) for f in sorted(os.listdir(p13))])
                check("kernel with a pfe_13 set refused", pfe(k13, os.path.join(w, "c13"), os.path.join(w, "fp13")) != 0)
                stock = os.path.join(w, "k12.uImage")
                fw = os.path.join(cache)
                fake_kernel(stock, [("lib/firmware/" + f, open(os.path.join(fw, f), "rb").read()) for f in sorted(os.listdir(fw))])
                check("fake kernel with the stock set accepted (test kernel builder sound)",
                      pfe(stock, os.path.join(w, "c12"), os.path.join(w, "fp12")) == 0)
    print("FAILURES %d" % FAIL)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
