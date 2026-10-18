#!/usr/bin/env python3
"""Compare the firmware-shared memory layout of a pfe.ko with the stock Zyxel
pfe.ko (pfe_ctrl_12_00_2, shipped together with the stock pfe_12 firmware).

  check-fw12-layout.py OUR_PFE_KO STOCK_PFE_KO

The vendor driver places every variable the PE firmware shares into sections
(.class_dmem_sh, .tmu_dmem_sh, .util_dmem_sh, .class_pe_lmem_sh, .util_ddr_sh)
whose layout must match the firmware byte for byte.  The firmware ELFs are
stripped; the stock driver is the reference that is known to work with the
stock firmware.  Exit 0 = every shared symbol has the stock offset and size
and every section has the stock size.
"""
import re
import subprocess
import sys

SECTIONS = (".class_dmem_sh", ".tmu_dmem_sh", ".util_dmem_sh", ".class_pe_lmem_sh", ".util_ddr_sh")
OBJDUMP = "arm-linux-gnueabihf-objdump"
# CONFIG_PFE_CTRL_FW12 keeps the pfe_12-sized slot under another symbol name
ALIAS = {"gTNLCtx_fw12_slot": "gTNLCtx"}


def syms(ko, sec):
    out = subprocess.run([OBJDUMP, "-t", "-j", sec, ko], capture_output=True, text=True).stdout
    d = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 6 and re.fullmatch(r"[0-9a-f]{8}", f[0]) and f[3] == sec and f[-1] != sec:
            name = ALIAS.get(f[-1], f[-1])
            d[name] = (int(f[0], 16), int(f[4], 16))
    return d


def size(ko, sec):
    out = subprocess.run(["readelf", "-S", "-W", ko], capture_output=True, text=True).stdout
    for line in out.splitlines():
        f = line.replace("[ ", "[").split()
        if sec in f:
            return int(f[f.index(sec) + 4], 16)
    return None


def main(ours, stock):
    bad = 0
    for sec in SECTIONS:
        a, b = syms(stock, sec), syms(ours, sec)
        sa, sb = size(stock, sec), size(ours, sec)
        diffs = [n for n in sorted(set(a) | set(b)) if a.get(n) != b.get(n)]
        ok = not diffs and sa == sb
        print("%s %-20s stock %s / ours %s bytes, %d symbols" % ("ok  " if ok else "FAIL", sec, sa, sb, len(b)))
        for n in diffs:
            print("     %-28s stock %-14s ours %s" % (n, "%#x/%d" % a[n] if n in a else "-", "%#x/%d" % b[n] if n in b else "-"))
        bad += not ok
    print("FW12 LAYOUT %s" % ("MATCH" if not bad else "MISMATCH"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
