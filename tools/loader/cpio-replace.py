#!/usr/bin/env python3
"""Replace the contents of regular files in a newc cpio archive.

  cpio-replace.py IN.cpio OUT.cpio PATH=FILE [PATH=FILE ...]

Every other entry (device nodes, links, modes, mtimes, order) is copied
byte for byte, so a loader initramfs can be repaired without re-packing
it from an extracted tree (which loses /dev nodes as non-root).
"""
import sys

def pad4(n):
    return (n + 3) & ~3

def entries(b):
    o = 0
    while True:
        h = b[o:o + 110]
        if h[:6] != b'070701':
            raise SystemExit(f'bad cpio header at {o:#x}')
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        namesize, filesize = f[11], f[6]
        name = b[o + 110:o + 110 + namesize - 1].decode()
        d0 = pad4(o + 110 + namesize)
        yield o, h, name, b[o + 110:d0], b[d0:d0 + filesize], f
        o = pad4(d0 + filesize)
        if name == 'TRAILER!!!':
            return

def main(a):
    src, dst, *reps = a
    rep = dict(r.split('=', 1) for r in reps)
    b = open(src, 'rb').read()
    out = bytearray(); done = set()
    for o, h, name, namefield, data, f in entries(b):
        if name in rep:
            if (f[1] & 0o170000) != 0o100000:
                raise SystemExit(f'{name} is not a regular file')
            data = open(rep[name], 'rb').read()
            h = h[:54] + b'%08X' % len(data) + h[62:]
            done.add(name)
        out += h + namefield
        out += b'\0' * (pad4(len(out)) - len(out))
        out += data
        out += b'\0' * (pad4(len(out)) - len(out))
    missing = set(rep) - done
    if missing:
        raise SystemExit(f'not in archive: {sorted(missing)}')
    out += b'\0' * ((-len(out)) % 512)
    open(dst, 'wb').write(out)

if __name__ == '__main__':
    main(sys.argv[1:])
