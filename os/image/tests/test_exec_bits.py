#!/usr/bin/env python3
"""Every program the image runs must be executable (no hardware needed).

2026-10-16: untrash-desk and untrash-config had lost their x bit (mode 644
since 2026-10-10).  The PC tests call them as "python3 FILE", so nothing
noticed until systemd on the NAS failed with 203/EXEC: no settings, no web
interface, an aborted stock takeover.  Checked here:
  - files with a #! line under usr/bin, usr/sbin, usr/lib/untrash (top level)
  - every Exec*= program of our units that lives in the image tree
  os/image/mkslot-erofs.sh runs this before it builds a slot.
"""
import os
import re
import sys

FILES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "untrash-files")
bad = []
for d in ("usr/bin", "usr/sbin", "usr/lib/untrash"):
    top = os.path.join(FILES, d)
    if not os.path.isdir(top):
        continue
    for n in sorted(os.listdir(top)):
        p = os.path.join(top, n)
        if not os.path.isfile(p) or os.path.islink(p):
            continue
        with open(p, "rb") as f:
            if f.read(2) != b"#!":
                continue
        if not os.access(p, os.X_OK):
            bad.append("%s/%s: has #! but is not executable" % (d, n))
units = os.path.join(FILES, "usr/lib/systemd/system")
for n in sorted(os.listdir(units)) if os.path.isdir(units) else []:
    if not n.endswith((".service", ".socket", ".timer", ".path")):
        continue
    for line in open(os.path.join(units, n)):
        m = re.match(r"\s*Exec\w*=\s*[-@:+!]*(/\S+)", line)
        if not m:
            continue
        prog = os.path.join(FILES, m.group(1).lstrip("/"))
        if os.path.isfile(prog) and not os.access(prog, os.X_OK):
            bad.append("%s: %s is not executable" % (n, m.group(1)))
for b in bad:
    print("FAIL", b)
print("exec bits:", "FAIL (%d)" % len(bad) if bad else "OK")
sys.exit(1 if bad else 0)
