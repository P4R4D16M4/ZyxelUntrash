#!/usr/bin/env python3
"""Synthetic NAS542 Barebox envs for the PartnerKey tests ("any stock NAS").

  mk-test-env.py SRC_ENV OUT [--pristine] [--curr N] [--next N] [--seed S]

SRC_ENV is a real env dump (not in git, e.g. inputs/test/
mtd2-before-a.bin; the repository carries no env with device values).  The
output gets fake device values (MAC 02:5a:54:xx:xx:xx, serial, IPs) derived
from --seed, so tests never handle the real ones.
  --pristine  undo the project's July 2026 additions (V4-V6 TFTP scripts and
              config blocks; partnerkey-install-disabled-base-v3.sh), giving
              the factory shape: /bin/init ends with "boot".
  --curr/--next  set curr_bootfrom / next_bootfrom (default: unchanged)
"""
import argparse
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import envfs  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('src')
ap.add_argument('out')
ap.add_argument('--pristine', action='store_true')
ap.add_argument('--curr')
ap.add_argument('--next')
ap.add_argument('--seed', default='a')
a = ap.parse_args()

blob = open(a.src, 'rb').read()
prio, flags, files = envfs.parse(blob)
h = hashlib.sha256(a.seed.encode()).digest()
mac = lambda k: '02:5A:54:%02X:%02X:%02X' % (h[k], h[k + 1], h[k + 2])  # noqa: E731
MAC = re.compile(rb'(?i)\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b')
IP = re.compile(rb'\b(192\.168|10\.\d{1,3}|172\.(1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b')


def scrub(name, data):
    macs = []

    def m(x):
        if x.group(0) not in macs:
            macs.append(x.group(0))
        return mac(3 * (macs.index(x.group(0)) % 8)).encode()
    data = MAC.sub(m, data)
    data = IP.sub(b'10.0.0.%d' % (h[30] % 200 + 2), data)
    data = re.sub(rb'serial_number="[^"]*"', b'serial_number="S000T%08d"' % (int.from_bytes(h[:4], 'big') % 10 ** 8), data)
    return data


out = []
for name, data in files:
    if a.pristine and name.startswith('/bin/boot_zyxeluntrash'):
        continue
    if a.pristine and name == '/config':
        i = data.find(b'\n\n###############################################################################\n# ZyxelUntrash')
        assert i > 0, 'no ZyxelUntrash block in config'
        data = data[:i + 1]
    if a.pristine and name == '/bin/init':
        block = (b'# ZyxelUntrash \xe2\x80\x93 deaktivierte Basisinstallation V4\n'
                 b'if [ x$zyxeluntrash_enabled = x1 ]; then\n\t/env/bin/boot_zyxeluntrash\nelse\n\tboot\nfi')
        assert block in data, 'no V4 dispatch in init'
        data = data.replace(block, b'boot')
    if name == '/config':
        for var, val in (('curr_bootfrom', a.curr), ('next_bootfrom', a.next)):
            if val is not None:
                data, n = re.subn(rb'(?m)^%s="[^"]*"' % var.encode(), b'%s="%s"' % (var.encode(), val.encode()), data)
                assert n, var
    out.append((name, scrub(name, data)))
open(a.out, 'wb').write(envfs.pack(out, len(blob), prio, flags))
print('%s: %d files, sha256 %s' % (a.out, len(out), hashlib.sha256(open(a.out, 'rb').read()).hexdigest()[:16]))
